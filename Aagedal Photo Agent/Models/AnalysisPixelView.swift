import Foundation

/// The spatially aligned image representations available in Pixel Analysis.
///
/// Channel, alpha, edge, and luminance views are display aids derived from the selected source
/// representation. They do not replace or modify the case's source-bound evidence.
nonisolated enum AnalysisPixelViewMode: String, CaseIterable, Sendable {
    case normal
    case red
    case green
    case blue
    case luminance
    case alpha
    case edges
    case compressionResidual
    case noiseResidual
    case levelSweep
    case cloneDetection

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .luminance: "Luminance"
        case .alpha: "Alpha"
        case .edges: "Edges"
        case .noiseResidual: "Noise Residual"
        case .levelSweep: "Level Sweep"
        case .cloneDetection: "Clone Detection"
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
        case .alpha: "Alpha"
        case .edges: "Edges"
        case .noiseResidual: "Noise"
        case .levelSweep: "Levels"
        case .cloneDetection: "Clones"
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
        case .alpha:
            "Source alpha coverage · opaque white, transparent black"
        case .edges:
            "Core Image CIEdges · intensity 3.0 · display-referred sRGB"
        case .noiseResidual:
            "2,048 px max · Metal-backed Core Image · sRGB luminance − 3×3 median · absolute difference ×8"
        case .levelSweep:
            "1,024 px while dragging, 2,048 px settled · Metal-backed Core Image · sRGB luminance · adjustable 32/255-wide contrast window"
        case .cloneDetection:
            "1,024 px max · 8×8 blocks on a 4 px grid · tolerant luminance-cell matches · ≥3 consistent translations · cyan highlights"
        case .compressionResidual:
            "2,048 px max preview · ImageIO JPEG 0.90 · |linear sRGB − re-encode| ×12 · alpha over 50% gray"
        }
    }

    var limitationLabel: String? {
        switch self {
        case .noiseResidual:
            "Texture, edges, compression, and camera processing affect residuals; differences do not establish manipulation."
        case .levelSweep:
            "Contrast enhancement can exaggerate ordinary gradients and compression boundaries; it does not establish manipulation."
        case .cloneDetection:
            "Repeated scene texture can match naturally. This baseline misses rotated, scaled, recolored, or off-grid copies; no matches do not establish authenticity."
        case .edges:
            "Edge strength is affected by focus, sharpening, noise, resizing, and scene texture; it does not establish manipulation."
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

/// Channel selection is independent of the spatial analysis operation.
nonisolated enum AnalysisPixelChannel: String, CaseIterable, Sendable {
    case rgb, red, green, blue, luminance

    var displayName: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .luminance: "Luminance"
        }
    }

    var viewMode: AnalysisPixelViewMode {
        switch self {
        case .rgb: .normal
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .luminance: .luminance
        }
    }
}

extension AnalysisPixelViewMode {
    nonisolated static var analysisModes: [Self] {
        [.normal, .alpha, .edges, .compressionResidual, .noiseResidual, .levelSweep, .cloneDetection]
    }
}
