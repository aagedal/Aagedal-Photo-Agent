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
    case organisationShownName, organisationShownCode, digitalSourceType
    case creator, creatorJobTitle, descriptionWriter, credit, copyright, jobId, dateCreated
    case city, sublocation, provinceState, country, countryCode, event, instructions, source

    var displayName: String {
        switch self {
        case .headline: return "Headline"
        case .description: return "Description"
        case .extendedDescription: return "Extended Description"
        case .keywords: return "Keywords"
        case .personShown: return "Person Shown"
        case .organisationShownName: return "Organisation Shown Name"
        case .organisationShownCode: return "Organisation Shown Code"
        case .digitalSourceType: return "Digital Source Type"
        case .creator: return "Creator"
        case .creatorJobTitle: return "Creator Job Title"
        case .descriptionWriter: return "Description Writer"
        case .credit: return "Credit"
        case .copyright: return "Copyright"
        case .jobId: return "Job ID"
        case .dateCreated: return "Date Created"
        case .city: return "City"
        case .sublocation: return "Sublocation"
        case .provinceState: return "State / Province"
        case .country: return "Country"
        case .countryCode: return "Country Code"
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
        case .organisationShownName: return metadata.organisationsShownNames.isEmpty
        case .organisationShownCode: return metadata.organisationsShownCodes.isEmpty
        case .digitalSourceType: return metadata.digitalSourceType == nil
        case .creator: return metadata.creator?.isEmpty ?? true
        case .creatorJobTitle: return metadata.creatorJobTitle?.isEmpty ?? true
        case .descriptionWriter: return metadata.descriptionWriter?.isEmpty ?? true
        case .credit: return metadata.credit?.isEmpty ?? true
        case .copyright: return metadata.copyright?.isEmpty ?? true
        case .jobId: return metadata.jobId?.isEmpty ?? true
        case .dateCreated: return metadata.dateCreated?.isEmpty ?? true
        case .city: return metadata.city?.isEmpty ?? true
        case .sublocation: return metadata.sublocation?.isEmpty ?? true
        case .provinceState: return metadata.provinceState?.isEmpty ?? true
        case .country: return metadata.country?.isEmpty ?? true
        case .countryCode: return metadata.countryCode?.isEmpty ?? true
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
        case .organisationShownName: return metadata.organisationsShownNames.joined(separator: ", ")
        case .organisationShownCode: return metadata.organisationsShownCodes.joined(separator: ", ")
        case .digitalSourceType: return metadata.digitalSourceType?.newsCodeURI
        case .creator: return metadata.creator
        case .creatorJobTitle: return metadata.creatorJobTitle
        case .descriptionWriter: return metadata.descriptionWriter
        case .credit: return metadata.credit
        case .copyright: return metadata.copyright
        case .jobId: return metadata.jobId
        case .dateCreated: return metadata.dateCreated
        case .city: return metadata.city
        case .sublocation: return metadata.sublocation
        case .provinceState: return metadata.provinceState
        case .country: return metadata.country
        case .countryCode: return metadata.countryCode
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
        case .organisationShownName:
            metadata.organisationsShownNames = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
        case .organisationShownCode:
            metadata.organisationsShownCodes = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
        case .digitalSourceType:
            metadata.digitalSourceType = scalar.flatMap(DigitalSourceType.init(metadataValue:))
        case .creator: metadata.creator = scalar
        case .creatorJobTitle: metadata.creatorJobTitle = scalar
        case .descriptionWriter: metadata.descriptionWriter = scalar
        case .credit: metadata.credit = scalar
        case .copyright: metadata.copyright = scalar
        case .jobId: metadata.jobId = scalar
        case .dateCreated: metadata.dateCreated = scalar
        case .city: metadata.city = scalar
        case .sublocation: metadata.sublocation = scalar
        case .provinceState: metadata.provinceState = scalar
        case .country: metadata.country = scalar
        case .countryCode: metadata.countryCode = ISO3166Country.normalizedAlpha3(scalar)
        case .event: metadata.event = scalar
        case .instructions: metadata.instructions = scalar
        case .source: metadata.source = scalar
        }
    }

    static let defaultCheckedFields: Set<Self> = [.headline, .description, .creator, .copyright]

    /// Fields displayed in the main Metadata section of the editor.
    static let primaryEditorFields: [Self] = [
        .headline, .description, .extendedDescription, .keywords, .personShown,
        .organisationShownName, .organisationShownCode,
        .copyright, .jobId,
    ]

    /// Fields displayed in the Additional Fields section of the editor.
    static let additionalEditorFields: [Self] = [
        .creator, .creatorJobTitle, .descriptionWriter, .credit, .source, .city, .sublocation,
        .provinceState, .country, .countryCode, .event, .instructions,
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
    // Digital Source Type has a dedicated controlled-vocabulary editor. Keep it out of the
    // legacy required-field settings until that screen can present vocabulary-aware rules.
    static let userSelectable = allCases.filter { $0 != .dateCreated && $0 != .digitalSourceType }

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
