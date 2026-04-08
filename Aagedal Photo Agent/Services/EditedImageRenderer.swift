import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated enum EditedImageRenderer {

    private static func loadAndProcess(from sourceURL: URL, cameraRaw: CameraRawSettings?) throws -> CIImage {
        let input: CIImage
        var effectiveSettings = cameraRaw

        let rawExtensions: Set<String> = ["raw", "cr2", "cr3", "nef", "nrw", "arw", "raf", "dng", "rw2", "orf", "pef", "srw"]
        if rawExtensions.contains(sourceURL.pathExtension.lowercased()) {
            // Full-quality CIRAWFilter decode for export (no draft mode)
            if let rawResult = FullScreenImageCache.loadRAWImage(from: sourceURL, draftMode: false) {
                input = rawResult.image
                // Propagate as-shot WB so renderOffscreen uses the correct reference
                effectiveSettings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                effectiveSettings?.asShotNeutralTint = Double(rawResult.neutralTint)
            } else {
                // Fallback to generic CIImage for unsupported RAW formats
                guard let ciImage = CIImage(contentsOf: sourceURL, options: [
                    .applyOrientationProperty: true,
                    .toneMapHDRtoSDR: false
                ]) else {
                    throw RenderError.unreadableImage
                }
                input = ciImage
            }
        } else {
            guard let ciImage = CIImage(contentsOf: sourceURL, options: [
                .applyOrientationProperty: true,
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
    /// Pass `ExifToolService.copyMetadataToRenderedFile` to use the persistent process.
    typealias MetadataCopier = @Sendable (URL, URL) async -> Void

    /// Renders the image to the configured format. Returns the output URL.
    /// When `metadataCopier` is provided (e.g. from ExifToolService), it uses the persistent
    /// ExifTool process instead of spawning a fresh one — significantly faster for batch renders.
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
            await metadataCopier(sourceURL, destURL)
        } else {
            await copyMetadata(from: sourceURL, to: destURL)
        }
        return destURL
    }

    // MARK: - SDR Encoding

    private static func renderSDRFormat(_ ciImage: CIImage, sourceURL: URL, outputFolder: URL) async throws -> URL {
        let format = ExportFormatSDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatSDR) ?? "") ?? .jpeg
        let quality = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualitySDR) as? Double ?? 0.92

        let destURL = outputURL(for: sourceURL, in: outputFolder, extension: format.fileExtension)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CameraRawApproximation.ciContext

        switch format {
        case .jpeg:
            guard let data = ctx.jpegRepresentation(of: ciImage, colorSpace: colorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)

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
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: false, encoder: .avif)

        case .jxl:
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: false, encoder: .jxl)
        }

        return destURL
    }

    // MARK: - HDR Encoding

    private static func renderHDRFormat(_ ciImage: CIImage, sourceURL: URL, outputFolder: URL) async throws -> URL {
        let format = ExportFormatHDR(rawValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.exportFormatHDR) ?? "") ?? .jxl
        let quality = UserDefaults.standard.object(forKey: UserDefaultsKeys.exportQualityHDR) as? Double ?? 0.92

        let destURL = outputURL(for: sourceURL, in: outputFolder, extension: format.fileExtension)
        let hdrColorSpace = CGColorSpace(name: CGColorSpace.displayP3_HLG) ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CameraRawApproximation.ciContext

        switch format {
        case .heic10bit:
            let data = try ctx.heif10Representation(of: ciImage, colorSpace: hdrColorSpace, options: [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ])
            try data.write(to: destURL, options: .atomic)

        case .avif10bit:
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: true, encoder: .avif)

        case .jxl:
            try await encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: true, encoder: .jxl)

        case .tiff16bit:
            // Half-float linear preserves HDR values >1.0 without needing OETF application
            let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpace(name: CGColorSpace.displayP3)!
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

    // MARK: - FFmpeg Encoding

    private enum FFmpegEncoder {
        case avif
        case jxl
    }

    /// Encode via FFmpeg: render to a temporary intermediate, then transcode to the target format.
    /// HDR uses a HEIC intermediate (heif10Representation correctly applies HLG OETF).
    /// SDR uses a TIFF intermediate.
    private static func encodeViaFFmpeg(_ ciImage: CIImage, to destURL: URL, quality: Double, isHDR: Bool, encoder: FFmpegEncoder) async throws {
        let ctx = CameraRawApproximation.ciContext
        let tempDir = FileManager.default.temporaryDirectory

        if isHDR {
            let tempPNG = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            defer { try? FileManager.default.removeItem(at: tempPNG) }

            let hdrColorSpace = CGColorSpace(name: CGColorSpace.displayP3_HLG) ?? CGColorSpace(name: CGColorSpace.displayP3)!
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

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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

    // MARK: - Output URL

    static func outputURL(for sourceURL: URL, in outputFolder: URL, extension ext: String) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let sourceExt = sourceURL.pathExtension.lowercased()
        let filenameBase = sourceExt.isEmpty ? base : "\(base)_\(sourceExt)"
        return outputFolder
            .appendingPathComponent(filenameBase)
            .appendingPathExtension(ext)
    }

    /// Legacy helper — returns JPEG output URL for compatibility
    static func outputURL(for sourceURL: URL, in outputFolder: URL) -> URL {
        outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
    }

    // MARK: - Legacy API

    static func renderJPEG(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL, metadataCopier: MetadataCopier? = nil) async throws {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = CameraRawApproximation.ciContext.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) else {
            throw RenderError.encodeFailed
        }
        let destinationURL = outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
        try data.write(to: destinationURL, options: .atomic)
        if let metadataCopier {
            await metadataCopier(sourceURL, destinationURL)
        } else {
            await copyMetadata(from: sourceURL, to: destinationURL)
        }
    }

    @discardableResult
    static func renderHDR(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) async throws -> URL {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        return try await renderHDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
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
    static func saveAs(from sourceURL: URL, cameraRaw: CameraRawSettings?, format: SaveAsFormat, metadataCopier: MetadataCopier? = nil) async throws -> URL {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CameraRawApproximation.ciContext

        let parentFolder = sourceURL.deletingLastPathComponent()
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
            guard let data = ctx.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)

        case .png:
            guard let data = ctx.pngRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace, options: [:]) else {
                throw RenderError.encodeFailed
            }
            try data.write(to: destURL, options: .atomic)
        }

        if let metadataCopier {
            await metadataCopier(sourceURL, destURL)
        } else {
            await copyMetadata(from: sourceURL, to: destURL)
        }
        return destURL
    }

    // MARK: - Metadata Copy

    /// Resolve ExifTool path respecting user settings (bundled / homebrew / custom).
    private static var exifToolPath: String? {
        let sourceRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.exifToolSource) ?? "bundled"

        switch sourceRaw {
        case "homebrew":
            for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] {
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
            return nil
        case "custom":
            if let customPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.exifToolCustomPath),
               FileManager.default.isExecutableFile(atPath: customPath) {
                return customPath
            }
            return nil
        default: // "bundled"
            if let bundledDir = Bundle.main.path(forResource: "ExifTool", ofType: nil) {
                let path = (bundledDir as NSString).appendingPathComponent("exiftool")
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
            if let path = Bundle.main.path(forResource: "exiftool", ofType: nil) { return path }
            // Fallback to Homebrew if bundled not found
            for path in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] {
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
            return nil
        }
    }

    /// Copy all metadata from source to rendered destination by spawning a one-off ExifTool process.
    /// Prefer `ExifToolService.copyMetadataToRenderedFile(from:to:)` when a persistent process is available.
    private static func copyMetadata(from source: URL, to destination: URL) async {
        guard let exiftool = exifToolPath else { return }

        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: exiftool),
                arguments: [
                    "-m",
                    "-charset", "iptc=UTF8",
                    "-TagsFromFile", source.path,
                    "-all:all",
                    "-IPTC:CodedCharacterSet=UTF8",
                    "--XMP-crs:all",
                    "--IFD1:all",
                    "--ICC_Profile:all",
                    "-Orientation#=1",
                    "-overwrite_original",
                    destination.path
                ]
            )
        } catch {
            // Metadata copy is best-effort
        }
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "Could not decode source image."
            case .encodeFailed:
                return "Could not encode output image."
            }
        }
    }
}
