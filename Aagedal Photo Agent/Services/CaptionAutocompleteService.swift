import Foundation

/// The origin of a Caption Workspace suggestion. Provenance is display-only: Known People and
/// structured-roster candidates deliberately carry no face, group, or roster identity mutation.
nonisolated enum CaptionAutocompleteProvenance: Hashable, Sendable {
    case approvedList
    case structuredKeywords
    case structuredPersonShown
    case knownPeople
    case currentFolder
    case utf8TextList(name: String)

    var displayName: String {
        switch self {
        case .approvedList: return "Approved list"
        case .structuredKeywords: return "Structured keywords"
        case .structuredPersonShown: return "Structured people"
        case .knownPeople: return "Known People"
        case .currentFolder: return "Current folder"
        case let .utf8TextList(name): return name
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .approvedList: return 0
        case .structuredKeywords, .structuredPersonShown: return 1
        case .knownPeople: return 2
        case .currentFolder: return 3
        case .utf8TextList: return 4
        }
    }
}

/// One value supplied by an existing metadata source.
///
/// `insertionValues` lets a structured keyword/name insert its canonical expansion while an alias
/// remains searchable and visible. Scalar fields use the first insertion value; repeatable fields
/// append all of them in order.
nonisolated struct CaptionAutocompleteSeed: Hashable, Sendable {
    let field: MetadataFieldID
    let displayValue: String
    let insertionValues: [String]
    let provenance: CaptionAutocompleteProvenance

    init(
        field: MetadataFieldID,
        displayValue: String,
        insertionValues: [String]? = nil,
        provenance: CaptionAutocompleteProvenance
    ) {
        self.field = field
        self.displayValue = displayValue
        self.insertionValues = insertionValues ?? [displayValue]
        self.provenance = provenance
    }
}

nonisolated enum CaptionAutocompleteMatchKind: Int, Hashable, Sendable {
    case prefix
    case substring
    case unfiltered
}

/// A suggestion is inert until the user explicitly asks to apply it.
nonisolated struct CaptionAutocompleteSuggestion: Hashable, Identifiable, Sendable {
    let field: MetadataFieldID
    let displayValue: String
    let insertionValues: [String]
    let provenances: [CaptionAutocompleteProvenance]
    let matchKind: CaptionAutocompleteMatchKind

    var id: String {
        "\(field.rawValue):\(CaptionAutocompleteService.normalized(displayValue))"
    }
}

nonisolated enum CaptionAutocompleteCompositionState: Hashable, Sendable {
    case committed
    case active
}

nonisolated enum CaptionAutocompleteRefusal: Hashable, Sendable {
    case activeComposition
    case fieldMismatch
    case emptyInsertion
    case noChange
}

nonisolated enum CaptionAutocompleteApplyResult: Equatable, Sendable {
    case applied(IPTCMetadata)
    case refused(CaptionAutocompleteRefusal)
}

/// Pure, deterministic suggestion matching and insertion semantics for Caption Workspace.
nonisolated enum CaptionAutocompleteService {
    /// Produces field-scoped suggestions without mutating metadata. Prefix matches precede
    /// substring matches, then source priority and source order provide deterministic tie breaks.
    static func suggestions(
        for field: MetadataFieldID,
        query: String,
        currentMetadata: IPTCMetadata,
        seeds: [CaptionAutocompleteSeed],
        limit: Int = 20
    ) -> [CaptionAutocompleteSuggestion] {
        guard limit > 0 else { return [] }
        let needle = normalized(query)
        var merged: [String: MergedCandidate] = [:]
        var order: [String] = []

        for (ordinal, seed) in seeds.enumerated() where seed.field == field {
            let display = seed.displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let insertions = sanitized(seed.insertionValues)
            guard !display.isEmpty, !insertions.isEmpty else { continue }

            let normalizedDisplay = normalized(display)
            let matchKind: CaptionAutocompleteMatchKind
            if needle.isEmpty {
                matchKind = .unfiltered
            } else if normalizedDisplay.hasPrefix(needle) {
                matchKind = .prefix
            } else if normalizedDisplay.contains(needle) {
                matchKind = .substring
            } else {
                continue
            }

            guard changesMetadata(field: field, insertionValues: insertions, metadata: currentMetadata) else {
                continue
            }

            if var existing = merged[normalizedDisplay] {
                if !existing.provenances.contains(seed.provenance) {
                    existing.provenances.append(seed.provenance)
                    existing.bestPriority = min(existing.bestPriority, seed.provenance.priority)
                }
                if matchKind.rawValue < existing.matchKind.rawValue {
                    existing.matchKind = matchKind
                }
                merged[normalizedDisplay] = existing
            } else {
                merged[normalizedDisplay] = MergedCandidate(
                    field: field,
                    displayValue: display,
                    insertionValues: insertions,
                    provenances: [seed.provenance],
                    matchKind: matchKind,
                    bestPriority: seed.provenance.priority,
                    ordinal: ordinal
                )
                order.append(normalizedDisplay)
            }
        }

        return order.compactMap { merged[$0] }
            .sorted {
                if $0.matchKind.rawValue != $1.matchKind.rawValue {
                    return $0.matchKind.rawValue < $1.matchKind.rawValue
                }
                if $0.bestPriority != $1.bestPriority {
                    return $0.bestPriority < $1.bestPriority
                }
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return normalized($0.displayValue) < normalized($1.displayValue)
            }
            .prefix(limit)
            .map {
                CaptionAutocompleteSuggestion(
                    field: $0.field,
                    displayValue: $0.displayValue,
                    insertionValues: $0.insertionValues,
                    provenances: $0.provenances,
                    matchKind: $0.matchKind
                )
            }
    }

    /// Applies one explicitly selected suggestion. An active IME composition is an atomic refusal;
    /// no partially committed text or metadata is changed.
    static func apply(
        _ suggestion: CaptionAutocompleteSuggestion,
        to field: MetadataFieldID,
        metadata: IPTCMetadata,
        compositionState: CaptionAutocompleteCompositionState
    ) -> CaptionAutocompleteApplyResult {
        guard compositionState == .committed else { return .refused(.activeComposition) }
        guard suggestion.field == field else { return .refused(.fieldMismatch) }
        let insertionValues = sanitized(suggestion.insertionValues)
        guard !insertionValues.isEmpty else { return .refused(.emptyInsertion) }

        var updated = metadata
        if field.isRepeatable {
            var values = repeatableValues(for: field, in: updated)
            var seen = Set(values.map(normalized))
            for value in insertionValues where seen.insert(normalized(value)).inserted {
                values.append(value)
            }
            guard values != repeatableValues(for: field, in: metadata) else {
                return .refused(.noChange)
            }
            setRepeatableValues(values, for: field, in: &updated)
        } else {
            let value = insertionValues[0]
            guard normalized(field.textValue(in: updated) ?? "") != normalized(value) else {
                return .refused(.noChange)
            }
            field.setTextValue(value, in: &updated)
        }
        return .applied(updated)
    }

    /// Converts values already loaded for the browser's current folder into typed candidates.
    /// First occurrence wins and repeatable values remain atomic even when they contain commas.
    static func currentFolderSeeds(
        from metadataValues: [IPTCMetadata],
        fields: [MetadataFieldID]
    ) -> [CaptionAutocompleteSeed] {
        var result: [CaptionAutocompleteSeed] = []
        var seenByField: [MetadataFieldID: Set<String>] = [:]

        for metadata in metadataValues {
            for field in fields {
                let values = field.isRepeatable
                    ? repeatableValues(for: field, in: metadata)
                    : [field.textValue(in: metadata)].compactMap { $0 }
                for value in sanitized(values) {
                    if seenByField[field, default: []].insert(normalized(value)).inserted {
                        result.append(CaptionAutocompleteSeed(
                            field: field,
                            displayValue: value,
                            provenance: .currentFolder
                        ))
                    }
                }
            }
        }
        return result
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct MergedCandidate {
        let field: MetadataFieldID
        let displayValue: String
        let insertionValues: [String]
        var provenances: [CaptionAutocompleteProvenance]
        var matchKind: CaptionAutocompleteMatchKind
        var bestPriority: Int
        let ordinal: Int
    }

    private static func sanitized(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(normalized(trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func changesMetadata(
        field: MetadataFieldID,
        insertionValues: [String],
        metadata: IPTCMetadata
    ) -> Bool {
        if field.isRepeatable {
            let existing = Set(repeatableValues(for: field, in: metadata).map(normalized))
            return insertionValues.contains { !existing.contains(normalized($0)) }
        }
        guard let first = insertionValues.first else { return false }
        return normalized(field.textValue(in: metadata) ?? "") != normalized(first)
    }

    private static func repeatableValues(for field: MetadataFieldID, in metadata: IPTCMetadata) -> [String] {
        switch field {
        case .creator: return metadata.creators
        case .keywords: return metadata.keywords
        case .personShown: return metadata.personShown
        case .organisationShownName: return metadata.organisationsShownNames
        case .organisationShownCode: return metadata.organisationsShownCodes
        case .sceneCode: return metadata.sceneCodes
        case .subjectCode: return metadata.subjectCodes
        case .mediaTopic: return metadata.mediaTopics.map(\.termIdentifier)
        case .genre: return metadata.genres.map(\.termIdentifier)
        default: return []
        }
    }

    private static func setRepeatableValues(
        _ values: [String],
        for field: MetadataFieldID,
        in metadata: inout IPTCMetadata
    ) {
        switch field {
        case .creator: metadata.creators = IPTCMetadata.normalizedCreators(values)
        case .keywords: metadata.keywords = values
        case .personShown: metadata.personShown = values
        case .organisationShownName: metadata.organisationsShownNames = values
        case .organisationShownCode: metadata.organisationsShownCodes = values
        case .sceneCode: metadata.sceneCodes = values
        case .subjectCode: metadata.subjectCodes = IPTCSubjectCode.normalizedValues(values)
        case .mediaTopic:
            metadata.mediaTopics = IPTCControlledVocabularyTerm.normalizedValues(
                values.compactMap { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
            )
        case .genre:
            metadata.genres = IPTCControlledVocabularyTerm.normalizedValues(
                values.compactMap { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
            )
        default: break
        }
    }
}
