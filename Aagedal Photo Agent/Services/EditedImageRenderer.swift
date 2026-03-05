import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum EditedImageRenderer {

    private static func loadAndProcess(from sourceURL: URL, cameraRaw: CameraRawSettings?) throws -> CIImage {
        guard let input = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }

        var exifOrientation = 1
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] as? Int {
            exifOrientation = orientation
        }

        return CameraRawApproximation.applyWithCrop(to: input, settings: cameraRaw, exifOrientation: exifOrientation)
    }

    // MARK: - Unified Render

    /// Renders the image to the configured format. Returns the output URL.
    @discardableResult
    static func render(from sourceURL: URL, cameraRaw: CameraRawSettings?, isHDR: Bool, outputFolder: URL) throws -> URL {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)

        if isHDR {
            return try renderHDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
        } else {
            return try renderSDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
        }
    }

    // MARK: - SDR Encoding

    private static func renderSDRFormat(_ ciImage: CIImage, sourceURL: URL, outputFolder: URL) throws -> URL {
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
            try encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: false, encoder: .avif)

        case .jxl:
            try encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: false, encoder: .jxl)
        }

        return destURL
    }

    // MARK: - HDR Encoding

    private static func renderHDRFormat(_ ciImage: CIImage, sourceURL: URL, outputFolder: URL) throws -> URL {
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
            try encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: true, encoder: .avif)

        case .jxl:
            try encodeViaFFmpeg(ciImage, to: destURL, quality: quality, isHDR: true, encoder: .jxl)

        case .tiff16bit:
            guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: .RGBA16, colorSpace: hdrColorSpace) else {
                throw RenderError.encodeFailed
            }
            try writeTIFF(cgImage: cgImage, to: destURL)

        case .png16bit:
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

    /// Encode via FFmpeg: render to a temporary 16-bit TIFF, then transcode to the target format.
    private static func encodeViaFFmpeg(_ ciImage: CIImage, to destURL: URL, quality: Double, isHDR: Bool, encoder: FFmpegEncoder) throws {
        let ctx = CameraRawApproximation.ciContext

        // Write a 16-bit TIFF intermediate to preserve full quality/HDR data
        let tempDir = FileManager.default.temporaryDirectory
        let tempTIFF = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
        defer { try? FileManager.default.removeItem(at: tempTIFF) }

        let colorSpace: CGColorSpace
        let format: CIFormat
        if isHDR {
            colorSpace = CGColorSpace(name: CGColorSpace.displayP3_HLG) ?? CGColorSpace(name: CGColorSpace.displayP3)!
            format = .RGBA16
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            format = .RGBA8
        }

        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent, format: format, colorSpace: colorSpace) else {
            throw RenderError.encodeFailed
        }
        try writeTIFF(cgImage: cgImage, to: tempTIFF)

        switch encoder {
        case .avif:
            try FFmpegService.encodeAVIF(input: tempTIFF.path, output: destURL.path, quality: quality, isHDR: isHDR)
        case .jxl:
            try FFmpegService.encodeJXL(input: tempTIFF.path, output: destURL.path, quality: quality, isHDR: isHDR)
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

    static func renderJPEG(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) throws {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = CameraRawApproximation.ciContext.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) else {
            throw RenderError.encodeFailed
        }
        let destinationURL = outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
        try data.write(to: destinationURL, options: .atomic)
    }

    @discardableResult
    static func renderHDR(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) throws -> URL {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)
        return try renderHDRFormat(output, sourceURL: sourceURL, outputFolder: outputFolder)
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
