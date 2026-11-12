import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Vision's instances for one image, reduced to what a SAM box prompt needs: each instance's
/// padded bounds and a coarse coverage grid for hit-testing clicks. Building it costs one Vision
/// pass; looking up a click afterwards is a few array reads, which a live drag preview needs.
nonisolated struct VisionInstanceIndex: Sendable {
    /// Grid cells per side. Rows run top to bottom; the grid spans the whole (stretched) image.
    static let gridSide = 256

    struct Instance: Sendable {
        /// Coverage per grid cell, 0...255.
        var coverage: [UInt8]
        /// Top-left normalized bounds of the covered pixels (coverage ≥ 0.5).
        var bounds: CGRect
    }

    var instances: [Instance]

    /// The padded bounds of the instance under `point`, or nil when none covers it or the instance
    /// is (nearly) the whole frame, which would constrain nothing and is the foreground model's
    /// known misfire. A soft boundary click still counts, as in click-to-select.
    func promptBox(at point: CGPoint) -> CGRect? {
        let side = Self.gridSide
        let column = min(max(Int(point.x * CGFloat(side)), 0), side - 1)
        let row = min(max(Int(point.y * CGFloat(side)), 0), side - 1)
        var best: Instance?
        var bestCoverage: UInt8 = 0
        for instance in instances where instance.coverage[row * side + column] > bestCoverage {
            bestCoverage = instance.coverage[row * side + column]
            best = instance
        }
        guard let best, bestCoverage >= 26,
              best.bounds.width * best.bounds.height < 0.9
        else { return nil }
        return AIMaskGenerator.paddedPromptBox(best.bounds)
    }

    /// Runs `request` once on `image` and indexes every non-background instance.
    static func build(
        request: VNImageBasedRequest & VNInstanceMaskProducing,
        image: CIImage
    ) throws -> VisionInstanceIndex {
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        try handler.perform([request])
        guard let observation = request.instanceMaskObservation else {
            return VisionInstanceIndex(instances: [])
        }
        var instances: [Instance] = []
        for instance in observation.allInstances where instance != 0 {
            let mask = try observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            )
            guard let bounds = AIMaskGenerator.normalizedBounds(of: mask),
                  let coverage = coverageGrid(of: mask)
            else { continue }
            instances.append(Instance(coverage: coverage, bounds: bounds))
        }
        return VisionInstanceIndex(instances: instances)
    }

    /// Nearest-sample of a one-component float matte (rows top to bottom) onto the grid.
    private static func coverageGrid(of mask: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else {
            return nil
        }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)

        let side = gridSide
        var grid = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            let y = min((row * height + height / 2) / side, height - 1)
            let source = address.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for column in 0..<side {
                let x = min((column * width + width / 2) / side, width - 1)
                grid[row * side + column] = UInt8((min(max(source[x], 0), 1) * 255).rounded())
            }
        }
        return grid
    }
}

/// Caches `VisionInstanceIndex`es for the most recent source image, one per Vision model, so
/// repeated clicks, Add/Subtract and live previews on the same photo run Vision only once.
/// Weak like `SAM2Segmenter`'s encoder cache: a new photo misses and rebuilds.
nonisolated final class VisionInstanceIndexCache: @unchecked Sendable {
    enum Model: Sendable {
        case person
        case foreground
    }

    static let shared = VisionInstanceIndexCache()

    private let lock = NSLock()
    private weak var indexedImage: CIImage?
    private var indexes: [Model: VisionInstanceIndex] = [:]

    func index(for image: CIImage, model: Model) throws -> VisionInstanceIndex {
        try lock.withLock {
            if indexedImage !== image {
                indexedImage = image
                indexes = [:]
            }
            if let cached = indexes[model] { return cached }

            // The box only needs coarse bounds; Vision on a full-resolution source costs seconds.
            let extent = image.extent
            let scale = min(1, 1536 / max(extent.width, extent.height))
            let visionImage = scale < 1
                ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : image
            let request: VNImageBasedRequest & VNInstanceMaskProducing = switch model {
            case .person: VNGeneratePersonInstanceMaskRequest()
            case .foreground: VNGenerateForegroundInstanceMaskRequest()
            }
            let index = try VisionInstanceIndex.build(request: request, image: visionImage)
            indexes[model] = index
            return index
        }
    }
}

/// A live drag preview: the mask SAM would produce for `points`, as a translucent tint over the
/// whole (display-oriented, unstraightened) image.
nonisolated struct AIMaskPreview: Sendable {
    static let longEdge = 768

    var image: CGImage
    var points: [AIMaskPromptPoint]

    /// Premultiplied RGBA: the selection is tinted red at up to half opacity, like a mask overlay.
    static func tintedImage(coverage: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, coverage.count == width * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in coverage.indices {
            let alpha = Float(coverage[index]) / 255 * 0.5
            pixels[index * 4] = UInt8((alpha * 255).rounded())
            pixels[index * 4 + 1] = UInt8((alpha * 0.2 * 255).rounded())
            pixels[index * 4 + 2] = UInt8((alpha * 0.2 * 255).rounded())
            pixels[index * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
