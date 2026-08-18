import Foundation

/// Stable identity for an editor-facing metadata field.
///
/// Raw values are persistence keys. They are intentionally independent of UI labels and metadata
/// container tags, and must not be changed when either of those changes. Existing releases stored
/// these values through `IPTCMetadata.FieldKey`; that spelling remains available as a type alias.
nonisolated enum MetadataFieldID: String, CaseIterable, Codable, Sendable {
    /// The raw value remains `title` because older builds persisted the headline field under that
    /// key. The case name reflects its actual IPTC meaning and leaves room for a distinct Title.
    case headline = "title"
    case description, extendedDescription, keywords, personShown
    case creator, credit, copyright, jobId, dateCreated
    case city, sublocation, provinceState, country, event, instructions, source

    var displayName: String {
        switch self {
        case .headline: return "Headline"
        case .description: return "Description"
        case .extendedDescription: return "Extended Description"
        case .keywords: return "Keywords"
        case .personShown: return "Person Shown"
        case .creator: return "Creator"
        case .credit: return "Credit"
        case .copyright: return "Copyright"
        case .jobId: return "Job ID"
        case .dateCreated: return "Date Created"
        case .city: return "City"
        case .sublocation: return "Sublocation"
        case .provinceState: return "State / Province"
        case .country: return "Country"
        case .event: return "Event"
        case .instructions: return "Instructions"
        case .source: return "Source"
        }
    }

    func isEmpty(in metadata: IPTCMetadata) -> Bool {
        switch self {
        case .headline: return metadata.title?.isEmpty ?? true
        case .description: return metadata.description?.isEmpty ?? true
        case .extendedDescription: return metadata.extendedDescription?.isEmpty ?? true
        case .keywords: return metadata.keywords.isEmpty
        case .personShown: return metadata.personShown.isEmpty
        case .creator: return metadata.creator?.isEmpty ?? true
        case .credit: return metadata.credit?.isEmpty ?? true
        case .copyright: return metadata.copyright?.isEmpty ?? true
        case .jobId: return metadata.jobId?.isEmpty ?? true
        case .dateCreated: return metadata.dateCreated?.isEmpty ?? true
        case .city: return metadata.city?.isEmpty ?? true
        case .sublocation: return metadata.sublocation?.isEmpty ?? true
        case .provinceState: return metadata.provinceState?.isEmpty ?? true
        case .country: return metadata.country?.isEmpty ?? true
        case .event: return metadata.event?.isEmpty ?? true
        case .instructions: return metadata.instructions?.isEmpty ?? true
        case .source: return metadata.source?.isEmpty ?? true
        }
    }

    func textValue(in metadata: IPTCMetadata) -> String? {
        switch self {
        case .headline: return metadata.title
        case .description: return metadata.description
        case .extendedDescription: return metadata.extendedDescription
        case .keywords: return metadata.keywords.joined(separator: ", ")
        case .personShown: return metadata.personShown.joined(separator: ", ")
        case .creator: return metadata.creator
        case .credit: return metadata.credit
        case .copyright: return metadata.copyright
        case .jobId: return metadata.jobId
        case .dateCreated: return metadata.dateCreated
        case .city: return metadata.city
        case .sublocation: return metadata.sublocation
        case .provinceState: return metadata.provinceState
        case .country: return metadata.country
        case .event: return metadata.event
        case .instructions: return metadata.instructions
        case .source: return metadata.source
        }
    }

    func setTextValue(_ value: String, in metadata: inout IPTCMetadata) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalar: String? = trimmed.isEmpty ? nil : trimmed
        switch self {
        case .headline: metadata.title = scalar
        case .description: metadata.description = scalar
        case .extendedDescription: metadata.extendedDescription = scalar
        case .keywords:
            metadata.keywords = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
        case .personShown:
            metadata.personShown = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
        case .creator: metadata.creator = scalar
        case .credit: metadata.credit = scalar
        case .copyright: metadata.copyright = scalar
        case .jobId: metadata.jobId = scalar
        case .dateCreated: metadata.dateCreated = scalar
        case .city: metadata.city = scalar
        case .sublocation: metadata.sublocation = scalar
        case .provinceState: metadata.provinceState = scalar
        case .country: metadata.country = scalar
        case .event: metadata.event = scalar
        case .instructions: metadata.instructions = scalar
        case .source: metadata.source = scalar
        }
    }

    static let defaultCheckedFields: Set<Self> = [.headline, .description, .creator, .copyright]

    /// Fields displayed in the main Metadata section of the editor.
    static let primaryEditorFields: [Self] = [
        .headline, .description, .extendedDescription, .keywords, .personShown,
        .copyright, .jobId,
    ]

    /// Fields displayed in the Additional Fields section of the editor.
    static let additionalEditorFields: [Self] = [
        .creator, .credit, .source, .city, .sublocation, .provinceState, .country, .event,
        .instructions,
    ]

    /// Every field that can be shown or hidden in the editable metadata panel.
    /// `dateCreated` has no editor and remains only for decoding older stored preferences.
    static let editorFields = primaryEditorFields + additionalEditorFields

    /// Core fields that must remain available in the metadata panel.
    static let alwaysVisibleEditorFields: Set<Self> = [
        .headline, .description, .keywords, .copyright,
    ]

    /// Fields offered in Settings for panel customization.
    static let optionalEditorFields = editorFields.filter {
        !alwaysVisibleEditorFields.contains($0)
    }

    /// Fields offered in required-metadata settings and the browser's Missing Field filter.
    static let userSelectable = allCases.filter { $0 != .dateCreated }

    static func decodeHidden(_ rawValues: [String]) -> Set<Self> {
        Set(rawValues.compactMap(Self.init(rawValue:)))
            .intersection(optionalEditorFields)
    }

    /// Source compatibility for the former nested `IPTCMetadata.FieldKey.title` case.
    static var title: Self { .headline }
}

extension IPTCMetadata {
    /// Source-compatible spelling retained for code and Codable values shipped before Phase 1.
    typealias FieldKey = MetadataFieldID
}
