import Foundation
import Observation

/// Section visibility toggles are sticky workspace preferences, while the keyboard-driven
/// comparison modes are press-and-hold interactions. This value lets the transient owner apply
/// both policies to a render copy without taking ownership of the section controls themselves.
nonisolated struct DevelopSectionMuteState: Equatable, Sendable {
    var color = false
    var exposure = false
    var detail = false
    var toneCurve = false
    var hsl = false
    var film = false
}

/// Owns press-and-hold comparison state for the Develop preview.
///
/// None of these modes persist an edit. The coordinator projects them onto a render-only copy of
/// `CameraRawSettings`, including selected-mask muting, so key-up and image-session teardown can
/// never leave the editable metadata temporarily disabled.
@MainActor
@Observable
final class DevelopTransientPreviewCoordinator {
    private(set) var activeImageURL: URL?
    private(set) var isShowingBefore = false
    private(set) var isMutingDevelop = false
    private(set) var isMutingGlobal = false
    private(set) var mutedMaskIndex: Int?

    var isMutingSelectedMask: Bool { mutedMaskIndex != nil }

    /// Starts a new image lifetime and releases every press-and-hold mode from the prior image.
    func beginImageSession(_ imageURL: URL?) {
        activeImageURL = imageURL
        releaseAll()
    }

    func endImageSession() {
        activeImageURL = nil
        releaseAll()
    }

    func beginBeforeComparison() {
        isShowingBefore = true
    }

    func endBeforeComparison() {
        isShowingBefore = false
    }

    func beginDevelopMute() {
        isMutingDevelop = true
    }

    func endDevelopMute() {
        isMutingDevelop = false
    }

    /// Begins a current-layer mute. A nil mask index represents Global; a non-negative index
    /// represents the selected local adjustment. Repeated key-down events retain the first target.
    @discardableResult
    func beginLayerMute(maskIndex: Int?) -> Bool {
        guard !isMutingGlobal, mutedMaskIndex == nil else { return false }
        if let maskIndex {
            guard maskIndex >= 0 else { return false }
            mutedMaskIndex = maskIndex
        } else {
            isMutingGlobal = true
        }
        return true
    }

    /// Releases whichever current-layer comparison is active.
    @discardableResult
    func endLayerMute() -> Bool {
        let changed = isMutingGlobal || mutedMaskIndex != nil
        isMutingGlobal = false
        mutedMaskIndex = nil
        return changed
    }

    func releaseAll() {
        isShowingBefore = false
        isMutingDevelop = false
        isMutingGlobal = false
        mutedMaskIndex = nil
    }

    /// Produces the exact settings payload for the live pipeline without mutating the editable
    /// metadata. RAW sources still receive the historical tonemap-only payload when settings are
    /// absent, and Global mute preserves only local masks plus HDR display mode.
    func settingsForPipeline(
        _ settings: CameraRawSettings?,
        isRawSource: Bool,
        sectionMutes: DevelopSectionMuteState
    ) -> CameraRawSettings? {
        guard var projected = settings else {
            guard isRawSource else { return nil }
            var tonemapOnly = CameraRawSettings()
            tonemapOnly.sourceHasHDRHeadroom = true
            return tonemapOnly
        }

        projected.sourceHasHDRHeadroom = isRawSource ? true : nil

        if isMutingGlobal {
            var masksOnly = CameraRawSettings()
            masksOnly.localAdjustments = projected.localAdjustments
            masksOnly.hdrEditMode = projected.hdrEditMode
            masksOnly.sourceHasHDRHeadroom = isRawSource ? true : nil
            return masksOnly
        }

        if let mutedMaskIndex,
           projected.localAdjustments?.indices.contains(mutedMaskIndex) == true {
            projected.localAdjustments?[mutedMaskIndex].enabled = false
        }

        if isMutingDevelop || sectionMutes.color {
            projected.whiteBalance = nil
            projected.temperature = nil
            projected.tint = nil
            projected.incrementalTemperature = nil
            projected.incrementalTint = nil
            projected.asShotNeutralTemperature = nil
            projected.asShotNeutralTint = nil
            projected.saturation = nil
            projected.vibrance = nil
            projected.globalDensity = nil
        }
        if isMutingDevelop || sectionMutes.exposure {
            projected.exposure2012 = nil
            projected.contrast2012 = nil
            projected.highlights2012 = nil
            projected.shadows2012 = nil
            projected.whites2012 = nil
            projected.blacks2012 = nil
        }
        if isMutingDevelop || sectionMutes.detail {
            projected.sharpness = nil
            projected.clarity2012 = nil
            projected.dehaze = nil
        }
        if isMutingDevelop || sectionMutes.toneCurve {
            projected.toneCurve = nil
        }
        if isMutingDevelop || sectionMutes.hsl {
            projected.hslAdjustments = nil
        }
        if isMutingDevelop || sectionMutes.film {
            projected.filmEmulation = nil
        }
        if isMutingDevelop {
            projected.localAdjustments = nil
        }
        return projected
    }
}
