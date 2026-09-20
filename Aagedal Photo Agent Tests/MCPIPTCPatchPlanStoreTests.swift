import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Immutable session-scoped IPTC patch plans")
struct MCPIPTCPatchPlanStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let rootID = UUID(uuidString: "40c770d1-dc70-42c7-999e-4b21b8794385")!

    private func fixture() throws -> (MCPIPTCPatchPreparation.Request, MCPJSONValue, MCPAuthorizationConfiguration) {
        let request = try MCPIPTCPatchPreparation.Request(arguments: [
            "path": .string("/photos/frame.jpg"), "sourceRevision": .string("source"),
            "xmpSidecarRevision": .string("xmp"), "appSidecarRevision": .string("app"),
            "operations": .array([.object(["field": .string("title"), "operation": .string("set"), "value": .string("New")])])
        ])
        let metadata = MCPJSONValue.object([
            "canonicalPath": .string("/photos/frame.jpg"), "rootID": .string(rootID.uuidString.lowercased()),
            "sourceRevision": .string("source"), "xmpSidecarRevision": .string("xmp"),
            "appSidecarRevision": .string("app"), "hasXMPConflict": .bool(false),
            "fields": .object(["title": .string("Before")])
        ])
        var configuration = MCPAuthorizationConfiguration()
        configuration.isEnabled = true
        configuration.roots = [MCPAuthorizedRoot(id: rootID, displayName: "photos", canonicalPath: "/photos",
            identity: MCPFileIdentity(device: 1, inode: 2), bookmarkData: nil)]
        return (request, try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata, now: now), configuration)
    }

    @Test("Retention adds opaque identity and explicitly disclaims durable storage and write authority")
    func retentionContract() throws {
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore()
        let one = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        let two = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        let fields = try #require(one.objectValue)
        #expect(fields["planID"] != two.objectValue?["planID"])
        #expect(fields["previewID"] == preview.objectValue?["previewID"])
        #expect(fields["planStorage"] == .string("helper-session-memory"))
        #expect(fields["previewOnly"] == .bool(true))
        #expect(fields["commitAvailable"] == .bool(false))
        for (key, value) in try #require(preview.objectValue) { #expect(fields[key] == value) }
    }

    @Test("Count and serialized byte budgets refuse additional live plans without evicting them")
    func budgets() throws {
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore(maximumPlans: 1)
        _ = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.capacity) {
            try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.capacity) {
            try MCPIPTCPatchPlanStore(maximumBytes: 1).retain(request: request, preview: preview,
                configuration: configuration, createdAt: now)
        }
    }

    @Test("Expiry boundary and backwards clock refuse before any photo access", arguments: [-1.0, 300.0, 301.0])
    func expiry(offset: TimeInterval) throws {
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore()
        let result = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        let id = try #require(result.objectValue?["planID"])
        let facade = MCPAutomationFacade(authorizationStore: MCPAuthorizationStore(readConfigurationData: { nil }, writeConfigurationData: { _ in }))
        #expect(throws: MCPIPTCPatchPlanStore.Failure.expiredPlan) {
            try plans.inspect(arguments: ["planID": id], facade: facade, now: now.addingTimeInterval(offset))
        }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.unknownPlan) {
            try plans.inspect(arguments: ["planID": id], facade: facade, now: now)
        }
    }

    @Test("An older preparation completing later does not evict a newer live plan")
    func outOfOrderPreparation() throws {
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore(maximumPlans: 2)
        // The preview deadline remains valid for both captures; B began one second later.
        let newer = try plans.retain(request: request, preview: preview, configuration: configuration,
            createdAt: now.addingTimeInterval(1))
        _ = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.capacity) {
            try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        }
        let id = try #require(newer.objectValue?["planID"])
        let facade = MCPAutomationFacade(authorizationStore: MCPAuthorizationStore(readConfigurationData: { nil }, writeConfigurationData: { _ in }))
        // Reaching the authority check proves B remains present; eviction reports unknownPlan.
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try plans.inspect(arguments: ["planID": id], facade: facade, now: now.addingTimeInterval(2))
        }
    }

    @Test("Disabled authority and replacement path or values cannot be supplied with a plan")
    func authorityAndArguments() throws {
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore()
        let result = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        let id = try #require(result.objectValue?["planID"])
        let facade = MCPAutomationFacade(authorizationStore: MCPAuthorizationStore(readConfigurationData: { nil }, writeConfigurationData: { _ in }))
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try plans.inspect(arguments: ["planID": id], facade: facade, now: now)
        }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.invalidArguments) {
            try plans.inspect(arguments: ["planID": id, "path": .string("/other.jpg")], facade: facade, now: now)
        }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.unknownPlan) {
            try MCPIPTCPatchPlanStore().inspect(arguments: ["planID": id], facade: facade, now: now)
        }
        var disabled = configuration
        disabled.isEnabled = false
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try plans.retain(request: request, preview: preview, configuration: disabled, createdAt: now)
        }
    }
}
