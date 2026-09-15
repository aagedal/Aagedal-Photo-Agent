import Foundation
import CoreGraphics
import ImageIO

nonisolated struct KnownPeopleAdditionThumbnails: Sendable {
    let embeddings: [UUID: Data]
    let representative: Data?
}

/// Immutable source locations for the optional model-independent enrollment crop.
nonisolated struct KnownPeopleUpgradeCropSource: Sendable {
    let embeddingID: UUID
    let imageURL: URL
    let faceRect: CGRect
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

    /// Re-open originals only when the user opted in. A square crop with generous face margin
    /// can be re-detected/re-aligned by a future model; today's 80 px display thumbnails cannot.
    func prepareUpgradeSources(_ sources: [KnownPeopleUpgradeCropSource]) throws -> [UUID: Data] {
        try Task.checkCancellation()
        var result: [UUID: Data] = [:]
        var cachedURL: URL?
        var cachedImage: CGImage?
        for source in sources {
            try Task.checkCancellation()
            if cachedURL != source.imageURL {
                cachedURL = source.imageURL
                cachedImage = orientedWorkingImage(at: source.imageURL, maxPixelSize: 4_096)
            }
            guard let image = cachedImage else { continue }
            var crop = squareFaceCrop(from: image, rect: source.faceRect)
            // Very small faces in a large original may need a larger working decode.
            if let initialCrop = crop, min(initialCrop.width, initialCrop.height) < 160,
               let larger = orientedWorkingImage(at: source.imageURL, maxPixelSize: 8_192) {
                cachedImage = larger
                crop = squareFaceCrop(from: larger, rect: source.faceRect)
            }
            guard let crop, min(crop.width, crop.height) >= 160,
                  let data = encodeUpgradeCrop(crop) else { continue }
            result[source.embeddingID] = data
        }
        try Task.checkCancellation()
        return result
    }

    private func orientedWorkingImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    private func squareFaceCrop(from image: CGImage, rect: CGRect) -> CGImage? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1, rect.maxY <= 1 else { return nil }
        let side = min(1, max(rect.width, rect.height) * 2)
        let x = min(max(rect.midX - side / 2, 0), 1 - side)
        let y = min(max(rect.midY - side / 2, 0), 1 - side)
        let pixels = CGRect(x: x * CGFloat(image.width),
                            y: (1 - y - side) * CGFloat(image.height),
                            width: side * CGFloat(image.width),
                            height: side * CGFloat(image.height)).integral
        return image.cropping(to: pixels)
    }

    private func encodeUpgradeCrop(_ crop: CGImage) -> Data? {
        let size = 320
        guard let context = CGContext(data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let output = context.makeImage() else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
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
