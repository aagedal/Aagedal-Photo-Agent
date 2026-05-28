import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("StructuredKeywordSerializer round-trip")
struct StructuredKeywordSerializerTests {

    @Test("Plain top-level keywords serialise back to one line each")
    func topLevel() {
        let tree = [
            StructuredKeyword(name: "animals", kind: .keyword),
            StructuredKeyword(name: "places", kind: .keyword),
        ]
        let text = StructuredKeywordSerializer.serialize(tree)
        #expect(text == "animals\nplaces\n")
    }

    @Test("Children render with one extra tab of indent per depth")
    func indentChildren() {
        let cattle = StructuredKeyword(name: "cattle", kind: .keyword)
        let livestock = StructuredKeyword(name: "livestock", kind: .keyword, children: [cattle])
        let animals = StructuredKeyword(name: "animals", kind: .keyword, children: [livestock])
        let text = StructuredKeywordSerializer.serialize([animals])
        #expect(text == "animals\n\tlivestock\n\t\tcattle\n")
    }

    @Test("Synonyms render under their parent indented one more level than the parent")
    func synonyms() {
        let animals = StructuredKeyword(name: "animals", kind: .keyword, synonyms: ["animal", "beast"])
        let text = StructuredKeywordSerializer.serialize([animals])
        #expect(text == "animals\n\t{animal}\n\t{beast}\n")
    }

    @Test("Container nodes render with [brackets]")
    func containers() {
        let bracket = StructuredKeyword(name: "ALLIGATOR & CROCODILES", kind: .container)
        let reptile = StructuredKeyword(name: "reptile", kind: .keyword, children: [bracket])
        let text = StructuredKeywordSerializer.serialize([reptile])
        #expect(text == "reptile\n\t[ALLIGATOR & CROCODILES]\n")
    }

    @Test("Parse → serialize → parse preserves the full tree")
    func roundTrip() {
        let input = """
        animals
        \t{animal}
        \tlivestock
        \t\tcattle
        \t\t\t{cows}
        \t[REPTILE]
        \t\talligators
        places
        \tcity
        """
        let parsedOnce = StructuredKeywordParser.parseString(input)
        let serialised = StructuredKeywordSerializer.serialize(parsedOnce)
        let parsedTwice = StructuredKeywordParser.parseString(serialised)

        // Compare structurally (ids differ).
        func describe(_ nodes: [StructuredKeyword]) -> String {
            var out = ""
            func walk(_ node: StructuredKeyword, depth: Int) {
                let pad = String(repeating: "  ", count: depth)
                let kind = node.isContainer ? "[CONT]" : "[KW]"
                out += "\(pad)\(kind) \(node.name) syn=\(node.synonyms.joined(separator: ","))\n"
                for child in node.children { walk(child, depth: depth + 1) }
            }
            for root in nodes { walk(root, depth: 0) }
            return out
        }
        #expect(describe(parsedOnce) == describe(parsedTwice))
    }
}
