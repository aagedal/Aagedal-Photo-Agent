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
    let interchangeProvenance: FaceEmbeddingProvenance? = .current

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
    private let modelLoadLock = NSLock()
    private var modelURL: URL?
    private let allowsDynamicResolution: Bool
    private var isResolutionPending: Bool
    private var loadedModel: MLModel?
    private var loadError: Error?
    private var installationGeneration = UUID()
    private let instanceID = UUID()
    /// Installation generation that has loaded successfully at least once. Native-scan
    /// capabilities are validated against this rather than `loadedModel`, so an idle unload
    /// does not revoke a capability for an installation that is proven loadable.
    private var verifiedGeneration: UUID?

    // MARK: Idle unload
    //
    // The ~125 MB AuraFace model used to stay resident for the whole session after the first
    // face scan. It is now released after `idleUnloadDelay` without embedding requests and on
    // critical memory pressure, and transparently reloaded (via `model()`) by the next request.
    // A request counts as active from before `model()` until its prediction returns, so the
    // model is never unloaded mid-request; a request that captured the model keeps its own
    // reference alive regardless.
    private let idleUnloadDelay: TimeInterval
    private var activeRequests = 0
    private var lastRequestEnded = DispatchTime.now()
    private var idleCheckScheduled = false
    private var unloadWhenIdle = false
    private var pressureRegistration: ImageMemoryCoordinator.Registration?

    nonisolated var availability: FaceRecognitionModelAvailability {
        lock.lock(); defer { lock.unlock() }
        if modelURL != nil { return loadError == nil ? .available : .verificationFailed }
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
        isResolutionPending: Bool = false,
        idleUnloadDelay: TimeInterval = 120,
        memoryCoordinator: ImageMemoryCoordinator = .shared
    ) {
        self.modelURL = modelURL
        self.allowsDynamicResolution = allowsDynamicResolution
        self.isResolutionPending = isResolutionPending
        self.idleUnloadDelay = idleUnloadDelay
        pressureRegistration = memoryCoordinator.registerPressureEviction(level: .critical) { [weak self] in
            self?.unloadModelForMemoryPressure()
        }
    }

    /// Whether the compiled model is currently resident (diagnostics/tests).
    var isModelLoaded: Bool {
        lock.withLock { loadedModel != nil }
    }

    /// Critical memory pressure: drop the model now unless a request is using it, in which case
    /// it is dropped as soon as the last in-flight request finishes.
    func unloadModelForMemoryPressure() {
        lock.withLock {
            if activeRequests == 0 {
                loadedModel = nil
            } else {
                unloadWhenIdle = true
            }
        }
    }

    private func beginRequest() {
        lock.withLock { activeRequests += 1 }
    }

    private func endRequest() {
        let scheduleCheck: Bool = lock.withLock {
            activeRequests -= 1
            guard activeRequests == 0 else { return false }
            if unloadWhenIdle {
                unloadWhenIdle = false
                loadedModel = nil
                return false
            }
            lastRequestEnded = .now()
            // One pending check at a time: a scan's thousands of sequential requests must not
            // each enqueue a timer. The check re-arms itself for the remaining idle time.
            guard loadedModel != nil, !idleCheckScheduled else { return false }
            idleCheckScheduled = true
            return true
        }
        if scheduleCheck { scheduleIdleCheck(after: idleUnloadDelay) }
    }

    private func scheduleIdleCheck(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runIdleCheck()
        }
    }

    private func runIdleCheck() {
        let remaining: TimeInterval? = lock.withLock {
            guard loadedModel != nil else {
                idleCheckScheduled = false
                return nil
            }
            // Never unload under a running request; look again after a full idle period.
            guard activeRequests == 0 else { return idleUnloadDelay }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                - lastRequestEnded.uptimeNanoseconds) / 1_000_000_000
            if elapsed >= idleUnloadDelay {
                loadedModel = nil
                idleCheckScheduled = false
                return nil
            }
            return idleUnloadDelay - elapsed
        }
        if let remaining { scheduleIdleCheck(after: remaining) }
    }

    /// Publishes a URL that was already resolved and verified by the serialized component probe.
    /// Any cached model or failure belongs to the previous installation and must not cross this
    /// boundary. This lock-only publication never performs filesystem work on its caller.
    nonisolated func publishResolvedModelURL(_ resolvedURL: URL?) {
        lock.lock(); defer { lock.unlock() }
        guard allowsDynamicResolution else { return }
        installationGeneration = UUID()
        loadedModel = nil
        loadError = nil
        verifiedGeneration = nil
        modelURL = resolvedURL
        isResolutionPending = false
    }

    /// Process-only proof that this exact installation loaded successfully. A
    /// same-version reinstallation also invalidates it; it grants no file effects.
    struct NativeScanModelCapability: Sendable {
        fileprivate let instanceID: UUID
        fileprivate let generation: UUID
    }

    /// Call on an I/O executor before presenting native consent, never on MainActor.
    func prepareNativeScanModel() throws -> NativeScanModelCapability {
        beginRequest()
        defer { endRequest() }
        _ = try model()
        return try lock.withLock {
            guard verifiedGeneration == installationGeneration, loadError == nil, modelURL != nil else {
                throw EmbedError.modelNotFound
            }
            return .init(instanceID: instanceID, generation: installationGeneration)
        }
    }

    /// Lock-only validation at retained scanner boundaries. It never loads a model.
    func validateNativeScanModel(_ capability: NativeScanModelCapability) throws {
        try lock.withLock {
            guard capability.instanceID == instanceID, capability.generation == installationGeneration,
                  verifiedGeneration == installationGeneration, loadError == nil, modelURL != nil else {
                throw EmbedError.modelNotFound
            }
        }
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
        // Serialize expensive loads independently: availability and capability
        // withdrawal remain lock-only while CoreML reads/loads an installation.
        modelLoadLock.lock(); defer { modelLoadLock.unlock() }
        let captured = try lock.withLock { () throws -> (MLModel?, URL?, UUID) in
            if let loadedModel { return (loadedModel, modelURL, installationGeneration) }
            if let loadError { throw loadError }
            return (nil, modelURL, installationGeneration)
        }
        if let loaded = captured.0 { return loaded }
        do {
            guard let url = captured.1 else { throw EmbedError.modelNotFound }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let loaded = try MLModel(contentsOf: url, configuration: config)
            return try lock.withLock {
                guard installationGeneration == captured.2 else { throw EmbedError.modelNotFound }
                loadedModel = loaded
                verifiedGeneration = captured.2
                return loaded
            }
        } catch {
            lock.withLock {
                if installationGeneration == captured.2 { loadError = error }
            }
            throw error
        }
    }

    func embed(_ alignedFace: CGImage) async throws -> [Float] {
        beginRequest()
        defer { endRequest() }
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
    /// Internal visibility lets the release contract test exercise the exact production
    /// preprocessing path even when the optional model is absent from a clean checkout.
    static func makeInput(from image: CGImage) -> MLMultiArray? {
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
