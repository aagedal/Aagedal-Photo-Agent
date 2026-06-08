import Foundation

/// Which side of an embedded-vs-sidecar conflict a field should be taken from.
nonisolated enum MetadataSource: String, Sendable, CaseIterable {
    case embedded
    case sidecar
}

/// One descriptive field whose embedded value disagrees with its `.xmp` sidecar value.
/// Drives the per-field comparison/merge UI.
nonisolated struct MetadataFieldComparison: Identifiable, Sendable, Equatable {
    let field: IPTCMetadata.FieldKey
    let embeddedValue: String
    let sidecarValue: String

    var id: String { field.rawValue }
    var label: String { field.displayName }

    func value(for source: MetadataSource) -> String {
        source == .embedded ? embeddedValue : sidecarValue
    }
}

/// Builds the per-field diff between an embedded image and its sidecar, and merges the
/// user's per-field source choices back onto a base. Descriptive fields only (the
/// `IPTCMetadata.FieldKey` set) — GPS and technical EXIF are reconciled separately and are
/// never force-overwritten here.
nonisolated enum MetadataComparison {
    /// The descriptive fields that differ between `embedded` and `sidecar`, in a stable
    /// display order. Keywords and people are compared order-insensitively so a mere
    /// reorder isn't reported as a conflict.
    static func differences(embedded: IPTCMetadata, sidecar: IPTCMetadata) -> [MetadataFieldComparison] {
        IPTCMetadata.FieldKey.allCases.compactMap { key in
            guard key.differs(embedded, sidecar) else { return nil }
            return MetadataFieldComparison(
                field: key,
                embeddedValue: key.displayValue(in: embedded),
                sidecarValue: key.displayValue(in: sidecar)
            )
        }
    }

    /// Produces a merged copy of `base` where each field in `choices` is taken from the
    /// chosen source. Only the listed (conflicting) fields are touched; everything else on
    /// `base` — including Camera Raw, GPS, rating, label — is preserved untouched.
    static func merge(
        base: IPTCMetadata,
        embedded: IPTCMetadata,
        sidecar: IPTCMetadata,
        choices: [IPTCMetadata.FieldKey: MetadataSource]
    ) -> IPTCMetadata {
        var result = base
        for (key, source) in choices {
            key.copyValue(from: source == .embedded ? embedded : sidecar, into: &result)
        }
        return result
    }
}

nonisolated extension IPTCMetadata.FieldKey {
    /// A human-readable string for this field's value, for display in the comparison UI.
    /// List fields are joined with ", ".
    func displayValue(in m: IPTCMetadata) -> String {
        switch self {
        case .title: return m.title ?? ""
        case .description: return m.description ?? ""
        case .extendedDescription: return m.extendedDescription ?? ""
        case .keywords: return m.keywords.joined(separator: ", ")
        case .personShown: return m.personShown.joined(separator: ", ")
        case .creator: return m.creator ?? ""
        case .credit: return m.credit ?? ""
        case .copyright: return m.copyright ?? ""
        case .jobId: return m.jobId ?? ""
        case .dateCreated: return m.dateCreated ?? ""
        case .city: return m.city ?? ""
        case .country: return m.country ?? ""
        case .event: return m.event ?? ""
        }
    }

    /// Whether this field's value differs between two versions. List fields compare
    /// order-insensitively.
    func differs(_ a: IPTCMetadata, _ b: IPTCMetadata) -> Bool {
        switch self {
        case .keywords: return Set(a.keywords) != Set(b.keywords)
        case .personShown: return Set(a.personShown) != Set(b.personShown)
        default: return displayValue(in: a) != displayValue(in: b)
        }
    }

    /// Copies this field's typed value from `source` into `dest`.
    func copyValue(from source: IPTCMetadata, into dest: inout IPTCMetadata) {
        switch self {
        case .title: dest.title = source.title
        case .description: dest.description = source.description
        case .extendedDescription: dest.extendedDescription = source.extendedDescription
        case .keywords: dest.keywords = source.keywords
        case .personShown: dest.personShown = source.personShown
        case .creator: dest.creator = source.creator
        case .credit: dest.credit = source.credit
        case .copyright: dest.copyright = source.copyright
        case .jobId: dest.jobId = source.jobId
        case .dateCreated: dest.dateCreated = source.dateCreated
        case .city: dest.city = source.city
        case .country: dest.country = source.country
        case .event: dest.event = source.event
        }
    }
}
