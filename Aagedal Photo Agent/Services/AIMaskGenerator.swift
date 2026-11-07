import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

nonisolated enum AIMaskGeneratorError: LocalizedError {
    case noForegroundInstances
    case noInstanceAtPoint
    case noFaces
    case noFaceAtPoint
    case selectionCoversEntireImage
    case couldNotGenerateMask
    case couldNotEncodeMask
    case samModelUnavailable

    var errorDescription: String? {
        switch self {
        case .noForegroundInstances:
            return "No selectable person or object was found in this image."
        case .noInstanceAtPoint:
            return "No person or object was found where you clicked."
        case .noFaces:
            return "No face was found in this image."
        case .noFaceAtPoint:
            return "No face was found where you clicked."
        case .selectionCoversEntireImage:
            return "Photo Agent could not separate that person or object from the rest of the image. Try clicking a more distinct subject."
        case .couldNotGenerateMask:
            return "Photo Agent could not generate a mask for that selection."
        case .couldNotEncodeMask:
            return "Photo Agent could not store the generated mask."
        case .samModelUnavailable:
            return "The SAM 2.1 models aren't downloaded. Download them in Settings › Develop Sliders, or switch the AI mask engine back to Vision."
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
        target: AIMaskTarget = .automatic,
        engine: AIMaskEngine = .vision
    ) throws -> GeneratedAIMask {
        // Keep the click in the same top-left normalized frame as the display-oriented source.
        // Each Vision instance is rendered back to source resolution below, which avoids the
        // model's private analysis crop/padding and lets us test the exact displayed pixel.
        let point = CGPoint(
            x: min(max(displayPoint.x, 0), 1),
            y: min(max(displayPoint.y, 0), 1)
        )

        if target == .face {
            return try generateFaceMask(
                from: image,
                at: point,
                sourceOrientation: sourceOrientation
            )
        }

        if engine == .sam21 {
            return try generateWithSAM(
                from: image,
                at: point,
                sourceOrientation: sourceOrientation,
                target: target
            )
        }

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

    /// SAM 2.1 click-to-select. SAM segments whatever is under the click (background objects,
    /// sky, a single garment), which also makes a lone click ambiguous between part and whole: a
    /// click on a skirt scores the skirt above the person. When a Vision instance (person first,
    /// then generic foreground) contains the click, its bounds become a box prompt, so SAM returns
    /// the whole subject with its own edges. Anything Vision does not see uses the bare point.
    private static func generateWithSAM(
        from image: CIImage,
        at point: CGPoint,
        sourceOrientation: Int,
        target: AIMaskTarget
    ) throws -> GeneratedAIMask {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            throw AIMaskGeneratorError.couldNotGenerateMask
        }

        // The box only needs coarse bounds; Vision on a full-resolution source costs seconds.
        let visionScale = min(1, 1536 / max(extent.width, extent.height))
        let visionImage = visionScale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: visionScale, y: visionScale))
            : image

        var promptBox: CGRect?
        if target != .object {
            do {
                promptBox = try visionPromptBox(
                    for: VNGeneratePersonInstanceMaskRequest(),
                    in: visionImage,
                    at: point
                )
            } catch {
                if target == .person { throw error }
            }
            if target == .person, promptBox == nil {
                throw AIMaskGeneratorError.noInstanceAtPoint
            }
        }
        if target != .person, promptBox == nil {
            // Best effort only: a failed or full-frame foreground pass just means a bare point.
            promptBox = try? visionPromptBox(
                for: VNGenerateForegroundInstanceMaskRequest(),
                in: visionImage,
                at: point
            )
        }

        let lowResolution = try SAM2Segmenter.shared.segment(image: image, point: point, box: promptBox)

        let scale = min(1, CGFloat(maximumMaskDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bytes = upsampledSAMMatte(
            logits: lowResolution.logits,
            side: SAM2LowResolutionMask.side,
            width: width,
            height: height
        )
        guard bytes.contains(where: { $0 >= 128 }) else {
            throw AIMaskGeneratorError.noInstanceAtPoint
        }
        if isEffectivelyFullFrameMask(bytes) {
            throw AIMaskGeneratorError.selectionCoversEntireImage
        }
        guard let pngData = encodeGrayscalePNG(bytes: bytes, width: width, height: height),
              pngData.count <= 2_000_000
        else { throw AIMaskGeneratorError.couldNotEncodeMask }

        let orientation = min(max(sourceOrientation, 1), 8)
        return GeneratedAIMask(raster: AIMaskGeometry(
            width: width,
            height: height,
            pngData: pngData,
            sourceOrientation: orientation,
            displayOrientation: orientation,
            target: target
        ))
    }

    /// Bounds of the Vision instance containing the click, padded for use as a SAM box prompt.
    /// Nil when no instance contains the click, or when the instance is (nearly) the whole frame,
    /// which would constrain nothing and is the foreground model's known misfire.
    private static func visionPromptBox(
        for request: VNImageBasedRequest & VNInstanceMaskProducing,
        in image: CIImage,
        at point: CGPoint
    ) throws -> CGRect? {
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        try handler.perform([request])
        guard let observation = request.instanceMaskObservation,
              !observation.allInstances.isEmpty,
              let mask = try scaledMask(selecting: point, observation: observation, handler: handler),
              let bounds = normalizedBounds(of: mask),
              bounds.width * bounds.height < 0.9
        else { return nil }
        return paddedPromptBox(bounds)
    }

    /// Bilinearly resamples SAM's square logit grid (which spans the whole, stretched image) to the
    /// mask raster, then thresholds at logit 0 like SAM itself, with a narrow linear band across
    /// [-1, 1] so edges stay anti-aliased. (A plain sigmoid turns SAM's low-confidence regions
    /// into a wide grey haze.) Pixel centres are aligned as in SAM's `align_corners=False`
    /// upsampling. Rows are top to bottom on both sides. Internal for focused coordinate tests.
    static func upsampledSAMMatte(logits: [Float], side: Int, width: Int, height: Int) -> [UInt8] {
        guard side > 0, logits.count >= side * side, width > 0, height > 0 else { return [] }

        func taps(_ count: Int) -> [(Int, Int, Float)] {
            (0..<count).map { index in
                let source = (Float(index) + 0.5) * Float(side) / Float(count) - 0.5
                let clamped = min(max(source, 0), Float(side - 1))
                let lower = Int(clamped.rounded(.down))
                let upper = min(lower + 1, side - 1)
                return (lower, upper, clamped - Float(lower))
            }
        }
        let columns = taps(width)
        let rows = taps(height)

        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let (top, bottom, fy) = rows[y]
            let topRow = top * side
            let bottomRow = bottom * side
            for x in 0..<width {
                let (left, right, fx) = columns[x]
                let upper = logits[topRow + left] * (1 - fx) + logits[topRow + right] * fx
                let lower = logits[bottomRow + left] * (1 - fx) + logits[bottomRow + right] * fx
                let logit = upper * (1 - fy) + lower * fy
                let coverage = min(max((logit + 1) * 0.5, 0), 1)
                bytes[y * width + x] = UInt8((coverage * 255).rounded())
            }
        }
        return bytes
    }

    /// Top-left normalized bounds of a Vision matte's covered pixels (coverage ≥ 0.5).
    static func normalizedBounds(of mask: CVPixelBuffer) -> CGRect? {
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

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = address.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width where row[x] >= 0.5 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    /// Vision's person matte can clip hair, fingers and held objects; a small margin lets SAM
    /// include them without inviting the surroundings in.
    static func paddedPromptBox(_ box: CGRect) -> CGRect {
        box.insetBy(dx: -box.width * 0.04, dy: -box.height * 0.03)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Selects a Vision-detected face at the click and turns its bounds into a softly feathered
    /// facial matte. Vision provides face detection and landmarks, but no face-segmentation
    /// request. The oval deliberately stays within the head bounds instead of falling back to
    /// the person-instance matte, so "Face" never changes the user's target to a full body.
    private static func generateFaceMask(
        from image: CIImage,
        at point: CGPoint,
        sourceOrientation: Int
    ) throws -> GeneratedAIMask {
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up)
        let request = VNDetectFaceRectanglesRequest()
        try handler.perform([request])
        guard let observations = request.results, !observations.isEmpty else {
            throw AIMaskGeneratorError.noFaces
        }

        // Vision bounding boxes use a lower-left origin; editor clicks and persisted raster rows
        // use a top-left origin. Prefer the smallest containing observation in the unlikely case
        // detector boxes overlap, which makes a click select the most specific face.
        let visionPoint = CGPoint(x: point.x, y: 1 - point.y)
        guard let face = observations
            .filter({ $0.boundingBox.contains(visionPoint) })
            .min(by: {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            })
        else {
            throw AIMaskGeneratorError.noFaceAtPoint
        }

        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            throw AIMaskGeneratorError.couldNotGenerateMask
        }
        let scale = min(1, CGFloat(maximumMaskDimension) / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bytes = renderFaceMaskBytes(
            boundingBox: face.boundingBox,
            width: width,
            height: height
        )
        guard let pngData = encodeGrayscalePNG(bytes: bytes, width: width, height: height),
              pngData.count <= 2_000_000 else {
            throw AIMaskGeneratorError.couldNotEncodeMask
        }

        let orientation = min(max(sourceOrientation, 1), 8)
        return GeneratedAIMask(raster: AIMaskGeometry(
            width: width,
            height: height,
            pngData: pngData,
            sourceOrientation: orientation,
            displayOrientation: orientation,
            target: .face
        ))
    }

    /// Builds the top-left-row-order facial oval used by the face target. Internal for focused
    /// coordinate/shape regression tests. The detector's box is slightly widened and shifted
    /// upward to include the forehead while avoiding shoulders and most surrounding background.
    static func renderFaceMaskBytes(
        boundingBox: CGRect,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let centerX = boundingBox.midX
        let centerY = 1 - boundingBox.midY - boundingBox.height * 0.035
        let radiusX = max(boundingBox.width * 0.56, 1 / CGFloat(width))
        let radiusY = max(boundingBox.height * 0.58, 1 / CGFloat(height))
        var bytes = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            let normalizedY = (CGFloat(y) + 0.5) / CGFloat(height)
            for x in 0..<width {
                let normalizedX = (CGFloat(x) + 0.5) / CGFloat(width)
                let dx = (normalizedX - centerX) / radiusX
                let dy = (normalizedY - centerY) / radiusY
                let distance = sqrt(dx * dx + dy * dy)
                let coverage: CGFloat
                if distance <= 0.84 {
                    coverage = 1
                } else if distance >= 1 {
                    coverage = 0
                } else {
                    let t = (distance - 0.84) / 0.16
                    let smooth = t * t * (3 - 2 * t)
                    coverage = 1 - smooth
                }
                bytes[y * width + x] = UInt8((coverage * 255).rounded())
            }
        }
        return bytes
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

/// The two Vision instance-mask requests share `results` of `VNInstanceMaskObservation` but no
/// common superclass exposing them; this lets the SAM box-prompt helper take either.
nonisolated protocol VNInstanceMaskProducing: AnyObject {
    var instanceMaskObservation: VNInstanceMaskObservation? { get }
}

extension VNGeneratePersonInstanceMaskRequest: VNInstanceMaskProducing {
    nonisolated var instanceMaskObservation: VNInstanceMaskObservation? { results?.first }
}

extension VNGenerateForegroundInstanceMaskRequest: VNInstanceMaskProducing {
    nonisolated var instanceMaskObservation: VNInstanceMaskObservation? { results?.first }
}
