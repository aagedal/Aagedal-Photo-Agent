import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// `ColorLabel` is the interop layer between our internal labels and the free-form
/// label strings other apps (Photo Mechanic, Bridge, Lightroom) write into XMP.
/// The parsing/normalization here is fiddly (case, whitespace, dashes, underscores,
/// and a table of aliases), so it's worth pinning down precisely.
@Suite("ColorLabel")
struct ColorLabelTests {

    // MARK: - Normalization

    @Test("Canonical names map regardless of case", arguments: [
        "Red", "RED", "red", "rEd", "  Red  "
    ])
    func canonicalNameCaseInsensitive(_ raw: String) {
        #expect(ColorLabel.fromMetadataLabel(raw) == .red)
    }

    @Test("Whitespace, dashes and underscores inside a label are collapsed", arguments: [
        "r e d", "r  e  d", "r-e-d", "r_e_d", " R - E _ D ", "RE D"
    ])
    func separatorsAreCollapsed(_ raw: String) {
        #expect(ColorLabel.fromMetadataLabel(raw) == .red)
    }

    @Test("A multi-word canonical label collapses to its alias")
    func multiWordCollapses() {
        // "To Do" -> "todo" -> .purple
        #expect(ColorLabel.fromMetadataLabel("To Do") == .purple)
        #expect(ColorLabel.fromMetadataLabel("to-do") == .purple)
        #expect(ColorLabel.fromMetadataLabel("TO_DO") == .purple)
    }

    // MARK: - Alias mapping

    @Test("Photo Mechanic style aliases map to colors", arguments: [
        ("Select", ColorLabel.red),
        ("Second", .yellow),
        ("Approved", .green),
        ("Review", .blue),
        ("To Do", .purple)
    ])
    func workflowAliases(_ pair: (String, ColorLabel)) {
        #expect(ColorLabel.fromMetadataLabel(pair.0) == pair.1)
    }

    @Test("Gray/grey variants are treated as Trash", arguments: [
        "gray", "grey", "darkgray", "darkgrey", "Dark Gray", "Trash"
    ])
    func grayMapsToTrash(_ raw: String) {
        #expect(ColorLabel.fromMetadataLabel(raw) == .trash)
    }

    @Test("Cyan synonyms map to cyan", arguments: ["cyan", "aqua", "teal", "Teal"])
    func cyanSynonyms(_ raw: String) {
        #expect(ColorLabel.fromMetadataLabel(raw) == .cyan)
    }

    @Test("Orange and white-ish labels resolve to none (no matching swatch)", arguments: [
        "orange", "white", "No Label", "none"
    ])
    func unmatchedSwatchesAreNone(_ raw: String) {
        #expect(ColorLabel.fromMetadataLabel(raw) == .none)
    }

    @Test("Unknown labels resolve to none for display")
    func unknownLabelIsNone() {
        #expect(ColorLabel.fromMetadataLabel("Maglubiyet") == .none)
        #expect(ColorLabel.fromMetadataLabel("") == .none)
        #expect(ColorLabel.fromMetadataLabel(nil) == .none)
    }

    // MARK: - Canonical metadata label (write path)

    @Test("Known labels normalize to the canonical XMP value we write")
    func canonicalReturnsXMPValue() {
        #expect(ColorLabel.canonicalMetadataLabel("red") == "Select")
        #expect(ColorLabel.canonicalMetadataLabel("APPROVED") == "Approved")
        #expect(ColorLabel.canonicalMetadataLabel(" review ") == "Review")
        #expect(ColorLabel.canonicalMetadataLabel("to do") == "To Do")
    }

    @Test("Unknown labels are preserved verbatim (trimmed), not discarded")
    func canonicalPreservesUnknown() {
        // A third-party custom label we don't recognize must survive a read/write
        // round-trip rather than being silently dropped.
        #expect(ColorLabel.canonicalMetadataLabel("  Custom Label  ") == "Custom Label")
        #expect(ColorLabel.canonicalMetadataLabel("Maglubiyet") == "Maglubiyet")
    }

    @Test("Empty or nil input yields nil canonical label")
    func canonicalEmptyIsNil() {
        #expect(ColorLabel.canonicalMetadataLabel(nil) == nil)
        #expect(ColorLabel.canonicalMetadataLabel("") == nil)
        #expect(ColorLabel.canonicalMetadataLabel("   ") == nil)
    }

    // MARK: - xmpLabelValue round-trip

    @Test("Every non-none label round-trips through its XMP value")
    func xmpRoundTrip() {
        for label in ColorLabel.allCases where label != .none {
            let xmp = label.xmpLabelValue
            #expect(xmp != nil, "\(label) should have an XMP value")
            if let xmp {
                #expect(ColorLabel.fromMetadataLabel(xmp) == label,
                        "\(label) -> \(xmp) -> should map back to \(label)")
            }
        }
    }

    @Test("none has no XMP value")
    func noneHasNoXMP() {
        #expect(ColorLabel.none.xmpLabelValue == nil)
    }

    // MARK: - Shortcut index

    @Test("Shortcut indices are unique and cover 0...8")
    func shortcutIndicesUnique() {
        let indices = ColorLabel.allCases.map { $0.shortcutIndex }
        #expect(indices.allSatisfy { $0 != nil })
        let unwrapped = indices.compactMap { $0 }.sorted()
        #expect(unwrapped == Array(0...8))
    }

    @Test("fromShortcutIndex inverts shortcutIndex")
    func shortcutIndexRoundTrip() {
        for label in ColorLabel.allCases {
            guard let index = label.shortcutIndex else {
                Issue.record("\(label) is missing a shortcut index")
                continue
            }
            #expect(ColorLabel.fromShortcutIndex(index) == label)
        }
    }

    @Test("Out-of-range shortcut indices return nil", arguments: [-1, 9, 100])
    func shortcutIndexOutOfRange(_ index: Int) {
        #expect(ColorLabel.fromShortcutIndex(index) == nil)
    }

    // MARK: - Display name & Codable

    @Test("displayName is 'None' for none, raw value otherwise")
    func displayName() {
        #expect(ColorLabel.none.displayName == "None")
        #expect(ColorLabel.red.displayName == "Red")
        #expect(ColorLabel.trash.displayName == "Trash")
    }

    @Test("Only none has a nil color swatch")
    func colorPresence() {
        for label in ColorLabel.allCases {
            if label == .none {
                #expect(label.color == nil)
                #expect(label.nsColor == nil)
            } else {
                #expect(label.color != nil)
                #expect(label.nsColor != nil)
            }
        }
    }

    @Test("Codable round-trips through the raw value")
    func codableRoundTrip() throws {
        for label in ColorLabel.allCases {
            let data = try JSONEncoder().encode(label)
            let decoded = try JSONDecoder().decode(ColorLabel.self, from: data)
            #expect(decoded == label)
        }
    }
}
