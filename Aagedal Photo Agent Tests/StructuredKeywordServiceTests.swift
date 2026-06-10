import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// `expand` is the only behaviour that diverges between the keyword tree and the
/// Person Shown tree: keywords add their keyword-ancestors, people do not. The
/// payload otherwise (node name + synonyms) is identical. These tests pin that
/// divergence so the two services can't silently converge.
@MainActor
@Suite("StructuredKeywordService expand semantics")
struct StructuredKeywordServiceTests {

    /// Politicians[container] › Norway[keyword] › "Jonas Gahr Støre"{Store}
    private func samplePath() -> StructuredKeywordPath {
        StructuredKeywordPath(
            ancestors: [
                StructuredKeyword(name: "Politicians", kind: .container),
                StructuredKeyword(name: "Norway", kind: .keyword),
            ],
            node: StructuredKeyword(name: "Jonas Gahr Støre", kind: .keyword, synonyms: ["Store"])
        )
    }

    @Test("Keyword tree includes keyword-ancestors plus node plus synonyms")
    func keywordExpandIncludesAncestors() {
        let expanded = StructuredKeywordService.shared.expand(samplePath())
        // Container ancestor "Politicians" is dropped; keyword ancestor "Norway" stays.
        #expect(expanded == ["Norway", "Jonas Gahr Støre", "Store"])
    }

    @Test("Person Shown tree writes only the name plus its synonyms — never the category")
    func personExpandExcludesAncestors() {
        let expanded = StructuredKeywordService.personShown.expand(samplePath())
        #expect(expanded == ["Jonas Gahr Støre", "Store"])
        #expect(!expanded.contains("Norway"))
        #expect(!expanded.contains("Politicians"))
    }

    @Test("expansion(forName:) matches keyword nodes case-insensitively and expands like the picker")
    func expansionForName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-expansion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structured)
            try service.saveTree([
                StructuredKeyword(name: "Politicians", kind: .container, children: [
                    StructuredKeyword(name: "Norway", kind: .keyword, children: [
                        StructuredKeyword(name: "Jonas Gahr Støre", kind: .keyword, synonyms: ["Store"]),
                    ]),
                ]),
            ])

            #expect(service.expansion(forName: "jonas gahr støre") == ["Norway", "Jonas Gahr Støre", "Store"])
            // Containers are navigation-only and never expand.
            #expect(service.expansion(forName: "Politicians") == nil)
            #expect(service.expansion(forName: "Not In Tree") == nil)
        }
    }
}
