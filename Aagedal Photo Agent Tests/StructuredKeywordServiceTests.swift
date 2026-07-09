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

    @Test("Activation carries ancestor category names separately from expanded values")
    func activationCarriesCategoryKeywords() {
        let activation = StructuredKeywordService.personShown.activation(samplePath())
        #expect(activation.values == ["Jonas Gahr Støre", "Store"])
        #expect(activation.categoryKeywords == ["Politicians", "Norway"])
        #expect(activation.relatedKeywords.isEmpty)
    }

    @Test("expansion(forName:) matches keyword nodes and synonyms case-insensitively")
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
            #expect(service.expansion(forName: "store") == ["Norway", "Jonas Gahr Støre", "Store"])
            // Containers are navigation-only and never expand.
            #expect(service.expansion(forName: "Politicians") == nil)
            #expect(service.expansion(forName: "Not In Tree") == nil)
        }
    }

    @Test("activation(forName:) carries related keywords for node and synonym matches")
    func activationForNameIncludesRelatedKeywords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)
            try service.saveTree([
                StructuredKeyword(name: "People", kind: .container, children: [
                    StructuredKeyword(
                        name: "Ada Lovelace",
                        kind: .keyword,
                        synonyms: ["Countess of Lovelace"],
                        relatedKeywords: ["mathematician", "computing pioneer"]
                    ),
                ]),
            ])

            #expect(service.activation(forName: "Ada Lovelace")?.values == ["Ada Lovelace", "Countess of Lovelace"])
            #expect(service.activation(forName: "countess of lovelace")?.relatedKeywords == ["mathematician", "computing pioneer"])
        }
    }

    @Test("searchable names include synonyms and canonical resolver maps aliases to node names")
    func searchableNamesAndCanonicalResolver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-searchable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)
            try service.saveTree([
                StructuredKeyword(name: "People", kind: .container, children: [
                    StructuredKeyword(name: "Jonas Gahr Støre", kind: .keyword, synonyms: ["Store", "Statsministeren"]),
                    StructuredKeyword(name: "Store", kind: .keyword),
                ]),
            ])

            #expect(service.allSearchableNames() == ["Jonas Gahr Støre", "Store", "Statsministeren"])
            #expect(service.canonicalName(forNameOrSynonym: "statsministeren") == "Jonas Gahr Støre")
            #expect(service.canonicalName(forNameOrSynonym: "Store") == "Jonas Gahr Støre")
            #expect(service.canonicalName(forNameOrSynonym: "People") == nil)
        }
    }
}
