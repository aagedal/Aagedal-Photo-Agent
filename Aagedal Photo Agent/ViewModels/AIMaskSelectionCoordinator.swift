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
        AIMaskTarget
    ) async throws -> GeneratedAIMask

    var isSelecting = false
    var isGenerating = false
    var replacingMaskID: UUID?
    /// The AI mask that Add/Subtract clicks extend. Unlike a new selection or Select Again,
    /// refinement stays active after each click until the user finishes or changes layers.
    var refiningMaskID: UUID?
    var pointMode: AIMaskPointMode = .add
    var isRefining: Bool { refiningMaskID != nil }
    var target: AIMaskTarget = .automatic
    var errorMessage: String?

    @ObservationIgnored private var activeImageURL: URL?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private let generator: Generator

    init(generator: @escaping Generator = { image, points, orientation, target in
        let engine = AIMaskEngine.current
        return try await Task.detached(priority: .userInitiated) {
            try AIMaskGenerator.generate(
                from: image,
                points: points,
                sourceOrientation: orientation,
                target: target,
                engine: engine
            )
        }.value
    }) {
        self.generator = generator
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
    }

    @discardableResult
    func beginSelection(replacing maskID: UUID?, resetsTarget: Bool) -> Bool {
        guard activeImageURL != nil, !isGenerating else { return false }
        if resetsTarget { target = .automatic }
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
        isSelecting = false
        isGenerating = false
        replacingMaskID = nil
        refiningMaskID = nil
    }

    /// Layer selection changes dismiss an idle pick overlay, but must not invalidate a generation
    /// that is completing and about to select its resulting layer.
    func cancelSelectionIfIdle() {
        guard !isGenerating else { return }
        isSelecting = false
        replacingMaskID = nil
        refiningMaskID = nil
    }

    func adoptTarget(_ target: AIMaskTarget) {
        self.target = target
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

        let replacementID = refiningMaskID ?? replacingMaskID
        let staysSelecting = refiningMaskID != nil
        let requestedTarget = target
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
                    requestedTarget
                )
                guard !Task.isCancelled,
                      requestID == newRequestID,
                      activeImageURL == imageURL else { return }

                isGenerating = false
                errorMessage = nil
                if !staysSelecting {
                    isSelecting = false
                    replacingMaskID = nil
                }
                generationTask = nil
                onGenerated(generated, replacementID)
            } catch is CancellationError {
                guard requestID == newRequestID, activeImageURL == imageURL else { return }
                isGenerating = false
                generationTask = nil
            } catch {
                guard !Task.isCancelled,
                      requestID == newRequestID,
                      activeImageURL == imageURL else { return }
                isGenerating = false
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
