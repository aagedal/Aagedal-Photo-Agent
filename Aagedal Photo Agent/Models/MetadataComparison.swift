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
    /// The descriptive fields where the `.xmp` sidecar holds a value that genuinely
    /// conflicts with the embedded file, in a stable display order. Keywords and people
    /// are compared order-insensitively so a mere reorder isn't reported as a conflict.
    ///
    /// Photo-Mechanic model — the sidecar *owns only what it sets*. A field the sidecar
    /// leaves empty is "unset" (it inherits the embedded value via `merged(preferring:)`),
    /// not a conflicting clear, so it is never listed here. This keeps the overlay/banner
    /// quiet for partial sidecars (e.g. those written by batch tagging, which carry only
    /// the fields the app touched) instead of flagging every missing Creator/Date.
    static func differences(embedded: IPTCMetadata, sidecar: IPTCMetadata) -> [MetadataFieldComparison] {
        IPTCMetadata.FieldKey.allCases.compactMap { key in
            guard key.sidecarConflicts(embedded: embedded, sidecar: sidecar) else { return nil }
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

    /// Whether the sidecar holds a genuine conflict for this field: it has set a non-empty
    /// value that differs from the embedded file. An empty sidecar value means the sidecar
    /// never set the field — it inherits the embedded value (see `merged(preferring:)`), so
    /// it is not a conflict. List fields compare order-insensitively.
    func sidecarConflicts(embedded: IPTCMetadata, sidecar: IPTCMetadata) -> Bool {
        switch self {
        case .keywords:
            let s = Set(sidecar.keywords)
            return !s.isEmpty && s != Set(embedded.keywords)
        case .personShown:
            let s = Set(sidecar.personShown)
            return !s.isEmpty && s != Set(embedded.personShown)
        default:
            let s = displayValue(in: sidecar)
            return !s.isEmpty && s != displayValue(in: embedded)
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
