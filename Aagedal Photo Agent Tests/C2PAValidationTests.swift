import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("C2PA validation result mapping")
struct C2PAValidationTests {
    @Test("trusted c2patool status maps to trusted")
    func trusted() throws {
        let result = try parse("""
        {"validation_state":"Valid","validation_status":[
          {"code":"signingCredential.trusted","success":true,"explanation":"Trusted chain"}
        ]}
        """)
        #expect(result.status == .trusted)
    }

    @Test("built-in test signer is valid but untrusted")
    func builtInTestSignerIsUntrusted() throws {
        let result = try parse("""
        {"validation_state":"Valid","validation_status":[
          {"code":"signingCredential.untrusted","success":true}
        ]}
        """)
        #expect(result.status == .untrusted)
        #expect(result.message.contains("valid"))
    }

    @Test("failed validation status maps to invalid")
    func invalid() throws {
        let result = try parse("""
        {"validation_state":"Invalid","validation_status":[
          {"code":"assertion.dataHash.mismatch","success":false,"explanation":"Hash does not match"}
        ]}
        """)
        #expect(result.status == .invalid)
        #expect(result.rawValidationCodes == ["assertion.dataHash.mismatch"])
    }

    @Test("malformed validation output is rejected")
    func malformed() {
        #expect(throws: C2PAValidationError.self) {
            try C2PASigningService.parseValidationInfoJSON(Data("not JSON".utf8))
        }
    }

    @Test("tool error output is not interpreted as a valid report")
    func toolError() {
        #expect(throws: C2PAValidationError.self) {
            try C2PASigningService.parseValidationInfoJSON(Data("{\"error\":\"unable to read file\"}".utf8))
        }
    }

    private func parse(_ json: String) throws -> C2PAValidationResult {
        try C2PASigningService.parseValidationInfoJSON(Data(json.utf8))
    }
}
