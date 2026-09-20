import Foundation
import CoreGraphics
import ImageIO
import Testing
import CryptoKit
@testable import Aagedal_Photo_Agent

@Suite("Revision-bound MCP proofreading preview")
struct MCPIPTCPatchPreparationTests {
    private func arguments(_ operations: [MCPJSONValue]) -> [String: MCPJSONValue] {
        ["path": .string("/photos/frame.jpg"), "sourceRevision": .string("source"),
         "xmpSidecarRevision": .string("xmp"), "appSidecarRevision": .string("app"),
         "operations": .array(operations)]
    }
    private func operation(_ field: String = "title", _ value: MCPJSONValue = .string("New headline")) -> MCPJSONValue {
        .object(["field": .string(field), "operation": .string("set"), "value": value])
    }
    private func metadata(conflict: Bool = false, pending: Bool = false) -> MCPJSONValue {
        .object(["canonicalPath": .string("/photos/frame.jpg"), "rootID": .string("root"),
                 "sourceRevision": .string("source"), "xmpSidecarRevision": .string("xmp"),
                 "appSidecarRevision": .string("app"), "hasXMPConflict": .bool(conflict),
                 "hasPendingChanges": .bool(pending),
                 "fields": .object(["title": .string("Old headline"), "keywords": .array([.string("news")])])])
    }
    @Test("Preview binds exact before/after, revisions, operations and expiry without commit authority")
    func previewIdentityAndNoCommit() throws {
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([operation()]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let preview = try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata(pending: true), now: now)
        let value = try #require(preview.objectValue)
        #expect(value["commitAvailable"] == .bool(false))
        #expect(value["previewOnly"] == .bool(true))
        #expect(value["sourceRevision"] == .string("source"))
        #expect(value["expiresAt"] == .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(300))))
        #expect(try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata(pending: true), now: now) == preview)
        let altered = try MCPIPTCPatchPreparation.Request(arguments: arguments([operation("title", .string("Other"))]))
        let other = try MCPIPTCPatchPreparation.preview(request: altered, metadata: metadata(pending: true), now: now)
        #expect(other.objectValue?["previewID"] != value["previewID"])
        #expect(value["changes"] == .array([.object(["field": .string("title"), "operation": .string("set"),
            "sourceValue": .string("Old headline"), "requestedValue": .string("New headline"),
            "before": .string("Old headline"), "after": .string("New headline"), "changed": .bool(true),
            "comparisonRule": .string("scalarWhitespace")])]))
    }
    @Test("Each carrier token must match and conflicts refuse preparation")
    func rejectsStaleAndConflict() throws {
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([operation()]))
        for tokens in [("changed", "xmp", "app"), ("source", "changed", "app"), ("source", "xmp", "changed")] {
            #expect(throws: MCPIPTCPatchPreparation.Failure.staleRevision) {
                try MCPIPTCPatchPreparation.checkRevisions(request, source: tokens.0, xmp: tokens.1, app: tokens.2)
            }
        }
        #expect(throws: MCPIPTCPatchPreparation.Failure.conflict) {
            try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata(conflict: true), now: Date())
        }
    }
    @Test("Unknown/private fields, duplicate fields, wrong types and oversized text fail closed")
    func rejectsInvalidOperations() throws {
        for field in ["CameraRaw", "captureDate", "rating", "creator", "localizedTitles", "metadata", "transcript"] {
            #expect(throws: MCPIPTCPatchPreparation.Failure.unsupportedField) {
                try MCPIPTCPatchPreparation.Request(arguments: arguments([operation(field)]))
            }
        }
        let invalid: [[MCPJSONValue]] = [[], [operation(), operation()], [operation("title", .null)],
            [operation("title", .string(" \n\t"))], [operation("keywords", .array([]))],
            [operation("keywords", .array([.string(" \n")]))],
            [operation("keywords", .string("not an array"))], [operation("keywords", .array([.integer(1)]))],
            [operation("title", .string(String(repeating: "ø", count: 16_385)))],
            [.object(["field": .string("title"), "operation": .string("clear"), "value": .null])],
            [.object(["field": .string("title"), "operation": .string("append"), "value": .string("text")])]]
        for operations in invalid {
            #expect(throws: MCPIPTCPatchPreparation.Failure.invalidArguments) {
                try MCPIPTCPatchPreparation.Request(arguments: arguments(operations))
            }
        }
    }
    @Test("Clear is explicit and IIM warnings do not truncate Unicode text")
    func clearAndByteWarnings() throws {
        let text = String(repeating: "ø", count: 129)
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([
            operation("title", .string(text)), .object(["field": .string("keywords"), "operation": .string("clear")])]))
        #expect(request.operations.first?.after == .array([]))
        let preview = try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata(), now: Date())
        let validation = try #require(preview.objectValue?["validation"]?.objectValue)
        let issues = try #require(validation["issues"]?.patchArrayValue)
        #expect(issues.count == 1)
        #expect(issues.first?.objectValue?["field"] == .string("title"))
        #expect(issues.first?.objectValue?["code"] == .string("iptc_iim_byte_limit"))
        #expect(issues.first?.objectValue?["technicalDetail"] == .string("Largest UTF-8 value: 258 bytes; values over limit: 1."))
        #expect(request.operations.last?.after == .string(text))
    }
    @Test("Every preview field resolves to the production mutation and verification registries")
    func productionFieldCoverage() throws {
        var record = try #require(metadata().objectValue)
        var fields: [String: MCPJSONValue] = [:]
        var operations: [MCPJSONValue] = []
        for field in MCPIPTCPatchPreparation.supportedFields.sorted() {
            let isArray = MCPIPTCPatchPreparation.arrayFields.contains(field)
            fields[field] = isArray ? .array([]) : .null
            operations.append(operation(field, isArray ? .array([.string(" Value ")]) : .string(" Value ")))
        }
        record["fields"] = .object(fields)
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments(operations))
        let result = try MCPIPTCPatchPreparation.preview(request: request, metadata: .object(record), now: Date())
        let changes = try #require(result.objectValue?["changes"]?.patchArrayValue)
        #expect(changes.count == MCPIPTCPatchPreparation.supportedFields.count)
        for change in changes {
            let object = try #require(change.objectValue)
            let field = try #require(object["field"]?.stringValue)
            #expect(object["after"] == (MCPIPTCPatchPreparation.arrayFields.contains(field)
                ? .array([.string("Value")]) : .string("Value")))
        }
    }

    @Test("Semantic normalization preserves exact input and detects no-op text and bags")
    func productionNormalization() throws {
        var record = try #require(metadata().objectValue)
        record["fields"] = .object([
            "title": .string("  Café\r\nCaption  "),
            "keywords": .array([.string(" Oslo "), .string("news"), .string("news")]),
        ])
        let requested = "Cafe\u{301}\nCaption"
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([
            operation("title", .string(requested)),
            operation("keywords", .array([.string("news"), .string(" Oslo "), .string(""), .string("news")]))]))
        let value = try #require(MCPIPTCPatchPreparation.preview(request: request, metadata: .object(record), now: Date()).objectValue)
        let changes = try #require(value["changes"]?.patchArrayValue)
        #expect(changes.count == 2)
        for change in changes { #expect(change.objectValue?["changed"] == .bool(false)) }
        #expect(changes[0].objectValue?["after"] == .array([.string("Oslo"), .string("news")]))
        #expect(changes[1].objectValue?["before"] == .string("Café\nCaption"))
        #expect(changes[1].objectValue?["after"] == .string("Café\nCaption"))
        #expect(changes[1].objectValue?["requestedValue"] == .string(requested))
        #expect(changes[1].objectValue?["sourceValue"] == .string("  Café\r\nCaption  "))
        #expect(value["schemaVersion"] == .integer(2))
        #expect(value["commitAvailable"] == .bool(false))
    }

    @Test("Explicit scalar clear normalizes absence and preserves original null")
    func absentClear() throws {
        var record = try #require(metadata().objectValue)
        record["fields"] = .object(["title": .null])
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([
            .object(["field": .string("title"), "operation": .string("clear")])]))
        let value = try MCPIPTCPatchPreparation.preview(request: request, metadata: .object(record), now: Date())
        let change = try #require(value.objectValue?["changes"]?.patchArrayValue?.first?.objectValue)
        #expect(change["before"] == .null)
        #expect(change["after"] == .null)
        #expect(change["changed"] == .bool(false))
        #expect(change["operation"] == .string("clear"))
    }

    @Test("Validation uses production mutation values and leaves unedited-field warnings out")
    func editedFieldValidation() throws {
        var record = try #require(metadata().objectValue)
        record["fields"] = .object(["title": .string(String(repeating: "x", count: 300)), "keywords": .array([])])
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([
            operation("keywords", .array([.string("  " + String(repeating: "ø", count: 32) + "  "), .string("Berg, Lina")]))]))
        let value = try MCPIPTCPatchPreparation.preview(request: request, metadata: .object(record), now: Date())
        #expect(value.objectValue?["validation"]?.objectValue?["issues"] == .array([]))
        let change = try #require(value.objectValue?["changes"]?.patchArrayValue?.first?.objectValue)
        #expect(change["after"] == .array([.string("Berg, Lina"), .string(String(repeating: "ø", count: 32))]))
        #expect(value.objectValue?["validation"]?.objectValue?["publicationProfileEvaluated"] == .bool(false))
        #expect(value.objectValue?["validation"]?.objectValue?["physicalCarrierSupportEvaluated"] == .bool(false))
    }

    @Test("Preservation preflight binds carrier bytes and RAW-safe production policy without claiming a write")
    func preservationPolicyAndIdentity() throws {
        let rootID = UUID()
        func snapshot(_ ext: String, xmp: Data? = nil) -> MCPPhotoCarrierSnapshot {
            .init(target: .init(url: URL(fileURLWithPath: "/photos/frame.\(ext)"), rootID: rootID,
                isDirectory: false, identity: .init(device: 1, inode: 2)), sourceBytes: Data([1, 2, 3]),
                xmpBytes: xmp, appSidecarBytes: nil, sourceModificationDate: Date(timeIntervalSince1970: 0),
                xmpModificationDate: nil, sourceRevision: "source", xmpSidecarRevision: "xmp", appSidecarRevision: "app")
        }
        let baseline = MetadataPreservationSnapshot(capability: .init(formatIdentifier: "raw.arw",
            domains: MetadataPreservationDomain.allCases.map { .init(domain: $0, support: .unknown) },
            c2pa: .unknown), identities: [], c2paIdentity: nil)
        let first = try MCPIPTCPatchPreparation.preservationPreflight(snapshot: snapshot("arw"), baseline: baseline)
        let second = try MCPIPTCPatchPreparation.preservationPreflight(snapshot: snapshot("arw", xmp: Data()), baseline: baseline)
        #expect(first != second) // absent and present-empty carriers are distinct.
        let policies = try #require(first.objectValue?["targetPolicyAlternatives"]?.patchArrayValue)
        #expect(policies.count == 4)
        for policy in policies {
            #expect(policy.objectValue?["writesEmbedded"] == .bool(false))
            #expect(policy.objectValue?["requiresSourceByteIdentity"] == .bool(true))
        }
        #expect(first.objectValue?["rawClassificationAgrees"] == .bool(true))
        let mismatched = try MCPIPTCPatchPreparation.preservationPreflight(snapshot: snapshot("jpg"), baseline: baseline)
        #expect(mismatched.objectValue?["rawClassificationAgrees"] == .bool(false))
        let request = try MCPIPTCPatchPreparation.Request(arguments: arguments([operation()]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata(), now: now, preflight: first)
        let b = try MCPIPTCPatchPreparation.preview(request: request, metadata: metadata(), now: now, preflight: second)
        #expect(a.objectValue?["previewID"] != b.objectValue?["previewID"])
        #expect(a.objectValue?["commitAvailable"] == .bool(false))
        #expect(throws: MCPIPTCPatchPreparation.Failure.invalidArguments) {
            try MCPIPTCPatchPreparation.preservationPreflight(snapshot: snapshot("arw"), baseline: nil)
        }
    }

    @Test("Exposed tool rejects disabled authority and advertises no mutation")
    func endpointRefusesDisabledAccess() {
        let store = MCPAuthorizationStore(readConfigurationData: { nil }, writeConfigurationData: { _ in })
        let tools = MCPFoundationTools(authorizationStore: store)
        #expect(tools.supportsTool(named: "prepare_iptc_patch"))
        let definition = tools.toolDefinitions(configuration: MCPAuthorizationConfiguration()).first {
            $0.objectValue?["name"] == .string("prepare_iptc_patch")
        }
        #expect(definition?.objectValue?["annotations"]?.objectValue?["readOnlyHint"] == .bool(true))
        #expect(definition?.objectValue?["annotations"]?.objectValue?["idempotentHint"] == .bool(false))
        let result = tools.callTool(name: "prepare_iptc_patch", arguments: arguments([operation()]))
        #expect(result.objectValue?["isError"] == .bool(true))
        #expect(result.objectValue?["structuredContent"]?.objectValue?["code"] == .string("disabled"))
    }
    @Test("Production endpoint preserves photo bytes and refuses carrier drift before publication", arguments: [false, true])
    func productionPreview(drift: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apa-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
        var args = arguments([operation()])
        args["path"] = .string(photo.path)
        for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { args[key] = read[key] }
        if drift {
            let racing = MCPAutomationFacade(authorizationStore: store, onCaptureCheckpoint: {
                try? Data("changed externally".utf8).write(to: photo)
            })
            #expect(throws: MCPAutomationReadError.photoChanged) {
                try MCPIPTCPatchPreparation.prepare(arguments: args, facade: racing)
            }
        } else {
            let tools = MCPFoundationTools(authorizationStore: store)
            let response = tools.callTool(name: "prepare_iptc_patch", arguments: args)
            #expect(response.objectValue?["isError"] == .bool(false))
            let content = try #require(response.objectValue?["structuredContent"]?.objectValue)
            #expect(content["commitAvailable"] == .bool(false))
            #expect(content["schemaVersion"] == .integer(3))
            let preflight = try #require(content["preservationPreflight"]?.objectValue)
            #expect(preflight["preservationVerified"] == .bool(false))
            #expect(preflight["writeSupportVerified"] == .bool(false))
            #expect(preflight["selectedWriteMode"] == .null)
            let carriers = try #require(preflight["carriers"]?.objectValue)
            let digest = SHA256.hash(data: bytes as Data).map { String(format: "%02x", $0) }.joined()
            #expect(carriers["source"]?.objectValue?["sha256"] == .string(digest))
            #expect(carriers["xmpSidecar"]?.objectValue?["present"] == .bool(false))
            #expect(carriers["appSidecar"]?.objectValue?["present"] == .bool(false))
            let semantic = try #require(preflight["sourceSemanticBaseline"]?.objectValue)
            #expect(semantic["capability"]?.objectValue?["formatIdentifier"] == .string("jpeg"))
            #expect(semantic["identities"]?.patchArrayValue?.count == 4)
            let endpointID = try #require(content["planID"])
            let retrieved = tools.callTool(name: "get_iptc_patch_plan", arguments: ["planID": endpointID])
            #expect(retrieved == response)
            let plans = MCPIPTCPatchPlanStore()
            let retained = try MCPIPTCPatchPreparation.prepare(arguments: args, facade: facade, plans: plans)
            let planID = try #require(retained.objectValue?["planID"])
            #expect(try plans.inspect(arguments: ["planID": planID], facade: facade) == retained)
            #expect(try Data(contentsOf: photo) == bytes as Data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["frame.jpg"])
            try Data("changed after read".utf8).write(to: photo)
            #expect(throws: MCPIPTCPatchPreparation.Failure.staleRevision) {
                try MCPIPTCPatchPreparation.prepare(arguments: args, facade: facade)
            }
            #expect(throws: MCPIPTCPatchPlanStore.Failure.stalePlan) {
                try plans.inspect(arguments: ["planID": planID], facade: facade)
            }
            // Restoring the same enabled/root values must not restore old plan authority.
            try (bytes as Data).write(to: photo)
            let restored = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { args[key] = restored[key] }
            let beforeRevocation = try MCPIPTCPatchPreparation.prepare(arguments: args, facade: facade, plans: plans)
            let revokedID = try #require(beforeRevocation.objectValue?["planID"])
            try store.setEnabled(false)
            try store.setEnabled(true)
            #expect(throws: MCPIPTCPatchPlanStore.Failure.authorityChanged) {
                try plans.inspect(arguments: ["planID": revokedID], facade: facade)
            }
        }
    }

}

private extension MCPJSONValue {
    var patchArrayValue: [MCPJSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }
}
