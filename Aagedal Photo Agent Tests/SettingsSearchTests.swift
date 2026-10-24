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

    @Test("Visible control and format names are searchable")
    func visibleTerms() {
        #expect(Section.format.matches("HEIC"))
        #expect(Section.format.matches("AVIF"))
        #expect(Section.format.matches("Gain Map"))
        #expect(Section.format.matchingTerms(for: "XL") == ["JPEG XL"])
        #expect(Section.webDownloads.matches("gallery-dl"))
        #expect(Section.webDownloads.matches("Instagram"))
        #expect(Section.watermarks.matches("text watermark"))
        #expect(Section.watermarks.matches("Margin"))
        #expect(Section.watermarks.matches("Placement"))
        #expect(Section.templates.matches("templates folder"))
        #expect(Section.templates.matches("Storage"))
        #expect(Section.descriptionModels.matches("remove downloaded model"))
    }

    @Test("Search does not promise controls that don't exist")
    func noPhantomTerms() {
        #expect(!Section.watermarks.matches("Opacity"))
        #expect(!Section.watermarks.matches("Position"))
        #expect(!Section.webDownloads.matches("FFmpeg"))
        #expect(!Section.descriptionModels.matches("Model storage"))
        #expect(!Section.format.matches("HEIF"))
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
