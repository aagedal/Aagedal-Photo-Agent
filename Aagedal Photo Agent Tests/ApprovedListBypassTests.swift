import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("ApprovedListService source-based bypass")
struct ApprovedListBypassTests {

    private func clear() {
        let field = ApprovedListField.keywords
        UserDefaults.standard.removeObject(forKey: field.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: field.enabledKey)
        UserDefaults.standard.removeObject(forKey: field.modeKey)
        UserDefaults.standard.removeObject(forKey: field.allowStructuredBypassKey)
        KeywordListsStore.shared.delete(.approved(field))
    }

    private func makeStrictService() throws -> ApprovedListService {
        clear()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bypass-\(UUID().uuidString).txt")
        try "Berlin\nMunich\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = ApprovedListService()
        try service.importListURL(url, for: .keywords)
        service.setMode(.strict, for: .keywords)
        service.setEnabled(true, for: .keywords)
        return service
    }

    @Test("Bypass toggle defaults to true (matches pre-toggle behavior)")
    func defaultIsBypassOn() throws {
        let service = try makeStrictService()
        #expect(service.allowStructuredBypass(.keywords) == true)
    }

    @Test("With bypass ON, .structuredTree source accepts non-approved values even in Strict mode")
    func bypassAcceptsStructured() throws {
        let service = try makeStrictService()
        service.setAllowStructuredBypass(true, for: .keywords)

        let result = service.validateBulk(["Berlin", "Tokyo", "Munich"], in: .keywords, source: .structuredTree)
        #expect(result.accepted == ["Berlin", "Tokyo", "Munich"])
        #expect(result.rejected.isEmpty)
    }

    @Test("With bypass OFF, .structuredTree source is validated like any other source")
    func bypassOffValidates() throws {
        let service = try makeStrictService()
        service.setAllowStructuredBypass(false, for: .keywords)

        let result = service.validateBulk(["Berlin", "Tokyo", "Munich"], in: .keywords, source: .structuredTree)
        #expect(result.accepted == ["Berlin", "Munich"])
        #expect(result.rejected == ["Tokyo"])
    }

    @Test("Bypass toggle never affects .user / .quickList / .template sources")
    func bypassOnlyTouchesStructured() throws {
        let service = try makeStrictService()
        service.setAllowStructuredBypass(true, for: .keywords)

        for source in [KeywordSource.user, .quickList, .template] {
            let result = service.validateBulk(["Berlin", "Tokyo"], in: .keywords, source: source)
            #expect(result.accepted == ["Berlin"], "Source \(source) leaked through bypass")
            #expect(result.rejected == ["Tokyo"])
        }
    }
}
