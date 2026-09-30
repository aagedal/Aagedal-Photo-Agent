import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Helper durable native review intent protocol")
struct MCPNativeReviewRequestProtocolTests {
    nonisolated private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
    private typealias Fixture = MCPIPTCPatchXMPPreflightServiceTests.Fixture
    private let requestTool = "request_iptc_patch_review"
    private let statusTool = "get_native_review_request"
    private let cancelTool = "cancel_native_review_request"

    private func arguments(_ fixture: Fixture, id: UUID, purpose: String = "pendingDraft") -> [String: MCPJSONValue] {
        ["requestID": .string(id.uuidString.lowercased()), "planID": .string(fixture.planID), "purpose": .string(purpose)]
    }

    private func structured(_ value: MCPJSONValue) throws -> [String: MCPJSONValue] {
        try #require(value.objectValue?["structuredContent"]?.objectValue)
    }

    private func physicalRoot(_ fixture: Fixture) throws -> URL {
        // Foundation can keep the system /var alias in temporaryDirectory. Durable
        // persistence deliberately refuses symlink ancestors, including that alias.
        let path = try #require(realpath(fixture.root.path, nil))
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    @Test("Native review tools require enablement, canonical IDs, exact arguments and known purpose")
    func authorizationAndRefusals() throws {
        let fixture = try Fixture()
        let requests = MCPNativeReviewRequestStore(storageDirectory: try physicalRoot(fixture).appendingPathComponent("requests"))
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, nativeReviewRequests: requests)
        let id = UUID()
        let args = arguments(fixture, id: id)
        try fixture.facade.authorizationStore.setEnabled(false)
        for (name, value) in [(requestTool, args), (statusTool, ["requestID": args["requestID"]!]),
                              (cancelTool, ["requestID": args["requestID"]!])] {
            #expect(try structured(tools.callTool(name: name, arguments: value))["code"] == .string("disabled"))
        }
        try fixture.facade.authorizationStore.setEnabled(true)
        for name in [requestTool, statusTool, cancelTool] {
            let minimal = name == requestTool ? args : ["requestID": args["requestID"]!]
            var invalid = minimal; invalid["execute"] = .bool(true)
            #expect(try structured(tools.callTool(name: name, arguments: invalid))["code"] == .string("invalid_arguments"))
            for value in [MCPJSONValue.string(id.uuidString.uppercased()), .integer(1), .null, .string("not-a-uuid")] {
                var invalid = minimal; invalid["requestID"] = value
                #expect(try structured(tools.callTool(name: name, arguments: invalid))["code"] == .string("invalid_arguments"))
            }
            #expect(try structured(tools.callTool(name: name, arguments: [:]))["code"] == .string("invalid_arguments"))
        }
        for (key, value) in [("purpose", MCPJSONValue.string("commit")), ("purpose", .bool(true)),
                             ("planID", .string(fixture.planID.uppercased()))] {
            var invalid = args; invalid[key] = value
            #expect(try structured(tools.callTool(name: requestTool, arguments: invalid))["code"] == .string("invalid_arguments"))
        }
        for name in [statusTool, cancelTool] {
            #expect(try structured(tools.callTool(name: name, arguments: ["requestID": args["requestID"]!]))["code"] == .string("unknown_native_review_request"))
        }
        #expect(try requests.records().isEmpty)
    }

    @Test("New intents validate the exact retained plan; accepted intent grants no execution or consent",
          arguments: ["pendingDraft", "xmpPublication"])
    func creationAndStaleness(purpose: String) throws {
        let fixture = try Fixture(pending: true)
        let requests = MCPNativeReviewRequestStore(storageDirectory: try physicalRoot(fixture).appendingPathComponent("requests"))
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, nativeReviewRequests: requests)
        let original = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        let args = arguments(fixture, id: UUID(), purpose: purpose)
        let result = tools.callTool(name: requestTool, arguments: args)
        #expect(result.objectValue?["isError"] == .bool(false))
        let value = try structured(result)
        #expect(value["state"] == .string("awaitingReview"))
        #expect(value["purpose"] == .string(purpose))
        #expect(value["commitAvailable"] == .bool(false))
        #expect(value["consentGranted"] == .bool(false))
        #expect(value["operationID"] == .null)
        #expect(value["executorLiveness"] == .string("unknown"))
        #expect(value["scope"] == .string("durable-native-review-intent"))
        #expect(value["canonicalPath"] == nil)
        #expect(value["ownerID"] == nil)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path) { $0 }
        #expect(original.sourceRevision == after.sourceRevision)
        #expect(original.xmpBytes == after.xmpBytes)
        #expect(original.appSidecarBytes == after.appSidecarBytes)
        #expect(tools.callTool(name: requestTool, arguments: args) == result)

        try Data("changed".utf8).write(to: fixture.photo)
        let stale = tools.callTool(name: requestTool, arguments: arguments(fixture, id: UUID(), purpose: purpose))
        #expect(stale.objectValue?["isError"] == .bool(true))
        #expect(try requests.records().count == 1)
        // Retrieving the existing intent never claims current validity or loses status.
        #expect(tools.callTool(name: requestTool, arguments: args) == result)
    }

    @Test("Exact retries retain durable cancellation after source disappearance and plan loss")
    func restartAndCancelledRetry() throws {
        let fixture = try Fixture()
        let directory = try physicalRoot(fixture).appendingPathComponent("requests")
        let requests = MCPNativeReviewRequestStore(storageDirectory: directory)
        let authority = fixture.facade.authorizationStore
        let tools = MCPFoundationTools(authorizationStore: authority, patchPlans: fixture.plans, nativeReviewRequests: requests)
        let id = UUID()
        let args = arguments(fixture, id: id)
        _ = tools.callTool(name: requestTool, arguments: args)
        let binding = try fixture.plans.localApprovalBinding(planID: fixture.planID, facade: fixture.facade, now: Date())
        #expect(throws: MCPIPTCPatchPlanStore.Failure.expiredPlan) {
            try fixture.plans.inspect(arguments: ["planID": .string(fixture.planID)], facade: fixture.facade, now: binding.expiresAt)
        }
        #expect(try structured(tools.callTool(name: requestTool, arguments: args))["state"] == .string("awaitingReview"))
        let cancelled = tools.callTool(name: cancelTool, arguments: ["requestID": args["requestID"]!])
        #expect(try structured(cancelled)["state"] == .string("cancelled"))
        #expect(try structured(cancelled)["cancellationRequested"] == .bool(true))
        #expect(try structured(cancelled)["consentGranted"] == .bool(false))
        try FileManager.default.removeItem(at: fixture.photo)
        let restarted = MCPFoundationTools(authorizationStore: authority, patchPlans: MCPIPTCPatchPlanStore(),
            nativeReviewRequests: MCPNativeReviewRequestStore(storageDirectory: directory))
        #expect(restarted.callTool(name: requestTool, arguments: args) == cancelled)
        #expect(restarted.callTool(name: statusTool, arguments: ["requestID": args["requestID"]!]) == cancelled)
        #expect(restarted.callTool(name: cancelTool, arguments: ["requestID": args["requestID"]!]) == cancelled)
        var conflicting = args; conflicting["purpose"] = .string("xmpPublication")
        #expect(try structured(restarted.callTool(name: requestTool, arguments: conflicting))["code"] == .string("conflicting_native_review_request"))
        conflicting = args; conflicting["planID"] = .string(UUID().uuidString.lowercased())
        #expect(try structured(restarted.callTool(name: requestTool, arguments: conflicting))["code"] == .string("conflicting_native_review_request"))
        try authority.setEnabled(false)
        #expect(try structured(restarted.callTool(name: requestTool, arguments: args))["code"] == .string("disabled"))
    }

    @Test("Settings are rechecked before accessing durable review state")
    func authorizationRecheck() throws {
        let fixture = try Fixture()
        let requests = MCPNativeReviewRequestStore(storageDirectory: try physicalRoot(fixture).appendingPathComponent("requests"))
        let enabled = try fixture.facade.authorizationStore.load()
        var disabled = enabled; disabled.isEnabled = false
        let enabledBytes = try JSONEncoder().encode(enabled)
        let disabledBytes = try JSONEncoder().encode(disabled)
        let counter = ReadCounter()
        let authority = MCPAuthorizationStore(
            readConfigurationData: { counter.next() == 1 ? enabledBytes : disabledBytes },
            writeConfigurationData: { _ in })
        let tools = MCPFoundationTools(authorizationStore: authority, patchPlans: fixture.plans, nativeReviewRequests: requests)
        let result = tools.callTool(name: requestTool, arguments: arguments(fixture, id: UUID()))
        #expect(try structured(result)["code"] == .string("rootChanged"))
        #expect(try requests.records().isEmpty)
    }

    @Test("Linked status exposes the operation and cancellation forwards intent without completing it")
    func linkedOperationCancellation() throws {
        let fixture = try Fixture()
        let storageRoot = try physicalRoot(fixture)
        let requests = MCPNativeReviewRequestStore(storageDirectory: storageRoot.appendingPathComponent("requests"))
        let registry = AutomationOperationRegistry(storageDirectory: storageRoot.appendingPathComponent("operations"))
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, operationRegistry: registry, nativeReviewRequests: requests)
        let id = UUID()
        let args = arguments(fixture, id: id)
        _ = tools.callTool(name: requestTool, arguments: args)
        _ = try requests.admit(id)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .iptcDraft, ownerID: owner)
        _ = try registry.start(operation.id, ownerID: owner)
        _ = try requests.link(id, operationID: operation.id)
        let status = try structured(tools.callTool(name: statusTool, arguments: ["requestID": args["requestID"]!]))
        #expect(status["state"] == .string("linked"))
        #expect(status["operationID"] == .string(operation.id.uuidString.lowercased()))
        #expect(status["consentGranted"] == .bool(false))
        #expect(status["operationStatus"] == .string("available"))
        #expect(status["operation"]?.objectValue?["state"] == .string("running"))
        #expect(status["operation"]?.objectValue?["outcome"] == .null)
        let cancelled = tools.callTool(name: cancelTool, arguments: ["requestID": args["requestID"]!])
        #expect(try structured(cancelled)["operationCancellationStatus"] == .string("requested"))
        #expect(try structured(cancelled)["state"] == .string("linked"))
        #expect(try registry.inspect(operation.id).state == .running)
        #expect(try registry.inspect(operation.id).cancellationRequestedAt != nil)
        #expect(tools.callTool(name: cancelTool, arguments: ["requestID": args["requestID"]!]) == cancelled)
        #expect(try structured(tools.callTool(name: "get_operation_status",
            arguments: ["operationID": status["operationID"]!]))["state"] == .string("running"))
    }

    @Test("Linked status preserves each terminal outcome and late cancellation never changes it",
          arguments: [AutomationOperationRegistry.Outcome.verified, .failed, .stale, .partialUncertain, .recoveryRequired, .cancelled])
    func terminalOperationStatus(outcome: AutomationOperationRegistry.Outcome) throws {
        let fixture = try Fixture()
        let root = try physicalRoot(fixture)
        let requests = MCPNativeReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("operations"))
        let id = UUID(), owner = UUID()
        _ = try requests.request(requestID: id, planID: fixture.planID, purpose: .xmpPublication)
        _ = try requests.admit(id)
        let operation = try registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try registry.start(operation.id, ownerID: owner)
        _ = try requests.link(id, operationID: operation.id)
        let terminal: AutomationOperationRegistry.Record
        if outcome == .cancelled {
            _ = try registry.requestCancellation(operation.id)
            terminal = try registry.acknowledgeCancellation(operation.id, ownerID: owner)
        } else {
            terminal = try registry.finish(operation.id, ownerID: owner, outcome: outcome)
        }
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, operationRegistry: registry, nativeReviewRequests: requests)
        let args: [String: MCPJSONValue] = ["requestID": .string(id.uuidString.lowercased())]
        let status = try structured(tools.callTool(name: statusTool, arguments: args))
        #expect(status["operationStatus"] == .string("available"))
        let projection = try #require(status["operation"]?.objectValue)
        #expect(projection["outcome"] == .string(outcome.rawValue))
        #expect(projection["terminal"] == .bool(true))
        #expect(projection["executorLiveness"] == .string("unknown"))
        #expect(projection["ownerID"] == nil)
        #expect(projection["recoveryResolution"] == .null)
        #expect(status["consentGranted"] == .bool(false))
        #expect(status["commitAvailable"] == .bool(false))
        #expect(status["operation"] == tools.callTool(name: "get_operation_status",
            arguments: ["operationID": .string(operation.id.uuidString.lowercased())]).objectValue?["structuredContent"])
        let cancelled = try structured(tools.callTool(name: cancelTool, arguments: args))
        #expect(cancelled["operationCancellationStatus"] == .string("already-terminal"))
        #expect(cancelled["operation"] == status["operation"])
        #expect(try registry.inspect(operation.id) == terminal)
        #expect(try requests.inspect(id).cancellationRequestedAt != nil)
        // Removing terminal history loses confirmation, never the retained intent/link.
        if terminal.canRemove {
            try registry.removeTerminal(operation.id, ownerID: owner)
            let missing = try structured(tools.callTool(name: statusTool, arguments: args))
            #expect(missing["state"] == .string("linked"))
            #expect(missing["operationStatus"] == .string("confirmation-unavailable"))
            #expect(missing["operation"] == .null)
        }
    }

    @Test("Authorization revocation after linked inspection refuses cancellation forwarding and status output")
    func linkedAuthorizationRecheck() throws {
        let fixture = try Fixture()
        let root = try physicalRoot(fixture)
        let requests = MCPNativeReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("operations"))
        let id = UUID(), owner = UUID()
        _ = try requests.request(requestID: id, planID: fixture.planID, purpose: .pendingDraft)
        _ = try requests.admit(id)
        let operation = try registry.enqueue(kind: .iptcDraft, ownerID: owner)
        _ = try requests.link(id, operationID: operation.id)
        let enabled = try fixture.facade.authorizationStore.load()
        var disabled = enabled; disabled.isEnabled = false
        let enabledBytes = try JSONEncoder().encode(enabled), disabledBytes = try JSONEncoder().encode(disabled)
        for name in [statusTool, cancelTool] {
            let counter = ReadCounter()
            let authority = MCPAuthorizationStore(readConfigurationData: {
                counter.next() < 4 ? enabledBytes : disabledBytes
            }, writeConfigurationData: { _ in })
            let tools = MCPFoundationTools(authorizationStore: authority,
                operationRegistry: registry, nativeReviewRequests: requests)
            let value = try structured(tools.callTool(name: name,
                arguments: ["requestID": .string(id.uuidString.lowercased())]))
            #expect(value["code"] == .string("rootChanged"))
            #expect(value["operation"] == nil)
            #expect(try registry.inspect(operation.id) == operation)
        }
        // The request intent precedes forwarding and remains durable even when
        // a later authorization recheck refuses the operation cancellation.
        #expect(try requests.inspect(id).cancellationRequestedAt != nil)
    }

    @Test("Resolved recovery is separate evidence and does not rewrite publication success")
    func resolvedRecoveryProjection() throws {
        let fixture = try Fixture()
        let root = try physicalRoot(fixture)
        let requests = MCPNativeReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("operations"))
        let id = UUID(), owner = UUID()
        _ = try requests.request(requestID: id, planID: fixture.planID, purpose: .xmpPublication)
        _ = try requests.admit(id)
        let operation = try registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try requests.link(id, operationID: operation.id)
        _ = try registry.finish(operation.id, ownerID: owner, outcome: .recoveryRequired)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: root.appendingPathComponent("recovery"))
        let material = try recovery.stage(id: operation.id, planID: fixture.planID, targetPath: fixture.photo.path + ".xmp",
            binding: .init(sourceRevision: "source", xmpSidecarRevision: "xmp", appSidecarRevision: "app", authorizationRevision: UUID()),
            original: nil, candidate: Data("candidate".utf8),
            appSidecarRecovery: .init(original: nil, candidate: Data("app-candidate".utf8)), publicationApprovalID: UUID())
        try recovery.recordUnchanged(material) {}
        try recovery.reconcileHistoryDisposition { _ = try registry.recordRecoveryResolution($0) }
        let retained = try #require(try registry.inspect(operation.id).recoveryResolution)
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, operationRegistry: registry, nativeReviewRequests: requests)
        let value = try structured(tools.callTool(name: statusTool,
            arguments: ["requestID": .string(id.uuidString.lowercased())]))
        let projection = try #require(value["operation"]?.objectValue)
        #expect(projection["outcome"] == .string("recoveryRequired"))
        #expect(projection["terminal"] == .bool(true))
        #expect(projection["recoveryResolution"] == .object([
            "disposition": .string("unchanged"), "receiptSHA256": .string(retained.receiptSHA256),
            "resolvedAt": .string(retained.resolvedAt.ISO8601Format())]))
        #expect(value["operation"] == tools.callTool(name: "get_operation_status",
            arguments: ["operationID": .string(operation.id.uuidString.lowercased())]).objectValue?["structuredContent"])
        #expect(value["consentGranted"] == .bool(false))
        #expect(try registry.inspect(operation.id).outcome == .recoveryRequired)
    }

    @Test("A link to another operation kind cannot report or cancel that operation")
    func mismatchedOperationKind() throws {
        let fixture = try Fixture()
        let root = try physicalRoot(fixture)
        let requests = MCPNativeReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("operations"))
        let id = UUID(), owner = UUID()
        _ = try requests.request(requestID: id, planID: fixture.planID, purpose: .pendingDraft)
        _ = try requests.admit(id)
        let operation = try registry.enqueue(kind: .faceScan, ownerID: owner)
        _ = try requests.link(id, operationID: operation.id)
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, operationRegistry: registry, nativeReviewRequests: requests)
        let args: [String: MCPJSONValue] = ["requestID": .string(id.uuidString.lowercased())]
        for name in [statusTool, cancelTool] {
            let status = try structured(tools.callTool(name: name, arguments: args))
            #expect(status["operationStatus"] == .string("confirmation-unavailable"))
            #expect(status["operation"] == .null)
            #expect(status["consentGranted"] == .bool(false))
        }
        #expect(try registry.inspect(operation.id) == operation)
        #expect(try requests.inspect(id).cancellationRequestedAt != nil)
    }

    @Test("Unavailable linked operation preserves cancellation and reports uncertainty")
    func unavailableLinkedOperation() throws {
        let fixture = try Fixture()
        let storageRoot = try physicalRoot(fixture)
        let requests = MCPNativeReviewRequestStore(storageDirectory: storageRoot.appendingPathComponent("requests"))
        let registry = AutomationOperationRegistry(storageDirectory: storageRoot.appendingPathComponent("operations"))
        let id = UUID()
        _ = try requests.request(requestID: id, planID: fixture.planID, purpose: .pendingDraft)
        _ = try requests.admit(id)
        _ = try requests.link(id, operationID: UUID())
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: fixture.plans, operationRegistry: registry, nativeReviewRequests: requests)
        let result = tools.callTool(name: cancelTool, arguments: ["requestID": .string(id.uuidString.lowercased())])
        #expect(result.objectValue?["isError"] == .bool(false))
        let value = try structured(result)
        #expect(value["state"] == .string("linked"))
        #expect(value["cancellationRequested"] == .bool(true))
        #expect(value["operationCancellationStatus"] == .string("confirmation-unavailable"))
        #expect(value["operationStatus"] == .string("confirmation-unavailable"))
        #expect(value["operation"] == .null)
        #expect(try requests.inspect(id).cancellationRequestedAt != nil)
    }

    @Test("Startup uncertainty remains inspectable and exact retry cannot admit again")
    func unknownDisposition() throws {
        let fixture = try Fixture()
        let requests = MCPNativeReviewRequestStore(storageDirectory: try physicalRoot(fixture).appendingPathComponent("requests"))
        let id = UUID()
        _ = try requests.request(requestID: id, planID: fixture.planID, purpose: .pendingDraft)
        _ = try requests.admit(id)
        _ = try requests.reconcileUnlinkedAdmissions()
        let tools = MCPFoundationTools(authorizationStore: fixture.facade.authorizationStore,
            patchPlans: MCPIPTCPatchPlanStore(), nativeReviewRequests: requests)
        let result = tools.callTool(name: requestTool, arguments: arguments(fixture, id: id))
        #expect(try structured(result)["state"] == .string("unknownDisposition"))
        #expect(try structured(result)["operationID"] == .null)
        #expect(throws: MCPNativeReviewRequestStore.Failure.invalidTransition) { try requests.admit(id) }
    }

    @Test("Discovery describes durable intent and preserves the helper consent boundary")
    func discovery() throws {
        let tools = MCPFoundationTools()
        let definitions = tools.toolDefinitions(configuration: .init())
        for name in [requestTool, statusTool, cancelTool] {
            let tool = try #require(definitions.first { $0.objectValue?["name"] == .string(name) }?.objectValue)
            #expect(tool["annotations"]?.objectValue?["readOnlyHint"] == .bool(name == statusTool))
            #expect(tool["annotations"]?.objectValue?["idempotentHint"] == .bool(true))
            #expect(tool["inputSchema"]?.objectValue?["additionalProperties"] == .bool(false))
        }
        let capabilities = try structured(tools.callTool(name: "get_server_capabilities", arguments: [:]))
        #expect(capabilities["nativeReviewRequestsAvailable"] == .bool(true))
        #expect(capabilities["helperCommitAvailable"] == .bool(false))
        #expect(capabilities["operationExecutorsConnected"] == .bool(false))
    }

    @Test("Default private review subtree cannot become a photo root through an authorized ancestor")
    func privateStorageAdmission() throws {
        let fixture = try Fixture()
        let root = try physicalRoot(fixture)
        let privateName = try MCPNativeReviewRequestStore.defaultStorageDirectory().lastPathComponent
        #expect(privateName.hasPrefix(".aagedal-photo-agent"))
        let privateDirectory = root.appendingPathComponent(privateName, isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false)
        let privatePhoto = privateDirectory.appendingPathComponent("intent.jpg")
        try Data("private intent".utf8).write(to: privatePhoto)
        let box = MCPServerCoreTests.DataBox()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root)
        try authority.setEnabled(true)
        #expect(throws: MCPAuthorizationError.privateAppStorage) { try authority.addRoot(privateDirectory) }
        #expect(throws: MCPAuthorizationError.privateAppStorage) { try authority.authorizeExistingPath(privatePhoto.path) }
        let tools = MCPFoundationTools(authorizationStore: authority)
        #expect(try structured(tools.callTool(name: "inspect_path_authorization",
            arguments: ["path": .string(privatePhoto.path)]))["code"] == .string("privateAppStorage"))
    }
}
