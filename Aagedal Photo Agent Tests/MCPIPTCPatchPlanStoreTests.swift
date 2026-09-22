import CoreGraphics
import ImageIO
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@_silgen_name("flock")
private nonisolated func testPatchPlanFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

@Suite("Immutable session-scoped IPTC patch plans")
struct MCPIPTCPatchPlanStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let rootID = UUID(uuidString: "40c770d1-dc70-42c7-999e-4b21b8794385")!

    private func fixture(createdAt: Date? = nil) throws -> (MCPIPTCPatchPreparation.Request, MCPJSONValue, MCPAuthorizationConfiguration) {
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
        return (request, try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata, now: createdAt ?? now), configuration)
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

    @Test("Second-resolution deadlines never round beyond authority at fractional boundaries",
        arguments: [0.0, 0.9994, 0.9995, 0.9999])
    func fractionalDeadline(fraction: TimeInterval) throws {
        let createdAt = now.addingTimeInterval(fraction)
        let (request, preview, configuration) = try fixture(createdAt: createdAt)
        let text = try #require(preview.objectValue?["expiresAt"]?.stringValue)
        let expiry = try #require(ISO8601DateFormatter().date(from: text))
        #expect(expiry == now.addingTimeInterval(MCPIPTCPatchPlanStore.lifetime))
        #expect(expiry <= createdAt.addingTimeInterval(MCPIPTCPatchPlanStore.lifetime))
        let directory = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = MCPIPTCPatchPlanStore(storageDirectory: directory)
        let retained = try first.retain(request: request, preview: preview,
            configuration: configuration, createdAt: createdAt)
        let id = try #require(retained.objectValue?["planID"])
        let restarted = MCPIPTCPatchPlanStore(storageDirectory: directory)
        let facade = MCPAutomationFacade(authorizationStore: MCPAuthorizationStore(
            readConfigurationData: { nil }, writeConfigurationData: { _ in }))
        // Reaching the authority check proves the archive's lifetime validation accepted
        // the fractional creation instant, rather than rejecting storage as malformed.
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try restarted.inspect(arguments: ["planID": id], facade: facade, now: createdAt)
        }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.expiredPlan) {
            try restarted.inspect(arguments: ["planID": id], facade: facade, now: expiry)
        }
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
    private func temporaryStorage() throws -> URL {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("patch-plans-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Durable restart restores opaque identity and preserves authority and expiry checks")
    func durableRestart() throws {
        let directory = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, preview, configuration) = try fixture()
        let first = MCPIPTCPatchPlanStore(maximumPlans: 1, storageDirectory: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let result = try first.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        #expect(result.objectValue?["planStorage"] == .string("local-durable-read-only"))
        let id = try #require(result.objectValue?["planID"])
        let restarted = MCPIPTCPatchPlanStore(maximumPlans: 1, storageDirectory: directory)
        let facade = MCPAutomationFacade(authorizationStore: MCPAuthorizationStore(readConfigurationData: { nil }, writeConfigurationData: { _ in }))
        let bytes = try Data(contentsOf: directory.appendingPathComponent("plans.json"))
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try restarted.inspect(arguments: ["planID": id], facade: facade, now: now)
        }
        #expect(throws: MCPIPTCPatchPlanStore.Failure.expiredPlan) {
            try restarted.inspect(arguments: ["planID": id], facade: facade, now: now.addingTimeInterval(300))
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("plans.json")) == bytes)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.capacity) {
            try restarted.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        }
    }

    @Test("Corrupt, unknown schema and unknown field archives refuse without overwriting evidence", arguments: ["corrupt", "checksum", "schema", "field", "configuration-field", "root-field", "identity-field"])
    func invalidArchive(kind: String) throws {
        let directory = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore(storageDirectory: directory)
        _ = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        let url = directory.appendingPathComponent("plans.json")
        var data = try Data(contentsOf: url)
        if kind == "corrupt" { data = Data("broken".utf8) }
        else {
            var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if kind == "field" { envelope["unknown"] = true }
            else if kind == "checksum" { envelope["sha256"] = "invalid" }
            else {
                let encodedPayload = try #require(envelope["payload"] as? String)
                let payload = try #require(Data(base64Encoded: encodedPayload))
                var archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                if kind == "schema" { archive["schemaVersion"] = 999 }
                else {
                    var records = try #require(archive["records"] as? [String: [String: Any]])
                    let id = try #require(records.keys.first)
                    var record = try #require(records[id])
                    var configuration = try #require(record["configuration"] as? [String: Any])
                    if kind == "configuration-field" { configuration["futureAuthority"] = true }
                    else {
                        var roots = try #require(configuration["roots"] as? [[String: Any]])
                        #expect(!roots.isEmpty)
                        if kind == "root-field" { roots[0]["futureRootAuthority"] = true }
                        else {
                            var identity = try #require(roots[0]["identity"] as? [String: Any])
                            identity["futureIdentity"] = true
                            roots[0]["identity"] = identity
                        }
                        configuration["roots"] = roots
                    }
                    record["configuration"] = configuration
                    records[id] = record
                    archive["records"] = records
                }
                let changed = try JSONSerialization.data(withJSONObject: archive)
                envelope["payload"] = changed.base64EncodedString()
                envelope["sha256"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
            }
            data = try JSONSerialization.data(withJSONObject: envelope)
        }
        try data.write(to: url)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.invalidStorage) {
            try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("Known optional authorization revision and bookmark survive durable reload")
    func optionalAuthorizationFields() throws {
        let directory = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, preview, originalConfiguration) = try fixture()
        var configuration = originalConfiguration
        configuration.authorizationRevision = UUID()
        let root = try #require(configuration.roots.first)
        configuration.roots = [.init(id: root.id, displayName: root.displayName,
            canonicalPath: root.canonicalPath, identity: root.identity, bookmarkData: Data("bookmark fixture".utf8))]
        _ = try MCPIPTCPatchPlanStore(storageDirectory: directory).retain(
            request: request, preview: preview, configuration: configuration, createdAt: now)
        _ = try MCPIPTCPatchPlanStore(storageDirectory: directory).retain(
            request: request, preview: preview, configuration: configuration, createdAt: now)
        let envelope = try #require(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("plans.json"))) as? [String: Any])
        let encodedPayload = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encodedPayload))
        let archive = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let records = try #require(archive["records"] as? [String: [String: Any]])
        #expect(records.count == 2)
        for record in records.values {
            let restored = try #require(record["configuration"] as? [String: Any])
            #expect(restored["authorizationRevision"] as? String == configuration.authorizationRevision?.uuidString)
            let roots = try #require(restored["roots"] as? [[String: Any]])
            #expect(roots.first?["bookmarkData"] as? String == configuration.roots.first?.bookmarkData?.base64EncodedString())
        }
    }

    @Test("A separately held archive lock refuses retention without changing storage")
    func archiveLockContention() throws {
        let directory = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (request, preview, configuration) = try fixture()
        let plans = MCPIPTCPatchPlanStore(storageDirectory: directory)
        _ = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        let archiveURL = directory.appendingPathComponent("plans.json")
        let original = try Data(contentsOf: archiveURL)
        let descriptor = Darwin.open(directory.appendingPathComponent("plans.lock").path,
                                     O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { _ = testPatchPlanFlock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try #require(testPatchPlanFlock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.storageUnavailable) {
            try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        }
        #expect(try Data(contentsOf: archiveURL) == original)
        try #require(testPatchPlanFlock(descriptor, LOCK_UN) == 0)
        _ = try plans.retain(request: request, preview: preview, configuration: configuration, createdAt: now)
        #expect(try Data(contentsOf: archiveURL) != original)
    }

    @Test("Symlink storage fails without touching its destination")
    func symlinkRefusal() throws {
        let directory = try temporaryStorage()
        let link = try temporaryStorage()
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let (request, preview, configuration) = try fixture()
        #expect(throws: MCPIPTCPatchPlanStore.Failure.storageUnavailable) {
            try MCPIPTCPatchPlanStore(storageDirectory: link).retain(request: request, preview: preview,
                configuration: configuration, createdAt: now)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Restarted durable plans exactly revalidate a real photo for set and clear", arguments: [false, true])
    func realPhotoRestart(clear: Bool) async throws {
        let root = try temporaryStorage()
        let storage = try temporaryStorage()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: storage) }
        let photo = root.appendingPathComponent("frame.jpg")
        let pixels = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(pixels.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCHeadline: "Embedded"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (bytes as Data).write(to: photo)
        let box = MCPServerCoreTests.DataBox()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root)
        try authority.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authority)
        let metadata = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
        var operation: [String: MCPJSONValue] = ["field": .string("title"), "operation": .string(clear ? "clear" : "set")]
        if !clear { operation["value"] = .string("New title") }
        var arguments: [String: MCPJSONValue] = ["path": .string(photo.path), "operations": .array([.object(operation)])]
        for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { arguments[key] = metadata[key] }
        let prepared = try MCPIPTCPatchPreparation.prepare(arguments: arguments, facade: facade,
            plans: MCPIPTCPatchPlanStore(storageDirectory: storage))
        let id = try #require(prepared.objectValue?["planID"])
        let restarted = MCPIPTCPatchPlanStore(storageDirectory: storage)
        #expect(try restarted.inspect(arguments: ["planID": id], facade: facade) == prepared)
        let reviewService = AutomationPatchReviewService(plans: restarted, facade: facade)
        let reviewID = try #require(id.stringValue)
        let review = try await reviewService.inspect(planID: reviewID)
        #expect(review.changes.first?.before == "Embedded")
        #expect(review.changes.first?.after == (clear ? "" : "New title"))
        #expect(try Data(contentsOf: photo) == bytes as Data)
        try authority.setEnabled(false)
        try authority.setEnabled(true)
        #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try restarted.inspect(arguments: ["planID": id], facade: facade)
        }
        await #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
            try await reviewService.inspect(planID: reviewID)
        }
    }

}
