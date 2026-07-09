import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("StructuredKeywordParser")
struct StructuredKeywordParserTests {

    @Test("Top-level keywords are parsed in file order")
    func topLevelKeywords() {
        let input = "animals\npets\nwildlife\n"
        let roots = StructuredKeywordParser.parseString(input)
        #expect(roots.map(\.name) == ["animals", "pets", "wildlife"])
        #expect(roots.allSatisfy { $0.isKeyword })
        #expect(roots.allSatisfy { $0.children.isEmpty })
    }

    @Test("Tab indent attaches children to the most recent parent")
    func tabIndentChildren() {
        let input = "animals\n\tlivestock\n\t\tcattle\n\tpets\n"
        let roots = StructuredKeywordParser.parseString(input)
        #expect(roots.count == 1)
        let animals = roots[0]
        #expect(animals.name == "animals")
        #expect(animals.children.map(\.name) == ["livestock", "pets"])
        let livestock = animals.children[0]
        #expect(livestock.children.map(\.name) == ["cattle"])
    }

    @Test("{Braces} are attached as synonyms of the owning parent")
    func bracedSynonyms() {
        let input = "animals\n\t{animal}\n\t{beast}\n\tlivestock\n\t\tcattle\n\t\t\t{cows}\n"
        let roots = StructuredKeywordParser.parseString(input)
        let animals = roots[0]
        #expect(animals.synonyms == ["animal", "beast"])
        let livestock = animals.children.first { $0.name == "livestock" }!
        let cattle = livestock.children.first { $0.name == "cattle" }!
        #expect(cattle.synonyms == ["cows"])
    }

    @Test("#Keywords are attached as related keywords of the owning parent")
    func relatedKeywords() {
        let input = "People\n\tAda Lovelace\n\t\t#mathematician\n\t\t# computing pioneer\n\t\t{Countess of Lovelace}\n"
        let roots = StructuredKeywordParser.parseString(input)
        let person = roots[0].children[0]
        #expect(person.name == "Ada Lovelace")
        #expect(person.relatedKeywords == ["mathematician", "computing pioneer"])
        #expect(person.synonyms == ["Countess of Lovelace"])
    }

    @Test("[Brackets] become non-keyword containers")
    func bracketContainers() {
        let input = "reptile\n\t[ALLIGATOR & CROCODILES]\n\t\talligators\n"
        let roots = StructuredKeywordParser.parseString(input)
        let reptile = roots[0]
        #expect(reptile.isKeyword)
        let bracket = reptile.children[0]
        #expect(bracket.isContainer)
        #expect(bracket.name == "ALLIGATOR & CROCODILES")
        #expect(bracket.children.map(\.name) == ["alligators"])
    }

    @Test("Container synonyms still attach to the container node")
    func containerSynonyms() {
        let input = "reptile\n\t[ALLIGATOR & CROCODILES]\n\t\t{Crocodilia}\n\t\talligators\n"
        let roots = StructuredKeywordParser.parseString(input)
        let bracket = roots[0].children[0]
        #expect(bracket.synonyms == ["Crocodilia"])
    }

    @Test("CRLF line endings work")
    func crlfLineEndings() {
        let input = "animals\r\n\tlivestock\r\n"
        let roots = StructuredKeywordParser.parseString(input)
        #expect(roots.first?.children.map(\.name) == ["livestock"])
    }

    @Test("BOM and NBSP are cleaned out")
    func bomAndNbsp() {
        let input = "\u{FEFF}animals\n\tlive\u{00A0}stock\n"
        let roots = StructuredKeywordParser.parseString(input)
        #expect(roots.first?.name == "animals")
        #expect(roots.first?.children.first?.name == "live stock")
    }

    @Test("Empty input produces an empty result")
    func emptyInput() {
        #expect(StructuredKeywordParser.parseString("").isEmpty)
    }

    @Test("Top-level orphan synonyms (with no owner above) are ignored")
    func orphanTopLevelSynonym() {
        let input = "{orphan}\nanimals\n"
        let roots = StructuredKeywordParser.parseString(input)
        #expect(roots.map(\.name) == ["animals"])
        #expect(roots[0].synonyms.isEmpty)
    }

    @Test("Top-level orphan related keywords (with no owner above) are ignored")
    func orphanTopLevelRelatedKeyword() {
        let input = "#orphan\nanimals\n"
        let roots = StructuredKeywordParser.parseString(input)
        #expect(roots.map(\.name) == ["animals"])
        #expect(roots[0].relatedKeywords.isEmpty)
    }

    @Test("Closing a deep branch returns to the right sibling level")
    func deepBranchClose() {
        let input = """
        animals
        \tlivestock
        \t\tcattle
        \t\t\tcow
        \tpets
        """
        let roots = StructuredKeywordParser.parseString(input)
        let animals = roots[0]
        #expect(animals.children.map(\.name) == ["livestock", "pets"])
    }

    @Test("Four-space indent is treated like one tab")
    func spaceIndentFallback() {
        let input = "animals\n    livestock\n        cattle\n"
        let roots = StructuredKeywordParser.parseString(input)
        let animals = roots[0]
        #expect(animals.children.map(\.name) == ["livestock"])
        #expect(animals.children[0].children.map(\.name) == ["cattle"])
    }
}

@Suite("StructuredKeywordService.expand")
struct StructuredKeywordExpandTests {

    @Test("Expand yields ancestors (keywords only) + node + synonyms in order")
    func expandFullPath() {
        let input = """
        animals
        \tlivestock
        \t\tcattle
        \t\t\tcow
        \t\t\t\t{cows}
        \t\t\t\t{kine}
        """
        let roots = StructuredKeywordParser.parseString(input)
        let animals = roots[0]
        let livestock = animals.children[0]
        let cattle = livestock.children[0]
        let cow = cattle.children[0]
        let path = StructuredKeywordPath(
            ancestors: [animals, livestock, cattle],
            node: cow
        )
        let expanded = StructuredKeywordService.shared.expand(path)
        #expect(expanded == ["animals", "livestock", "cattle", "cow", "cows", "kine"])
    }

    @Test("Container ancestors are excluded from the expansion")
    func expandSkipsContainerAncestors() {
        let input = """
        reptile
        \t[ALLIGATOR & CROCODILES]
        \t\talligators
        """
        let roots = StructuredKeywordParser.parseString(input)
        let reptile = roots[0]
        let bracket = reptile.children[0]
        let alligators = bracket.children[0]
        let path = StructuredKeywordPath(ancestors: [reptile, bracket], node: alligators)
        let expanded = StructuredKeywordService.shared.expand(path)
        #expect(expanded == ["reptile", "alligators"])
    }

    @Test("Activation carries related keywords separately from expanded values")
    func activationIncludesRelatedKeywords() {
        let input = """
        People
        \tAda Lovelace
        \t\t{Countess of Lovelace}
        \t\t#mathematician
        """
        let roots = StructuredKeywordParser.parseString(input)
        let people = roots[0]
        let ada = people.children[0]
        let path = StructuredKeywordPath(ancestors: [people], node: ada)
        let activation = StructuredKeywordService.personShown.activation(path)
        #expect(activation.values == ["Ada Lovelace", "Countess of Lovelace"])
        #expect(activation.relatedKeywords == ["mathematician"])
    }

    @Test("Container node itself yields no expansion")
    func expandContainerNodeIsEmpty() {
        let input = "reptile\n\t[CONTAINER]\n"
        let roots = StructuredKeywordParser.parseString(input)
        let reptile = roots[0]
        let bracket = reptile.children[0]
        let path = StructuredKeywordPath(ancestors: [reptile], node: bracket)
        let expanded = StructuredKeywordService.shared.expand(path)
        #expect(expanded == ["reptile"])
    }
}
