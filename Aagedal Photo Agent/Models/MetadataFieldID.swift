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
    case organisationShownName, organisationShownCode, digitalSourceType, urgency, sceneCode
    case subjectCode, mediaTopic, genre
    case creator, creatorJobTitle, descriptionWriter, credit, copyright
    case rightsUsageTerms, webStatementOfRights, digitalImageGUID, imageSupplierImageID, imageSupplier, jobId, dateCreated
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
        case .urgency: return "Urgency"
        case .sceneCode: return "Scene Code"
        case .subjectCode: return "Subject Code"
        case .mediaTopic: return "Media Topic"
        case .genre: return "Genre"
        case .creator: return "Creator"
        case .creatorJobTitle: return "Creator Job Title"
        case .descriptionWriter: return "Description Writer"
        case .credit: return "Credit"
        case .copyright: return "Copyright"
        case .rightsUsageTerms: return "Rights Usage Terms"
        case .webStatementOfRights: return "Web Statement of Rights"
        case .digitalImageGUID: return "Digital Image GUID"
        case .imageSupplierImageID: return "Image Supplier Image ID"
        case .imageSupplier: return "Image Supplier"
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
        case .urgency: return metadata.urgency == nil
        case .sceneCode: return metadata.sceneCodes.isEmpty
        case .subjectCode: return metadata.subjectCodes.isEmpty
        case .mediaTopic: return metadata.mediaTopics.isEmpty
        case .genre: return metadata.genres.isEmpty
        case .creator: return metadata.creator?.isEmpty ?? true
        case .creatorJobTitle: return metadata.creatorJobTitle?.isEmpty ?? true
        case .descriptionWriter: return metadata.descriptionWriter?.isEmpty ?? true
        case .credit: return metadata.credit?.isEmpty ?? true
        case .copyright: return metadata.copyright?.isEmpty ?? true
        case .rightsUsageTerms: return metadata.rightsUsageTerms?.isEmpty ?? true
        case .webStatementOfRights: return metadata.webStatementOfRights?.isEmpty ?? true
        case .digitalImageGUID: return metadata.digitalImageGUID?.isEmpty ?? true
        case .imageSupplierImageID: return metadata.imageSupplierImageID?.isEmpty ?? true
        case .imageSupplier: return metadata.imageSuppliers.isEmpty
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
        case .urgency: return metadata.urgency.map(String.init)
        case .sceneCode: return metadata.sceneCodes.joined(separator: ", ")
        case .subjectCode: return metadata.subjectCodes.joined(separator: ", ")
        case .mediaTopic: return metadata.mediaTopics.map(\.editorValue).joined(separator: ", ")
        case .genre: return metadata.genres.map { $0.genreCode ?? $0.termIdentifier }.joined(separator: ", ")
        case .creator: return metadata.creators.joined(separator: ", ")
        case .creatorJobTitle: return metadata.creatorJobTitle
        case .descriptionWriter: return metadata.descriptionWriter
        case .credit: return metadata.credit
        case .copyright: return metadata.copyright
        case .rightsUsageTerms: return metadata.rightsUsageTerms
        case .webStatementOfRights: return metadata.webStatementOfRights
        case .digitalImageGUID: return metadata.digitalImageGUID
        case .imageSupplierImageID: return metadata.imageSupplierImageID
        case .imageSupplier: return EditorialImageSupplier.canonicalJSONString(for: metadata.imageSuppliers)
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

    /// Canonical value retained by editing history. Repeatable fields use a JSON array so values
    /// containing commas can be restored without being split into multiple values.
    func historyValue(in metadata: IPTCMetadata) -> String? {
        if self == .imageSupplier {
            return EditorialImageSupplier.canonicalJSONString(for: metadata.imageSuppliers)
        }
        if self == .mediaTopic || self == .genre {
            let terms = self == .mediaTopic ? metadata.mediaTopics : metadata.genres
            guard !terms.isEmpty, let data = try? JSONEncoder().encode(terms) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let values: [String]
        switch self {
        case .creator: values = metadata.creators
        case .keywords: values = metadata.keywords
        case .personShown: values = metadata.personShown
        case .organisationShownName: values = metadata.organisationsShownNames
        case .organisationShownCode: values = metadata.organisationsShownCodes
        case .sceneCode: values = metadata.sceneCodes
        case .subjectCode: values = metadata.subjectCodes
        default: return textValue(in: metadata)
        }
        guard !values.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replays the canonical history representation, while retaining the comma-delimited parser
    /// for sidecars written before repeatable values were encoded losslessly.
    func setHistoryValue(_ value: String?, in metadata: inout IPTCMetadata) {
        if self == .imageSupplier {
            metadata.imageSuppliers = value.flatMap(
                EditorialImageSupplier.values(fromCanonicalJSONString:)
            ) ?? []
            return
        }
        if self == .mediaTopic || self == .genre,
           let value,
           let data = value.data(using: .utf8),
           let terms = try? JSONDecoder().decode([IPTCControlledVocabularyTerm].self, from: data) {
            if self == .mediaTopic {
                metadata.mediaTopics = IPTCControlledVocabularyTerm.normalizedValues(terms)
            } else {
                metadata.genres = IPTCControlledVocabularyTerm.normalizedValues(terms)
            }
            return
        }
        guard isRepeatable else {
            setTextValue(value ?? "", in: &metadata)
            return
        }

        let values: [String]
        if let value,
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            values = decoded
        } else {
            values = (value ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if self == .subjectCode {
            metadata.subjectCodes = IPTCSubjectCode.normalizedValues(values)
            return
        }
        setRepeatableValues(values, in: &metadata)
    }

    var isRepeatable: Bool {
        switch self {
        case .creator, .keywords, .personShown, .organisationShownName, .organisationShownCode,
                .sceneCode, .subjectCode, .mediaTopic, .genre:
            return true
        default:
            return false
        }
    }

    /// The low-level writer key for this stable editorial field identity.
    ///
    /// Keeping this mapping typed lets model and contract tests cover the complete field set
    /// without deriving behavior from presentation labels or delimiter-based strings.
    var metadataWriteKey: MetadataFieldKey {
        switch self {
        case .headline: .headline
        case .description: .description
        case .extendedDescription: .extendedDescription
        case .keywords: .subject
        case .personShown: .personInImage
        case .organisationShownName: .organisationInImageName
        case .organisationShownCode: .organisationInImageCode
        case .digitalSourceType: .digitalSourceType
        case .urgency: .urgency
        case .sceneCode: .scene
        case .subjectCode: .subjectCode
        case .mediaTopic: .mediaTopic
        case .genre: .genre
        case .creator: .creator
        case .creatorJobTitle: .creatorJobTitle
        case .descriptionWriter: .descriptionWriter
        case .credit: .credit
        case .copyright: .rights
        case .rightsUsageTerms: .rightsUsageTerms
        case .webStatementOfRights: .webStatementOfRights
        case .digitalImageGUID: .digitalImageGUID
        case .imageSupplierImageID: .imageSupplierImageID
        case .imageSupplier: .imageSupplier
        case .jobId: .transmissionReference
        case .dateCreated: .dateCreated
        case .city: .city
        case .sublocation: .sublocation
        case .provinceState: .provinceState
        case .country: .country
        case .countryCode: .countryCode
        case .event: .event
        case .instructions: .instructions
        case .source: .source
        }
    }

    /// The corresponding semantic read-back field. This is deliberately independent of the
    /// writer key because verification names describe the normalized model, not a container tag.
    var verificationField: IPTCMetadataVerificationField {
        switch self {
        case .headline: .headline
        case .description: .description
        case .extendedDescription: .extendedDescription
        case .keywords: .keywords
        case .personShown: .personShown
        case .organisationShownName: .organisationsShownNames
        case .organisationShownCode: .organisationsShownCodes
        case .digitalSourceType: .digitalSourceType
        case .urgency: .urgency
        case .sceneCode: .sceneCodes
        case .subjectCode: .subjectCodes
        case .mediaTopic: .mediaTopics
        case .genre: .genres
        case .creator: .creator
        case .creatorJobTitle: .creatorJobTitle
        case .descriptionWriter: .descriptionWriter
        case .credit: .credit
        case .copyright: .copyright
        case .rightsUsageTerms: .rightsUsageTerms
        case .webStatementOfRights: .webStatementOfRights
        case .digitalImageGUID: .digitalImageGUID
        case .imageSupplierImageID: .imageSupplierImageID
        case .imageSupplier: .imageSuppliers
        case .jobId: .jobId
        case .dateCreated: .dateCreated
        case .city: .city
        case .sublocation: .sublocation
        case .provinceState: .provinceState
        case .country: .country
        case .countryCode: .countryCode
        case .event: .event
        case .instructions: .instructions
        case .source: .source
        }
    }

    fileprivate func setRepeatableValues(_ values: [String], in metadata: inout IPTCMetadata) {
        let trimmed = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
        switch self {
        case .creator: metadata.creators = IPTCMetadata.normalizedCreators(trimmed)
        case .keywords: metadata.keywords = trimmed
        case .personShown: metadata.personShown = trimmed
        case .organisationShownName: metadata.organisationsShownNames = trimmed
        case .organisationShownCode: metadata.organisationsShownCodes = trimmed
        case .sceneCode:
            metadata.sceneCodes = IPTCSceneCode.normalizedValues(
                trimmed.map(IPTCSceneCode.normalizedEditorValue)
            )
        case .subjectCode:
            let existing = Set(metadata.subjectCodes)
            metadata.subjectCodes = IPTCSubjectCode.normalizedValues(trimmed.filter { value in
                IPTCSubjectCode.isCurrentSyntax(IPTCSubjectCode.normalizedValue(value))
                    || existing.contains(value)
            })
        case .mediaTopic:
            let existing = Dictionary(
                metadata.mediaTopics.map { ($0.termIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            metadata.mediaTopics = IPTCControlledVocabularyTerm.normalizedValues(
                trimmed.compactMap { value in
                    if let retained = existing[value] { return retained }
                    if let parsed = IPTCControlledVocabularyTerm.mediaTopic(metadataValue: value) {
                        return existing[parsed.termIdentifier] ?? parsed
                    }
                    let generic = IPTCControlledVocabularyTerm(termIdentifier: value)
                    return generic.isValid ? generic : nil
                }
            )
        case .genre:
            let existing = Dictionary(
                metadata.genres.map { ($0.termIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            metadata.genres = IPTCControlledVocabularyTerm.normalizedValues(
                trimmed.compactMap { value in
                    if let retained = existing[value] { return retained }
                    if let parsed = IPTCControlledVocabularyTerm.genre(metadataValue: value) {
                        return existing[parsed.termIdentifier] ?? parsed
                    }
                    let generic = IPTCControlledVocabularyTerm(termIdentifier: value)
                    return generic.isValid ? generic : nil
                }
            )
        default: break
        }
    }

    fileprivate func repeatableValues(in metadata: IPTCMetadata) -> [String] {
        switch self {
        case .creator: metadata.creators
        case .keywords: metadata.keywords
        case .personShown: metadata.personShown
        case .organisationShownName: metadata.organisationsShownNames
        case .organisationShownCode: metadata.organisationsShownCodes
        case .sceneCode: metadata.sceneCodes
        case .subjectCode: metadata.subjectCodes
        case .mediaTopic: metadata.mediaTopics.map(\.termIdentifier)
        case .genre: metadata.genres.map(\.termIdentifier)
        default: []
        }
    }

    fileprivate func invalidRepeatableValue(
        in values: [String],
        existing metadata: IPTCMetadata
    ) -> String? {
        let values = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch self {
        case .subjectCode:
            let existing = Set(metadata.subjectCodes)
            return values.first { value in
                !IPTCSubjectCode.isCurrentSyntax(IPTCSubjectCode.normalizedValue(value))
                    && !existing.contains(value)
            }
        case .mediaTopic:
            let existing = Set(metadata.mediaTopics.map(\.termIdentifier))
            return values.first { value in
                if existing.contains(value) { return false }
                if IPTCControlledVocabularyTerm.mediaTopic(metadataValue: value) != nil { return false }
                return !IPTCControlledVocabularyTerm(termIdentifier: value).isValid
            }
        case .genre:
            let existing = Set(metadata.genres.map(\.termIdentifier))
            return values.first { value in
                if existing.contains(value) { return false }
                if IPTCControlledVocabularyTerm.genre(metadataValue: value) != nil { return false }
                return !IPTCControlledVocabularyTerm(termIdentifier: value).isValid
            }
        default:
            return nil
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
        case .urgency: metadata.urgency = scalar.flatMap(Int.init)
        case .sceneCode:
            metadata.sceneCodes = IPTCSceneCode.normalizedValues(
                value.components(separatedBy: CharacterSet(charactersIn: ",;"))
            )
        case .subjectCode:
            metadata.subjectCodes = IPTCSubjectCode.normalizedValues(
                value.components(separatedBy: CharacterSet(charactersIn: ",;"))
            )
        case .mediaTopic:
            metadata.mediaTopics = IPTCControlledVocabularyTerm.normalizedValues(
                value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .compactMap { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
            )
        case .genre:
            metadata.genres = IPTCControlledVocabularyTerm.normalizedValues(
                value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .compactMap { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
            )
        case .creator: metadata.creator = scalar
        case .creatorJobTitle: metadata.creatorJobTitle = scalar
        case .descriptionWriter: metadata.descriptionWriter = scalar
        case .credit: metadata.credit = scalar
        case .copyright: metadata.copyright = scalar
        case .rightsUsageTerms: metadata.rightsUsageTerms = scalar
        case .webStatementOfRights: metadata.webStatementOfRights = scalar
        case .digitalImageGUID: metadata.digitalImageGUID = scalar
        case .imageSupplierImageID: metadata.imageSupplierImageID = scalar
        case .imageSupplier:
            if trimmed.isEmpty {
                metadata.imageSuppliers = []
            } else if let values = EditorialImageSupplier.values(fromCanonicalJSONString: trimmed) {
                metadata.imageSuppliers = values
            }
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
        .copyright, .creator, .rightsUsageTerms, .webStatementOfRights, .digitalImageGUID,
        .imageSupplierImageID, .imageSupplier, .jobId, .dateCreated,
    ]

    /// Fields displayed after the primary metadata and classification editors.
    static let additionalEditorFields: [Self] = [
        .urgency, .sceneCode, .subjectCode, .mediaTopic, .genre,
        .creatorJobTitle, .descriptionWriter, .credit, .source, .city, .sublocation,
        .provinceState, .country, .countryCode, .event, .instructions,
    ]

    /// Every field that can be shown or hidden in the editable metadata panel.
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
    static let userSelectable = allCases.filter { $0 != .digitalSourceType }

    static func decodeHidden(_ rawValues: [String]) -> Set<Self> {
        Set(rawValues.compactMap(Self.init(rawValue:)))
            .intersection(optionalEditorFields)
    }

    /// Source compatibility for the former nested `IPTCMetadata.FieldKey.title` case.
    static var title: Self { .headline }

    /// Maps labels written by pre-stable-ID history entries back to canonical field identity.
    /// Keep aliases here so label changes never make old entries unrestorable.
    init?(legacyHistoryName: String) {
        switch legacyHistoryName {
        case "Title", "Headline": self = .headline
        case "Job-ID", "Job ID": self = .jobId
        default:
            guard let match = Self.allCases.first(where: { $0.displayName == legacyHistoryName }) else {
                return nil
            }
            self = match
        }
    }
}

/// A value carried by an explicit field mutation. Scalar and repeatable values are separate so a
/// comma inside a keyword, person, or organisation name is never interpreted as a delimiter.
nonisolated enum MetadataFieldMutationValue: Sendable, Equatable {
    case scalar(String)
    case repeatable([String])
}

/// An explicit per-field editing intent. Empty overwrite values are rejected: callers must choose
/// `.clear` or `.untouched`, so an empty string can never acquire both meanings at this boundary.
nonisolated enum MetadataFieldMutation: Sendable, Equatable {
    case untouched
    case overwrite(MetadataFieldMutationValue)
    case append([String])
    case clear
}

nonisolated enum MetadataFieldMutationError: Error, Sendable, Equatable {
    case scalarValueRequired(MetadataFieldID)
    case repeatableValueRequired(MetadataFieldID)
    case appendRequiresRepeatableField(MetadataFieldID)
    case emptyOverwriteRequiresClear(MetadataFieldID)
    case emptyAppendRequiresUntouched(MetadataFieldID)
    case invalidCanonicalValue(MetadataFieldID, String)
}

/// A transport-safe group of explicit field mutations suitable for detached preparation and
/// validation before a writer is invoked.
nonisolated struct MetadataFieldMutationSet: Sendable, Equatable {
    let operations: [MetadataFieldID: MetadataFieldMutation]

    nonisolated init(_ operations: [MetadataFieldID: MetadataFieldMutation]) {
        self.operations = operations
    }

    nonisolated func applying(to metadata: IPTCMetadata) throws -> IPTCMetadata {
        var result = metadata
        for field in MetadataFieldID.allCases {
            guard let operation = operations[field] else { continue }
            try result.apply(operation, to: field)
        }
        return result
    }
}

extension IPTCMetadata {
    /// Applies one explicit mutation transactionally. Invalid values never partially alter the
    /// receiver, leaving validation and I/O callers with an exact pre-mutation record.
    nonisolated mutating func apply(
        _ operation: MetadataFieldMutation,
        to field: MetadataFieldID
    ) throws {
        switch operation {
        case .untouched:
            return

        case .clear:
            var candidate = self
            if field.isRepeatable {
                field.setRepeatableValues([], in: &candidate)
            } else {
                field.setTextValue("", in: &candidate)
            }
            self = candidate

        case .overwrite(.scalar(let value)):
            guard !field.isRepeatable else {
                throw MetadataFieldMutationError.repeatableValueRequired(field)
            }
            let canonicalInput = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalInput.isEmpty else {
                throw MetadataFieldMutationError.emptyOverwriteRequiresClear(field)
            }
            if field == .dateCreated,
               (try? EditorialDateCreated(parsing: canonicalInput)) == nil {
                throw MetadataFieldMutationError.invalidCanonicalValue(field, canonicalInput)
            }
            var candidate = self
            field.setTextValue(canonicalInput, in: &candidate)
            guard !field.isEmpty(in: candidate) else {
                throw MetadataFieldMutationError.invalidCanonicalValue(field, canonicalInput)
            }
            self = candidate

        case .overwrite(.repeatable(let values)):
            guard field.isRepeatable else {
                throw MetadataFieldMutationError.scalarValueRequired(field)
            }
            if let invalid = field.invalidRepeatableValue(in: values, existing: self) {
                throw MetadataFieldMutationError.invalidCanonicalValue(field, invalid)
            }
            var candidate = self
            field.setRepeatableValues(values, in: &candidate)
            guard !field.isEmpty(in: candidate) else {
                throw MetadataFieldMutationError.emptyOverwriteRequiresClear(field)
            }
            self = candidate

        case .append(let values):
            guard field.isRepeatable else {
                throw MetadataFieldMutationError.appendRequiresRepeatableField(field)
            }
            if let invalid = field.invalidRepeatableValue(in: values, existing: self) {
                throw MetadataFieldMutationError.invalidCanonicalValue(field, invalid)
            }
            var appendedCandidate = self
            field.setRepeatableValues(values, in: &appendedCandidate)
            let appended = field.repeatableValues(in: appendedCandidate)
            guard !appended.isEmpty else {
                throw MetadataFieldMutationError.emptyAppendRequiresUntouched(field)
            }
            var candidate = self
            field.setRepeatableValues(
                field.repeatableValues(in: self) + appended,
                in: &candidate
            )
            self = candidate
        }
    }
}

extension IPTCMetadata {
    /// Source-compatible spelling retained for code and Codable values shipped before Phase 1.
    typealias FieldKey = MetadataFieldID
}
