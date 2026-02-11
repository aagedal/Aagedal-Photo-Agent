import CoreImage
import ImageIO

enum EditedImageRenderer {

    static func renderJPEG(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) throws {
        guard let input = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }

        // Read EXIF orientation from the source file
        var exifOrientation = 1
        if let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] as? Int {
            exifOrientation = orientation
        }

        let output = CameraRawApproximation.applyWithCrop(to: input, settings: cameraRaw, exifOrientation: exifOrientation)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = CameraRawApproximation.ciContext.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) else {
            throw RenderError.encodeFailed
        }

        let destinationURL = outputURL(for: sourceURL, in: outputFolder)
        try data.write(to: destinationURL, options: .atomic)
    }

    static func outputURL(for sourceURL: URL, in outputFolder: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let filenameBase = ext.isEmpty ? base : "\(base)_\(ext)"
        return outputFolder
            .appendingPathComponent(filenameBase)
            .appendingPathExtension("jpg")
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "Could not decode source image."
            case .encodeFailed:
                return "Could not encode JPEG output."
            }
        }
    }
}
