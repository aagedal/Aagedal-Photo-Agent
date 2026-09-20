import Foundation
import CoreGraphics
import ImageIO
import Testing
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
            "before": .string("Old headline"), "after": .string("New headline"), "changed": .bool(true)])]))
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
        #expect(validation["issues"] == .array([.object(["field": .string("title"), "severity": .string("warning"),
            "code": .string("iptc_iim_byte_limit"), "maximumUTF8BytesPerValue": .integer(256)])]))
        #expect(request.operations.last?.after == .string(text))
    }
    @Test("Exposed tool rejects disabled authority and advertises no mutation")
    func endpointRefusesDisabledAccess() {
        let store = MCPAuthorizationStore(readConfigurationData: { nil }, writeConfigurationData: { _ in })
        let tools = MCPFoundationTools(authorizationStore: store)
        #expect(tools.supportsTool(named: "prepare_iptc_patch"))
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
            let response = MCPFoundationTools(authorizationStore: store).callTool(name: "prepare_iptc_patch", arguments: args)
            #expect(response.objectValue?["isError"] == .bool(false))
            let content = try #require(response.objectValue?["structuredContent"]?.objectValue)
            #expect(content["commitAvailable"] == .bool(false))
            #expect(try Data(contentsOf: photo) == bytes as Data)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["frame.jpg"])
            try Data("changed after read".utf8).write(to: photo)
            #expect(throws: MCPIPTCPatchPreparation.Failure.staleRevision) {
                try MCPIPTCPatchPreparation.prepare(arguments: args, facade: facade)
            }
        }
    }

}
