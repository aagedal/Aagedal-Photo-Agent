import Foundation
import CoreML
import CoreGraphics
import Accelerate

/// Installation and compatibility state for the optional AuraFace component. The associated
/// versions are distribution versions; the persisted embedding-space version is tracked separately.
nonisolated enum FaceRecognitionModelAvailability: Equatable, Sendable {
    case checking
    case notInstalled
    case downloading(progress: Double)
    case ready(version: String)
    case updateAvailable(installedVersion: String, availableVersion: String)
    case incompatible(requiredSystemVersion: String)
    case verificationFailed
    case offline

    /// Compatibility names retained while the download coordinator is integrated into the UI.
    static var available: Self { .ready(version: CoreMLFaceEmbedder.modelVersion) }
    static var unavailable: Self { .notInstalled }

    var isAvailable: Bool {
        switch self {
        case .ready, .updateAvailable: true
        case .checking, .notInstalled, .downloading, .incompatible, .verificationFailed, .offline: false
        }
    }

    var title: String {
        switch self {
        case .checking: "Checking Face Recognition"
        case .notInstalled: "Face Recognition Unavailable"
        case .downloading: "Downloading Face Model"
        case .ready: "Face Recognition Available"
        case .updateAvailable: "Face Model Update Available"
        case .incompatible: "Face Model Incompatible"
        case .verificationFailed: "Face Model Verification Failed"
        case .offline: "Face Model Download Offline"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "Checking the verified AuraFace component on this Mac."
        case .notInstalled:
            "AuraFace is not installed. Face scanning and recognition remain unavailable until the verified model is downloaded."
        case .downloading(let progress):
            "Downloading and verifying AuraFace (\(Int(min(max(progress, 0), 1) * 100))%)."
        case .ready(let version):
            "AuraFace \(version) is installed and runs only on this Mac."
        case .updateAvailable(let installedVersion, let availableVersion):
            "AuraFace \(installedVersion) remains usable. Version \(availableVersion) is available to download."
        case .incompatible(let requiredSystemVersion):
            "This AuraFace model requires macOS \(requiredSystemVersion) or later."
        case .verificationFailed:
            "The downloaded AuraFace model could not be verified and was not installed."
        case .offline:
            "The AuraFace model is not installed and the download service is currently unreachable."
        }
    }

    static let downloadExplanation =
        "AuraFace is approximately 125 MB. It is downloaded from aagedal.me, verified before installation, used only on this Mac, works offline after installation, and can be removed later in Settings."

    /// Exact copy release operators can use when intentionally shipping without the optional model.
    static let releaseNotesDisclosure =
        "Face recognition is unavailable in this build because the AuraFace model is not included."
}

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
    // Keep this synchronized with the persisted embedding-space version and the
    // on-demand distribution descriptor. Changing model bytes or preprocessing
    // requires a new value before either artifact can be published.
    let version = FaceRecognitionDefaults.embeddingVersion

    private static let inputSize = 112
    private static let inputName = "input"
    private static let outputName = "embedding"
    private static let modelResource = "AuraFaceR100"
    static let modelVersion = "AuraFace-v1/glintr100"
    private static let mean: Float = 127.5
    private static let std: Float = 127.5
    /// Set false only if a future model expects BGR input.
    private static let inputIsRGB = true

    private let lock = NSLock()
    private var modelURL: URL?
    private let allowsDynamicResolution: Bool
    private var isResolutionPending: Bool
    private var loadedModel: MLModel?
    private var loadError: Error?

    nonisolated var availability: FaceRecognitionModelAvailability {
        lock.lock(); defer { lock.unlock() }
        if modelURL != nil { return .available }
        return isResolutionPending ? .checking : .unavailable
    }

    nonisolated convenience init() {
        self.init(modelURL: nil, allowsDynamicResolution: true, isResolutionPending: true)
    }

    /// Kept separate from downloaded-component resolution so Settings can distinguish an
    /// app-bundled fallback. Downloaded components are supplied only after the serialized
    /// signed-package probe succeeds.
    nonisolated static func bundledModelURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: Self.modelResource, withExtension: "mlmodelc")
    }

    /// Internal injection point keeps the omitted-package state deterministic in focused tests.
    nonisolated init(
        modelURL: URL?,
        allowsDynamicResolution: Bool = false,
        isResolutionPending: Bool = false
    ) {
        self.modelURL = modelURL
        self.allowsDynamicResolution = allowsDynamicResolution
        self.isResolutionPending = isResolutionPending
    }

    /// Publishes a URL that was already resolved and verified by the serialized component probe.
    /// Any cached model or failure belongs to the previous installation and must not cross this
    /// boundary. This lock-only publication never performs filesystem work on its caller.
    nonisolated func publishResolvedModelURL(_ resolvedURL: URL?) {
        lock.lock(); defer { lock.unlock() }
        guard allowsDynamicResolution else { return }
        loadedModel = nil
        loadError = nil
        modelURL = resolvedURL
        isResolutionPending = false
    }

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
            guard let url = modelURL else {
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
