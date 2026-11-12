import CoreImage
import CoreML
import CoreVideo
import Foundation

/// SAM 2.1's best candidate for one prompt: decoder logits on a 256×256 grid covering the whole
/// image (the encoder input is the image stretched to a 1024 square). Rows run top to bottom.
nonisolated struct SAM2LowResolutionMask: Sendable {
    static let side = 256
    var logits: [Float]
    var score: Float
    /// Logit cells inside the mask (logit > 0); orders the nested candidates part → whole.
    var area: Int { logits.reduce(0) { $1 > 0 ? $0 + 1 : $0 } }
}

/// Every candidate SAM 2.1 returns for one prompt, smallest first, with the one it scores highest.
nonisolated struct SAM2Prediction: Sendable {
    var candidates: [SAM2LowResolutionMask]
    var bestIndex: Int

    /// A candidate scoring under this fraction of the best is one SAM itself does not believe in:
    /// typically a frame-wide, low-confidence blob whose logits hover around zero and threshold
    /// into blotches. Size choices skip those rather than offer them as "Large".
    static let plausibleScoreFraction: Float = 0.5

    /// The candidate for `size`: the best-scoring one for Auto, otherwise by area rank among the
    /// plausible candidates (the best always counts, so there is at least one).
    func candidate(for size: AIMaskSelectionSize) -> SAM2LowResolutionMask {
        guard let rank = size.candidateRank else { return candidates[bestIndex] }
        let threshold = candidates[bestIndex].score * Self.plausibleScoreFraction
        let plausible = candidates.indices.filter { $0 == bestIndex || candidates[$0].score >= threshold }
        let index: Int = switch rank {
        case 0: plausible[0]
        case 1: plausible[plausible.count / 2]
        default: plausible[plausible.count - 1]
        }
        return candidates[index]
    }
}

/// Runs the downloaded SAM 2.1 Small models. The image encoder is the expensive stage, so its
/// output is cached for the most recent source image: repeated clicks or "Select Again" on the same
/// photo only rerun the prompt encoder and mask decoder. Calls are serialized by `lock`; the AI mask
/// coordinator already allows only one generation at a time.
nonisolated final class SAM2Segmenter: @unchecked Sendable {
    static let shared = SAM2Segmenter()
    static let inputSide = 1024

    /// Point-prompt labels from the SAM convention (box corners are 2 and 3).
    enum Label: Float {
        case foreground = 1
        case background = 0
        case boxTopLeft = 2
        case boxBottomRight = 3
    }

    private struct Models {
        var encoder: MLModel
        var prompt: MLModel
        var decoder: MLModel
    }

    private let lock = NSLock()
    private var models: Models?
    /// Weak, so the cache never keeps a previous photo's pixels alive; a new source image (a
    /// different object) misses and re-encodes.
    private weak var encodedImage: CIImage?
    private var encoding: MLFeatureProvider?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func unloadModels() {
        lock.withLock {
            models = nil
            encodedImage = nil
            encoding = nil
        }
    }

    /// Loads the models and encodes `image` ahead of the first click, so the first prompt (and a
    /// live drag preview) only pays for the fast decoder.
    func prewarm(image: CIImage) throws {
        try lock.withLock {
            _ = try imageEncoding(for: image, encoder: loadedModels().encoder)
        }
    }

    /// Segments `image` from top-left normalized click points (positive = include, negative =
    /// exclude), optionally constrained by a top-left normalized `box` around the intended subject.
    func segment(image: CIImage, points clicks: [AIMaskPromptPoint], box: CGRect?) throws -> SAM2Prediction {
        try lock.withLock {
            let models = try loadedModels()
            let encoding = try imageEncoding(for: image, encoder: models.encoder)

            var prompts: [(CGPoint, Label)] = clicks.map {
                (CGPoint(x: $0.x, y: $0.y), $0.isPositive ? .foreground : .background)
            }
            if let box {
                prompts.append((CGPoint(x: box.minX, y: box.minY), .boxTopLeft))
                prompts.append((CGPoint(x: box.maxX, y: box.maxY), .boxBottomRight))
            }
            let side = Float(Self.inputSide)
            let points = try MLMultiArray(shape: [1, NSNumber(value: prompts.count), 2], dataType: .float32)
            let labels = try MLMultiArray(shape: [1, NSNumber(value: prompts.count)], dataType: .float32)
            for (index, prompt) in prompts.enumerated() {
                points[[0, index, 0] as [NSNumber]] = NSNumber(value: Float(prompt.0.x) * side)
                points[[0, index, 1] as [NSNumber]] = NSNumber(value: Float(prompt.0.y) * side)
                labels[[0, index] as [NSNumber]] = NSNumber(value: prompt.1.rawValue)
            }
            let promptOutput = try models.prompt.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "points": points,
                "labels": labels,
            ]))
            guard let sparse = promptOutput.featureValue(for: "sparse_embeddings"),
                  let dense = promptOutput.featureValue(for: "dense_embeddings"),
                  let imageEmbedding = encoding.featureValue(for: "image_embedding"),
                  let featsS0 = encoding.featureValue(for: "feats_s0"),
                  let featsS1 = encoding.featureValue(for: "feats_s1")
            else { throw AIMaskGeneratorError.couldNotGenerateMask }

            let decoded = try models.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "image_embedding": imageEmbedding,
                "sparse_embedding": sparse,
                "dense_embedding": dense,
                "feats_s0": featsS0,
                "feats_s1": featsS1,
            ]))
            guard let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
                  let scores = decoded.featureValue(for: "scores")?.multiArrayValue,
                  masks.shape.count == 4,
                  masks.shape[2].intValue == SAM2LowResolutionMask.side,
                  masks.shape[3].intValue == SAM2LowResolutionMask.side
            else { throw AIMaskGeneratorError.couldNotGenerateMask }

            // SAM returns three nested candidates (part → whole) with predicted IoU scores. With a
            // box prompt the whole subject reliably scores highest; a lone point stays ambiguous,
            // so callers can override the model's own pick by size.
            let candidateCount = min(masks.shape[1].intValue, scores.count)
            let plane = SAM2LowResolutionMask.side * SAM2LowResolutionMask.side
            let all = MLShapedArray<Float>(converting: masks).scalars
            guard candidateCount > 0, all.count >= candidateCount * plane else {
                throw AIMaskGeneratorError.couldNotGenerateMask
            }
            let unsorted = (0..<candidateCount).map { index in
                SAM2LowResolutionMask(
                    logits: Array(all[(index * plane)..<((index + 1) * plane)]),
                    score: scores[index].floatValue
                )
            }
            return Self.prediction(from: unsorted)
        }
    }

    /// Sorts candidates by area and keeps track of the best-scoring one. Internal for tests.
    static func prediction(from unsorted: [SAM2LowResolutionMask]) -> SAM2Prediction {
        let best = unsorted.indices.max { unsorted[$0].score < unsorted[$1].score } ?? 0
        let areas = unsorted.map(\.area)
        let order = unsorted.indices.sorted { areas[$0] < areas[$1] }
        return SAM2Prediction(
            candidates: order.map { unsorted[$0] },
            bestIndex: order.firstIndex(of: best) ?? 0
        )
    }

    private func loadedModels() throws -> Models {
        if let models { return models }
        guard SAM2ModelStore.isInstalled else { throw AIMaskGeneratorError.samModelUnavailable }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        // The Neural Engine compiler rejects this decoder conversion; Core ML then falls back, but
        // only after a failed compile attempt on every load. Skip straight to CPU/GPU.
        let decoderConfiguration = MLModelConfiguration()
        decoderConfiguration.computeUnits = .cpuAndGPU
        let loaded = Models(
            encoder: try MLModel(contentsOf: SAM2ModelStore.compiledModelURL(.imageEncoder), configuration: configuration),
            prompt: try MLModel(contentsOf: SAM2ModelStore.compiledModelURL(.promptEncoder), configuration: configuration),
            decoder: try MLModel(contentsOf: SAM2ModelStore.compiledModelURL(.maskDecoder), configuration: decoderConfiguration)
        )
        models = loaded
        return loaded
    }

    private func imageEncoding(for image: CIImage, encoder: MLModel) throws -> MLFeatureProvider {
        if let encoding, encodedImage === image { return encoding }

        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            throw AIMaskGeneratorError.couldNotGenerateMask
        }
        let side = CGFloat(Self.inputSide)
        // SAM 2's preprocessing stretches (not letterboxes) to the square input; normalization is
        // part of the converted model, so the encoder takes plain sRGB pixels.
        let stretched = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: side / extent.width, y: side / extent.height))
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            Self.inputSide,
            Self.inputSide,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard let pixelBuffer else { throw AIMaskGeneratorError.couldNotGenerateMask }
        context.render(
            stretched,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: side, height: side),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer),
        ]))
        encodedImage = image
        encoding = output
        return output
    }
}
