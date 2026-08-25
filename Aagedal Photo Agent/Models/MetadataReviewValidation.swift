import Foundation

/// Presentation-ready validation details for one field in Metadata Review.
///
/// Keeping the severity name and reason together ensures compact review cells do not rely on
/// border color or pointer-only help to explain a failure.
nonisolated struct MetadataReviewFieldFailure: Equatable, Sendable, Identifiable {
    let id: String
    let severity: MetadataValidationSeverity
    let message: String
    let technicalDetail: String?

    init(issue: MetadataValidationIssue) {
        id = issue.id
        severity = issue.severity
        message = issue.message
        technicalDetail = issue.technicalDetail
    }

    var severityName: String {
        switch severity {
        case .blocker: "Blocker"
        case .warning: "Warning"
        case .information: "Information"
        }
    }

    var systemImageName: String {
        switch severity {
        case .blocker: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        }
    }

    /// Used for both persistent on-screen text and the VoiceOver description.
    var accessibleDescription: String {
        let reason = technicalDetail.map { "\(message) \($0)" } ?? message
        return "\(severityName): \(reason)"
    }
}

nonisolated enum MetadataReviewValidation {
    static func failures(
        for field: MetadataFieldID,
        in metadata: IPTCMetadata,
        imageURL: URL,
        levels: MetadataRequirements.Levels,
        minimumLengths: MetadataRequirements.MinimumLengths
    ) -> [MetadataReviewFieldFailure] {
        let profile = MetadataValidationProfile.currentRequirements(
            levels: levels.filter { $0.key == field },
            minimumLengths: minimumLengths.filter { $0.key == field }
        )
        return MetadataValidationEngine().validate(
            metadata,
            imageURL: imageURL,
            profile: profile
        ).issues
            .filter { $0.field == field }
            .map(MetadataReviewFieldFailure.init(issue:))
    }
}
