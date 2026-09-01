import AppKit
import CoreImage
import Foundation
import Observation

/// Owns the image-scoped preview lifecycle for the Develop workspace.
///
/// Source/load identity, retained decoded pixels, visible progress, and every task that can replace
/// the source texture share one cancellation boundary. Starting another image session therefore
/// invalidates the quick decode, final decode, adjacent RAW precache, and zoom upgrade together.
/// Materialized-preview publication has its own `DevelopPreviewRenderCoordinator`, which the same
/// image-session events begin and end alongside this owner. Decode and Metal work remain injected at
/// the view/pipeline boundary; this owner gates their source publication and independently testable
/// lifetime state.
@MainActor
@Observable
final class DevelopPreviewSessionCoordinator {
    private(set) var sessionGeneration: UInt64 = 0
    private(set) var activeImageURL: URL?
    private(set) var sourceLoadedURL: URL?
    private(set) var sourceLoadedOrientation: Int?
    private(set) var sourceImage: NSImage?
    private(set) var sourceCIImage: CIImage?

    var isLoadingPreview = false
    var isDecodingFullResolution = false
    var isEditFullResLoaded = false

    @ObservationIgnored private(set) var sourceLoadTask: Task<Void, Never>?
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
        sourceImage = nil
        sourceCIImage = nil
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

    /// Publishes a quick or fallback source only into the image session that requested it.
    /// Generation participates in the identity so an A → B → A navigation cannot accept a
    /// completion retained by the first A session.
    @discardableResult
    func publishSource(
        image: NSImage?,
        ciImage: CIImage?,
        for imageURL: URL,
        sessionGeneration: UInt64
    ) -> Bool {
        guard isCurrent(imageURL: imageURL, sessionGeneration: sessionGeneration) else {
            return false
        }
        sourceImage = image
        sourceCIImage = ciImage
        return true
    }

    /// Replaces the retained Core Image source after the final decode has been materialized. The
    /// quick `NSImage` remains available as a fallback until the image session ends.
    @discardableResult
    func publishMaterializedSource(
        _ ciImage: CIImage,
        for imageURL: URL,
        sessionGeneration: UInt64
    ) -> Bool {
        guard isCurrent(imageURL: imageURL, sessionGeneration: sessionGeneration) else {
            return false
        }
        sourceCIImage = ciImage
        return true
    }

    /// Replaces both retained representations after an in-memory orientation change. Rotation is
    /// deliberately scoped to the active decoded source so another image cannot inherit its pixels.
    @discardableResult
    func replaceSourceAfterRotation(
        image: NSImage?,
        ciImage: CIImage?,
        orientation: Int,
        for imageURL: URL
    ) -> Bool {
        guard activeImageURL == imageURL, sourceLoadedURL == imageURL else { return false }
        // Rotation replaces the complete source lifecycle without blanking the last good pixels.
        // Advance identity so an already-running decode/upload from the pre-rotation task cannot
        // publish into this same-URL session after cooperative cancellation arrives too late.
        cancelAllTasks()
        sessionGeneration &+= 1
        sourceImage = image
        sourceCIImage = ciImage
        sourceLoadedOrientation = orientation
        return true
    }

    func replaceSourceLoadTask(with task: Task<Void, Never>?) {
        if task != nil { sourceLoadTask?.cancel() }
        sourceLoadTask = task
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
        adjacentPrecacheTask?.cancel()
        fullResolutionUpgradeTask?.cancel()
        sourceLoadTask = nil
        adjacentPrecacheTask = nil
        fullResolutionUpgradeTask = nil
    }

    private func isCurrent(imageURL: URL, sessionGeneration: UInt64) -> Bool {
        self.sessionGeneration == sessionGeneration
            && activeImageURL == imageURL
            && sourceLoadedURL == imageURL
    }
}
