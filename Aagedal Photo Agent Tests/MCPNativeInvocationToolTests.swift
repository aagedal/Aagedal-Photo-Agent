import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Authenticated native review tool boundary")
struct MCPNativeInvocationToolTests {
    nonisolated final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func record() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func authority() -> MCPAuthorizationStore {
        let box = MCPServerCoreTests.DataBox()
        return .init(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
    }

    @Test("Disabled automation and noncanonical or extra arguments never invoke the app")
    func refusesInvalidCalls() throws {
        let store = authority(), calls = Calls()
        let tools = MCPFoundationTools(authorizationStore: store, nativeReviewInvocation: { _, _ in
            calls.record(); return try .init(status: .reviewRequired)
        })
        let id = UUID(), epoch = UUID()
        let valid: [String: MCPJSONValue] = ["requestID": .string(id.uuidString.lowercased()),
            "requestEpoch": .string(epoch.uuidString.lowercased())]
        #expect(tools.callTool(name: "open_voice_transcription_review", arguments: valid).objectValue?["isError"] == .bool(true))
        try store.setEnabled(true)
        var extra = valid; extra["consent"] = .bool(true)
        var uppercase = valid; uppercase["requestID"] = .string(id.uuidString.uppercased())
        for args in [[:], extra, uppercase, ["requestID": valid["requestID"]!], ["requestID": .bool(true), "requestEpoch": valid["requestEpoch"]!]] {
            let result = tools.callTool(name: "open_voice_transcription_review", arguments: args)
            #expect(result.objectValue?["structuredContent"]?.objectValue?["code"] == .string("invalid_arguments"))
        }
        #expect(calls.count == 0)
        let definition = try #require(tools.toolDefinitions(configuration: try store.load()).first {
            $0.objectValue?["name"] == .string("open_voice_transcription_review")
        }?.objectValue)
        #expect(definition["annotations"]?.objectValue?["readOnlyHint"] == .bool(false))
        #expect(definition["annotations"]?.objectValue?["idempotentHint"] == .bool(false))
        #expect(definition["inputSchema"]?.objectValue?["additionalProperties"] == .bool(false))
    }

    @Test("Presentation and linked responses never claim consent, execution or completion", arguments: [false, true])
    func truthfulResponse(linked: Bool) throws {
        let store = authority(); try store.setEnabled(true)
        let id = UUID(), epoch = UUID(), operationID = UUID()
        let tools = MCPFoundationTools(authorizationStore: store, nativeReviewInvocation: { actualID, actualEpoch in
            #expect(actualID == id && actualEpoch == epoch)
            return try .init(status: linked ? .linkedOperation : .reviewRequired, operationID: linked ? operationID : nil)
        })
        let result = tools.callTool(name: "open_voice_transcription_review", arguments: [
            "requestID": .string(id.uuidString.lowercased()), "requestEpoch": .string(epoch.uuidString.lowercased())])
        #expect(result.objectValue?["isError"] == .bool(false))
        let content = try #require(result.objectValue?["structuredContent"]?.objectValue)
        #expect(content["status"] == .string(linked ? "linkedOperation" : "reviewRequired"))
        #expect(content["operationID"] == (linked ? .string(operationID.uuidString.lowercased()) : .null))
        for field in ["consentGranted", "executionStarted", "completionConfirmed", "directHelperExecutionAvailable"] {
            #expect(content[field] == .bool(false))
        }
    }

    @Test("Unavailable authentication and revoked authority refuse with private fixed copy", arguments: [false, true])
    func privateFailure(revoke: Bool) throws {
        enum PrivateError: Error { case sensitivePathAndTranscript }
        let store = authority(); try store.setEnabled(true)
        let tools = MCPFoundationTools(authorizationStore: store, nativeReviewInvocation: { _, _ in
            if revoke { try store.setEnabled(false); return try .init(status: .reviewRequired) }
            throw PrivateError.sensitivePathAndTranscript
        })
        let result = tools.callTool(name: "open_voice_transcription_review", arguments: [
            "requestID": .string(UUID().uuidString.lowercased()), "requestEpoch": .string(UUID().uuidString.lowercased())])
        #expect(result.objectValue?["structuredContent"]?.objectValue?["code"] == .string("native_review_unavailable"))
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("sensitivePathAndTranscript"))
    }
}
