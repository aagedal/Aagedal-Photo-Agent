import CoreImage
import Observation

/// Owns the Develop workspace's publication contract with Clean Feed.
///
/// The editor still owns image processing and viewport geometry. This coordinator owns the
/// workspace lifetime, live-pipeline mirror connection, live-versus-fallback presentation policy,
/// committed-crop freezing while the crop tool is open, and the final redraw publication.
@MainActor
@Observable
final class DevelopCleanFeedPublicationCoordinator {
    struct PublicationDecision: Equatable {
        let usesEditPipeline: Bool
        let crop: CleanFeedController.FeedCrop?
    }

    private(set) var isWorkspaceActive = false
    private(set) var publishedCrop: CleanFeedController.FeedCrop?

    func beginWorkspace(controller: CleanFeedController) {
        isWorkspaceActive = true
        publishedCrop = controller.feedCrop
        controller.editModeActive = true
    }

    /// Disconnects every editor-owned Clean Feed resource so browse mode can resume publication.
    func endWorkspace(
        editorPipeline: MetalLivePreviewPipeline?,
        controller: CleanFeedController
    ) {
        isWorkspaceActive = false
        editorPipeline?.mirror = nil
        editorPipeline?.onParamsChanged = nil
        controller.editModeActive = false
        controller.useEditPipeline = false
        controller.feedPipeline?.clearSourceTexture()
        controller.setFeedContinuousRendering(false)
        controller.requestFeedRedraw()
        publishedCrop = nil
    }

    /// Connects the editor and feed pipelines when Clean Feed is enabled, or releases that mirror
    /// immediately when it is disabled. The caller supplies the render callback because actual
    /// image processing remains outside this state owner.
    func updateMirror(
        enabled: Bool,
        editorPipeline: MetalLivePreviewPipeline?,
        controller: CleanFeedController,
        renderCurrent: () -> Void
    ) {
        guard isWorkspaceActive, let editorPipeline else { return }
        if enabled, let feedPipeline = controller.feedPipeline {
            editorPipeline.mirror = feedPipeline
            feedPipeline.asShotTemperature = editorPipeline.asShotTemperature
            feedPipeline.asShotTint = editorPipeline.asShotTint
            feedPipeline.gamutClipMode = editorPipeline.gamutClipMode
            editorPipeline.shareSourceTexture(with: feedPipeline)
            editorPipeline.onParamsChanged = { [hooks = controller.hooks] in hooks.redraw?() }
            renderCurrent()
        } else {
            editorPipeline.mirror = nil
            editorPipeline.onParamsChanged = nil
            controller.useEditPipeline = false
            controller.feedPipeline?.clearSourceTexture()
        }
    }

    /// Resolves the state that may be published for the current workspace. Crop edits remain
    /// frozen at the last committed geometry until the crop tool closes.
    func publicationDecision(
        hasSourceTexture: Bool,
        isShowingBefore: Bool,
        isMutingDevelop: Bool,
        isCropToolActive: Bool,
        proposedCrop: CleanFeedController.FeedCrop?
    ) -> PublicationDecision? {
        guard isWorkspaceActive else { return nil }
        if !isCropToolActive, let proposedCrop {
            publishedCrop = proposedCrop
        }
        return PublicationDecision(
            usesEditPipeline: hasSourceTexture && !isShowingBefore && !isMutingDevelop,
            crop: publishedCrop
        )
    }

    func publish(
        fallbackImage: CIImage?,
        isHDR: Bool,
        hasSourceTexture: Bool,
        isShowingBefore: Bool,
        isMutingDevelop: Bool,
        isCropToolActive: Bool,
        proposedCrop: CleanFeedController.FeedCrop?,
        controller: CleanFeedController
    ) {
        guard let decision = publicationDecision(
            hasSourceTexture: hasSourceTexture,
            isShowingBefore: isShowingBefore,
            isMutingDevelop: isMutingDevelop,
            isCropToolActive: isCropToolActive,
            proposedCrop: proposedCrop
        ) else { return }
        controller.feedImage = fallbackImage
        controller.isHDR = isHDR
        controller.useEditPipeline = decision.usesEditPipeline
        controller.feedCrop = decision.crop
        controller.requestFeedRedraw()
    }

    func setContinuousRendering(_ enabled: Bool, controller: CleanFeedController) {
        guard isWorkspaceActive else { return }
        controller.setFeedContinuousRendering(enabled)
    }
}
