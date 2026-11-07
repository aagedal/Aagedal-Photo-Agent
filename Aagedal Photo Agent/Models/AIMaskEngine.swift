import Foundation

/// The model behind click-to-select AI masks. Vision is the shipping default; SAM 2.1 is an
/// experimental, opt-in download kept side by side so the two can be compared on real photos.
/// Both produce the same `AIMaskGeometry` raster, so saved masks never depend on the engine.
nonisolated enum AIMaskEngine: String, CaseIterable, Sendable {
    case vision
    case sam21

    /// Master switch for the SAM 2.1 experiment: the Settings section, the Develop engine picker
    /// and the engine preference itself. Turn off before a release that should not offer it; the
    /// model files and code stay intact, and every AI mask falls back to Vision.
    static let samExperimentEnabled = true

    var title: String {
        switch self {
        case .vision: return "Vision"
        case .sam21: return "SAM 2.1"
        }
    }

    /// The engine the next generation uses. Read at click time (off the main actor too), so a
    /// picker change applies to the very next selection.
    static var current: AIMaskEngine {
        guard samExperimentEnabled,
              let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.aiMaskEngine),
              let engine = AIMaskEngine(rawValue: raw)
        else { return .vision }
        return engine
    }
}
