import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os

nonisolated private let editedRendererLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "EditedImageRenderer"
)

nonisolated struct AdvancedExportRenderedArtifact: @unchecked Sendable {
    let referenceImage: CGImage
    let outputURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

nonisolated enum EditedImageRenderer {

    /// Fixed color target for rendered RAW archives. Keeping it independent of general
    /// export preferences makes JPEG XL and TIFF archives consistent HDR masters.
    static let rawArchiveConversionGamut: TargetColorGamut = .rec2020
    static let rawArchiveConversionColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

    private static func loadAndProcess(
        from sourceURL: URL,
        cameraRaw: CameraRawSettings?,
        rawDecodeProfile: RAWDecodeProfile? = nil
    ) throws -> CIImage {
        let input: CIImage
        var effectiveSettings = cameraRaw

        let rawExtensions: Set<String> = ["raw", "cr2", "cr3", "nef", "nrw", "arw", "raf", "dng", "rw2", "orf", "pef", "srw"]
        if rawExtensions.contains(sourceURL.pathExtension.lowercased()) {
            // Full-quality CIRAWFilter decode for export (no draft mode). Always decodes
            // with full EDR headroom; SDR output is rolled off by the tone pipeline.
            if let rawResult = FullScreenImageCache.loadRAWImage(
                from: sourceURL,
                draftMode: false,
                decodeProfile: rawDecodeProfile
            ) {
                input = rawResult.image
                // Synthesize settings for unedited RAWs so the SDR output tonemap still
                // applies, then propagate as-shot WB so renderOffscreen uses the correct
                // reference.
                var settings = effectiveSettings ?? CameraRawSettings()
                settings.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                settings.asShotNeutralTint = Double(rawResult.neutralTint)
                settings.sourceHasHDRHeadroom = true
                effectiveSettings = settings
            } else {
                // Fallback to generic CIImage for unsupported RAW formats
                guard let ciImage = CIImage(contentsOf: sourceURL, options: [
                    .applyOrientationProperty: true,
                    .expandToHDR: true,
                    .toneMapHDRtoSDR: false
                ]) else {
                    throw RenderError.unreadableImage
                }
                input = ciImage
            }
        } else {
            guard let ciImage = CIImage(contentsOf: sourceURL, options: [
                .applyOrientationProperty: true,
                .expandToHDR: true,
                .toneMapHDRtoSDR: false
            ]) else {
                throw RenderError.unreadableImage
            }
            input = ciImage
        }

        var exifOrientation = 1
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] as? Int {
            exifOrientation = orientation
        }

        return CameraRawApproximation.applyWithCrop(to: input, settings: effectiveSettings, exifOrientation: exifOrientation)
    }

    // MARK: - Unified Render

    /// Closure type for copying metadata from a source image to a rendered destination.
    /// Callers pass `MetadataWriteEngine.copyMetadataToRenderedFile` so the
    /// renderer stays decoupled from the active write engine.
    typealias MetadataCopier = @Sendable (URL, URL) async throws -> Void

    /// Renders the image to the configured format. Returns the output URL.
    /// `metadataCopier` is required to populate IPTC/XMP/EXIF on the rendered file.
    @discardableResult
    static func render(
        from sourceURL: URL,
        cameraRaw: CameraRawSettings?,
        isHDR: Bool,
        outputFolder: URL,
        configuration: AdvancedExportConfiguration? = nil,
        outputFilenameSuffix: String = "",
        metadataCopier: MetadataCopier? = nil
    ) async throws -> URL {
        let processed = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        let output = limitedForExport(
            processed,
            maximumPixelSize: (configuration?.resolutionLimit ?? currentResolutionLimit)
                .maximumPixelSize
        )

        let destURL: URL
        if isHDR {
            destURL = try await renderHDRFormat(
                output,
                sourceURL: sourceURL,
                outputFolder: outputFolder,
                configuration: configuration,
                outputFilenameSuffix: outputFilenameSuffix
            )
        } else {
            destURL = try await renderSDRFormat(
                output,
                sourceURL: sourceURL,
                outputFolder: outputFolder,
                configuration: configuration,
                outputFilenameSuffix: outputFilenameSuffix
            )
        }
        if let metadataCopier {
            do {
                try await metadataCopier(sourceURL, destURL)
            } catch {
                editedRendererLog.error(
                    "metadataCopier failed for \(sourceURL.lastPathComponent, privacy: .public) → \(destURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return destURL
    }

    /// Produces the two inputs needed by Advanced Export without touching the user's
    /// destination: an uncompressed, developed reference and a real encoded artifact.
    /// The artifact is full resolution so its file size and compression behavior match
    /// the final export; only the in-memory reference is reduced for display.
    static func renderAdvancedPreview(
        from sourceURL: URL,
        cameraRaw: CameraRawSettings?,
        isHDR: Bool,
        configuration: AdvancedExportConfiguration,
        outputFolder: URL,
        maxReferencePixelSize: CGFloat,
        cachedReferenceImage: CGImage? = nil
    ) async throws -> AdvancedExportRenderedArtifact {
        let processed = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        let output = limitedForExport(
            processed,
            maximumPixelSize: configuration.resolutionLimit.maximumPixelSize
        )
        let reference: CGImage
        if let cachedReferenceImage {
            reference = cachedReferenceImage
        } else {
            reference = try makeReferencePreview(
                from: output,
                isHDR: isHDR,
                configuration: configuration,
                maxPixelSize: maxReferencePixelSize
            )
        }

        let outputURL: URL
        if isHDR {
            outputURL = try await renderHDRFormat(
                output,
                sourceURL: sourceURL,
                outputFolder: outputFolder,
                configuration: configuration
            )
        } else {
            outputURL = try await renderSDRFormat(
                output,
                sourceURL: sourceURL,
                outputFolder: outputFolder,
                configuration: configuration
            )
        }
        return AdvancedExportRenderedArtifact(
            referenceImage: reference,
            outputURL: outputURL,
            pixelWidth: Int(output.extent.width.rounded()),
            pixelHeight: Int(output.extent.height.rounded())
        )
    }

    /// Returns a source-accurate crop for the Advanced Export loupe. The crop is
    /// rendered at one source pixel per output pixel after applying the resolution cap.
    static func makeAdvancedReferenceLoupe(
        from sourceURL: URL,
        cameraRaw: CameraRawSettings?,
        isHDR: Bool,
        configuration: AdvancedExportConfiguration,
        normalizedPoint: CGPoint,
        pixelSize: Int
    ) throws -> CGImage {
        let processed = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        let output = limitedForExport(
            processed,
            maximumPixelSize: configuration.resolutionLimit.maximumPixelSize
        )
        return try makeLoupeCrop(
            from: output,
            isHDR: isHDR,
            configuration: configuration,
            normalizedPoint: normalizedPoint,
            pixelSize: pixelSize
        )
    }

    static func makeLoupeCrop(
        from image: CIImage,
        isHDR: Bool,
        configuration: AdvancedExportConfiguration,
        normalizedPoint: CGPoint,
        pixelSize: Int
    ) throws -> CGImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            throw RenderError.encodeFailed
        }

        let cropWidth = min(CGFloat(pixelSize), extent.width)
        let cropHeight = min(CGFloat(pixelSize), extent.height)
        let unitX = min(1, max(0, normalizedPoint.x))
        let unitY = min(1, max(0, normalizedPoint.y))
        let centerX = extent.minX + unitX * extent.width
        // SwiftUI reports hover locations from the top; Core Image's origin is bottom-left.
        let centerY = extent.minY + (1 - unitY) * extent.height
        let originX = min(
            extent.maxX - cropWidth,
            max(extent.minX, centerX - cropWidth / 2)
        )
        let originY = min(
            extent.maxY - cropHeight,
            max(extent.minY, centerY - cropHeight / 2)
        )
        let cropRect = CGRect(
            x: originX,
            y: originY,
            width: cropWidth,
            height: cropHeight
        ).integral
        let colorSpace = isHDR
            ? configuration.hdrGamut.hdrLinearColorSpace
            : configuration.sdrGamut.sdrColorSpace
        let format: CIFormat = isHDR ? .RGBAh : .RGBA8

        guard let crop = CameraRawApproximation.ciContext.createCGImage(
            image,
            from: cropRect,
            format: format,
            colorSpace: colorSpace
        ) else {
            throw RenderError.encodeFailed
        }
        return crop
    }

    private static var currentResolutionLimit: ExportResolutionLimit {
        let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportResolutionLimit)
        return ExportResolutionLimit(rawValue: stored ?? "") ?? .original
    }

    static func limitedForExport(
        _ image: CIImage,
        maximumPixelSize: Int?
    ) -> CIImage {
        guard let maximumPixelSize else { return image }
        let extent = image.extent
        let longestEdge = max(extent.width, extent.height)
        guard longestEdge > CGFloat(maximumPixelSize),
              longestEdge.isFinite,
              extent.width > 0,
              extent.height > 0 else {
            return image
        }

        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let scale = CGFloat(maximumPixelSize) / longestEdge
        let width = max(1, (extent.width * scale).rounded())
        let height = max(1, (extent.height * scale).rounded())
        return normalized
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func makeReferencePreview(
        from image: CIImage,
        isHDR: Bool,
        configuration: AdvancedExportConfiguration,
        maxPixelSize: CGFloat
    ) throws -> CGImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else {
            throw RenderError.encodeFailed
        }

        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let longestEdge = max(extent.width, extent.height)
        let scale = min(1, maxPixelSize / longestEdge)
        let preview = scale < 1
            ? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : normalized
        let colorSpace = isHDR
            ? configuration.hdrGamut.hdrLinearColorSpace
            : configuration.sdrGamut.sdrColorSpace
        let format: CIFormat = isHDR ? .RGBAh : .RGBA8

        guard let cgImage = CameraRawApproximation.ciContext.createCGImage(
            preview,
            from: preview.extent,
            format: format,
            colorSpace: colorSpace
        ) else {
            throw RenderError.encodeFailed
        }
        return cgImage
    }

    // MARK: - SDR Encoding

    private static func renderSDRFormat(
        _ ciImage: CIImage,
        sourceURL: URL,
        outputFolder: URL,
        configuration: AdvancedExportConfiguration? = nil,
        outputFilenameSuffix: String = ""
    ) async throws -> URL {
        let format = configuration?.sdrFormat
            ?? ExportFormatSDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? "")
            ?? .jpeg
        let quality = configuration?.sdrQuality
            ?? (UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double)
            ?? 0.92
        let gamut = configuration?.sdrGamut
            ?? TargetColorGamut(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutSDR) ?? "")
            ?? .sRGB

        let destURL = outputURL(
            for: sourceURL,
            in: outputFolder,
            extension: format.fileExtension,
            filenameSuffix: outputFilenameSuffix
        )
        let colorSpace = gamut.sdrColorSpace
        let ctx = CameraRawApproximation.ciContext

        switch format {
        case .jpeg:
            try writeJPEGWithSourceProperties(
                ciImage: ciImage,
                sourceURL: sourceURL,
                destURL: destURL,
                colorSpace: colorSpace,
                quality: quality,
                ctx: ctx
            )

        case .png:
            guard let data = ctx.pngRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)

        case .tiff:
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(
                cgImage: cgImage,
                to: destURL,
                compression: configuration?.tiffCompression
            )

        case .heic:
            guard let data = ctx.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)

        case .avif:
            try writeAVIF(
                ciImage: ciImage,
                destURL: destURL,
                colorSpace: colorSpace,
                quality: quality,
                isHDR: false,
                ctx: ctx
            )

        case .avifFFmpeg:
            try await encodeAVIFViaFFmpeg(
                ciImage,
                to: destURL,
                quality: quality,
                isHDR: false,
                gamut: gamut
            )

        case .jxl:
            try await encodeJXLViaFFmpeg(
                ciImage,
                to: destURL,
                quality: quality,
                isHDR: false,
                gamut: gamut
            )
        }

        return destURL
    }

    /// Write the rendered CIImage as a JPEG with EXIF/TIFF/IPTC/GPS segments copied from
    /// the source. `CIContext.jpegRepresentation` produces a JPEG with no APP1 segment, so
    /// downstream metadata libraries (SwiftExif) fail with `segmentNotFound` when they try
    /// to read it. Routing through `CGImageDestination` and seeding it with the source's
    /// ImageIO properties gives the JPEG a parseable metadata structure. The `metadataCopier`
    /// step (SwiftExif) then merges in the source's full IPTC/XMP and strips CRS / IFD1 /
    /// orientation. XMP is intentionally left to the copier; ImageIO doesn't expose XMP via
    /// the property dict (it lives behind a separate `CGImageMetadata` API) and SwiftExif
    /// is the authoritative writer for XMP namespaces we care about.
    private static func writeJPEGWithSourceProperties(
        ciImage: CIImage,
        sourceURL: URL,
        destURL: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        ctx: CIContext
    ) throws {
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw RenderError.encodeFailed
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Pixels are already upright after CIRAWFilter + applyOrientationProperty.
            kCGImagePropertyOrientation: 1
        ]
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let metadataKeys: [CFString] = [
                kCGImagePropertyExifDictionary,
                kCGImagePropertyTIFFDictionary,
                kCGImagePropertyIPTCDictionary,
                kCGImagePropertyGPSDictionary,
                kCGImagePropertyExifAuxDictionary,
                kCGImagePropertyMakerAppleDictionary
            ]
            for key in metadataKeys {
                if let value = sourceProps[key] {
                    properties[key] = value
                }
            }
        }

        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.encodeFailed
        }
    }

    // MARK: - HDR Encoding

    private static func renderHDRFormat(
        _ ciImage: CIImage,
        sourceURL: URL,
        outputFolder: URL,
        configuration: AdvancedExportConfiguration? = nil,
        outputFilenameSuffix: String = ""
    ) async throws -> URL {
        let format = configuration?.hdrFormat
            ?? ExportFormatHDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? "")
            ?? .jxl
        let quality = configuration?.hdrQuality
            ?? (UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualityHDR) as? Double)
            ?? 0.92
        let gamut = configuration?.hdrGamut
            ?? TargetColorGamut(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutHDR) ?? "")
            ?? .displayP3

        let destURL = outputURL(
            for: sourceURL,
            in: outputFolder,
            extension: format.fileExtension,
            filenameSuffix: outputFilenameSuffix
        )
        let hdrColorSpace = gamut.hdrHLGColorSpace
        let ctx = CameraRawApproximation.ciContext

        switch format {
        case .jpegGainMap:
            try writeHDRGainMapJPEG(
                hdrImage: ciImage,
                destURL: destURL,
                colorSpace: gamut.hdrLinearColorSpace,
                quality: quality,
                ctx: ctx
            )

        case .heic10bit:
            let data = try ctx.heif10Representation(of: ciImage, colorSpace: hdrColorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ])
            try data.write(to: destURL, options: .atomic)

        case .avif10bit:
            try writeAVIF(
                ciImage: ciImage,
                destURL: destURL,
                colorSpace: hdrColorSpace,
                quality: quality,
                isHDR: true,
                ctx: ctx
            )

        case .avifFFmpeg10bit:
            try await encodeAVIFViaFFmpeg(
                ciImage,
                to: destURL,
                quality: quality,
                isHDR: true,
                gamut: gamut
            )

        case .jxl:
            try await encodeJXLViaFFmpeg(
                ciImage,
                to: destURL,
                quality: quality,
                isHDR: true,
                gamut: gamut
            )

        case .tiff16bit:
            // Half-float linear preserves HDR values >1.0 without needing OETF application
            let linearP3 = gamut.hdrLinearColorSpace
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBAh, colorSpace: linearP3) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(
                cgImage: cgImage,
                to: destURL,
                compression: configuration?.tiffCompression
            )

        case .png16bit:
            // PNG is integer-only; use HLG for best-effort HDR (viewer support varies)
            guard let data = ctx.pngRepresentation(of: ciImage, format: .RGBA16, colorSpace: hdrColorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)
        }

        return destURL
    }

    /// Author a standards-based Adaptive HDR JPEG.
    ///
    /// ImageIO derives a backward-compatible SDR base and an ISO gain map from the
    /// rendered HDR image. The normal post-render metadata merge then adds the source's
    /// EXIF/IPTC/XMP while preserving the JPEG's gain-map segments.
    static func writeHDRGainMapJPEG(
        hdrImage: CIImage,
        destURL: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        ctx: CIContext
    ) throws {
        let extent = hdrImage.extent
        guard extent.width > 0, extent.height > 0 else {
            throw RenderError.encodeFailed
        }

        let measuredHeadroom = max(
            1,
            CameraRawApproximation.contentHeadroom(of: hdrImage, extent: extent)
        )
        // Images returned by the Metal edit pipeline contain extended-range pixels but
        // have no source headroom metadata. Materialize a half-float, extended-linear
        // CGImage and stamp its measured headroom before asking ImageIO to generate the
        // SDR base and ISO gain map.
        guard let renderedHDR = ctx.createCGImage(
            hdrImage,
            from: extent,
            format: .RGBAh,
            colorSpace: colorSpace
        ) else {
            throw RenderError.encodeFailed
        }
        let headroomTaggedCG = CGImageCreateCopyWithContentHeadroom(
            measuredHeadroom,
            renderedHDR
        ) ?? renderedHDR
        guard let destination = CGImageDestinationCreateWithURL(
            destURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw RenderError.encodeFailed
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
            kCGImageDestinationEncodeRequestOptions: [
                kCGImageDestinationEncodeBaseIsSDR: false
            ]
        ]
        CGImageDestinationAddImage(
            destination,
            headroomTaggedCG,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.encodeFailed
        }
    }

    // MARK: - AVIF Encoding

    /// Encode AVIF directly through macOS Image I/O.
    ///
    /// An 8-bit CGImage produces an SDR AVIF with the requested ICC profile. A half-float
    /// CGImage in an HLG color space makes Image I/O select a 10-bit AV1 payload and retain
    /// the HDR transfer function, color primaries, and content headroom.
    static func writeAVIF(
        ciImage: CIImage,
        destURL: URL,
        colorSpace: CGColorSpace,
        quality: Double,
        isHDR: Bool,
        ctx: CIContext
    ) throws {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite,
              let cgImage = ctx.createCGImage(
                  ciImage,
                  from: extent,
                  format: isHDR ? .RGBAh : .RGBA8,
                  colorSpace: colorSpace
              ),
              let destination = CGImageDestinationCreateWithURL(
                  destURL as CFURL,
                  "public.avif" as CFString,
                  1,
                  nil
              ) else {
            throw RenderError.encodeFailed
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality)),
            // The render pipeline has already applied the source orientation.
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.encodeFailed
        }
    }

    /// Render to a lossless intermediate, then encode AVIF with FFmpeg/libaom.
    /// HDR uses a 16-bit HLG PNG; SDR uses an 8-bit TIFF.
    private static func encodeAVIFViaFFmpeg(
        _ ciImage: CIImage,
        to destURL: URL,
        quality: Double,
        isHDR: Bool,
        gamut: TargetColorGamut
    ) async throws {
        let ctx = CameraRawApproximation.ciContext
        let tempDir = FileManager.default.temporaryDirectory

        if isHDR {
            let tempPNG = tempDir
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")
            defer { try? FileManager.default.removeItem(at: tempPNG) }

            guard let pngData = ctx.pngRepresentation(
                of: ciImage,
                format: .RGBA16,
                colorSpace: gamut.hdrHLGColorSpace,
                options: [:]
            ) else {
                throw RenderError.encodeFailed
            }
            try pngData.write(to: tempPNG, options: .atomic)
            try await FFmpegService.encodeAVIF(
                input: tempPNG.path,
                output: destURL.path,
                quality: quality,
                isHDR: true,
                gamut: gamut
            )
        } else {
            let tempTIFF = tempDir
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("tiff")
            defer { try? FileManager.default.removeItem(at: tempTIFF) }

            guard let cgImage = ctx.createCGImage(
                ciImage,
                from: ciImage.extent,
                format: .RGBA8,
                colorSpace: gamut.sdrColorSpace
            ) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(cgImage: cgImage, to: tempTIFF)
            try await FFmpegService.encodeAVIF(
                input: tempTIFF.path,
                output: destURL.path,
                quality: quality,
                isHDR: false,
                gamut: gamut
            )
        }
    }

    // MARK: - JPEG XL Encoding

    /// Render to a temporary intermediate, then transcode to JPEG XL with FFmpeg.
    /// HDR uses a 16-bit HLG PNG; SDR uses an 8-bit TIFF.
    private static func encodeJXLViaFFmpeg(
        _ ciImage: CIImage,
        to destURL: URL,
        quality: Double,
        isHDR: Bool,
        gamut: TargetColorGamut
    ) async throws {
        let ctx = CameraRawApproximation.ciContext
        let tempDir = FileManager.default.temporaryDirectory

        if isHDR {
            let tempPNG = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            defer { try? FileManager.default.removeItem(at: tempPNG) }

            let hdrColorSpace = gamut.hdrHLGColorSpace
            guard let pngData = ctx.pngRepresentation(of: ciImage, format: .RGBA16, colorSpace: hdrColorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try pngData.write(to: tempPNG, options: .atomic)
            try await FFmpegService.encodeJXL(
                input: tempPNG.path,
                output: destURL.path,
                quality: quality,
                isHDR: true
            )
        } else {
            let tempTIFF = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
            defer { try? FileManager.default.removeItem(at: tempTIFF) }

            let colorSpace = gamut.sdrColorSpace
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(cgImage: cgImage, to: tempTIFF)
            try await FFmpegService.encodeJXL(
                input: tempTIFF.path,
                output: destURL.path,
                quality: quality,
                isHDR: false
            )
        }
    }

    /// Encode a 16-bit-per-channel JPEG XL from a 16-bit PNG intermediate. Unlike the
    /// ordinary SDR JPEG XL export path, this never quantizes the rendered pixels to 8-bit.
    private static func encode16BitJXL(
        _ ciImage: CIImage,
        to destURL: URL,
        quality: Double,
        colorSpace: CGColorSpace
    ) async throws {
        let ctx = CameraRawApproximation.ciContext
        let tempPNG = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: tempPNG) }

        guard let pngData = ctx.pngRepresentation(
            of: ciImage,
            format: .RGBA16,
            colorSpace: colorSpace,
            options: [:]
        ) else {
            throw RenderError.encodeFailed
        }
        try pngData.write(to: tempPNG, options: .atomic)
        try await FFmpegService.encodeJXL(
            input: tempPNG.path,
            output: destURL.path,
            quality: quality,
            isHDR: true,
            force16Bit: true
        )
    }

    // MARK: - TIFF Writer

    private static func writeTIFF(
        cgImage: CGImage,
        to url: URL,
        compression requestedCompression: TIFFCompression? = nil
    ) throws {
        let compression: TIFFCompression
        if let requestedCompression {
            compression = requestedCompression
        } else {
            let compressionRaw = UserDefaults.standard.string(
                forKey: UserDefaultsKeys.exportTIFFCompression
            ) ?? "lzw"
            compression = TIFFCompression(rawValue: compressionRaw) ?? .lzw
        }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }

        var properties: [CFString: Any] = [:]
        var tiffProperties: [CFString: Any] = [:]

        switch compression {
        case .none:
            tiffProperties[kCGImagePropertyTIFFCompression] = 1
        case .lzw:
            tiffProperties[kCGImagePropertyTIFFCompression] = 5
        case .zip:
            tiffProperties[kCGImagePropertyTIFFCompression] = 8
        }

        properties[kCGImagePropertyTIFFDictionary] = tiffProperties

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.encodeFailed
        }
    }

    // MARK: - Output Folder Naming

    /// Returns a format-aware subfolder name like "Signed_JPEG" or "Edited_HEIC_10bit".
    static func formatFolderName(
        prefix: String,
        isHDR: Bool,
        configuration: AdvancedExportConfiguration? = nil
    ) -> String {
        let formatName: String
        if isHDR {
            let format = configuration?.hdrFormat
                ?? ExportFormatHDR(
                    rawValue: UserDefaults.standard.string(
                        forKey: UserDefaultsKeys.exportFormatHDR
                    ) ?? ""
                )
                ?? .jxl
            formatName = switch format {
            case .jpegGainMap: "JPEG_HDR_Gain_Map"
            case .heic10bit: "HEIC_10bit"
            case .avif10bit: "AVIF_10bit"
            case .avifFFmpeg10bit: "AVIF_FFmpeg_10bit"
            case .jxl: "JPEG_XL"
            case .tiff16bit: "TIFF_16bit"
            case .png16bit: "PNG_16bit"
            }
        } else {
            let format = configuration?.sdrFormat
                ?? ExportFormatSDR(
                    rawValue: UserDefaults.standard.string(
                        forKey: UserDefaultsKeys.exportFormatSDR
                    ) ?? ""
                )
                ?? .jpeg
            formatName = switch format {
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .tiff: "TIFF"
            case .heic: "HEIC"
            case .avif: "AVIF"
            case .avifFFmpeg: "AVIF_FFmpeg"
            case .jxl: "JPEG_XL"
            }
        }
        return "\(prefix)_\(formatName)"
    }

    /// The user's configured export location mode, read live from `UserDefaults`.
    /// Read directly (not via a `SettingsViewModel` instance) so changes take effect
    /// without an app restart — matching the convention used by `formatFolderName`.
    static var currentLocationMode: ExportLocationMode {
        ExportLocationMode(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportLocationMode) ?? "") ?? .formatSubfolder
    }

    /// Resolves the destination folder for a single exported file based on the user's
    /// configured `ExportLocationMode` (read live from `UserDefaults`).
    /// - Parameters:
    ///   - rootFolder: the source folder the export was initiated from.
    ///   - formatPrefix: prefix used for `.formatSubfolder` naming (e.g. "Signed", "Edited").
    ///   - askedFolder: the folder the user picked for `.askOnSave` (resolved once per batch).
    static func resolveOutputFolder(
        sourceURL: URL,
        rootFolder: URL,
        isHDR: Bool,
        formatPrefix: String,
        askedFolder: URL?,
        configuration: AdvancedExportConfiguration? = nil
    ) -> URL {
        switch configuration?.locationMode ?? currentLocationMode {
        case .sameAsOriginal:
            return sourceURL.deletingLastPathComponent()
        case .customSubfolder:
            let customName = configuration?.customSubfolderName
                ?? UserDefaults.standard.string(
                    forKey: UserDefaultsKeys.exportCustomSubfolderName
                )
                ?? "Exports"
            return customSubfolder(in: rootFolder, name: customName)
        case .formatSubfolder:
            return rootFolder.appendingPathComponent(
                formatFolderName(
                    prefix: formatPrefix,
                    isHDR: isHDR,
                    configuration: configuration
                ),
                isDirectory: true
            )
        case .askOnSave:
            return askedFolder ?? rootFolder
        }
    }

    /// Resolves the `.customSubfolder` destination from a user-entered name, extracted
    /// as a pure function so the path-containment guard is unit-testable.
    ///
    /// The Settings UI offers a single "Sub-folder Name" field, so the destination must
    /// stay inside the source folder. A name is taken verbatim (nested names like
    /// `Edited/2026` are honored) *unless* it resolves outside `rootFolder` — e.g.
    /// `../..`, an absolute path, or a name that climbs out via `..`. Such names would
    /// otherwise silently write exports over unrelated files outside the source folder,
    /// so they fall back to a safe `Exports` sub-folder. An empty name also defaults to
    /// `Exports`.
    static func customSubfolder(in rootFolder: URL, name: String) -> URL {
        let safeDefault = rootFolder.appendingPathComponent("Exports", isDirectory: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return safeDefault }

        // An absolute path escapes immediately; reject before it replaces rootFolder.
        guard !trimmed.hasPrefix("/") else { return safeDefault }

        // `standardizedFileURL` resolves `.`/`..` lexically (no disk access), so an
        // escaping name collapses to a path outside rootFolder that the prefix check
        // below catches.
        let candidate = rootFolder.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
        let root = rootFolder.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return safeDefault }
        return candidate
    }

    // MARK: - Output URL

    static func outputURL(
        for sourceURL: URL,
        in outputFolder: URL,
        extension ext: String,
        filenameSuffix: String = ""
    ) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent + filenameSuffix
        return outputFolder
            .appendingPathComponent(base)
            .appendingPathExtension(ext)
    }

    /// Returns a non-existing output URL by appending " 2", " 3", … when needed.
    static func uniqueOutputURL(for sourceURL: URL, in outputFolder: URL, extension ext: String) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = outputFolder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputFolder
                .appendingPathComponent("\(baseName) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    /// Legacy helper — returns JPEG output URL for compatibility
    static func outputURL(for sourceURL: URL, in outputFolder: URL) -> URL {
        outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
    }

    // MARK: - Legacy API

    static func renderJPEG(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL, metadataCopier: MetadataCopier? = nil) async throws {
        // JPEG output is always SDR — force SDR render mode so the tone pipeline
        // rolls HDR headroom off into display range instead of clipping it.
        var sdrSettings = cameraRaw
        sdrSettings?.hdrEditMode = 0
        let output = try loadAndProcess(from: sourceURL, cameraRaw: sdrSettings)
        let gamut = TargetColorGamut(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutSDR) ?? "") ?? .sRGB
        let colorSpace = gamut.sdrColorSpace
        let quality = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double ?? 0.92
        let destinationURL = outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
        try writeJPEGWithSourceProperties(
            ciImage: output,
            sourceURL: sourceURL,
            destURL: destinationURL,
            colorSpace: colorSpace,
            quality: quality,
            ctx: CameraRawApproximation.ciContext
        )
        if let metadataCopier {
            do {
                try await metadataCopier(sourceURL, destinationURL)
            } catch {
                editedRendererLog.error(
                    "metadataCopier failed for \(sourceURL.lastPathComponent, privacy: .public) → \(destinationURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    @discardableResult
    static func renderHDR(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) async throws -> URL {
        // Force HDR render mode so headroom passes through to the HDR encode.
        var hdrSettings = cameraRaw ?? CameraRawSettings()
        hdrSettings.hdrEditMode = 1
        let output = try loadAndProcess(from: sourceURL, cameraRaw: hdrSettings)
        return try await renderHDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
    }

    /// Converts a RAW source to an unedited Rec. 2020 PQ HDR, 16-bit-per-channel JPEG XL.
    /// Only the selected RAW decode profile is applied; current develop settings and the
    /// general SDR/HDR gamut settings do not affect the archive.
    @discardableResult
    static func convertRAWTo16BitJXL(
        from sourceURL: URL,
        decodeProfile: RAWDecodeProfile,
        destinationFolder: URL,
        metadataCopier: MetadataCopier? = nil
    ) async throws -> URL {
        guard SupportedImageFormats.isRaw(url: sourceURL) else {
            throw RenderError.rawSourceRequired
        }

        // Always bypass the SDR output tone map so the RAW decoder's scene-referred
        // highlight headroom reaches the Rec. 2020 PQ encode.
        var archiveSettings = CameraRawSettings()
        archiveSettings.hdrEditMode = 1
        let output = try loadAndProcess(
            from: sourceURL,
            cameraRaw: archiveSettings,
            rawDecodeProfile: decodeProfile
        )
        let quality = UserDefaults.standard.object(
            forKey: UserDefaultsKeys.exportQualityHDR
        ) as? Double ?? 0.92
        let destinationURL = RAWArchiveService.uniqueDestinationURL(
            for: sourceURL,
            in: destinationFolder,
            extension: "jxl"
        )

        try await encode16BitJXL(
            output,
            to: destinationURL,
            quality: quality,
            colorSpace: rawArchiveConversionColorSpace
        )

        if let metadataCopier {
            do {
                try await metadataCopier(sourceURL, destinationURL)
            } catch {
                editedRendererLog.error(
                    "metadataCopier failed for \(sourceURL.lastPathComponent, privacy: .public) → \(destinationURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return destinationURL
    }

    /// Converts a RAW source to a losslessly compressed, unedited 16-bit Rec. 2020 PQ
    /// TIFF. Only the requested RAW decode profile is applied.
    @discardableResult
    static func convertRAWTo16BitTIFF(
        from sourceURL: URL,
        decodeProfile: RAWDecodeProfile,
        destinationFolder: URL,
        metadataCopier: MetadataCopier? = nil
    ) async throws -> URL {
        guard SupportedImageFormats.isRaw(url: sourceURL) else {
            throw RenderError.rawSourceRequired
        }

        var archiveSettings = CameraRawSettings()
        archiveSettings.hdrEditMode = 1
        let output = try loadAndProcess(
            from: sourceURL,
            cameraRaw: archiveSettings,
            rawDecodeProfile: decodeProfile
        )
        let destinationURL = RAWArchiveService.uniqueDestinationURL(
            for: sourceURL,
            in: destinationFolder,
            extension: "tiff"
        )
        let context = CameraRawApproximation.ciContext
        guard let cgImage = context.createCGImage(
            output,
            from: output.extent,
            format: .RGBA16,
            colorSpace: rawArchiveConversionColorSpace
        ) else {
            throw RenderError.encodeFailed
        }
        try writeTIFF(cgImage: cgImage, to: destinationURL, compression: .lzw)

        if let metadataCopier {
            do {
                try await metadataCopier(sourceURL, destinationURL)
            } catch {
                editedRendererLog.error(
                    "metadataCopier failed for \(sourceURL.lastPathComponent, privacy: .public) → \(destinationURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return destinationURL
    }

    enum SaveAsFormat {
        case jpeg
        case png

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            }
        }
    }

    /// Render and save next to the original file in a specific format (JPEG or PNG).
    /// Returns the output URL. Handles name collisions by appending a number.
    @discardableResult
    static func saveAs(from sourceURL: URL, cameraRaw: CameraRawSettings?, format: SaveAsFormat, destinationFolder: URL? = nil, metadataCopier: MetadataCopier? = nil) async throws -> URL {
        // Save As always renders SDR (JPEG/PNG) — force SDR render mode so HDR-edited
        // images tonemap into display range instead of clipping.
        var sdrSettings = cameraRaw
        sdrSettings?.hdrEditMode = 0
        let output = try loadAndProcess(from: sourceURL, cameraRaw: sdrSettings)
        let gamut = TargetColorGamut(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutSDR) ?? "") ?? .sRGB
        let colorSpace = gamut.sdrColorSpace
        let ctx = CameraRawApproximation.ciContext

        let parentFolder = destinationFolder ?? sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var destURL = parentFolder.appendingPathComponent(baseName).appendingPathExtension(format.fileExtension)

        // Handle name collision
        var counter = 2
        while FileManager.default.fileExists(atPath: destURL.path) {
            destURL = parentFolder.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(format.fileExtension)
            counter += 1
        }

        switch format {
        case .jpeg:
            let quality = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double ?? 0.92
            try writeJPEGWithSourceProperties(
                ciImage: output,
                sourceURL: sourceURL,
                destURL: destURL,
                colorSpace: colorSpace,
                quality: quality,
                ctx: ctx
            )

        case .png:
            guard let data = ctx.pngRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)
        }

        if let metadataCopier {
            do {
                try await metadataCopier(sourceURL, destURL)
            } catch {
                editedRendererLog.error(
                    "metadataCopier failed for \(sourceURL.lastPathComponent, privacy: .public) → \(destURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return destURL
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case encodeFailed
        case rawSourceRequired

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "Could not decode source image."
            case .encodeFailed:
                return "Could not encode output image."
            case .rawSourceRequired:
                return "The 16-bit JPEG XL conversion requires a RAW source image."
            }
        }
    }
}
