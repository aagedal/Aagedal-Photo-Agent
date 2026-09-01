import Foundation

/// Immutable facts that determine how one Develop preview refresh should be dispatched.
/// Pixel references and renderer implementations deliberately stay outside this value.
nonisolated struct DevelopRenderPolicyInput: Equatable, Sendable {
    var hasSourceImage: Bool
    var isSliderInteractionActive: Bool
    var hasMetalScopePipeline: Bool
    var hasMetalSourceTexture: Bool
    var isCropInteractionActive: Bool
    var isComparisonActive: Bool
}

/// The mutually exclusive work path for one Develop preview refresh.
nonisolated enum DevelopRenderWorkPath: Equatable, Sendable {
    /// No Core Image source exists; publish the retained `NSImage` fallback to the preview owner.
    case sourceFallback
    /// Metal scopes redraw continuously during the active control gesture; no CPU work is needed.
    case interactiveMetalScope
    /// No Metal scope pipeline exists, so request the throttled CPU scope fallback.
    case interactiveCPUScope
    /// Keep the full-resolution Metal preview live without materializing a competing CG image.
    case cropInteraction
    /// Materialize the current Core Image result for the fallback preview and scope publication.
    case materializePreview
}

/// A complete render-policy decision consumed by `EditWorkspaceView`.
nonisolated struct DevelopRenderPolicyDecision: Equatable, Sendable {
    var workPath: DevelopRenderWorkPath
    var shouldScheduleComparison: Bool
    var shouldUpdateScopeCrop: Bool
    var shouldUpdateMetalPipeline: Bool

    var shouldRequestMetalScopeRedraw: Bool { shouldUpdateMetalPipeline }
}

/// Owns the branch policy for Develop preview refreshes without owning renderer state or pixels.
///
/// Source decode, Metal mutation, Core Image materialization, scope publication, and request-lifetime
/// cancellation remain injected at the view and their existing state-owning coordinators. Keeping the
/// policy itself value-based makes every dispatch combination deterministic and independently testable.
nonisolated struct DevelopRenderPolicyCoordinator: Sendable {
    func decision(for input: DevelopRenderPolicyInput) -> DevelopRenderPolicyDecision {
        guard input.hasSourceImage else {
            return DevelopRenderPolicyDecision(
                workPath: .sourceFallback,
                shouldScheduleComparison: false,
                shouldUpdateScopeCrop: false,
                shouldUpdateMetalPipeline: false
            )
        }

        let workPath: DevelopRenderWorkPath
        if input.isSliderInteractionActive {
            workPath = input.hasMetalScopePipeline
                ? .interactiveMetalScope
                : .interactiveCPUScope
        } else if input.isCropInteractionActive {
            workPath = .cropInteraction
        } else {
            workPath = .materializePreview
        }

        return DevelopRenderPolicyDecision(
            workPath: workPath,
            shouldScheduleComparison: input.isComparisonActive,
            shouldUpdateScopeCrop: true,
            shouldUpdateMetalPipeline: !input.isSliderInteractionActive
                && input.hasMetalSourceTexture
        )
    }

    /// The editor and scopes use the same configured output gamut for the active SDR/HDR mode.
    func displayGamut(
        isHDR: Bool,
        sdr: TargetColorGamut,
        hdr: TargetColorGamut
    ) -> TargetColorGamut {
        isHDR ? hdr : sdr
    }

    /// Metal's clipping mode reserves zero for disabled and uses one-based gamut identifiers.
    func gamutClipMode(
        isEnabled: Bool,
        target: TargetColorGamut
    ) -> UInt32 {
        isEnabled ? target.shaderIndex + 1 : 0
    }
}
