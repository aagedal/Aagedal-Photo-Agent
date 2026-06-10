import Foundation
import CoreML
import CoreGraphics
import Accelerate

/// Face-identity embedder backed by the bundled **AuraFace-v1** model
/// (`glintr100` / ArcFace R100, Apache-2.0). See `Resources/Models/AuraFaceR100.mlpackage`.
///
/// Preprocessing matches InsightFace's `ArcFaceONNX`:
/// - input `112×112`, **RGB** channel order (`swapRB=True` in InsightFace),
/// - normalized `(pixel - 127.5) / 127.5`, laid out NCHW `[1, 3, 112, 112]`.
///
/// The 512-d model output is L2-normalized here, so downstream code can use
/// `EmbeddingCodec.cosineDistance`.
nonisolated final class CoreMLFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    static let shared = CoreMLFaceEmbedder()

    let dimension = 512
    let version = 2

    private static let inputSize = 112
    private static let inputName = "input"
    private static let outputName = "embedding"
    private static let modelResource = "AuraFaceR100"
    private static let mean: Float = 127.5
    private static let std: Float = 127.5
    /// Set false only if a future model expects BGR input.
    private static let inputIsRGB = true

    private let lock = NSLock()
    private var loadedModel: MLModel?
    private var loadError: Error?

    enum EmbedError: LocalizedError {
        case modelNotFound
        case badInput
        case badOutput
        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "AuraFace CoreML model (AuraFaceR100.mlmodelc) not found in app bundle."
            case .badInput: return "Failed to build the face-embedding model input buffer."
            case .badOutput: return "Face-embedding model returned no embedding."
            }
        }
    }

    /// Lazily load + cache the compiled model (thread-safe). A load failure is cached
    /// so we don't retry a missing/broken model on every face.
    private func model() throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let m = loadedModel { return m }
        if let e = loadError { throw e }
        do {
            guard let url = Bundle.main.url(forResource: Self.modelResource, withExtension: "mlmodelc") else {
                throw EmbedError.modelNotFound
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let m = try MLModel(contentsOf: url, configuration: config)
            loadedModel = m
            return m
        } catch {
            loadError = error
            throw error
        }
    }

    func embed(_ alignedFace: CGImage) async throws -> [Float] {
        let model = try model()
        guard let input = Self.makeInput(from: alignedFace) else { throw EmbedError.badInput }
        let provider = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
        let output = try await model.prediction(from: provider)
        guard let result = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw EmbedError.badOutput
        }
        return Self.l2normalized(result)
    }

    // MARK: - Preprocessing

    /// Draw the face into a deterministic 112×112 sRGB buffer (top-left origin) and pack
    /// it into a normalized NCHW float32 MLMultiArray.
    private static func makeInput(from image: CGImage) -> MLMultiArray? {
        let n = inputSize
        let bytesPerRow = n * 4
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let drawn: Bool = pixels.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: n, height: n,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            // A standard CGBitmapContext stores row 0 = top and `draw` orients the CGImage
            // correctly, so reading the buffer row-major yields an upright face. (Do NOT flip —
            // flipping feeds ArcFace upside-down faces, which destroys identity discrimination.)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: n), NSNumber(value: n)],
            dataType: .float32
        ) else { return nil }

        let out = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        let plane = n * n
        let rPlane = inputIsRGB ? 0 : 2 * plane
        let gPlane = plane
        let bPlane = inputIsRGB ? 2 * plane : 0
        for y in 0..<n {
            let row = y * n
            for x in 0..<n {
                let p = (row + x) * 4               // RGBX
                let idx = row + x
                out[rPlane + idx] = (Float(pixels[p])     - mean) / std
                out[gPlane + idx] = (Float(pixels[p + 1]) - mean) / std
                out[bPlane + idx] = (Float(pixels[p + 2]) - mean) / std
            }
        }
        return array
    }

    private static func l2normalized(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = array[i].floatValue }
        var sumSq: Float = 0
        vDSP_svesq(out, 1, &sumSq, vDSP_Length(count))
        let norm = sqrt(sumSq)
        if norm > 1e-12 {
            var inv = 1 / norm
            vDSP_vsmul(out, 1, &inv, &out, 1, vDSP_Length(count))
        }
        return out
    }
}
