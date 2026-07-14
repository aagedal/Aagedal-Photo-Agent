import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

nonisolated enum AIMaskGeneratorError: LocalizedError {
    case noForegroundInstances
    case noInstanceAtPoint
    case selectionCoversEntireImage
    case couldNotGenerateMask
    case couldNotEncodeMask

    var errorDescription: String? {
        switch self {
        case .noForegroundInstances:
            return "No selectable person or object was found in this image."
        case .noInstanceAtPoint:
            return "No person or object was found where you clicked."
        case .selectionCoversEntireImage:
            return "Photo Agent could not separate that person or object from the rest of the image. Try clicking a more distinct subject."
        case .couldNotGenerateMask:
            return "Photo Agent could not generate a mask for that selection."
        case .couldNotEncodeMask:
            return "Photo Agent could not store the generated mask."
        }
    }
}

/// The immutable output of a click-to-select Vision pass.
nonisolated struct GeneratedAIMask: Sendable {
    var raster: AIMaskGeometry
}

/// Generates one instance matte from a display-oriented source image. The dedicated person model
/// is tried first because the generic foreground model can occasionally classify the entire frame
/// as one salient instance; ordinary objects then fall back to the foreground-instance model.
nonisolated enum AIMaskGenerator {
    private static let maximumMaskDimension = 1024
    nonisolated static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func generate(
        from image: CIImage,
        displayPoint: CGPoint,
        sourceOrientation: Int,
        target: AIMaskTarget = .automatic
    ) throws -> GeneratedAIMask {
        // Keep the click in the same top-left normalized frame as the display-oriented source.
        // Each Vision instance is rendered back to source resolution below, which avoids the
        // model's private analysis crop/padding and lets us test the exact displayed pixel.
        let point = CGPoint(
            x: min(max(displayPoint.x, 0), 1),
            y: min(max(displayPoint.y, 0), 1)
        )

        var sawInstances = false
        var rejectedFullFrame = false

        // People get their own instance model. Besides producing cleaner hair/body boundaries,
        // it avoids the foreground model's tendency to call a portrait's complete frame one
        // object. A failure here is non-fatal: the generic object pass remains available.
        if target != .object {
            let personHandler = VNImageRequestHandler(ciImage: image, orientation: .up)
            let personRequest = VNGeneratePersonInstanceMaskRequest()
            do {
                try personHandler.perform([personRequest])
                if let personObservation = personRequest.results?.first,
                   let generated = try generateCandidate(
                       observation: personObservation,
                       handler: personHandler,
                       point: point,
                       sourceOrientation: sourceOrientation,
                       target: target,
                       sawInstances: &sawInstances,
                       rejectedFullFrame: &rejectedFullFrame
                   ) {
                    return generated
                }
            } catch {
                // Auto can still try the generic object model. A forced Person selection should
                // surface the model failure rather than silently using a different target.
                if target == .person { throw error }
            }
        }

        // Non-person objects use Vision's foreground-instance model.
        if target != .person {
            let foregroundHandler = VNImageRequestHandler(ciImage: image, orientation: .up)
            let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
            try foregroundHandler.perform([foregroundRequest])
            if let foregroundObservation = foregroundRequest.results?.first,
               let generated = try generateCandidate(
                   observation: foregroundObservation,
                   handler: foregroundHandler,
                   point: point,
                   sourceOrientation: sourceOrientation,
                   target: target,
                   sawInstances: &sawInstances,
                   rejectedFullFrame: &rejectedFullFrame
               ) {
                return generated
            }
        }

        if rejectedFullFrame { throw AIMaskGeneratorError.selectionCoversEntireImage }
        if sawInstances { throw AIMaskGeneratorError.noInstanceAtPoint }
        throw AIMaskGeneratorError.noForegroundInstances
    }

    private static func generateCandidate(
        observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler,
        point: CGPoint,
        sourceOrientation: Int,
        target: AIMaskTarget,
        sawInstances: inout Bool,
        rejectedFullFrame: inout Bool
    ) throws -> GeneratedAIMask? {
        guard !observation.allInstances.isEmpty else { return nil }
        sawInstances = true

        // Do not bridge a VNInstanceMaskObservation into Vision.InstanceMaskObservation here.
        // The bridge can return the background index (0) for every point even when
        // `allInstances` contains real nonzero labels. Rendering index 0 caused both reported
        // symptoms: the chosen object appeared unrelated to the click and the matte was inverted.
        // Rendering each real instance at source resolution also accounts for Vision's internal
        // aspect-fit analysis frame, whose dimensions do not necessarily match the source.
        guard let fullResolutionMask = try scaledMask(
            selecting: point,
            observation: observation,
            handler: handler
        ) else { return nil }
        let maskImage = CIImage(cvPixelBuffer: fullResolutionMask)
        guard maskImage.extent.width > 0, maskImage.extent.height > 0 else {
            throw AIMaskGeneratorError.couldNotGenerateMask
        }

        let scale = min(
            1,
            CGFloat(maximumMaskDimension) / max(maskImage.extent.width, maskImage.extent.height)
        )
        let scaled = maskImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: -maskImage.extent.minX * scale,
                y: -maskImage.extent.minY * scale
            ))
        let width = max(1, Int((maskImage.extent.width * scale).rounded()))
        let height = max(1, Int((maskImage.extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let bytes = renderGrayscaleBytes(from: scaled, width: width, height: height, bounds: bounds)
        else { throw AIMaskGeneratorError.couldNotGenerateMask }

        // A nearly uniform white matte is the foreground model reporting the complete frame as
        // one instance, not a usable object selection. Let another model try before surfacing a
        // helpful error; never create the misleading all-image mask the user just encountered.
        if isEffectivelyFullFrameMask(bytes) {
            rejectedFullFrame = true
            return nil
        }

        guard let pngData = encodeGrayscalePNG(bytes: bytes, width: width, height: height),
              pngData.count <= 2_000_000
        else { throw AIMaskGeneratorError.couldNotEncodeMask }

        let orientation = min(max(sourceOrientation, 1), 8)
        return GeneratedAIMask(
            raster: AIMaskGeometry(
                width: width,
                height: height,
                pngData: pngData,
                sourceOrientation: orientation,
                displayOrientation: orientation,
                target: target
            )
        )
    }

    /// Returns the non-background instance whose rendered matte contains the user's click.
    /// Vision normally finds only a handful of salient instances; generating their scaled mattes
    /// does not rerun inference and gives us an exact source-coordinate hit test.
    private static func scaledMask(
        selecting point: CGPoint,
        observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler
    ) throws -> CVPixelBuffer? {
        var bestMask: CVPixelBuffer?
        var bestCoverage: Float = 0

        for instance in observation.allInstances where instance != 0 {
            let mask = try observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instance),
                from: handler
            )
            let coverage = maskCoverage(atDisplayPoint: point, in: mask) ?? 0
            if coverage > bestCoverage {
                bestCoverage = coverage
                bestMask = mask
            }
        }

        // Permit a soft boundary click, but never silently substitute a different salient object
        // when the clicked object was not detected by this model.
        return bestCoverage >= 0.1 ? bestMask : nil
    }

    /// Samples a source-resolution Vision matte using the preview's top-left normalized frame.
    /// `generateScaledMaskForImage` produces a one-component float CVPixelBuffer whose memory rows
    /// are top-to-bottom, matching the app preview and persisted PNG contract.
    static func maskCoverage(atDisplayPoint point: CGPoint, in mask: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else {
            return nil
        }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(mask) else { return nil }

        let x = min(max(Int(min(max(point.x, 0), 1) * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(min(max(point.y, 0), 1) * CGFloat(height)), 0), height - 1)
        let row = address
            .advanced(by: y * CVPixelBufferGetBytesPerRow(mask))
            .assumingMemoryBound(to: Float.self)
        return min(max(row[x], 0), 1)
    }

    /// True only for an essentially uniform selected frame. Requiring every pixel to retain at
    /// least 94% coverage distinguishes Vision's erroneous full-frame instance from legitimate
    /// close-up subjects whose matte still has some real background or edge falloff.
    static func isEffectivelyFullFrameMask(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy { $0 >= 240 }
    }

    /// Renders a Core Image mask into the top-left row order used by persisted PNGs and Metal.
    /// Kept internal so the image-coordinate contract can be covered by the raster pipeline tests.
    static func renderGrayscalePNG(
        from image: CIImage,
        width: Int,
        height: Int,
        bounds: CGRect
    ) -> Data? {
        guard let bytes = renderGrayscaleBytes(
            from: image,
            width: width,
            height: height,
            bounds: bounds
        ) else { return nil }
        return encodeGrayscalePNG(bytes: bytes, width: width, height: height)
    }

    private static func renderGrayscaleBytes(
        from image: CIImage,
        width: Int,
        height: Int,
        bounds: CGRect
    ) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        ciContext.render(
            image,
            toBitmap: &bytes,
            rowBytes: width,
            bounds: bounds,
            format: .R8,
            colorSpace: nil
        )
        return bytes
    }

    private static func encodeGrayscalePNG(bytes: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
