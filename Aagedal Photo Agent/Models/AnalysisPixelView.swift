import Foundation

/// The spatially aligned image representations available in Pixel Analysis.
///
/// Channel and luminance views are display aids derived from the currently selected source
/// representation. They do not replace or modify the case's source-bound evidence.
nonisolated enum AnalysisPixelViewMode: String, CaseIterable, Sendable {
    case normal
    case red
    case green
    case blue
    case luminance

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .luminance: "Luminance"
        }
    }

    var compactLabel: String {
        switch self {
        case .normal: "Normal"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .luminance: "Luma"
        }
    }

    var methodLabel: String {
        switch self {
        case .normal:
            "Displayed representation"
        case .red:
            "Red channel · linear RGB · grayscale"
        case .green:
            "Green channel · linear RGB · grayscale"
        case .blue:
            "Blue channel · linear RGB · grayscale"
        case .luminance:
            "Relative luminance · linear RGB · Rec. 709 coefficients"
        }
    }
}
