import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People interchange presentation copy")
struct KnownPeopleInterchangePresentationTests {
    @Test("Replacement prompt names every relationship explicitly",
          arguments: [
            KnownPeopleInterchangeImportPrompt.Relationship.sameLibrary,
            .differentLibrary,
            .untracked
          ])
    func relationshipCopy(relationship: KnownPeopleInterchangeImportPrompt.Relationship) {
        let content = KnownPeopleInterchangePromptCopy.content(for: prompt(relationship: relationship))
        switch relationship {
        case .sameLibrary:
            #expect(content.title == "Replace This People Library?")
            #expect(content.message.contains("same library"))
        case .differentLibrary:
            #expect(content.title == "Replace with a Different People Library?")
            #expect(content.message.contains("different library"))
        case .untracked:
            #expect(content.title == "Replace Untracked Local Data?")
            #expect(content.message.contains("has no library identity"))
        }
        #expect(content.confirmLabel == "Replace Library")
        #expect(content.message.contains("Current: 3 people, 7 face samples"))
        #expect(content.message.contains("Incoming: 2 people, 5 face samples"))
        #expect(content.message.contains("11111111-1111-1111-1111-111111111111"))
        #expect(content.message.contains("22222222-2222-2222-2222-222222222222"))
    }

    @Test("Empty import and missing editor metadata receive distinct warnings")
    func emptyAndMissingEditorWarnings() {
        let content = KnownPeopleInterchangePromptCopy.content(
            for: prompt(relationship: .differentLibrary, people: 0, embeddings: 0, missingEditor: true)
        )
        #expect(content.title == "Replace with a Different Empty Library?")
        #expect(content.message.contains("removes every person and face sample"))
        #expect(content.message.contains("does not include editor metadata"))
        #expect(content.message.contains("roles, notes, representative-photo choices"))
        #expect(content.message.contains("added and updated dates"))
        #expect(content.message.contains("source descriptions"))
        #expect(content.message.contains("recognition metadata"))
        #expect(content.message.contains("unavailable or use defaults"))
    }

    @Test("Unknown local measurements are never presented as zero")
    func unknownCurrentCounts() {
        let value = KnownPeopleInterchangeImportPrompt(
            token: .init(),
            sourceURL: URL(fileURLWithPath: "/private/tmp/people.aagedalpeople"),
            libraryID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            relationship: .untracked,
            peopleCount: 1,
            embeddingCount: 1
        )
        let content = KnownPeopleInterchangePromptCopy.content(for: value)
        #expect(content.message.contains("Current: unknown people, unknown face samples"))
        #expect(content.message.contains("Library ID: Untracked"))
    }

    private func prompt(
        relationship: KnownPeopleInterchangeImportPrompt.Relationship,
        people: Int = 2,
        embeddings: Int = 5,
        missingEditor: Bool = false
    ) -> KnownPeopleInterchangeImportPrompt {
        .init(
            token: .init(),
            sourceURL: URL(fileURLWithPath: "/private/tmp/people.aagedalpeople"),
            libraryID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            relationship: relationship,
            peopleCount: people,
            embeddingCount: embeddings,
            currentLibraryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            currentPeopleCount: 3,
            currentEmbeddingCount: 7,
            missingEditorMetadata: missingEditor
        )
    }
}
