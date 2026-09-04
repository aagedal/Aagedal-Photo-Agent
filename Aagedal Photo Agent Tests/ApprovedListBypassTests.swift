import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("ApprovedListService source-based bypass")
struct ApprovedListBypassTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.aagedal.photo-agent.tests.approved-bypass.\(UUID().uuidString)")!
    }

    private func makeStrictService() async throws -> ApprovedListService {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bypass-\(UUID().uuidString).txt")
        try "Berlin\nMunich\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = ApprovedListService(
            defaults: makeDefaults(),
            startInitialLoad: false,
            observeChanges: false
        )
        try await service.importListURL(url, for: .keywords)
        service.setMode(.strict, for: .keywords)
        service.setEnabled(true, for: .keywords)
        return service
    }

    @Test("Bypass toggle defaults to true (matches pre-toggle behavior)")
    func defaultIsBypassOn() async throws {
        let service = try await makeStrictService()
        #expect(service.allowStructuredBypass(.keywords) == true)
    }

    @Test("With bypass ON, .structuredTree source accepts non-approved values even in Strict mode")
    func bypassAcceptsStructured() async throws {
        let service = try await makeStrictService()
        service.setAllowStructuredBypass(true, for: .keywords)

        let result = service.validateBulk(["Berlin", "Tokyo", "Munich"], in: .keywords, source: .structuredTree)
        #expect(result.accepted == ["Berlin", "Tokyo", "Munich"])
        #expect(result.rejected.isEmpty)
    }

    @Test("With bypass OFF, .structuredTree source is validated like any other source")
    func bypassOffValidates() async throws {
        let service = try await makeStrictService()
        service.setAllowStructuredBypass(false, for: .keywords)

        let result = service.validateBulk(["Berlin", "Tokyo", "Munich"], in: .keywords, source: .structuredTree)
        #expect(result.accepted == ["Berlin", "Munich"])
        #expect(result.rejected == ["Tokyo"])
    }

    @Test("Bypass toggle never affects .user / .quickList / .template sources")
    func bypassOnlyTouchesStructured() async throws {
        let service = try await makeStrictService()
        service.setAllowStructuredBypass(true, for: .keywords)

        for source in [KeywordSource.user, .quickList, .template] {
            let result = service.validateBulk(["Berlin", "Tokyo"], in: .keywords, source: source)
            #expect(result.accepted == ["Berlin"], "Source \(source) leaked through bypass")
            #expect(result.rejected == ["Tokyo"])
        }
    }
}
