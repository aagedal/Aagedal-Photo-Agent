import Foundation
import Observation

/// Owns the image-scoped preview lifecycle for the Develop workspace.
///
/// Source/load identity, visible progress, and every task that can publish preview pixels share
/// one cancellation boundary. Starting another image session therefore invalidates the quick
/// preview, final decode, scope render, adjacent RAW precache, and zoom upgrade together. The
/// actual decode and Metal work remain at the view/pipeline boundary; this owner only coordinates
/// their lifetime and independently testable state.
@MainActor
@Observable
final class DevelopPreviewSessionCoordinator {
    private(set) var sessionGeneration: UInt64 = 0
    private(set) var activeImageURL: URL?
    private(set) var sourceLoadedURL: URL?
    private(set) var sourceLoadedOrientation: Int?

    var isLoadingPreview = false
    var isDecodingFullResolution = false
    var isEditFullResLoaded = false

    @ObservationIgnored private(set) var sourceLoadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var previewRenderTask: Task<Void, Never>?
    @ObservationIgnored private(set) var adjacentPrecacheTask: Task<Void, Never>?
    @ObservationIgnored private(set) var fullResolutionUpgradeTask: Task<Void, Never>?

    /// Starts a new source-image lifecycle and cancels all work capable of publishing pixels from
    /// the previous image. A non-nil source is recorded immediately, matching the decode request
    /// identity used by in-place orientation changes.
    func beginImageSession(_ imageURL: URL?, orientation: Int?) {
        cancelAllTasks()
        sessionGeneration &+= 1
        activeImageURL = imageURL
        sourceLoadedURL = imageURL
        sourceLoadedOrientation = imageURL == nil ? nil : orientation
        isLoadingPreview = false
        isDecodingFullResolution = false
        isEditFullResLoaded = false
    }

    func endImageSession() {
        beginImageSession(nil, orientation: nil)
    }

    /// Returns the orientation of the retained source only when it belongs to the active image.
    func loadedOrientation(for imageURL: URL) -> Int? {
        guard activeImageURL == imageURL, sourceLoadedURL == imageURL else { return nil }
        return sourceLoadedOrientation
    }

    func recordLoadedOrientation(_ orientation: Int) {
        guard activeImageURL != nil, sourceLoadedURL == activeImageURL else { return }
        sourceLoadedOrientation = orientation
    }

    func replaceSourceLoadTask(with task: Task<Void, Never>?) {
        if task != nil { sourceLoadTask?.cancel() }
        sourceLoadTask = task
    }

    func replacePreviewRenderTask(with task: Task<Void, Never>?) {
        if task != nil { previewRenderTask?.cancel() }
        previewRenderTask = task
    }

    func replaceAdjacentPrecacheTask(with task: Task<Void, Never>?) {
        if task != nil { adjacentPrecacheTask?.cancel() }
        adjacentPrecacheTask = task
    }

    func replaceFullResolutionUpgradeTask(with task: Task<Void, Never>?) {
        if task != nil { fullResolutionUpgradeTask?.cancel() }
        fullResolutionUpgradeTask = task
    }

    /// A cancelled producer may resume after the user navigates away and back to the same URL.
    /// Only the generation that installed the task may clear its handle.
    func finishFullResolutionUpgrade(sessionGeneration: UInt64) {
        guard self.sessionGeneration == sessionGeneration else { return }
        fullResolutionUpgradeTask = nil
    }

    func cancelAllTasks() {
        sourceLoadTask?.cancel()
        previewRenderTask?.cancel()
        adjacentPrecacheTask?.cancel()
        fullResolutionUpgradeTask?.cancel()
        sourceLoadTask = nil
        previewRenderTask = nil
        adjacentPrecacheTask = nil
        fullResolutionUpgradeTask = nil
    }
}
