import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Settings search")
struct SettingsSearchTests {
    private typealias Section = SettingsView.SettingsSection

    @Test("Empty and whitespace queries restore every category")
    func emptySearch() {
        for section in Section.allCases {
            #expect(section.matches(""))
            #expect(section.matches(" \n\t "))
            #expect(section.matchingTerms(for: " ").isEmpty)
        }
    }

    @Test("Search finds control labels and aliases beyond category titles")
    func controlLabels() {
        #expect(Section.metadata.matches("place-name language"))
        #expect(Section.general.matches("thumbnails"))
        #expect(Section.transcription.matches("whisper"))
        #expect(Section.signing.matches("certificate"))
        #expect(Section.automation.matches("MCP"))
        #expect(Section.keywordLists.matches("IPTC Media Topics"))
        #expect(Section.developControls.matches("halation"))
        #expect(Section.metadata.matches("minimum length"))
        #expect(!Section.general.matches("certificate"))
    }

    @Test("Search ignores case, accents, repeated whitespace and word order")
    func normalizedSearch() {
        #expect(Section.rawDecoding.matches("  hdr RAW \n"))
        #expect(Section.templates.matches("témplates"))
        #expect(Section.metadata.matches("LANGUAGE place-name"))
        #expect(!Section.rawDecoding.matches("HDR certificate"))
    }

    @Test("Results explain matched controls without hints for a title-only match")
    func matchHints() {
        #expect(Section.metadata.matchingTerms(for: "place-name") == ["Place-name language"])
        #expect(Section.general.matchingTerms(for: "thumbnails").contains("Always show original thumbnails"))
        #expect(Section.metadata.matchingTerms(for: "metadata").isEmpty)
    }

    @Test("Selection stays on a matching category and moves away from hidden ones")
    func selection() {
        #expect(Section.searchSelection(current: .general, query: "whisper") == .transcription)
        #expect(Section.searchSelection(current: .format, query: "HDR") == .format)
        #expect(Section.searchSelection(current: .format, query: " ") == .format)
        #expect(Section.searchSelection(current: .general, query: "no-such-setting") == nil)
        #expect(Section.searchSelection(current: nil, query: "") == .general)
    }
}
