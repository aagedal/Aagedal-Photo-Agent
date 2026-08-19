import Foundation

/// Persisted inputs and presentation choices for a reproducible solar-position overlay.
///
/// The linked evidence identifier is provenance only. The timestamp remains frozen here so a
/// calculation can still be reproduced if its timeline row is later removed.
nonisolated struct AnalysisSolarOverlayState: Codable, Equatable, Sendable {
    var isVisible: Bool
    var timestamp: AnalysisTimestampValue
    var linkedTimestampEvidenceID: UUID?
    var showsSunDirection: Bool
    var showsShadowDirection: Bool
    var showsSunriseDirection: Bool
    var showsSunsetDirection: Bool
    var calculationMethod: AnalysisSolarCalculationMethod

    init(
        isVisible: Bool = true,
        timestamp: AnalysisTimestampValue,
        linkedTimestampEvidenceID: UUID? = nil,
        showsSunDirection: Bool = true,
        showsShadowDirection: Bool = true,
        showsSunriseDirection: Bool = true,
        showsSunsetDirection: Bool = true,
        calculationMethod: AnalysisSolarCalculationMethod = .meeusNOAAV1
    ) {
        self.isVisible = isVisible
        self.timestamp = timestamp
        self.linkedTimestampEvidenceID = linkedTimestampEvidenceID
        self.showsSunDirection = showsSunDirection
        self.showsShadowDirection = showsShadowDirection
        self.showsSunriseDirection = showsSunriseDirection
        self.showsSunsetDirection = showsSunsetDirection
        self.calculationMethod = calculationMethod
    }

    /// Solar calculations require an absolute, minute-or-better timestamp. The UUID is not
    /// validated against the current timeline because a removed link must not discard the input.
    func validate() -> Bool {
        timestamp.validate()
            && timestamp.timezoneKnown
            && timestamp.precision != .day
            && timestamp.resolvedInstant != nil
            && AnalysisSolarCalculationMethod.allCases.contains(calculationMethod)
    }
}
