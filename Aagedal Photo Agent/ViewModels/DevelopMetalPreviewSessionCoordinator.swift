import Foundation
import Observation

/// Owns the live Metal preview objects and their workspace/image presentation lifetime.
///
/// The pipeline is expensive and remains retained for this view's lifetime, while workspace and
/// source-image state are explicit. `EditWorkspaceView` supplies editing facts and render commands;
/// this owner creates and warms the engine, resets image-scoped GPU state, owns continuous-render
/// presentation, and tears the preview down through one independently testable boundary.
@MainActor
@Observable
final class DevelopMetalPreviewSessionCoordinator {
    typealias PipelineFactory = @MainActor () -> MetalLivePreviewPipeline?
    typealias PipelineWarmup = @MainActor (MetalLivePreviewPipeline) -> Void

    private(set) var pipeline: MetalLivePreviewPipeline?
    private(set) var isWorkspaceActive = false
    private(set) var sourceSessionGeneration: UInt64?
    private(set) var isContinuousRenderingRequested = false

    @ObservationIgnored let viewCoordinator: MetalPreviewView.Coordinator
    @ObservationIgnored private let pipelineFactory: PipelineFactory
    @ObservationIgnored private let warmup: PipelineWarmup

    init(
        viewCoordinator: MetalPreviewView.Coordinator = MetalPreviewView.Coordinator(),
        pipelineFactory: @escaping PipelineFactory = {
            MetalLivePreviewPipeline(
                device: MetalPreviewView.Coordinator.device,
                commandQueue: MetalPreviewView.Coordinator.commandQueue
            )
        },
        warmup: @escaping PipelineWarmup = { pipeline in
            Task.detached(priority: .low) {
                pipeline.warmupCIContext()
            }
        }
    ) {
        self.viewCoordinator = viewCoordinator
        self.pipelineFactory = pipelineFactory
        self.warmup = warmup
    }

    /// Activates the presentation and lazily creates the expensive pipeline once. A failed factory
    /// can be retried by a later workspace presentation without retaining a partial engine.
    func beginWorkspace() {
        guard !isWorkspaceActive else { return }
        isWorkspaceActive = true
        guard pipeline == nil, let pipeline = pipelineFactory() else { return }
        self.pipeline = pipeline
        warmup(pipeline)
    }

    /// Opens a source-publication generation and restores image-scoped GPU defaults.
    func beginImageSession(_ generation: UInt64) {
        guard isWorkspaceActive else { return }
        sourceSessionGeneration = generation
        pipeline?.beginSourceImageSession(generation)
        pipeline?.maskMattePreviewMaskID = nil
        pipeline?.asShotTemperature = 6500
        pipeline?.asShotTint = 0
        pipeline?.updateOverlayParams(geometry: nil, visible: false)
    }

    /// Advances publication identity for an in-memory same-image rotation without clearing the
    /// valid fallback texture. This mirrors the preview-session generation replacement exactly.
    func replaceSourceImagePublication(_ generation: UInt64) {
        guard isWorkspaceActive else { return }
        sourceSessionGeneration = generation
        pipeline?.beginSourceImagePublication(generation)
    }

    /// Rejects the active source generation and releases its retained texture without destroying
    /// the reusable pipeline.
    func endImageSession() {
        sourceSessionGeneration = nil
        pipeline?.maskMattePreviewMaskID = nil
        pipeline?.clearSourceTexture()
    }

    func startContinuousRendering() {
        guard isWorkspaceActive else { return }
        isContinuousRenderingRequested = true
        viewCoordinator.startContinuousRendering()
    }

    func stopContinuousRendering() {
        isContinuousRenderingRequested = false
        viewCoordinator.stopContinuousRendering()
    }

    func requestRedraw() {
        guard isWorkspaceActive else { return }
        viewCoordinator.requestRedraw()
    }

    /// Ends every workspace/image presentation state while retaining the warmed pipeline for a
    /// possible later appearance of the same SwiftUI view identity.
    func endWorkspace() {
        endImageSession()
        pipeline?.updateOverlayParams(geometry: nil, visible: false)
        stopContinuousRendering()
        isWorkspaceActive = false
    }
}
