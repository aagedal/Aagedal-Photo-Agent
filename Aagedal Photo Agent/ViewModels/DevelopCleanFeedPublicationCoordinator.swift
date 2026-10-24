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
        /// Whether the editor's unedited source may stand in when the live pipeline is not used.
        /// False for a photo that redacts (or whose redaction is not known yet): the feed shows
        /// black rather than the unblurred original.
        var allowsFallbackImage = true
        /// Whether the feed pipeline stays pinned to the full redacted settings instead of
        /// mirroring the editor's press-and-hold Before / mute projection.
        var holdsRedactedRender = false
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
        editorPipeline?.releaseMirrorParams()
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
        if enabled, let feedPipeline = controller.ensureFeedPipeline() {
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
    ///
    /// Privacy: for a photo with Anonymizer redactions the audience display never shows the
    /// unblurred original. Press-and-hold comparisons (Before, D mute, Cmd-D layer mute) keep the
    /// feed on the full redacted render, and before the GPU source exists the feed shows black
    /// instead of the unedited fallback. A photo whose settings are not known yet is treated the
    /// same way, except it never uses the live pipeline (its settings may be incomplete).
    func publicationDecision(
        hasSourceTexture: Bool,
        isShowingBefore: Bool,
        isMutingDevelop: Bool,
        isMutingLayer: Bool = false,
        redaction: RedactionKnowledge = .none,
        isCropToolActive: Bool,
        proposedCrop: CleanFeedController.FeedCrop?
    ) -> PublicationDecision? {
        guard isWorkspaceActive else { return nil }
        if !isCropToolActive, let proposedCrop {
            publishedCrop = proposedCrop
        }
        switch redaction {
        case .none:
            return PublicationDecision(
                usesEditPipeline: hasSourceTexture && !isShowingBefore && !isMutingDevelop,
                crop: publishedCrop
            )
        case .redacts:
            let isTransientComparison = isShowingBefore || isMutingDevelop || isMutingLayer
            return PublicationDecision(
                usesEditPipeline: hasSourceTexture,
                crop: publishedCrop,
                allowsFallbackImage: false,
                holdsRedactedRender: hasSourceTexture && isTransientComparison
            )
        case .unknown:
            return PublicationDecision(
                usesEditPipeline: false,
                crop: publishedCrop,
                allowsFallbackImage: false,
                holdsRedactedRender: false
            )
        }
    }

    /// `redactedSettings` is the full (non-transient) pipeline payload; it is pushed to the feed
    /// while the decision holds the redacted render.
    func publish(
        fallbackImage: CIImage?,
        isHDR: Bool,
        hasSourceTexture: Bool,
        isShowingBefore: Bool,
        isMutingDevelop: Bool,
        isMutingLayer: Bool = false,
        redaction: RedactionKnowledge = .none,
        redactedSettings: CameraRawSettings? = nil,
        editorPipeline: MetalLivePreviewPipeline? = nil,
        isCropToolActive: Bool,
        proposedCrop: CleanFeedController.FeedCrop?,
        controller: CleanFeedController
    ) {
        guard let decision = publicationDecision(
            hasSourceTexture: hasSourceTexture,
            isShowingBefore: isShowingBefore,
            isMutingDevelop: isMutingDevelop,
            isMutingLayer: isMutingLayer,
            redaction: redaction,
            isCropToolActive: isCropToolActive,
            proposedCrop: proposedCrop
        ) else { return }
        if decision.holdsRedactedRender {
            editorPipeline?.holdMirrorParams(redactedSettings)
        } else if editorPipeline?.isHoldingMirrorParams == true {
            editorPipeline?.releaseMirrorParams()
        }
        controller.feedImage = decision.allowsFallbackImage ? fallbackImage : nil
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
