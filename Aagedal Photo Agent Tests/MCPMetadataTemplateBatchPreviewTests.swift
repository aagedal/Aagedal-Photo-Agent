import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Retained exact-template batch previews")
struct MCPMetadataTemplateBatchPreviewTests {
    private func arguments(_ photos: [MCPJSONValue]) -> [String: MCPJSONValue] {
        ["templateID": .string(UUID().uuidString), "templateRevision": .string("sha256:" + String(repeating: "a", count: 64)),
         "mode": .string("append"), "photos": .array(photos)]
    }
    private func photo(_ path: String) -> MCPJSONValue {
        .object(["path": .string(path), "sourceRevision": .string("s"), "xmpSidecarRevision": .string("x"), "appSidecarRevision": .string("a")])
    }

    @Test("Empty, oversized, duplicate and shared-sidecar batches are rejected")
    func invalidBatches() throws {
        for photos in [[], Array(repeating: photo("/p/a.jpg"), count: 9),
                       [photo("/p/a.jpg"), photo("/p/a.jpg")], [photo("/p/a.jpg"), photo("/p/A.ARW")],
                       [photo("/p/a.jpg"), photo("/p/nested/../a.jpg")],
                       [.object(["path": .string("/p/a.jpg")])], [.string("/p/a.jpg")]] {
            #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
                try MCPMetadataTemplateBatchPreview.requests(arguments: arguments(photos))
            }
        }
        for key in MCPMetadataTemplateBatchPreview.argumentKeys {
            var args = arguments([photo("/p/a.jpg")]); args.removeValue(forKey: key)
            #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
                try MCPMetadataTemplateBatchPreview.requests(arguments: args)
            }
        }
        var extraTopLevel = arguments([photo("/p/a.jpg")]); extraTopLevel["approve"] = .bool(true)
        #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
            try MCPMetadataTemplateBatchPreview.requests(arguments: extraTopLevel)
        }
        var extraPhoto = try #require(photo("/p/a.jpg").objectValue); extraPhoto["mode"] = .string("replace")
        #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) {
            try MCPMetadataTemplateBatchPreview.requests(arguments: arguments([.object(extraPhoto)]))
        }
        #expect(try MCPMetadataTemplateBatchPreview.requests(arguments: arguments([photo("/p/a.jpg"), photo("/p/b.jpg")])).count == 2)
        #expect(try MCPMetadataTemplateBatchPreview.requests(arguments: arguments((0..<8).map { photo("/p/\($0).jpg") })).count == 8)
    }

    @Test("Batch endpoint preserves requested order, photo bytes and all-or-error authority", arguments: ["suffix", "Photo {filename}", "Photo {filename} / {seq} / {seq:3}"])
    func endpoint(templateValue: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apa-batch-preview-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let template = MetadataTemplate(name: "Batch", fields: [TemplateField(fieldKey: "title", templateValue: templateValue)])
        let data = try JSONEncoder().encode(template)
        let templateURL = directory.appendingPathComponent(template.id.uuidString + ".json")
        try data.write(to: templateURL)
        let pixels = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(pixels.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let photos = [root.appendingPathComponent("z.jpg"), root.appendingPathComponent("a.jpg")]
        for photo in photos { try (bytes as Data).write(to: photo) }
        let box = MCPServerCoreTests.DataBox()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try store.addRoot(root); try store.setEnabled(true)
        let discovery = MCPTemplateDiscovery(authorizationStore: store, resolveScope: { .init(directory: directory, release: {}) })
        let inventory = try discovery.list(kind: "metadata")
        guard case .array(let entries) = inventory["templates"] else { Issue.record("Missing templates"); return }
        let entry = try #require(entries.first?.objectValue)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let inputs = try photos.map { photo -> MCPJSONValue in
            let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
            var item = read.filter { MCPMetadataTemplateBatchPreview.photoKeys.contains($0.key) }
            item["path"] = .string(photo.path)
            return .object(item)
        }
        var args = arguments(inputs)
        args["templateID"] = entry["id"]; args["templateRevision"] = entry["revision"]
        let tools = MCPFoundationTools(authorizationStore: store, templateDiscovery: discovery)
        let result = tools.callTool(name: "preview_metadata_template_batch", arguments: args)
        #expect(result.objectValue?["isError"] == .bool(false))
        let content = try #require(result.objectValue?["structuredContent"]?.objectValue)
        guard case .array(let previews) = content["photos"] else { Issue.record("Missing photos"); return }
        #expect(previews.compactMap { $0.objectValue?["canonicalPath"]?.stringValue } == photos.map(\.path))
        #expect(content["commitAvailable"] == .bool(false))
        #expect(content["photoCount"] == .integer(2))
        for (index, preview) in previews.enumerated() {
            var expected: [String: MCPJSONValue] = [
                "field": .string("title"), "before": .null, "after": .string("suffix"),
                "templateValue": .string("suffix"), "changed": .bool(true),
            ]
            if templateValue.contains("{") {
                let resolved = PresetVariableInterpolator().resolve(templateValue,
                    filename: photos[index].lastPathComponent, sequenceIndex: index + 1)
                expected["after"] = .string(resolved)
                expected["templateValue"] = .string(templateValue)
                expected["resolvedTemplateValue"] = .string(resolved)
                expected["resolvedVariables"] = .array(templateValue.contains("{seq")
                    ? [.string("filename"), .string("seq")] : [.string("filename")])
                if templateValue.contains("{seq") { expected["sequenceIndex"] = .integer(Int64(index + 1)) }
            }
            #expect(preview.objectValue?["changes"] == .array([.object(expected)]))
        }
        for photo in photos { #expect(try Data(contentsOf: photo) == bytes as Data) }
        #expect(try Data(contentsOf: templateURL) == data)
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            try MCPMetadataTemplateBatchPreview.prepare(arguments: args, facade: facade, discovery: discovery, maximumBytes: 1)
        }
        var staleInputs = inputs
        var stale = try #require(inputs[1].objectValue); stale["appSidecarRevision"] = .string("stale")
        staleInputs[1] = .object(stale)
        var staleArgs = args; staleArgs["photos"] = .array(staleInputs)
        let failure = tools.callTool(name: "preview_metadata_template_batch", arguments: staleArgs)
        #expect(failure.objectValue?["isError"] == .bool(true))
        #expect(failure.objectValue?["structuredContent"]?.objectValue?["photos"] == nil)
        // Exact-template drift and revoked authorization must suppress the entire result.
        var staleTemplate = args
        staleTemplate["templateRevision"] = .string("sha256:" + String(repeating: "0", count: 64))
        let staleResult = tools.callTool(name: "preview_metadata_template_batch", arguments: staleTemplate)
        #expect(staleResult.objectValue?["isError"] == .bool(true))
        #expect(staleResult.objectValue?["structuredContent"]?.objectValue?["code"] == .string("stale_template"))
        #expect(staleResult.objectValue?["structuredContent"]?.objectValue?["photos"] == nil)
        let revoked = MCPTemplateDiscovery(authorizationStore: store,
            resolveScope: { .init(directory: directory, release: {}) }, checkpoint: {
                try? store.setEnabled(false)
            })
        #expect(throws: (any Error).self) {
            try MCPMetadataTemplateBatchPreview.prepare(arguments: args, facade: facade, discovery: revoked)
        }
        try store.setEnabled(true)
        #expect(tools.callTool(name: "preview_metadata_template_batch", arguments: args).objectValue?["isError"] == .bool(false))
        // Change the alphabetically first photo after every result has been assembled.
        // Its outer retained descriptor must catch the change before publication.
        let changing = MCPTemplateDiscovery(authorizationStore: store,
            resolveScope: { .init(directory: directory, release: {}) }, checkpoint: {
                try? Data("replaced".utf8).write(to: photos[1])
            })
        #expect(throws: (any Error).self) {
            try MCPMetadataTemplateBatchPreview.prepare(arguments: args, facade: facade, discovery: changing)
        }
        try (bytes as Data).write(to: photos[1])
        // Failure unwinds every reservation, permitting an immediate new request.
        let refreshed = try photos.map { photo -> MCPJSONValue in
            let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
            var item = read.filter { MCPMetadataTemplateBatchPreview.photoKeys.contains($0.key) }
            item["path"] = .string(photo.path); return .object(item)
        }
        args["photos"] = .array(refreshed)
        #expect(tools.callTool(name: "preview_metadata_template_batch", arguments: args).objectValue?["isError"] == .bool(false))
    }
}
