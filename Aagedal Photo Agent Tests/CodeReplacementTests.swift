import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Code replacement parser and engine")
struct CodeReplacementTests {
    private let parser = CodeReplacementParser()
    private let engine = CodeReplacementEngine()

    @Test("UTF-8 tab lists accept BOM, Unicode, CRLF, LF, and CR")
    func parsesPhotoMechanicTabList() {
        let source = CodeReplacementSourceReference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Newsroom codes"
        )
        let data = Data("\u{FEFF}oslo\tOslo, Norge\r\nname\tSølve 😄\n東京\t東京都\rslug\tfinal".utf8)

        let list = parser.parse(data, source: source)

        #expect(list.source == source)
        #expect(list.entries.map(\.code) == ["oslo", "name", "東京", "slug"])
        #expect(list.entries.map(\.replacement) == ["Oslo, Norge", "Sølve 😄", "東京都", "final"])
        #expect(list.entries.map(\.sourceLine) == [1, 2, 3, 4])
        #expect(list.diagnostics.isEmpty)
    }

    @Test("Malformed rows and empty columns are diagnosed while valid rows remain usable")
    func malformedRows() {
        let list = parser.parse(Data("good\tValue\nno-tab\ntoo\tmany\ttabs\n\tMissing code\nempty\t\n \tWhitespace code".utf8))

        #expect(list.entries == [CodeReplacementEntry(code: "good", replacement: "Value", sourceLine: 1)])
        #expect(list.diagnostics == [
            CodeReplacementDiagnostic(severity: .error, kind: .malformedRow(columnCount: 1), line: 2),
            CodeReplacementDiagnostic(severity: .error, kind: .malformedRow(columnCount: 3), line: 3),
            CodeReplacementDiagnostic(severity: .error, kind: .emptyCode, line: 4),
            CodeReplacementDiagnostic(severity: .error, kind: .emptyValue(code: "empty"), line: 5),
            CodeReplacementDiagnostic(severity: .error, kind: .emptyCode, line: 6),
        ])

        let preview = engine.preview(
            text: "\\good\\ and \\no-tab\\",
            list: list,
            configuration: CodeReplacementConfiguration()
        )
        #expect(preview.proposedText == "Value and \\no-tab\\")
        #expect(preview.sourceDiagnostics == list.diagnostics)
    }

    @Test("Invalid UTF-8 is explicit and blocks all expansion")
    func invalidUTF8() {
        let list = parser.parse(Data([0x66, 0x6f, 0x80, 0x6f]))
        #expect(list.entries.isEmpty)
        #expect(list.diagnostics == [CodeReplacementDiagnostic(
            severity: .error,
            kind: .invalidUTF8,
            line: nil
        )])

        let preview = engine.preview(
            text: "\\code\\",
            list: list,
            configuration: CodeReplacementConfiguration()
        )
        #expect(preview.disposition == .invalidSourceEncoding)
        #expect(preview.proposedText == "\\code\\")
    }

    @Test("Same-value duplicates warn; conflicting duplicates quarantine the code")
    func duplicateAndAmbiguousCodes() {
        let list = parser.parse(Data("same\tOne\nsame\tOne\nconflict\tFirst\nconflict\tSecond\nok\tSafe".utf8))

        #expect(list.entries.map(\.code) == ["same", "ok"])
        #expect(list.ambiguousCodes == ["conflict": [3, 4]])
        #expect(list.diagnostics == [
            CodeReplacementDiagnostic(
                severity: .warning,
                kind: .duplicateCode(code: "same", originalLine: 1),
                line: 2
            ),
            CodeReplacementDiagnostic(
                severity: .error,
                kind: .ambiguousCode(code: "conflict", originalLine: 3),
                line: 4
            ),
        ])

        let preview = engine.preview(
            text: "\\same\\ / \\conflict\\ / \\ok\\",
            list: list,
            configuration: CodeReplacementConfiguration()
        )
        #expect(preview.proposedText == "One / \\conflict\\ / Safe")
        #expect(preview.replacements.map(\.code) == ["same", "ok"])
        #expect(preview.unresolvedOccurrences == [CodeReplacementUnresolvedOccurrence(
            code: "conflict",
            sourceRange: 9..<19,
            reason: .ambiguousCode
        )])
    }

    @Test("Exact longest tokens expand deterministically and unmatched text is preserved")
    func exactLongestAndMultipleOccurrences() {
        let list = parser.parse(Data("a\tA\nalpha\tLONG\nÅ\tNordic".utf8))
        let input = "\\alpha\\, \\a\\, \\alpha\\; \\unknown\\; \\Å\\"

        let preview = engine.preview(
            text: input,
            list: list,
            configuration: CodeReplacementConfiguration()
        )

        #expect(preview.disposition == .applied)
        #expect(preview.proposedText == "LONG, A, LONG; \\unknown\\; Nordic")
        #expect(preview.replacements.map(\.code) == ["alpha", "a", "alpha", "Å"])
        #expect(preview.replacements.map(\.sourceRange) == [0..<7, 9..<12, 14..<21, 34..<37])
        #expect(preview.unresolvedOccurrences.isEmpty)
    }

    @Test("Codes are case-sensitive exact matches")
    func caseSensitive() {
        let list = parser.parse(Data("abc\tExpanded".utf8))
        let preview = engine.preview(
            text: "\\abc\\ \\ABC\\ abc",
            list: list,
            configuration: CodeReplacementConfiguration()
        )

        #expect(preview.proposedText == "Expanded \\ABC\\ abc")
        #expect(preview.replacements.count == 1)
    }

    @Test("Codes containing a configured delimiter are preserved as one unresolved token")
    func codeContainingDelimiter() {
        let list = parser.parse(Data("a\\b\tUnsafe\nb\tWrong partial expansion".utf8))
        let preview = engine.preview(
            text: "\\a\\b\\",
            list: list,
            configuration: CodeReplacementConfiguration()
        )

        #expect(preview.proposedText == "\\a\\b\\")
        #expect(preview.replacements.isEmpty)
        #expect(preview.unresolvedOccurrences == [CodeReplacementUnresolvedOccurrence(
            code: "a\\b",
            sourceRange: 0..<5,
            reason: .codeContainsDelimiter
        )])
    }

    @Test("Doubled default delimiters are literal and adjacent exact tokens still expand")
    func escapedDefaultDelimiter() {
        let list = parser.parse(Data("a\tOne\nb\tTwo".utf8))
        let preview = engine.preview(
            text: "\\\\a\\\\ then \\a\\\\b\\",
            list: list,
            configuration: CodeReplacementConfiguration()
        )

        #expect(preview.proposedText == "\\a\\ then OneTwo")
        #expect(preview.replacements.map(\.code) == ["a", "b"])
    }

    @Test("Custom multi-character delimiters and literal delimiter escapes are supported")
    func customDelimiters() {
        let list = parser.parse(Data("who\tJane Doe".utf8))
        let configuration = CodeReplacementConfiguration(
            startDelimiter: "[[",
            endDelimiter: "]]"
        )
        let preview = engine.preview(
            text: "By [[who]]. Literal: [[[[who]]]] and ]]]]",
            list: list,
            configuration: configuration
        )

        #expect(preview.proposedText == "By Jane Doe. Literal: [[who]] and ]]")
        #expect(preview.replacements == [CodeReplacementOccurrence(
            code: "who",
            replacement: "Jane Doe",
            sourceRange: 3..<10
        )])
    }

    @Test("Disabled state is a no-op")
    func disabled() {
        let list = parser.parse(Data("code\tExpanded".utf8))
        let preview = engine.preview(
            text: "\\code\\",
            list: list,
            configuration: CodeReplacementConfiguration(isEnabled: false)
        )

        #expect(preview.disposition == .disabled)
        #expect(preview.proposedText == "\\code\\")
        #expect(preview.replacements.isEmpty)
    }

    @Test("The caller can refuse replacement during active IME composition")
    func activeIMEComposition() {
        let list = parser.parse(Data("name\t山田太郎".utf8))
        let preview = engine.preview(
            text: "入力 \\name\\",
            list: list,
            configuration: CodeReplacementConfiguration(),
            compositionState: .active
        )

        #expect(preview.disposition == .refusedActiveComposition)
        #expect(preview.proposedText == "入力 \\name\\")
        #expect(preview.replacements.isEmpty)
    }

    @Test("Empty delimiters are invalid instead of matching every position")
    func invalidDelimiterConfiguration() {
        let list = parser.parse(Data("a\tA".utf8))
        let preview = engine.preview(
            text: "a",
            list: list,
            configuration: CodeReplacementConfiguration(startDelimiter: "", endDelimiter: "]")
        )

        #expect(preview.disposition == .invalidConfiguration)
        #expect(preview.proposedText == "a")
    }

    @Test("Versioned configuration round-trips only source and bookmark metadata")
    func configurationPersistence() throws {
        let sourceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let bookmarkID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let configuration = CodeReplacementConfiguration(
            isEnabled: true,
            startDelimiter: "{",
            endDelimiter: "}",
            source: CodeReplacementSourceReference(
                id: sourceID,
                displayName: "wire codes.txt",
                path: "/Newsroom/Lists/wire-codes.txt",
                bookmark: CodeReplacementBookmarkReference(
                    id: bookmarkID,
                    createdAt: Date(timeIntervalSince1970: 100),
                    lastResolvedAt: Date(timeIntervalSince1970: 200),
                    wasStaleWhenLastResolved: true
                ),
                fingerprint: CodeReplacementSourceFingerprint(
                    byteCount: 42,
                    modificationDate: Date(timeIntervalSince1970: 300)
                )
            )
        )

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(CodeReplacementConfiguration.self, from: data)
        let json = String(decoding: data, as: UTF8.self)

        #expect(decoded == configuration)
        #expect(json.contains("bookmarkData") == false)
        #expect(json.contains("securityScope") == false)
        #expect(json.contains("replacement") == false)
    }

    @MainActor
    @Test("future configuration remains disabled and its settings and bookmark bytes are untouched")
    func futureConfigurationIsReadOnly() throws {
        let suiteName = "CodeReplacementFutureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationKey = "configuration"
        let bookmarkKey = "bookmark"
        let futureData = Data(
            #"{"schemaVersion":99,"isEnabled":true,"future":{"keep":true}}"#.utf8
        )
        let bookmarkData = Data([0x01, 0x02, 0x03])
        defaults.set(futureData, forKey: configurationKey)
        defaults.set(bookmarkData, forKey: bookmarkKey)

        let store = CodeReplacementSettingsStore(
            defaults: defaults,
            configurationKey: configurationKey,
            bookmarkKey: bookmarkKey
        )

        #expect(store.configuration.isEnabled == false)
        #expect(store.isConfigurationReadOnly)
        #expect(store.configurationLoadError == .newerSchema(
            found: 99,
            supported: CodeReplacementConfiguration.currentSchemaVersion
        ))
        store.setEnabled(true)
        store.setStartDelimiter("[[")
        store.removeSource()
        #expect(throws: CodeReplacementSettingsStoreError.newerSchema(
            found: 99,
            supported: CodeReplacementConfiguration.currentSchemaVersion
        )) {
            try store.selectSource(URL(fileURLWithPath: "/tmp/codes.txt"))
        }
        #expect(defaults.data(forKey: configurationKey) == futureData)
        #expect(defaults.data(forKey: bookmarkKey) == bookmarkData)
    }

    @MainActor
    @Test("unreadable configuration remains disabled and cannot overwrite its bytes")
    func unreadableConfigurationIsReadOnly() throws {
        let suiteName = "CodeReplacementUnreadableTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationKey = "configuration"
        let unreadableData = Data(#"{"schemaVersion":"future"}"#.utf8)
        defaults.set(unreadableData, forKey: configurationKey)

        let store = CodeReplacementSettingsStore(
            defaults: defaults,
            configurationKey: configurationKey,
            bookmarkKey: "bookmark"
        )

        #expect(store.configuration.isEnabled == false)
        #expect(store.configurationLoadError == .unreadableConfiguration)
        #expect(store.isConfigurationReadOnly)
        store.setEndDelimiter("]]")
        #expect(defaults.data(forKey: configurationKey) == unreadableData)
    }
}
