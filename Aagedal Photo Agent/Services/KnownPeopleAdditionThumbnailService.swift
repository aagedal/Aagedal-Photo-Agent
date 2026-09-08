import Foundation
import CoreGraphics
import ImageIO

nonisolated struct KnownPeopleAdditionThumbnails: Sendable {
    let embeddings: [UUID: Data]
    let representative: Data?
}

/// Owns decoding, centered aspect-fill rendering and JPEG encoding away from MainActor.
/// Encoded inputs are immutable snapshots; no AppKit images cross the actor boundary.
actor KnownPeopleAdditionThumbnailService {
    static let shared = KnownPeopleAdditionThumbnailService()

    func prepare(embeddingSources: [UUID: Data], representativeSource: Data?) throws -> KnownPeopleAdditionThumbnails {
        try Task.checkCancellation()
        var embeddings: [UUID: Data] = [:]
        for (id, data) in embeddingSources {
            try Task.checkCancellation()
            embeddings[id] = autoreleasepool { encode(data, size: 80, quality: 0.7) }
        }
        try Task.checkCancellation()
        let representative = representativeSource.flatMap { data in
            autoreleasepool { encode(data, size: nil, quality: 0.85) }
        }
        try Task.checkCancellation()
        return KnownPeopleAdditionThumbnails(embeddings: embeddings, representative: representative)
    }

    private func encode(_ data: Data, size: Int?, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { return nil }
        let output: CGImage
        if let size {
            guard let context = CGContext(data: nil, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let scale = max(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2,
                                           y: (CGFloat(size) - height) / 2, width: width, height: height))
            guard let resized = context.makeImage() else { return nil }
            output = resized
        } else {
            output = image
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
