import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Exact revision literal metadata template previews")
struct MCPMetadataTemplatePreviewTests {
    private func arguments(mode: String = "append") -> [String: MCPJSONValue] {
        ["templateID": .string(UUID().uuidString), "templateRevision": .string("sha256:" + String(repeating: "a", count: 64)),
         "mode": .string(mode), "path": .string("/photos/frame.jpg"), "sourceRevision": .string("source"),
         "xmpSidecarRevision": .string("xmp"), "appSidecarRevision": .string("app")]
    }

    private func template(_ fields: [(String, String)], instantly: Bool = false) throws -> Data {
        try JSONEncoder().encode(MetadataTemplate(name: "Preview", fields: fields.map {
            TemplateField(fieldKey: $0.0, templateValue: $0.1)
        }, processInstantly: instantly))
    }

    @Test("Literal append and replace values agree with the production editor", arguments: ["append", "replace"])
    @MainActor func editorSemantics(mode: String) throws {
        let model = MetadataViewModel(readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine())
        model.editingMetadata.title = " Existing "
        model.editingMetadata.description = "Body"
        model.editingMetadata.personShown = ["Ann"]
        model.editingMetadata.imageSupplierImageID = "old-id"
        let values = ["title": " New ", "description": "", "credit": "First", "imageSupplierImageID": "new-id",
                      "personShown": " Ann, Bob, Bob, "]
        let fields: [String: MCPJSONValue] = ["title": .string(" Existing "), "description": .string("Body"),
            "credit": .null, "imageSupplierImageID": .string("old-id"), "personShown": .array([.string("Ann")])]
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments(mode: mode))
        var metadata = request.revisions
        metadata["fields"] = .object(fields)
        metadata["hasXMPConflict"] = .bool(false)
        let preview = try MCPMetadataTemplatePreview.preview(request: request, templateFields: values, metadata: .object(metadata))
        model.applyTemplateFields(values, append: mode == "append")
        let expected: [String: MCPJSONValue] = ["title": .string(model.editingMetadata.title!),
            "description": .string(model.editingMetadata.description!), "credit": .string(model.editingMetadata.credit!),
            "imageSupplierImageID": .string(model.editingMetadata.imageSupplierImageID!),
            "personShown": .array(model.editingMetadata.personShown.map(MCPJSONValue.string))]
        guard case .array(let changes) = preview.objectValue?["changes"] else { Issue.record("Missing changes"); return }
        for change in changes {
            let object = try #require(change.objectValue)
            let key = try #require(object["field"]?.stringValue)
            #expect(object["after"] == expected[key])
        }
        #expect(preview.objectValue?["commitAvailable"] == .bool(false))
        #expect(preview.objectValue?["planID"] == nil)
    }

    @Test("Unsupported context-dependent templates fail closed")
    func rejectsUnsupported() throws {
        for (key, value) in [("keywords", "news"), ("creator", "Byline"), ("unknown", "value"),
                             ("title", "{filename}"), ("title", "{unknown}"), ("title", "\0")] {
            #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
                try MCPMetadataTemplatePreview.templateFields(template([(key, value)]))
            }
        }
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(template([]))
        }
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(template([("title", "Literal")], instantly: true))
        }
        #expect(try MCPMetadataTemplatePreview.templateFields(template([("title", "First"), ("title", "Last")])) == ["title": "Last"])
        var malformed = try #require(JSONDecoder().decode(MCPJSONValue.self, from: template([("title", "Literal")])).objectValue)
        malformed["shortcutSlot"] = .string("invalid")
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(JSONEncoder().encode(MCPJSONValue.object(malformed)))
        }
        malformed.removeValue(forKey: "shortcutSlot")
        malformed["futureBehavior"] = .bool(true)
        #expect(throws: MCPMetadataTemplatePreview.Failure.unsupportedTemplate) {
            try MCPMetadataTemplatePreview.templateFields(JSONEncoder().encode(MCPJSONValue.object(malformed)))
        }
    }

    @Test("Exact request fields and every photo revision are mandatory")
    func revisions() throws {
        for key in MCPMetadataTemplatePreview.argumentKeys {
            var args = arguments(); args.removeValue(forKey: key)
            #expect(throws: MCPMetadataTemplatePreview.Failure.invalidArguments) { try MCPMetadataTemplatePreview.Request(arguments: args) }
        }
        let request = try MCPMetadataTemplatePreview.Request(arguments: arguments())
        var metadata = request.revisions
        metadata["fields"] = .object(["title": .string("Before")])
        metadata["hasXMPConflict"] = .bool(false)
        for key in request.revisions.keys {
            var stale = metadata; stale[key] = .string("changed")
            #expect(throws: MCPMetadataTemplatePreview.Failure.staleRevision) {
                try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": "After"], metadata: .object(stale))
            }
        }
        metadata["hasXMPConflict"] = .bool(true)
        #expect(throws: MCPMetadataTemplatePreview.Failure.conflict) {
            try MCPMetadataTemplatePreview.preview(request: request, templateFields: ["title": "After"], metadata: .object(metadata))
        }
    }

    @Test("Exposed endpoint binds template and photo and leaves bytes unchanged")
    func productionEndpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apa-template-preview-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let templates = root.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: false)
        let data = try template([("title", "New")])
        let object = try #require(JSONDecoder().decode(MCPJSONValue.self, from: data).objectValue)
        let id = try #require(object["id"]?.stringValue)
        let templateURL = templates.appendingPathComponent(id + ".json")
        try data.write(to: templateURL)
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
        try store.addRoot(root); try store.setEnabled(true)
        let discovery = MCPTemplateDiscovery(authorizationStore: store,
            resolveScope: { .init(directory: templates, release: {}) })
        let inventory = try discovery.list(kind: "metadata")
        guard case .array(let entries) = inventory["templates"] else { Issue.record("Missing inventory"); return }
        let revision = try #require(entries.first?.objectValue?["revision"])
        let facade = MCPAutomationFacade(authorizationStore: store)
        let read = try #require(MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue)
        var args = arguments()
        args["templateID"] = .string(id); args["templateRevision"] = revision; args["path"] = .string(photo.path)
        for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { args[key] = read[key] }
        let tools = MCPFoundationTools(authorizationStore: store, templateDiscovery: discovery)
        let result = tools.callTool(name: "preview_metadata_template", arguments: args)
        #expect(result.objectValue?["isError"] == .bool(false))
        let preview = try #require(result.objectValue?["structuredContent"]?.objectValue)
        #expect(preview["templateRevision"] == revision)
        #expect(preview["changes"] == .array([.object(["field": .string("title"), "before": .string("Embedded"),
            "after": .string("Embedded New"), "templateValue": .string("New"), "changed": .bool(true)])]))
        #expect(try Data(contentsOf: photo) == bytes as Data)
        #expect(try Data(contentsOf: templateURL) == data)
        args["templateRevision"] = .string("sha256:" + String(repeating: "0", count: 64))
        let stale = tools.callTool(name: "preview_metadata_template", arguments: args)
        #expect(stale.objectValue?["structuredContent"]?.objectValue?["code"] == .string("stale_template"))
        args["templateRevision"] = revision
        let changing = MCPTemplateDiscovery(authorizationStore: store,
            resolveScope: { .init(directory: templates, release: {}) }, checkpoint: {
                try? Data("changed".utf8).write(to: photo)
            })
        #expect(throws: (any Error).self) {
            try MCPMetadataTemplatePreview.prepare(arguments: args, facade: facade, discovery: changing)
        }
    }
}
