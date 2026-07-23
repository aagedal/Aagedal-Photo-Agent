import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os

nonisolated private let editedRendererLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "EditedImageRenderer"
)

nonisolated enum EditedImageRenderer {

    /// Fixed color target for the dedicated RAW conversion command. Keeping it independent
    /// of general export preferences makes every converted file a consistent HDR master.
    static let rawJXLConversionGamut: TargetColorGamut = .rec2020
    static let rawJXLConversionColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

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
    static func render(from sourceURL: URL, cameraRaw: CameraRawSettings?, isHDR: Bool, outputFolder: URL, metadataCopier: MetadataCopier? = nil) async throws -> URL {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)

        let destURL: URL
        if isHDR {
            destURL = try await renderHDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
        } else {
            destURL = try await renderSDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
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

    // MARK: - SDR Encoding

    private static func renderSDRFormat(_ ciImage: CIImage, sourceURL: URL, outputFolder: URL) async throws -> URL {
        let format = ExportFormatSDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? "") ?? .jpeg
        let quality = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double ?? 0.92
        let gamut = TargetColorGamut(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutSDR) ?? "") ?? .sRGB

        let destURL = outputURL(for: sourceURL, in: outputFolder, extension: format.fileExtension)
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
            try writeTIFF(cgImage: cgImage, to: destURL)

        case .heic:
            guard let data = ctx.heifRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)

        case .avif:
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: false, encoder: .avif, gamut: gamut)

        case .jxl:
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: false, encoder: .jxl, gamut: gamut)
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

    private static func renderHDRFormat(_ ciImage: CIImage, sourceURL: URL, outputFolder: URL) async throws -> URL {
        let format = ExportFormatHDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? "") ?? .jxl
        let quality = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualityHDR) as? Double ?? 0.92
        let gamut = TargetColorGamut(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportColorGamutHDR) ?? "") ?? .displayP3

        let destURL = outputURL(for: sourceURL, in: outputFolder, extension: format.fileExtension)
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
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: true, encoder: .avif, gamut: gamut)

        case .jxl:
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: true, encoder: .jxl, gamut: gamut)

        case .tiff16bit:
            // Half-float linear preserves HDR values >1.0 without needing OETF application
            let linearP3 = gamut.hdrLinearColorSpace
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBAh, colorSpace: linearP3) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(cgImage: cgImage, to: destURL)

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

    // MARK: - FFmpeg Encoding

    private enum FFmpegEncoder {
        case avif
        case jxl
    }

    /// Encode via FFmpeg: render to a temporary intermediate, then transcode to the target format.
    /// HDR uses a HEIC intermediate (heif10Representation correctly applies HLG OETF).
    /// SDR uses a TIFF intermediate.
    private static func encodeViaFFmpeg(_ ciImage: CIImage, to destURL: URL, quality: Double, isHDR: Bool, encoder: FFmpegEncoder, gamut: TargetColorGamut) async throws {
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

            switch encoder {
            case .avif:
                try await FFmpegService.encodeAVIF(input: tempPNG.path, output: destURL.path, quality: quality, isHDR: true)
            case .jxl:
                try await FFmpegService.encodeJXL(input: tempPNG.path, output: destURL.path, quality: quality, isHDR: true)
            }
        } else {
            let tempTIFF = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
            defer { try? FileManager.default.removeItem(at: tempTIFF) }

            let colorSpace = gamut.sdrColorSpace
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(cgImage: cgImage, to: tempTIFF)

            switch encoder {
            case .avif:
                try await FFmpegService.encodeAVIF(input: tempTIFF.path, output: destURL.path, quality: quality, isHDR: false)
            case .jxl:
                try await FFmpegService.encodeJXL(input: tempTIFF.path, output: destURL.path, quality: quality, isHDR: false)
            }
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

    private static func writeTIFF(cgImage: CGImage, to url: URL) throws {
        let compressionRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportTIFFCompression) ?? "lzw"
        let compression = TIFFCompression(rawValue: compressionRaw) ?? .lzw

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
    static func formatFolderName(prefix: String, isHDR: Bool) -> String {
        let formatName: String
        if isHDR {
            let format = ExportFormatHDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? "") ?? .jxl
            formatName = switch format {
            case .jpegGainMap: "JPEG_HDR_Gain_Map"
            case .heic10bit: "HEIC_10bit"
            case .avif10bit: "AVIF_10bit"
            case .jxl: "JPEG_XL"
            case .tiff16bit: "TIFF_16bit"
            case .png16bit: "PNG_16bit"
            }
        } else {
            let format = ExportFormatSDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? "") ?? .jpeg
            formatName = switch format {
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .tiff: "TIFF"
            case .heic: "HEIC"
            case .avif: "AVIF"
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
        askedFolder: URL?
    ) -> URL {
        switch currentLocationMode {
        case .sameAsOriginal:
            return sourceURL.deletingLastPathComponent()
        case .customSubfolder:
            let customName = UserDefaults.standard.string(forKey: UserDefaultsKeys.exportCustomSubfolderName) ?? "Exports"
            return customSubfolder(in: rootFolder, name: customName)
        case .formatSubfolder:
            return rootFolder.appendingPathComponent(formatFolderName(prefix: formatPrefix, isHDR: isHDR), isDirectory: true)
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

    /// Resolves the destination for the fixed-format RAW conversion command. It follows
    /// the user's normal export-location policy, but the format-subfolder name must not
    /// depend on whichever general SDR/HDR format happens to be selected in Settings.
    static func resolveRAWJXLConversionFolder(
        sourceURL: URL,
        rootFolder: URL,
        askedFolder: URL?
    ) -> URL {
        switch currentLocationMode {
        case .sameAsOriginal:
            return sourceURL.deletingLastPathComponent()
        case .customSubfolder:
            let customName = UserDefaults.standard.string(
                forKey: UserDefaultsKeys.exportCustomSubfolderName
            ) ?? "Exports"
            return customSubfolder(in: rootFolder, name: customName)
        case .formatSubfolder:
            return rootFolder.appendingPathComponent(
                "Converted_JPEG_XL_16bit_HDR_Rec2020_PQ",
                isDirectory: true
            )
        case .askOnSave:
            return askedFolder ?? rootFolder
        }
    }

    // MARK: - Output URL

    static func outputURL(for sourceURL: URL, in outputFolder: URL, extension ext: String) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
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

    /// Converts a RAW source to a Rec. 2020 PQ HDR, 16-bit-per-channel JPEG XL while
    /// applying the current develop settings. The selected decode profile applies only
    /// to this conversion; the general SDR/HDR gamut settings do not affect it.
    @discardableResult
    static func convertRAWTo16BitJXL(
        from sourceURL: URL,
        cameraRaw: CameraRawSettings?,
        decodeProfile: RAWDecodeProfile,
        destinationFolder: URL,
        metadataCopier: MetadataCopier? = nil
    ) async throws -> URL {
        guard SupportedImageFormats.isRaw(url: sourceURL) else {
            throw RenderError.rawSourceRequired
        }

        // Always bypass the SDR output tone map so the RAW decoder's scene-referred
        // highlight headroom reaches the Rec. 2020 PQ encode.
        var hdrSettings = cameraRaw ?? CameraRawSettings()
        hdrSettings.hdrEditMode = 1
        let output = try loadAndProcess(
            from: sourceURL,
            cameraRaw: hdrSettings,
            rawDecodeProfile: decodeProfile
        )
        let quality = UserDefaults.standard.object(
            forKey: UserDefaultsKeys.exportQualityHDR
        ) as? Double ?? 0.92
        let destinationURL = uniqueOutputURL(
            for: sourceURL,
            in: destinationFolder,
            extension: "jxl"
        )

        try await encode16BitJXL(
            output,
            to: destinationURL,
            quality: quality,
            colorSpace: rawJXLConversionColorSpace
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
