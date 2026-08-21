import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Caption autocomplete service")
struct CaptionAutocompleteServiceTests {
    @Test("Suggestions are field scoped, prefix first, and deterministic")
    func fieldScopedOrdering() {
        let seeds = [
            seed(.keywords, "World Cup", .currentFolder),
            seed(.personShown, "World Person", .knownPeople),
            seed(.keywords, "Cup Final", .approvedList),
            seed(.keywords, "World News", .utf8TextList(name: "Keywords list")),
            seed(.keywords, "Worldwide", .structuredKeywords),
        ]

        let suggestions = CaptionAutocompleteService.suggestions(
            for: .keywords,
            query: "world",
            currentMetadata: IPTCMetadata(),
            seeds: seeds
        )

        #expect(suggestions.map(\.displayValue) == ["Worldwide", "World Cup", "World News"])
        #expect(suggestions.map(\.matchKind) == [.prefix, .prefix, .prefix])
        #expect(!suggestions.contains { $0.displayValue == "World Person" })
    }

    @Test("Substring matches follow prefix matches")
    func substringAfterPrefix() {
        let suggestions = CaptionAutocompleteService.suggestions(
            for: .city,
            query: "york",
            currentMetadata: IPTCMetadata(),
            seeds: [
                seed(.city, "New York", .currentFolder),
                seed(.city, "York", .utf8TextList(name: "City list")),
            ]
        )

        #expect(suggestions.map(\.displayValue) == ["York", "New York"])
        #expect(suggestions.map(\.matchKind) == [.prefix, .substring])
    }

    @Test("Duplicate candidates merge typed provenance without changing first insertion semantics")
    func provenanceMerge() throws {
        let suggestions = CaptionAutocompleteService.suggestions(
            for: .keywords,
            query: "sport",
            currentMetadata: IPTCMetadata(),
            seeds: [
                CaptionAutocompleteSeed(
                    field: .keywords,
                    displayValue: "Sport",
                    insertionValues: ["Sport"],
                    provenance: .approvedList
                ),
                CaptionAutocompleteSeed(
                    field: .keywords,
                    displayValue: "sport",
                    insertionValues: ["News", "Sport"],
                    provenance: .structuredKeywords
                ),
                seed(.keywords, "SPORT", .currentFolder),
            ]
        )

        let suggestion = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(suggestion.displayValue == "Sport")
        #expect(suggestion.insertionValues == ["Sport"])
        #expect(suggestion.provenances == [.approvedList, .structuredKeywords, .currentFolder])
    }

    @Test("Empty query returns source-priority candidates and obeys limit")
    func emptyQueryAndLimit() {
        let suggestions = CaptionAutocompleteService.suggestions(
            for: .creator,
            query: "",
            currentMetadata: IPTCMetadata(),
            seeds: [
                seed(.creator, "Folder", .currentFolder),
                seed(.creator, "List One", .utf8TextList(name: "Creator list")),
                seed(.creator, "List Two", .utf8TextList(name: "Creator list")),
            ],
            limit: 2
        )

        #expect(suggestions.map(\.displayValue) == ["Folder", "List One"])
    }

    @Test("Generating suggestions is inert until explicit apply")
    func suggestionGenerationDoesNotMutate() {
        let original = IPTCMetadata(city: "Oslo")
        _ = CaptionAutocompleteService.suggestions(
            for: .city,
            query: "ber",
            currentMetadata: original,
            seeds: [seed(.city, "Berlin", .currentFolder)]
        )
        #expect(original.city == "Oslo")
    }

    @Test("Ordered Creator insertion appends without changing unrelated fields")
    func scalarInsertion() throws {
        let metadata = IPTCMetadata(
            title: "Headline",
            keywords: ["news"],
            creator: "Old Creator",
            city: "Oslo"
        )
        let suggestion = try #require(CaptionAutocompleteService.suggestions(
            for: .creator,
            query: "new",
            currentMetadata: metadata,
            seeds: [seed(.creator, "New Creator", .utf8TextList(name: "Creator list"))]
        ).first)

        let result = CaptionAutocompleteService.apply(
            suggestion,
            to: .creator,
            metadata: metadata,
            compositionState: .committed
        )
        let updated = try appliedMetadata(result)
        #expect(updated.creators == ["Old Creator", "New Creator"])
        #expect(updated.title == "Headline")
        #expect(updated.keywords == ["news"])
        #expect(updated.city == "Oslo")
    }

    @Test("Repeatable insertion appends expansion in order with normalized deduplication")
    func repeatableAppendAndDeduplicate() throws {
        let metadata = IPTCMetadata(keywords: ["News", "Café"])
        let suggestion = CaptionAutocompleteSuggestion(
            field: .keywords,
            displayValue: "Football",
            insertionValues: ["news", "Cafe", "Sports", "Football", "sports"],
            provenances: [.structuredKeywords],
            matchKind: .prefix
        )

        let updated = try appliedMetadata(CaptionAutocompleteService.apply(
            suggestion,
            to: .keywords,
            metadata: metadata,
            compositionState: .committed
        ))
        #expect(updated.keywords == ["News", "Café", "Sports", "Football"])
    }

    @Test("Known People insertion changes metadata text but no identity-bearing state")
    func knownPeopleIsSuggestionOnly() throws {
        let metadata = IPTCMetadata(personShown: ["Existing"], jobId: "JOB-1")
        let suggestion = try #require(CaptionAutocompleteService.suggestions(
            for: .personShown,
            query: "ada",
            currentMetadata: metadata,
            seeds: [seed(.personShown, "Ada Lovelace", .knownPeople)]
        ).first)

        let updated = try appliedMetadata(CaptionAutocompleteService.apply(
            suggestion,
            to: .personShown,
            metadata: metadata,
            compositionState: .committed
        ))
        #expect(updated.personShown == ["Existing", "Ada Lovelace"])
        #expect(updated.jobId == "JOB-1")
        #expect(suggestion.provenances == [.knownPeople])
    }

    @Test("Active IME composition is an atomic refusal")
    func activeCompositionRefusal() throws {
        let metadata = IPTCMetadata(description: "入力中", keywords: ["news"])
        let suggestion = CaptionAutocompleteSuggestion(
            field: .description,
            displayValue: "完成した説明",
            insertionValues: ["完成した説明"],
            provenances: [.currentFolder],
            matchKind: .prefix
        )

        let result = CaptionAutocompleteService.apply(
            suggestion,
            to: .description,
            metadata: metadata,
            compositionState: .active
        )
        #expect(result == .refused(.activeComposition))
        #expect(metadata.description == "入力中")
        #expect(metadata.keywords == ["news"])
    }

    @Test("A suggestion cannot be redirected into a different focused field")
    func fieldMismatchRefusal() {
        let suggestion = CaptionAutocompleteSuggestion(
            field: .city,
            displayValue: "Oslo",
            insertionValues: ["Oslo"],
            provenances: [.currentFolder],
            matchKind: .prefix
        )
        let result = CaptionAutocompleteService.apply(
            suggestion,
            to: .country,
            metadata: IPTCMetadata(country: "Norway"),
            compositionState: .committed
        )
        #expect(result == .refused(.fieldMismatch))
    }

    @Test("Current-folder extraction preserves first occurrence and atomic list values")
    func currentFolderExtraction() {
        let metadata = [
            IPTCMetadata(keywords: ["News", "Smith, Jane"], city: "Oslo"),
            IPTCMetadata(keywords: ["news", "Sport"], city: "oslo"),
            IPTCMetadata(city: "Bergen"),
        ]
        let seeds = CaptionAutocompleteService.currentFolderSeeds(
            from: metadata,
            fields: [.keywords, .city]
        )

        #expect(seeds.map { "\($0.field.rawValue):\($0.displayValue)" } == [
            "keywords:News", "keywords:Smith, Jane", "city:Oslo",
            "keywords:Sport", "city:Bergen",
        ])
        #expect(seeds.allSatisfy { $0.provenance == .currentFolder })
    }

    @Test("Already-present values are omitted as no-op suggestions")
    func omitNoOps() {
        let metadata = IPTCMetadata(keywords: ["Café"], city: "OSLO")
        #expect(CaptionAutocompleteService.suggestions(
            for: .keywords,
            query: "cafe",
            currentMetadata: metadata,
            seeds: [seed(.keywords, "Cafe", .currentFolder)]
        ).isEmpty)
        #expect(CaptionAutocompleteService.suggestions(
            for: .city,
            query: "oslo",
            currentMetadata: metadata,
            seeds: [seed(.city, "oslo", .currentFolder)]
        ).isEmpty)
    }

    private func seed(
        _ field: MetadataFieldID,
        _ value: String,
        _ provenance: CaptionAutocompleteProvenance
    ) -> CaptionAutocompleteSeed {
        CaptionAutocompleteSeed(field: field, displayValue: value, provenance: provenance)
    }

    private func appliedMetadata(_ result: CaptionAutocompleteApplyResult) throws -> IPTCMetadata {
        guard case let .applied(metadata) = result else {
            Issue.record("Expected applied metadata, got \(result)")
            throw TestFailure.expectedAppliedMetadata
        }
        return metadata
    }

    private enum TestFailure: Error {
        case expectedAppliedMetadata
    }
}
