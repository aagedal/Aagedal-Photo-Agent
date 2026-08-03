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
    case compressionResidual

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .luminance: "Luminance"
        case .compressionResidual: "Compression Residual"
        }
    }

    var compactLabel: String {
        switch self {
        case .normal: "Normal"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .luminance: "Luma"
        case .compressionResidual: "Residual"
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
        case .compressionResidual:
            "2,048 px max preview · ImageIO JPEG 0.90 · |linear sRGB − re-encode| ×12 · alpha over 50% gray"
        }
    }

    var limitationLabel: String? {
        switch self {
        case .compressionResidual:
            "Visualization only. Detail, gradients, resaving, and prior processing can all create bright residuals; this does not establish manipulation."
        default:
            nil
        }
    }
}

/// Fixed, reportable parameters for the baseline compression-residual view.
///
/// Keeping these values out of UI state makes screenshots, future report figures, and tests
/// reproducible. A later adjustable method must persist its parameters with the evidence.
nonisolated struct AnalysisCompressionResidualConfiguration: Hashable, Sendable {
    static let standard = AnalysisCompressionResidualConfiguration(
        jpegQuality: 0.90,
        differenceGain: 12,
        alphaMatte: 0.50
    )

    let jpegQuality: Double
    let differenceGain: CGFloat
    let alphaMatte: CGFloat
}
