import Foundation
import CoreImage

nonisolated enum RAWDecodeProfile: String, CaseIterable, Identifiable, Sendable {
    case linear
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear:
            return "Linear RAW"
        case .camera:
            return "Camera RAW"
        }
    }

    var subtitle: String {
        switch self {
        case .linear:
            return "Neutral decode without Apple's camera tone boost."
        case .camera:
            return "Apple's camera-matched RAW decode, closer to Finder and Preview. Default."
        }
    }

    init?(storedRawValue: String) {
        switch storedRawValue {
        case "flat":
            self = .linear
        case "native":
            self = .camera
        default:
            self.init(rawValue: storedRawValue)
        }
    }
}

nonisolated enum RAWDecoderVersionPreference: String, CaseIterable, Identifiable {
    case auto
    case v9
    case v8
    case v7
    case v6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto (Newest)"
        case .v9:
            return "Version 9"
        case .v8:
            return "Version 8"
        case .v7:
            return "Version 7"
        case .v6:
            return "Version 6"
        }
    }

    /// Select only an identifier advertised for this file. RAW 9 is opt-in, so
    /// Auto must explicitly choose the newest version instead of trusting the
    /// filter's initial decoder. Sort numerically rather than relying on API order.
    nonisolated func selectedDecoder(in supportedVersions: [String]) -> String? {
        let newest = supportedVersions.filter { $0.first?.isNumber == true }.max {
            $0.compare($1, options: .numeric) == .orderedAscending
        }
        guard self != .auto else { return newest }
        let version: String
        switch self {
        case .auto: return newest
        case .v9: version = "9"
        case .v8: version = "8"
        case .v7: version = "7"
        case .v6: version = "6"
        }
        // Apple's actual identifiers are "9" and "9.dng", not "9DNG".
        // Exact matching prevents a pin to 9 from accidentally selecting 19.
        return supportedVersions.first { $0 == version || $0 == version + ".dng" } ?? newest
    }

}

/// Shared filter policy for interactive Develop and retained-byte automation admission.
/// Callers select their own preference domain; this helper never reads defaults or paths.
nonisolated enum RAWSourceDecoder {
    struct Result: @unchecked Sendable {
        let image: CIImage
        let neutralTemperature: Float
        let neutralTint: Float
    }

    static func decode(_ filter: CIRAWFilter, draftMode: Bool, maxPixelSize: CGFloat?,
                       nativeLongestSide: CGFloat?, profile: RAWDecodeProfile,
                       decoderPreference: RAWDecoderVersionPreference) -> Result? {
        guard !Task.isCancelled else { return nil }
        if let selected = decoderPreference.selectedDecoder(in: filter.supportedDecoderVersions.map(\.rawValue)),
           let version = filter.supportedDecoderVersions.first(where: { $0.rawValue == selected }) {
            filter.decoderVersion = version
        }
        filter.isDraftModeEnabled = draftMode
        if profile == .linear {
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
        }
        if let maxPixelSize, let longestSide = nativeLongestSide,
           longestSide > maxPixelSize * 1.5 {
            filter.scaleFactor = Float(maxPixelSize / longestSide)
        }
        // Scene-referred highlight recovery is retained regardless of SDR output mode.
        filter.extendedDynamicRangeAmount = 2.0
        let temperature = filter.neutralTemperature
        let tint = filter.neutralTint
        guard temperature.isFinite, temperature > 0, tint.isFinite,
              let output = filter.outputImage, !Task.isCancelled else { return nil }
        let extent = output.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0,
              extent.width < Double(Int.max), extent.height < Double(Int.max),
              Double(temperature) < Double(Int.max), abs(Double(tint)) < Double(Int.max) else { return nil }
        return Result(image: output, neutralTemperature: temperature, neutralTint: tint)
    }
}
