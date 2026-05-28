import Testing
import Foundation
@testable import Aagedal_Photo_Agent

// MARK: - Parser

@Suite("ApprovedListParser")
struct ApprovedListParserTests {

    @Test("Simple TXT, one keyword per line")
    func simpleTxt() {
        let input = "Berlin\nParis\nLondon\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("CRLF line endings are handled")
    func crlfLineEndings() {
        let input = "Berlin\r\nParis\r\nLondon\r\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("Empty lines and # comments are skipped")
    func emptyAndComments() {
        let input = "# Cities of Europe\nBerlin\n\nParis\n  # mid-file comment\nLondon\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("Duplicates preserve first occurrence")
    func duplicatesFirstWins() {
        let input = "Berlin\nBerlin\nberlin\nParis\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        // The parser dedupes by exact string. NFC/case folding is the service's job, not the parser's.
        #expect(result == ["Berlin", "berlin", "Paris"])
    }

    @Test("CSV takes first column only, ignoring extra columns")
    func csvFirstColumn() {
        let input = "Berlin,DE,1\nParis,FR,2\nLondon,UK,3\n"
        let result = ApprovedListParser.parseString(input, csv: true)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("CSV strips surrounding double quotes on first column")
    func csvStripsQuotes() {
        let input = "\"Berlin\",DE\n\"Saint-Tropez\",FR\nLondon,UK\n"
        let result = ApprovedListParser.parseString(input, csv: true)
        #expect(result == ["Berlin", "Saint-Tropez", "London"])
    }

    @Test("BOM and NBSP are cleaned out")
    func bomAndNbsp() {
        let input = "\u{FEFF}Berlin\nParis\u{00A0}Mitte\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris Mitte"])
    }

    @Test("Empty file produces empty result")
    func emptyFile() {
        let result = ApprovedListParser.parseString("", csv: false)
        #expect(result.isEmpty)
    }

    @Test("Whitespace-only lines are skipped")
    func whitespaceOnlyLines() {
        let input = "Berlin\n   \n\t\nParis\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris"])
    }
}

// MARK: - Service suggestions/matching

@Suite("ApprovedListService.suggestions (static)")
struct ApprovedListSuggestionTests {

    private let cities = ["Berlin", "Bergen", "Paris", "London", "Saint-Petersburg", "Heidelberg"]

    @Test("Empty prefix returns no suggestions")
    func emptyPrefix() {
        let result = ApprovedListService.suggestions(prefix: "", in: cities)
        #expect(result.isEmpty)
    }

    @Test("Prefix matches come before substring matches")
    func prefixBeforeSubstring() {
        let result = ApprovedListService.suggestions(prefix: "ber", in: cities)
        // Berlin and Bergen are prefix matches; Heidelberg is a substring match.
        let canonicals = result.map(\.canonical)
        #expect(canonicals.firstIndex(of: "Berlin")! < canonicals.firstIndex(of: "Heidelberg")!)
        #expect(canonicals.firstIndex(of: "Bergen")! < canonicals.firstIndex(of: "Heidelberg")!)
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let result = ApprovedListService.suggestions(prefix: "PARIS", in: cities)
        #expect(result.first?.canonical == "Paris")
    }

    @Test("Limit is respected")
    func limitRespected() {
        let many = (0..<100).map { "Item \($0)" }
        let result = ApprovedListService.suggestions(prefix: "Item", in: many, limit: 5)
        #expect(result.count == 5)
    }

    @Test("Match kind correctly labels prefix vs substring")
    func matchKindLabels() {
        let result = ApprovedListService.suggestions(prefix: "berg", in: cities)
        let bergen = result.first(where: { $0.canonical == "Bergen" })
        let heidelberg = result.first(where: { $0.canonical == "Heidelberg" })
        #expect(bergen?.matchKind == .prefix)
        #expect(heidelberg?.matchKind == .substring)
    }
}

// MARK: - Service end-to-end

@Suite("ApprovedListService end-to-end")
struct ApprovedListServiceTests {

    private func tempCSV(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approved-test-\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func clearDefaults() {
        let field = ApprovedListField.keywords
        UserDefaults.standard.removeObject(forKey: field.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: field.enabledKey)
        UserDefaults.standard.removeObject(forKey: field.modeKey)
        UserDefaults.standard.removeObject(forKey: field.allowStructuredBypassKey)
        KeywordListsStore.shared.delete(.approved(field))
    }

    @Test("contains uses NFC + case-insensitive normalization")
    func containsCaseAndUnicode() throws {
        clearDefaults()
        let url = try tempCSV("Berlin,DE\nMünchen,DE\nParis,FR\n")
        let service = ApprovedListService()
        try service.importListURL(url, for: .keywords)

        #expect(service.contains("berlin", in: .keywords))
        #expect(service.contains("BERLIN", in: .keywords))
        #expect(service.contains("München", in: .keywords))
        // NFD-decomposed Munchen should still match NFC-normalized "München".
        let nfd = "Mu\u{0308}nchen"
        #expect(service.contains(nfd, in: .keywords))
        #expect(!service.contains("Tokyo", in: .keywords))

        try? FileManager.default.removeItem(at: url)
    }

    @Test("canonicalCasing returns file-original casing")
    func canonicalCasing() throws {
        clearDefaults()
        let url = try tempCSV("Berlin\nParis\nNew York\n")
        let service = ApprovedListService()
        try service.importListURL(url, for: .keywords)

        #expect(service.canonicalCasing(of: "berlin", in: .keywords) == "Berlin")
        #expect(service.canonicalCasing(of: "NEW YORK", in: .keywords) == "New York")
        #expect(service.canonicalCasing(of: "tokyo", in: .keywords) == nil)

        try? FileManager.default.removeItem(at: url)
    }

    @Test("isActive requires both enabled toggle and a populated list")
    func isActiveContract() throws {
        clearDefaults()
        let url = try tempCSV("Berlin\nParis\n")
        let service = ApprovedListService()
        try service.importListURL(url, for: .keywords)

        #expect(service.hasListConfigured(for: .keywords))
        #expect(!service.isActive(for: .keywords))

        service.setEnabled(true, for: .keywords)
        #expect(service.isActive(for: .keywords))

        service.clearList(for: .keywords)
        #expect(!service.isActive(for: .keywords))

        try? FileManager.default.removeItem(at: url)
    }

    @Test("mode defaults to .warn when unset")
    func modeDefaultsToWarn() {
        clearDefaults()
        let service = ApprovedListService()
        #expect(service.mode(for: .keywords) == .warn)
    }

    @Test("entryCount reflects parsed list size")
    func entryCount() throws {
        clearDefaults()
        let url = try tempCSV("Berlin\nParis\nLondon\n")
        let service = ApprovedListService()
        try service.importListURL(url, for: .keywords)
        #expect(service.entryCount(for: .keywords) == 3)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Service validation surface

@Suite("ApprovedListService.validate / validateBulk")
struct ApprovedListValidationTests {

    private func tempList(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approved-validate-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func clearDefaults() {
        let field = ApprovedListField.keywords
        UserDefaults.standard.removeObject(forKey: field.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: field.enabledKey)
        UserDefaults.standard.removeObject(forKey: field.modeKey)
        UserDefaults.standard.removeObject(forKey: field.allowStructuredBypassKey)
        KeywordListsStore.shared.delete(.approved(field))
    }

    private func makeService(mode: ApprovedListMode, enabled: Bool = true) throws -> (ApprovedListService, URL) {
        clearDefaults()
        let url = try tempList("Berlin\nMunich\nParis\n")
        let service = ApprovedListService()
        try service.importListURL(url, for: .keywords)
        service.setMode(mode, for: .keywords)
        service.setEnabled(enabled, for: .keywords)
        return (service, url)
    }

    @Test("validate returns .accept when list is inactive (no enforcement)")
    func validateInactive() throws {
        let (service, url) = try makeService(mode: .strict, enabled: false)
        defer { try? FileManager.default.removeItem(at: url) }

        if case .accept = service.validate("anything", in: .keywords) {} else {
            Issue.record("Expected .accept when list is disabled")
        }
    }

    @Test("validate canonicalises approved values regardless of mode")
    func validateCanonicalAllModes() throws {
        for mode in [ApprovedListMode.suggest, .warn, .strict] {
            let (service, url) = try makeService(mode: mode)
            defer { try? FileManager.default.removeItem(at: url) }
            if case .acceptCanonical(let canonical) = service.validate("berlin", in: .keywords) {
                #expect(canonical == "Berlin")
            } else {
                Issue.record("Expected .acceptCanonical(\"Berlin\") in mode \(mode)")
            }
        }
    }

    @Test("validate accepts non-approved values in Suggest and Warn modes")
    func validateNonApprovedSuggestWarn() throws {
        for mode in [ApprovedListMode.suggest, .warn] {
            let (service, url) = try makeService(mode: mode)
            defer { try? FileManager.default.removeItem(at: url) }
            if case .accept = service.validate("Tokyo", in: .keywords) {} else {
                Issue.record("Expected .accept for non-approved in mode \(mode)")
            }
        }
    }

    @Test("validate rejects non-approved values in Strict mode")
    func validateNonApprovedStrict() throws {
        let (service, url) = try makeService(mode: .strict)
        defer { try? FileManager.default.removeItem(at: url) }
        if case .reject = service.validate("Tokyo", in: .keywords) {} else {
            Issue.record("Expected .reject for non-approved in Strict mode")
        }
    }

    @Test("validateBulk canonicalises accepted entries and preserves input order")
    func validateBulkCanonicalAndOrder() throws {
        let (service, url) = try makeService(mode: .warn)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["paris", "BERLIN", "Munich"], in: .keywords)
        #expect(result.accepted == ["Paris", "Berlin", "Munich"])
        #expect(result.rejected.isEmpty)
    }

    @Test("validateBulk dedupes case-insensitively across accepted entries")
    func validateBulkDedupe() throws {
        let (service, url) = try makeService(mode: .warn)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["berlin", "BERLIN", "Berlin"], in: .keywords)
        #expect(result.accepted == ["Berlin"])
        #expect(result.rejected.isEmpty)
    }

    @Test("validateBulk splits accepted vs rejected in Strict mode, preserves input casing of rejects")
    func validateBulkStrictSplit() throws {
        let (service, url) = try makeService(mode: .strict)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["berlin", "Belin", "munich", "tokyo"], in: .keywords)
        #expect(result.accepted == ["Berlin", "Munich"])
        #expect(result.rejected == ["Belin", "tokyo"])
    }

    @Test("validateBulk in Warn mode accepts non-approved without canonicalising")
    func validateBulkWarnPassthrough() throws {
        let (service, url) = try makeService(mode: .warn)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["berlin", "Belin"], in: .keywords)
        // "berlin" canonicalises to "Berlin"; "Belin" is non-approved but accepted in Warn.
        #expect(result.accepted == ["Berlin", "Belin"])
        #expect(result.rejected.isEmpty)
    }

    @Test("validateBulk on inactive list accepts everything verbatim")
    func validateBulkInactive() throws {
        let (service, url) = try makeService(mode: .strict, enabled: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["foo", "Bar", "baz"], in: .keywords)
        #expect(result.accepted == ["foo", "Bar", "baz"])
        #expect(result.rejected.isEmpty)
    }
}
