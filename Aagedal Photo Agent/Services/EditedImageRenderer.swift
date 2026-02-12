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

    static func renderJPEG(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) throws {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = CameraRawApproximation.ciContext.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) else {
            throw RenderError.encodeFailed
        }

        let destinationURL = outputURL(for: sourceURL, in: outputFolder)
        try data.write(to: destinationURL, options: .atomic)
    }

    @discardableResult
    static func renderHDR(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) throws -> URL {
        let output = try loadAndProcess(from: sourceURL, cameraRaw: cameraRaw)

        let hdrColorSpace = CGColorSpace(name: CGColorSpace.displayP3_HLG) ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CameraRawApproximation.ciContext

        // Attempt JPEG XL via CGImageDestination (future macOS versions may add encoder support)
        let jxlURL = outputURLForJXL(for: sourceURL, in: outputFolder)
        let jxlUTType = UTType("public.jxl")
        if let jxlType = jxlUTType,
           let cgImage = ctx.createCGImage(output, from: output.extent, format: .RGBAh, colorSpace: hdrColorSpace),
           let dest = CGImageDestinationCreateWithURL(jxlURL as CFURL, jxlType.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            if CGImageDestinationFinalize(dest) {
                return jxlURL
            }
        }

        // 10-bit HEIF with Display P3 HLG for HDR
        let heifURL = outputURLForHEIF(for: sourceURL, in: outputFolder)
        let heifData = try ctx.heif10Representation(
            of: output,
            colorSpace: hdrColorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9]
        )
        try heifData.write(to: heifURL, options: .atomic)
        return heifURL
    }

    static func outputURL(for sourceURL: URL, in outputFolder: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let filenameBase = ext.isEmpty ? base : "\(base)_\(ext)"
        return outputFolder
            .appendingPathComponent(filenameBase)
            .appendingPathExtension("jpg")
    }

    static func outputURLForJXL(for sourceURL: URL, in outputFolder: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let filenameBase = ext.isEmpty ? base : "\(base)_\(ext)"
        return outputFolder
            .appendingPathComponent(filenameBase)
            .appendingPathExtension("jxl")
    }

    static func outputURLForHEIF(for sourceURL: URL, in outputFolder: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let filenameBase = ext.isEmpty ? base : "\(base)_\(ext)"
        return outputFolder
            .appendingPathComponent(filenameBase)
            .appendingPathExtension("heic")
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
