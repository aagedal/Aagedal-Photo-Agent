import CoreImage
import Foundation
import Observation

/// Whether a refinement click includes or excludes the region under it.
enum AIMaskPointMode: Sendable {
    case add, subtract
}

/// Owns the transient lifecycle of click-to-select AI mask generation for one source image.
/// The editor remains responsible for applying a generated raster to its layer model; this owner
/// guarantees that cancellation, image changes, and late generator results cannot mutate it.
@MainActor
@Observable
final class AIMaskSelectionCoordinator {
    typealias Generator = @Sendable (
        CIImage,
        [AIMaskPromptPoint],
        Int,
        AIMaskTarget,
        AIMaskSelectionSize
    ) async throws -> GeneratedAIMask
    /// A live drag preview for the points, or nil when the current engine/target has none
    /// (Vision and Face only select on release).
    typealias Previewer = @Sendable (
        CIImage,
        [AIMaskPromptPoint],
        AIMaskTarget,
        AIMaskSelectionSize
    ) async throws -> AIMaskPreview?
    /// Analyses a photo ahead of the first click when the engine benefits from it.
    typealias Prewarmer = @Sendable (CIImage, AIMaskTarget) async -> Void

    var isSelecting = false
    var isGenerating = false
    var replacingMaskID: UUID?
    /// The AI mask that Add/Subtract clicks extend. Unlike a new selection or Select Again,
    /// refinement stays active after each click until the user finishes or changes layers.
    var refiningMaskID: UUID?
    var pointMode: AIMaskPointMode = .add
    var isRefining: Bool { refiningMaskID != nil }
    var target: AIMaskTarget = .automatic
    /// Which SAM proposal new and regenerated mattes use.
    var selectionSize: AIMaskSelectionSize = .automatic
    var errorMessage: String?
    /// The mask the current drag would produce. It stays up while the release generates the real
    /// matte, so the overlay does not flicker off before the layer appears.
    var preview: AIMaskPreview?

    @ObservationIgnored private var activeImageURL: URL?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private let generator: Generator
    @ObservationIgnored private let previewer: Previewer
    @ObservationIgnored private let prewarmer: Prewarmer
    @ObservationIgnored private var previewID = UUID()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreview: (source: CIImage, points: [AIMaskPromptPoint])?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?

    init(
        generator: @escaping Generator = { image, points, orientation, target, size in
            let engine = AIMaskEngine.current
            return try await Task.detached(priority: .userInitiated) {
                try AIMaskGenerator.generate(
                    from: image,
                    points: points,
                    sourceOrientation: orientation,
                    target: target,
                    engine: engine,
                    size: size
                )
            }.value
        },
        previewer: @escaping Previewer = { image, points, target, size in
            guard AIMaskEngine.current == .sam21, target != .face else { return nil }
            return try await Task.detached(priority: .userInitiated) {
                try AIMaskGenerator.previewWithSAM(from: image, points: points, target: target, size: size)
            }.value
        },
        prewarmer: @escaping Prewarmer = { image, target in
            guard AIMaskEngine.current == .sam21 else { return }
            await Task.detached(priority: .utility) {
                AIMaskGenerator.prewarmSAM(for: image, target: target)
            }.value
        }
    ) {
        self.generator = generator
        self.previewer = previewer
        self.prewarmer = prewarmer
    }

    /// Starts a new image-scoped lifecycle and cancels any Vision request from the previous image.
    func beginImageSession(_ imageURL: URL?) {
        cancelGenerationAndInvalidateRequest()
        activeImageURL = imageURL
        isSelecting = false
        isGenerating = false
        replacingMaskID = nil
        refiningMaskID = nil
        errorMessage = nil
        clearPreview()
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    @discardableResult
    func beginSelection(replacing maskID: UUID?, resetsTarget: Bool) -> Bool {
        guard activeImageURL != nil, !isGenerating else { return false }
        if resetsTarget {
            target = .automatic
            selectionSize = .automatic
        }
        replacingMaskID = maskID
        refiningMaskID = nil
        isSelecting = true
        return true
    }

    /// Enters Add/Subtract mode for an existing AI mask. Each click regenerates the mask from its
    /// recorded points plus the new one; the mode stays active between clicks.
    @discardableResult
    func beginRefinement(of maskID: UUID, mode: AIMaskPointMode) -> Bool {
        guard activeImageURL != nil, !isGenerating else { return false }
        replacingMaskID = nil
        refiningMaskID = maskID
        pointMode = mode
        errorMessage = nil
        isSelecting = true
        return true
    }

    func cancelSelection() {
        cancelGenerationAndInvalidateRequest()
        clearPreview()
        isSelecting = false
        isGenerating = false
        replacingMaskID = nil
        refiningMaskID = nil
    }

    /// Layer selection changes dismiss an idle pick overlay, but must not invalidate a generation
    /// that is completing and about to select its resulting layer.
    func cancelSelectionIfIdle() {
        guard !isGenerating else { return }
        clearPreview()
        isSelecting = false
        replacingMaskID = nil
        refiningMaskID = nil
    }

    func adoptTarget(_ target: AIMaskTarget) {
        self.target = target
    }

    func adoptSelectionSize(_ size: AIMaskSelectionSize) {
        selectionSize = size
    }

    /// Starts analysing `source` for the current target in the background. Repeated calls for the
    /// same photo are cheap: the generator caches its analysis per image.
    func prewarm(_ source: CIImage, imageURL: URL) {
        guard activeImageURL == imageURL else { return }
        let target = target
        let prewarmer = prewarmer
        prewarmTask?.cancel()
        prewarmTask = Task {
            await prewarmer(source, target)
        }
    }

    /// Shows what the selection would be for `points` while the pointer is down. Only the latest
    /// request matters: while one preview runs, newer positions replace each other and the last
    /// one runs next, so a fast drag never queues stale work.
    func updatePreview(from source: CIImage, points: [AIMaskPromptPoint], imageURL: URL) {
        guard isSelecting, !isGenerating, activeImageURL == imageURL,
              points.first?.isPositive == true else { return }
        pendingPreview = (source, points)
        if previewTask == nil { runPendingPreview(imageURL: imageURL) }
    }

    func clearPreview() {
        stopPreviewWork()
        preview = nil
    }

    private func stopPreviewWork() {
        previewID = UUID()
        previewTask?.cancel()
        previewTask = nil
        pendingPreview = nil
    }

    private func runPendingPreview(imageURL: URL) {
        guard let request = pendingPreview else {
            previewTask = nil
            return
        }
        pendingPreview = nil
        let id = previewID
        let target = target
        let size = selectionSize
        let previewer = previewer
        previewTask = Task { [weak self] in
            // A failed preview (no model yet, nothing under the pointer) just shows nothing; the
            // release reports the real error.
            let result = try? await previewer(request.source, request.points, target, size)
            guard let self, previewID == id, activeImageURL == imageURL else { return }
            preview = result
            runPendingPreview(imageURL: imageURL)
        }
    }

    @discardableResult
    func generate(
        from source: CIImage,
        sourcePoint: CGPoint,
        sourceOrientation: Int,
        imageURL: URL,
        onGenerated: @escaping @MainActor (GeneratedAIMask, UUID?) -> Void
    ) -> Bool {
        generate(
            from: source,
            points: [AIMaskPromptPoint(x: sourcePoint.x, y: sourcePoint.y, isPositive: true)],
            sourceOrientation: sourceOrientation,
            imageURL: imageURL,
            onGenerated: onGenerated
        )
    }

    /// Generates from an ordered point list (the first must be positive). `onGenerated` receives
    /// the mask to replace: the Select Again or refined mask, or nil for a new layer.
    @discardableResult
    func generate(
        from source: CIImage,
        points: [AIMaskPromptPoint],
        sourceOrientation: Int,
        imageURL: URL,
        onGenerated: @escaping @MainActor (GeneratedAIMask, UUID?) -> Void
    ) -> Bool {
        guard isSelecting, !isGenerating, activeImageURL == imageURL else { return false }
        return startGeneration(
            from: source,
            points: points,
            sourceOrientation: sourceOrientation,
            imageURL: imageURL,
            replacementID: refiningMaskID ?? replacingMaskID,
            endsSelection: refiningMaskID == nil,
            onGenerated: onGenerated
        )
    }

    /// Rebuilds an existing mask from its recorded points, e.g. after a Size change. It does not
    /// enter or leave selection, so it also works between Add/Subtract clicks.
    @discardableResult
    func regenerate(
        replacing maskID: UUID,
        from source: CIImage,
        points: [AIMaskPromptPoint],
        sourceOrientation: Int,
        imageURL: URL,
        onGenerated: @escaping @MainActor (GeneratedAIMask, UUID?) -> Void
    ) -> Bool {
        guard !isGenerating, activeImageURL == imageURL,
              !isSelecting || refiningMaskID == maskID else { return false }
        return startGeneration(
            from: source,
            points: points,
            sourceOrientation: sourceOrientation,
            imageURL: imageURL,
            replacementID: maskID,
            endsSelection: false,
            onGenerated: onGenerated
        )
    }

    private func startGeneration(
        from source: CIImage,
        points: [AIMaskPromptPoint],
        sourceOrientation: Int,
        imageURL: URL,
        replacementID: UUID?,
        endsSelection: Bool,
        onGenerated: @escaping @MainActor (GeneratedAIMask, UUID?) -> Void
    ) -> Bool {
        stopPreviewWork()
        let requestedTarget = target
        let requestedSize = selectionSize
        let newRequestID = UUID()
        requestID = newRequestID
        isGenerating = true
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await generator(
                    source,
                    points,
                    sourceOrientation,
                    requestedTarget,
                    requestedSize
                )
                guard !Task.isCancelled,
                      requestID == newRequestID,
                      activeImageURL == imageURL else { return }

                isGenerating = false
                errorMessage = nil
                preview = nil
                if endsSelection {
                    isSelecting = false
                    replacingMaskID = nil
                }
                generationTask = nil
                onGenerated(generated, replacementID)
            } catch is CancellationError {
                guard requestID == newRequestID, activeImageURL == imageURL else { return }
                isGenerating = false
                preview = nil
                generationTask = nil
            } catch {
                guard !Task.isCancelled,
                      requestID == newRequestID,
                      activeImageURL == imageURL else { return }
                isGenerating = false
                preview = nil
                errorMessage = error.localizedDescription
                generationTask = nil
            }
        }
        return true
    }

    func endImageSession() {
        beginImageSession(nil)
    }

    private func cancelGenerationAndInvalidateRequest() {
        requestID = UUID()
        generationTask?.cancel()
        generationTask = nil
    }
}
