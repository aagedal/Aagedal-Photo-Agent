import CoreImage
import Foundation
import Observation

/// Owns the transient lifecycle of click-to-select AI mask generation for one source image.
/// The editor remains responsible for applying a generated raster to its layer model; this owner
/// guarantees that cancellation, image changes, and late generator results cannot mutate it.
@MainActor
@Observable
final class AIMaskSelectionCoordinator {
    typealias Generator = @Sendable (
        CIImage,
        CGPoint,
        Int,
        AIMaskTarget
    ) async throws -> GeneratedAIMask

    var isSelecting = false
    var isGenerating = false
    var replacingMaskID: UUID?
    var target: AIMaskTarget = .automatic
    var errorMessage: String?

    @ObservationIgnored private var activeImageURL: URL?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private let generator: Generator

    init(generator: @escaping Generator = { image, point, orientation, target in
        try await Task.detached(priority: .userInitiated) {
            try AIMaskGenerator.generate(
                from: image,
                displayPoint: point,
                sourceOrientation: orientation,
                target: target
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
        errorMessage = nil
    }

    @discardableResult
    func beginSelection(replacing maskID: UUID?, resetsTarget: Bool) -> Bool {
        guard activeImageURL != nil, !isGenerating else { return false }
        if resetsTarget { target = .automatic }
        replacingMaskID = maskID
        isSelecting = true
        return true
    }

    func cancelSelection() {
        cancelGenerationAndInvalidateRequest()
        isSelecting = false
        isGenerating = false
        replacingMaskID = nil
    }

    /// Layer selection changes dismiss an idle pick overlay, but must not invalidate a generation
    /// that is completing and about to select its resulting layer.
    func cancelSelectionIfIdle() {
        guard !isGenerating else { return }
        isSelecting = false
        replacingMaskID = nil
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
        guard isSelecting, !isGenerating, activeImageURL == imageURL else { return false }

        let replacementID = replacingMaskID
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
                    sourcePoint,
                    sourceOrientation,
                    requestedTarget
                )
                guard !Task.isCancelled,
                      requestID == newRequestID,
                      activeImageURL == imageURL else { return }

                isGenerating = false
                isSelecting = false
                replacingMaskID = nil
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
