import Foundation

/// Mosaic cell tiling. Purely cosmetic — all three sample one point per cell.
nonisolated enum AnonymizerMosaicShape: String, Codable, Sendable, CaseIterable, Identifiable {
    case square = "Square"
    case triangle = "Triangle"
    case hexagon = "Hexagon"

    var id: String { rawValue }

    /// Shader index (`MosaicCellCenter` in RedactAnonymizer.metal).
    var shaderIndex: Int32 {
        switch self {
        case .square: 0
        case .triangle: 1
        case .hexagon: 2
        }
    }
}

/// An RGB colour with 0...1 components (Frosted Glass tint).
nonisolated struct AnonymizerColor: Codable, Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let frostDefault = AnonymizerColor(red: 0.75, green: 0.75, blue: 0.75)

    /// "R,G,B" with three decimals, the form written to XMP.
    var xmpValue: String {
        String(format: "%.3f,%.3f,%.3f", red, green, blue)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(xmpValue: String) {
        let parts = xmpValue.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2],
              r.isFinite, g.isFinite, b.isFinite
        else { return nil }
        self.init(red: min(max(r, 0), 1), green: min(max(g, 0), 1), blue: min(max(b, 0), 1))
    }
}

/// Redact Anonymizer parameter ranges and defaults, kept identical to the plugin
/// (`shared/AnonymizerAlgo.h`). The three layer strengths have floors below their defaults:
/// a slider can't quietly weaken a layer past them; the layer switches turn a layer off
/// instead (for previewing the others).
nonisolated enum RedactDefaults {
    static let distortionAmount = 20.0
    static let distortionAmountRange: ClosedRange<Double> = 15...200
    static let distortionScale = 11.0
    static let distortionScaleRange: ClosedRange<Double> = 4...400
    static let blurRadius = 20.0
    static let blurAfterMosaicRadius = 40.0
    static let blurRadiusRange: ClosedRange<Double> = 15...100
    static let mosaicSize = 30.0
    static let mosaicSizeRange: ClosedRange<Double> = 21...256
    static let cellNoise = 3.0
    static let colorNoise = 1.0
    static let noiseRange: ClosedRange<Double> = 0...25
    static let desaturate = 0.0
    static let percentRange: ClosedRange<Double> = 0...100
    static let frostAmount = 40.0
    static let seedRange: ClosedRange<Int> = 0...16_777_215
    /// Colour Noise gain with Blur After Mosaic (that blur averages most of it away).
    static let colorNoiseBlurredGain = 2.5
    /// Frosted Glass blur radius, in mosaic cells.
    static let frostBlurCells = 1.75
    /// Pixel parameters are specified at this short-side reference and scale with the image.
    static let referenceShortSide = 1080.0

    static func randomSeed() -> Int {
        Int.random(in: 1...seedRange.upperBound)
    }

    /// Blur After Mosaic switches between the two blur defaults; other values are kept.
    static func blurRadiusForOrderChange(_ radius: Double, blurAfterMosaic: Bool) -> Double {
        if blurAfterMosaic, radius == blurRadius { return blurAfterMosaicRadius }
        if !blurAfterMosaic, radius == blurAfterMosaicRadius { return blurRadius }
        return radius
    }
}

/// Fully resolved Redact parameters in user units (1080p-reference pixels, percent), with
/// the plugin's floors applied. The renderer, the strength comparison and the UI read these.
nonisolated struct RedactParameters: Sendable, Equatable {
    var seed: Int
    var distortionEnabled: Bool
    var blurEnabled: Bool
    var mosaicEnabled: Bool
    var distortionAmount: Double
    var distortionScale: Double
    var blurRadius: Double
    var mosaicSize: Double
    var mosaicShape: AnonymizerMosaicShape
    var cellNoise: Double
    var colorNoise: Double
    var desaturate: Double
    var blurAfterMosaic: Bool
    var frostedGlass: Bool
    var frostAmount: Double
    var frostColor: AnonymizerColor

    static let defaults = RedactParameters(
        seed: 0,
        distortionEnabled: true, blurEnabled: true, mosaicEnabled: true,
        distortionAmount: RedactDefaults.distortionAmount,
        distortionScale: RedactDefaults.distortionScale,
        blurRadius: RedactDefaults.blurRadius,
        mosaicSize: RedactDefaults.mosaicSize,
        mosaicShape: .square,
        cellNoise: RedactDefaults.cellNoise,
        colorNoise: RedactDefaults.colorNoise,
        desaturate: RedactDefaults.desaturate,
        blurAfterMosaic: false,
        frostedGlass: false,
        frostAmount: RedactDefaults.frostAmount,
        frostColor: .frostDefault
    )

    /// A legacy single-strength anonymizer (0...100) mapped onto Redact's layers. The earlier
    /// one-sample shader used a 1080p-reference mosaic of mix(4, 128, t²) with blur and
    /// distortion at 0.6× and the noise scale at 0.4× of it; those sizes are raised to Redact's
    /// minimums, so an old redaction only ever renders stronger. Seed 0 keeps it deterministic.
    init(legacyAmount: Double) {
        let t = min(max(legacyAmount / 100.0, 0), 1)
        let base = 4.0 + (128.0 - 4.0) * t * t
        self = .defaults
        mosaicSize = max(base, RedactDefaults.mosaicSizeRange.lowerBound)
        blurRadius = max(base * 0.6, RedactDefaults.blurRadiusRange.lowerBound)
        distortionAmount = max(base * 0.6, RedactDefaults.distortionAmountRange.lowerBound)
        distortionScale = max(base * 0.4, RedactDefaults.distortionScale)
    }

    init(
        seed: Int, distortionEnabled: Bool, blurEnabled: Bool, mosaicEnabled: Bool,
        distortionAmount: Double, distortionScale: Double, blurRadius: Double, mosaicSize: Double,
        mosaicShape: AnonymizerMosaicShape, cellNoise: Double, colorNoise: Double,
        desaturate: Double, blurAfterMosaic: Bool, frostedGlass: Bool, frostAmount: Double,
        frostColor: AnonymizerColor
    ) {
        self.seed = seed
        self.distortionEnabled = distortionEnabled
        self.blurEnabled = blurEnabled
        self.mosaicEnabled = mosaicEnabled
        self.distortionAmount = distortionAmount
        self.distortionScale = distortionScale
        self.blurRadius = blurRadius
        self.mosaicSize = mosaicSize
        self.mosaicShape = mosaicShape
        self.cellNoise = cellNoise
        self.colorNoise = colorNoise
        self.desaturate = desaturate
        self.blurAfterMosaic = blurAfterMosaic
        self.frostedGlass = frostedGlass
        self.frostAmount = frostAmount
        self.frostColor = frostColor
    }

    /// Every value inside its slider range (layer strengths at or above their floors).
    var clamped: RedactParameters {
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
            v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
        }
        var p = self
        p.seed = min(max(seed, RedactDefaults.seedRange.lowerBound), RedactDefaults.seedRange.upperBound)
        p.distortionAmount = clamp(distortionAmount, RedactDefaults.distortionAmountRange)
        p.distortionScale = clamp(distortionScale, RedactDefaults.distortionScaleRange)
        p.blurRadius = clamp(blurRadius, RedactDefaults.blurRadiusRange)
        p.mosaicSize = clamp(mosaicSize, RedactDefaults.mosaicSizeRange)
        p.cellNoise = clamp(cellNoise, RedactDefaults.noiseRange)
        p.colorNoise = clamp(colorNoise, RedactDefaults.noiseRange)
        p.desaturate = clamp(desaturate, RedactDefaults.percentRange)
        p.frostAmount = clamp(frostAmount, RedactDefaults.percentRange)
        return p
    }

    /// The protective strengths, 0 for a switched-off layer. A redaction is at least as strong
    /// as another when none of these is lower.
    var strengths: [Double] {
        [
            distortionEnabled ? distortionAmount : 0,
            blurEnabled ? blurRadius : 0,
            mosaicEnabled ? mosaicSize : 0,
            mosaicEnabled ? cellNoise : 0,
            mosaicEnabled ? colorNoise : 0,
            desaturate,
        ]
    }

    func isAtLeastAsStrong(as other: RedactParameters) -> Bool {
        zip(strengths, other.strengths).allSatisfy { $0 >= $1 }
    }

    /// True when no layer is switched on — the region is then not anonymized at all.
    var hasNoActiveLayer: Bool { !distortionEnabled && !blurEnabled && !mosaicEnabled }

    /// The single strength (0...100) written as `AnonymizerAmount` for versions that only
    /// read that key: the inverse of the legacy mosaic mapping, from the mosaic size.
    var compatibleLegacyAmount: Double {
        let t = ((max(mosaicSize, 4.0) - 4.0) / 124.0).squareRoot()
        return min(max((t * 1000).rounded() / 10, 1), 100)
    }
}

nonisolated extension AnonymizerSettings {
    /// A new anonymizer at Redact's defaults with a fresh random seed.
    static func redactDefaults(seed: Int = RedactDefaults.randomSeed()) -> AnonymizerSettings {
        var settings = AnonymizerSettings()
        settings.store(RedactParameters.defaults, seed: seed)
        return settings
    }

    /// True for a single-strength anonymizer from before the Redact controls.
    var isLegacyStrengthOnly: Bool { seed == nil }

    /// The parameters this anonymizer renders with (Black Out aside).
    var redactParameters: RedactParameters {
        if seed == nil {
            return RedactParameters(legacyAmount: amount ?? 0).clamped
        }
        let d = RedactParameters.defaults
        return RedactParameters(
            seed: seed ?? 0,
            distortionEnabled: distortionEnabled ?? d.distortionEnabled,
            blurEnabled: blurEnabled ?? d.blurEnabled,
            mosaicEnabled: mosaicEnabled ?? d.mosaicEnabled,
            distortionAmount: distortionAmount ?? d.distortionAmount,
            distortionScale: distortionScale ?? d.distortionScale,
            blurRadius: blurRadius ?? d.blurRadius,
            mosaicSize: mosaicSize ?? d.mosaicSize,
            mosaicShape: mosaicShape ?? d.mosaicShape,
            cellNoise: cellNoise ?? d.cellNoise,
            colorNoise: colorNoise ?? d.colorNoise,
            desaturate: desaturate ?? d.desaturate,
            blurAfterMosaic: blurAfterMosaic ?? d.blurAfterMosaic,
            frostedGlass: frostedGlass ?? d.frostedGlass,
            frostAmount: frostAmount ?? d.frostAmount,
            frostColor: frostColor ?? d.frostColor
        ).clamped
    }

    /// Writes every Redact field from `parameters` (making the settings Redact-era) and drops
    /// the legacy strength. Black Out is left as it is.
    mutating func store(_ parameters: RedactParameters, seed newSeed: Int? = nil) {
        let p = parameters.clamped
        amount = nil
        seed = newSeed ?? p.seed
        distortionEnabled = p.distortionEnabled
        blurEnabled = p.blurEnabled
        mosaicEnabled = p.mosaicEnabled
        distortionAmount = p.distortionAmount
        distortionScale = p.distortionScale
        blurRadius = p.blurRadius
        mosaicSize = p.mosaicSize
        mosaicShape = p.mosaicShape
        cellNoise = p.cellNoise
        colorNoise = p.colorNoise
        desaturate = p.desaturate
        blurAfterMosaic = p.blurAfterMosaic
        frostedGlass = p.frostedGlass
        frostAmount = p.frostAmount
        frostColor = p.frostColor
    }

    /// Applies `change` to the resolved parameters and stores the result. A legacy
    /// single-strength anonymizer is converted on its first edit (keeping its seed 0, so only
    /// the edited value changes the look).
    mutating func updateParameters(_ change: (inout RedactParameters) -> Void) {
        var p = redactParameters
        change(&p)
        store(p)
    }

    /// The global or mask Anonymizer a paste/template/merge leaves when the target already
    /// redacts: it may be turned on or strengthened from the source, never turned off or
    /// weakened (privacy rule). The incoming settings win when they are at least as strong in
    /// every protective strength; otherwise the target's settings are kept with each strength
    /// raised to the stronger of the two. Black Out from either side is kept.
    nonisolated static func atLeastAsStrong(
        target: AnonymizerSettings?,
        incoming: AnonymizerSettings?
    ) -> AnonymizerSettings? {
        guard let target, !target.isEmpty else { return incoming }
        guard let incoming, !incoming.isEmpty else { return target }
        let blackOut = target.blackOut == true || incoming.blackOut == true
        let t = target.redactParameters
        let i = incoming.redactParameters
        var result: AnonymizerSettings
        if target.isLegacyStrengthOnly, incoming.isLegacyStrengthOnly {
            result = AnonymizerSettings(amount: max(target.amount ?? 0, incoming.amount ?? 0))
            if (result.amount ?? 0) <= 0 { result.amount = nil }
        } else if i.isAtLeastAsStrong(as: t) {
            result = incoming
        } else if t.isAtLeastAsStrong(as: i) {
            result = target
        } else {
            var merged = t
            merged.distortionEnabled = t.distortionEnabled || i.distortionEnabled
            merged.blurEnabled = t.blurEnabled || i.blurEnabled
            merged.mosaicEnabled = t.mosaicEnabled || i.mosaicEnabled
            merged.distortionAmount = max(
                t.distortionEnabled ? t.distortionAmount : 0, i.distortionEnabled ? i.distortionAmount : 0
            )
            merged.blurRadius = max(t.blurEnabled ? t.blurRadius : 0, i.blurEnabled ? i.blurRadius : 0)
            merged.mosaicSize = max(t.mosaicEnabled ? t.mosaicSize : 0, i.mosaicEnabled ? i.mosaicSize : 0)
            merged.cellNoise = max(t.mosaicEnabled ? t.cellNoise : 0, i.mosaicEnabled ? i.cellNoise : 0)
            merged.colorNoise = max(t.mosaicEnabled ? t.colorNoise : 0, i.mosaicEnabled ? i.colorNoise : 0)
            merged.desaturate = max(t.desaturate, i.desaturate)
            result = target
            result.store(merged)
        }
        result.blackOut = blackOut ? true : nil
        return result
    }
}

// MARK: - XMP

/// App-private XMP field names and encoding, shared by the global (`aaphoto:` top level)
/// and per-mask (`MaskGroupBasedCorrections` entry) writers and readers. Every name starts
/// with "Anonymizer" (`FolderRedactionScanner` relies on that prefix).
nonisolated enum AnonymizerXMP {
    static let amount = "AnonymizerAmount"
    static let blackOut = "AnonymizerBlackOut"
    static let seed = "AnonymizerSeed"
    static let distortion = "AnonymizerDistortion"
    static let blur = "AnonymizerBlur"
    static let mosaic = "AnonymizerMosaic"
    static let distortionAmount = "AnonymizerDistortionAmount"
    static let distortionScale = "AnonymizerDistortionScale"
    static let blurRadius = "AnonymizerBlurRadius"
    static let mosaicSize = "AnonymizerMosaicSize"
    static let mosaicShape = "AnonymizerMosaicShape"
    static let cellNoise = "AnonymizerCellNoise"
    static let colorNoise = "AnonymizerColorNoise"
    static let desaturate = "AnonymizerDesaturate"
    static let blurAfterMosaic = "AnonymizerBlurAfterMosaic"
    static let frostedGlass = "AnonymizerFrostedGlass"
    static let frostAmount = "AnonymizerFrostAmount"
    static let frostColor = "AnonymizerFrostColor"

    /// Every property this app writes for an anonymizer (for clearing a develop block).
    static let propertyNames: [String] = [
        amount, blackOut, seed, distortion, blur, mosaic, distortionAmount, distortionScale,
        blurRadius, mosaicSize, mosaicShape, cellNoise, colorNoise, desaturate, blurAfterMosaic,
        frostedGlass, frostAmount, frostColor,
    ]

    /// The (property, value) pairs for `settings`; empty when it doesn't redact.
    static func fields(for settings: AnonymizerSettings?) -> [(String, String)] {
        guard let settings, !settings.isEmpty else { return [] }
        func number(_ v: Double) -> String { String(format: "%.1f", v) }
        func bool(_ v: Bool) -> String { v ? "True" : "False" }
        var result: [(String, String)] = []
        if settings.isLegacyStrengthOnly {
            if let amount = settings.amount, amount > 0 { result.append((AnonymizerXMP.amount, number(amount))) }
        } else {
            let p = settings.redactParameters
            result.append((AnonymizerXMP.amount, number(p.compatibleLegacyAmount)))
            result.append((seed, String(p.seed)))
            result.append((distortion, bool(p.distortionEnabled)))
            result.append((blur, bool(p.blurEnabled)))
            result.append((mosaic, bool(p.mosaicEnabled)))
            result.append((distortionAmount, number(p.distortionAmount)))
            result.append((distortionScale, number(p.distortionScale)))
            result.append((blurRadius, number(p.blurRadius)))
            result.append((mosaicSize, number(p.mosaicSize)))
            result.append((mosaicShape, p.mosaicShape.rawValue))
            result.append((cellNoise, number(p.cellNoise)))
            result.append((colorNoise, number(p.colorNoise)))
            result.append((desaturate, number(p.desaturate)))
            result.append((blurAfterMosaic, bool(p.blurAfterMosaic)))
            result.append((frostedGlass, bool(p.frostedGlass)))
            result.append((frostAmount, number(p.frostAmount)))
            result.append((frostColor, p.frostColor.xmpValue))
        }
        if settings.blackOut == true { result.append((blackOut, "True")) }
        return result
    }

    /// Reads an anonymizer from app-private fields (`value(name)` returns the raw XMP value);
    /// nil when the fields don't redact. With a seed, the legacy strength is dropped.
    static func settings(reading value: (String) -> Any?) -> AnonymizerSettings? {
        func double(_ name: String) -> Double? {
            switch value(name) {
            case let n as NSNumber: return n.doubleValue
            case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
            default: return nil
            }
        }
        func bool(_ name: String) -> Bool? {
            switch value(name) {
            case let n as NSNumber: return n.boolValue
            case let s as String:
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: return nil
                }
            default: return nil
            }
        }
        var settings = AnonymizerSettings(amount: double(amount), blackOut: bool(blackOut))
        if let seedValue = double(seed), seedValue.isFinite {
            settings.amount = nil
            settings.seed = min(max(Int(seedValue), RedactDefaults.seedRange.lowerBound),
                                RedactDefaults.seedRange.upperBound)
            settings.distortionEnabled = bool(distortion)
            settings.blurEnabled = bool(blur)
            settings.mosaicEnabled = bool(mosaic)
            settings.distortionAmount = double(distortionAmount)
            settings.distortionScale = double(distortionScale)
            settings.blurRadius = double(blurRadius)
            settings.mosaicSize = double(mosaicSize)
            settings.mosaicShape = (value(mosaicShape) as? String).flatMap(AnonymizerMosaicShape.init(rawValue:))
            settings.cellNoise = double(cellNoise)
            settings.colorNoise = double(colorNoise)
            settings.desaturate = double(desaturate)
            settings.blurAfterMosaic = bool(blurAfterMosaic)
            settings.frostedGlass = bool(frostedGlass)
            settings.frostAmount = double(frostAmount)
            settings.frostColor = (value(frostColor) as? String).flatMap(AnonymizerColor.init(xmpValue:))
            // Normalize to the stored (clamped, fully populated) form the editor writes, so a
            // re-read compares equal to the settings that were saved.
            let blackOutValue = settings.blackOut
            settings.store(settings.redactParameters)
            settings.blackOut = blackOutValue
        } else if (settings.amount ?? 0) <= 0 {
            settings.amount = nil
        }
        if settings.blackOut != true { settings.blackOut = nil }
        return settings.isEmpty ? nil : settings
    }
}
