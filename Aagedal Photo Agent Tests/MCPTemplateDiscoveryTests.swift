import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Bounded MCP template header discovery")
struct MCPTemplateDiscoveryTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apa-template-discovery-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(enabled: Bool = true, root: URL? = nil) throws -> MCPAuthorizationStore {
        let box = MCPServerCoreTests.DataBox()
        let store = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        if let root { try store.addRoot(root) }
        try store.setEnabled(enabled)
        return store
    }

    private func reader(_ store: MCPAuthorizationStore, _ root: URL,
                        checkpoint: @escaping @Sendable () -> Void = {}) -> MCPTemplateDiscovery {
        MCPTemplateDiscovery(authorizationStore: store,
                             resolveScope: { MCPTemplateDiscovery.Scope(directory: root, release: {}) },
                             checkpoint: checkpoint)
    }

    private func write(_ id: UUID, to root: URL, kind: String = "metadata", name: String = "My template") throws {
        var value: [String: MCPJSONValue] = ["id": .string(id.uuidString), "name": .string(name), "schemaVersion": .integer(1)]
        if kind == "metadata" {
            value["templateType"] = .string("Full")
            value["fields"] = .array([.object(["id": .string(UUID().uuidString), "fieldKey": .string("copyright"),
                                                "templateValue": .string("PRIVATE_TEMPLATE_VALUE")])])
        } else {
            value["settings"] = .object(["privateSetting": .string("PRIVATE_TEMPLATE_VALUE")])
        }
        try JSONEncoder().encode(MCPJSONValue.object(value)).write(to: root.appendingPathComponent("\(id.uuidString).json"))
    }

    @Test("Default local discovery requires authorization and never creates missing storage")
    func defaultLocalStorage() throws {
        let support = try folder()
        defer { try? FileManager.default.removeItem(at: support) }
        let scope = try MCPTemplateDiscovery.configuredScope(iCloudEnabled: false, bookmark: nil,
                                                            applicationSupportDirectory: support)
        defer { scope.release() }
        let expected = support.appendingPathComponent("Aagedal Photo Agent/Templates", isDirectory: true)
        #expect(scope.directory == expected)
        #expect(scope.routing == .localDefault)
        #expect(!FileManager.default.fileExists(atPath: expected.path))
        let authorization = try store(root: support)
        let access = MCPTemplateDiscovery(authorizationStore: authorization, resolveScope: {
            try MCPTemplateDiscovery.configuredScope(iCloudEnabled: false, bookmark: nil,
                                                     applicationSupportDirectory: support)
        })
        #expect(throws: MCPAuthorizationError.unavailable) { _ = try access.list(kind: "metadata") }
        #expect(!FileManager.default.fileExists(atPath: expected.path))
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        let id = UUID()
        try write(id, to: expected)
        let result = try access.list(kind: "metadata")
        guard case .array(let entries) = result["templates"] else { Issue.record("Missing templates"); return }
        #expect(entries.first?.objectValue?["id"] == .string(id.uuidString.lowercased()))
        let unauthorized = MCPTemplateDiscovery(authorizationStore: try store(), resolveScope: {
            try MCPTemplateDiscovery.configuredScope(iCloudEnabled: false, bookmark: nil,
                                                     applicationSupportDirectory: support)
        })
        #expect(throws: MCPAuthorizationError.outsideAuthorizedRoots) { _ = try unauthorized.list(kind: "metadata") }
    }

    @Test("Cloud routing and broken bookmarks never fall back to default local storage")
    func noRoutingFallback() throws {
        let support = try folder()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(throws: MCPTemplateDiscoveryError.customFolderRequired) {
            _ = try MCPTemplateDiscovery.configuredScope(iCloudEnabled: true, bookmark: nil,
                                                         applicationSupportDirectory: support)
        }
        #expect(throws: MCPTemplateDiscoveryError.staleBookmark) {
            _ = try MCPTemplateDiscovery.configuredScope(iCloudEnabled: false, bookmark: Data("invalid bookmark".utf8),
                                                         applicationSupportDirectory: support)
        }
        #expect(throws: MCPTemplateDiscoveryError.localStorageUnavailable) {
            _ = try MCPTemplateDiscovery.configuredScope(iCloudEnabled: false, bookmark: nil,
                                                         applicationSupportDirectory: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)
    }

    @Test("Routing changes invalidate publication even when both routes name the same directory")
    func sameDirectoryRoutingChange() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(UUID(), to: root)
        let changed = MCPServerCoreTests.DataBox()
        let access = MCPTemplateDiscovery(authorizationStore: try store(root: root), resolveScope: {
            MCPTemplateDiscovery.Scope(directory: root, release: {},
                                       routing: changed.read() == nil ? .localDefault : .custom(Data([1])))
        }, checkpoint: { changed.write(Data([1])) })
        #expect(throws: MCPTemplateDiscoveryError.inventoryChanged) { _ = try access.list(kind: "metadata") }
    }

    @Test("Disabled automation never resolves or accesses the template library")
    func disabled() throws {
        let access = MCPTemplateDiscovery(authorizationStore: try store(enabled: false), resolveScope: {
            Issue.record("Disabled template discovery resolved a library")
            throw MCPTemplateDiscoveryError.customFolderRequired
        })
        #expect(throws: MCPAuthorizationError.disabled) { _ = try access.list(kind: "metadata") }
    }

    @Test("A configured library still needs explicit folder authorization")
    func unauthorized() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MCPAuthorizationError.outsideAuthorizedRoots) {
            _ = try reader(store(), root).list(kind: "metadata")
        }
    }

    @Test("Discovery exposes stable UUIDs and revisions but no paths or template values")
    func metadataAndDevelop() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let develop = root.appendingPathComponent("Develop")
        try FileManager.default.createDirectory(at: develop, withIntermediateDirectories: false)
        let metadataID = UUID(), developID = UUID()
        try write(metadataID, to: root)
        try write(developID, to: develop, kind: "develop")
        let access = reader(try store(root: root), root)
        for (kind, id) in [("metadata", metadataID), ("develop", developID)] {
            let result = try access.list(kind: kind)
            guard case .array(let entries) = result["templates"] else { Issue.record("Missing templates"); return }
            #expect(entries.count == 1)
            #expect(entries.first?.objectValue?["id"] == .string(id.uuidString.lowercased()))
            #expect(entries.first?.objectValue?["revision"]?.stringValue?.hasPrefix("sha256:") == true)
            #expect(result["applicationAuthorized"] == .bool(false))
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(!encoded.contains("PRIVATE_TEMPLATE_VALUE"))
            #expect(!encoded.contains(root.path))
            #expect(try access.list(kind: kind) == result)
        }
    }

    @Test("Noncanonical duplicate IDs invalidate the complete inventory")
    func ambiguousID() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try write(id, to: root)
        try FileManager.default.copyItem(at: root.appendingPathComponent("\(id.uuidString).json"),
                                         to: root.appendingPathComponent("copy.json"))
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try reader(store(root: root), root).list(kind: "metadata") }
    }

    @Test("Malformed, newer-schema, null-schema, and linked JSON entries are not silently omitted")
    func invalidEntries() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let file = root.appendingPathComponent("\(id.uuidString).json")
        let access = reader(try store(root: root), root)
        for bytes in ["invalid", "{\"id\":\"\(id)\",\"name\":\"N\",\"schemaVersion\":2}",
                      "{\"id\":\"\(id)\",\"name\":\"N\",\"schemaVersion\":null}"] {
            try Data(bytes.utf8).write(to: file)
            #expect(throws: MCPTemplateDiscoveryError.self) { _ = try access.list(kind: "metadata") }
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try access.list(kind: "metadata") }
    }

    @Test("Peer content changes and authorization revocation invalidate publication")
    func revalidation() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try write(id, to: root)
        let authorization = try store(root: root)
        let changed = reader(authorization, root, checkpoint: {
            try? Data("changed".utf8).write(to: root.appendingPathComponent("\(id.uuidString).json"))
        })
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try changed.list(kind: "metadata") }
        try write(id, to: root)
        let revoked = reader(authorization, root, checkpoint: { try? authorization.setEnabled(false) })
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try revoked.list(kind: "metadata") }
    }

    @Test("Content changed during final scope resolution cannot publish an old revision")
    func contentChangeDuringScopeResolution() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try write(id, to: root)
        let file = root.appendingPathComponent("\(id.uuidString).json")
        let replacement = try JSONEncoder().encode(MCPJSONValue.object([
            "id": .string(id.uuidString), "name": .string("Changed during resolution"),
            "schemaVersion": .integer(1), "templateType": .string("Full"), "fields": .array([]),
        ]))
        let resolvingAgain = MCPServerCoreTests.DataBox()
        let access = MCPTemplateDiscovery(authorizationStore: try store(root: root), resolveScope: {
            if resolvingAgain.read() != nil { try replacement.write(to: file) }
            return MCPTemplateDiscovery.Scope(directory: root, release: {}, routing: .localDefault)
        }, checkpoint: { resolvingAgain.write(Data([1])) })
        #expect(throws: MCPTemplateDiscoveryError.inventoryChanged) { _ = try access.list(kind: "metadata") }
        #expect(try Data(contentsOf: file) == replacement)
    }

    @Test("Authorization revoked during final bookmark resolution prevents publication")
    func revocationDuringScopeResolution() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(UUID(), to: root)
        let authorization = try store(root: root)
        // The initial inventory checkpoint precedes the final resolver call.
        let resolvingAgain = MCPServerCoreTests.DataBox()
        let access = MCPTemplateDiscovery(
            authorizationStore: authorization,
            resolveScope: {
                if resolvingAgain.read() != nil { try authorization.setEnabled(false) }
                return MCPTemplateDiscovery.Scope(directory: root, release: {})
            },
            checkpoint: { resolvingAgain.write(Data([1])) }
        )
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try access.list(kind: "metadata") }
        #expect(try authorization.load().isEnabled == false)
    }

    @Test("Oversized names and files fail within discovery limits")
    func bounds() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let access = reader(try store(root: root), root)
        try write(id, to: root, name: String(repeating: "x", count: 1025))
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try access.list(kind: "metadata") }
        try Data(repeating: 32, count: 1_048_577).write(to: root.appendingPathComponent("\(id.uuidString).json"))
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try access.list(kind: "metadata") }
    }

    @Test("Missing Develop libraries are not created by discovery")
    func noCreation() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = reader(try store(root: root), root)
        #expect(throws: MCPAuthorizationError.unavailable) { _ = try access.list(kind: "develop") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Develop").path))
    }

    @Test("A concurrent template transaction blocks discovery")
    func reservationConflict() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = reader(try store(root: root), root)
        let held = try MCPProcessReservation.acquireFolder(root)
        defer { held.release() }
        #expect(throws: MCPProcessReservationError.self) { _ = try access.list(kind: "metadata") }
    }

    @Test("Replacing the configured directory invalidates captured descriptor evidence")
    func replacedDirectory() throws {
        let parent = try folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Templates")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let id = UUID()
        try write(id, to: root)
        let access = reader(try store(root: parent), root, checkpoint: {
            try? FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("OldTemplates"))
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        })
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try access.list(kind: "metadata") }
    }

    @Test("The tool validates kind and unexpected arguments")
    func toolArguments() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let authorization = try store(root: root)
        let tools = MCPFoundationTools(authorizationStore: authorization, templateDiscovery: reader(authorization, root))
        for arguments: [String: MCPJSONValue] in [[:], ["kind": .string("all")], ["kind": .string("metadata"), "path": .string(root.path)]] {
            let result = tools.callTool(name: "list_templates", arguments: arguments)
            #expect(result.objectValue?["isError"] == .bool(true))
            #expect(result.objectValue?["structuredContent"]?.objectValue?["code"] == .string("invalid_arguments"))
        }
        #expect(tools.callTool(name: "list_templates", arguments: ["kind": .string("metadata")]).objectValue?["isError"] == .bool(false))
    }

    private func developArguments(_ access: MCPTemplateDiscovery, id: UUID) throws -> [String: MCPJSONValue] {
        let inventory = try access.list(kind: "develop")
        guard case .array(let templates) = inventory["templates"],
              let revision = templates.first(where: { $0.objectValue?["id"] == .string(id.uuidString.lowercased()) })?
                .objectValue?["revision"] else { throw MCPTemplateDiscoveryError.invalidInventory }
        return ["templateID": .string(id.uuidString.lowercased()), "templateRevision": revision]
    }

    @Test("Develop inspection decodes production controls and crop policy without destination authority", arguments: [false, true])
    func developInspection(includesCrop: Bool) throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Develop")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var settings = CameraRawSettings()
        settings.exposure2012 = 1.25
        settings.crop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 3, hasCrop: true)
        settings.asShotNeutralTemperature = 6400
        settings.asShotNeutralTint = 4
        settings.sourceHasHDRHeadroom = true
        let template = DevelopTemplate(name: "Exposure", settings: settings, includesCrop: includesCrop)
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        let bytes = try JSONEncoder().encode(template)
        try bytes.write(to: url)
        let authorization = try store(root: root)
        let access = reader(authorization, root)
        let arguments = try developArguments(access, id: template.id)
        let tools = MCPFoundationTools(authorizationStore: authorization, templateDiscovery: access)
        let result = tools.callTool(name: "inspect_develop_template", arguments: arguments)
        #expect(result.objectValue?["isError"] == .bool(false))
        let content = try #require(result.objectValue?["structuredContent"]?.objectValue)
        let controls = try #require(content["controls"]?.objectValue)
        #expect(controls["exposure2012"] == .number(1.25))
        #expect((controls["crop"] != nil) == includesCrop)
        for key in ["asShotNeutralTemperature", "asShotNeutralTint", "sourceHasHDRHeadroom", "unparsedMaskCorrections"] {
            #expect(controls[key] == nil)
        }
        #expect(content["cropPolicy"] == .string(includesCrop ? "apply-template-crop" : "preserve-destination-crop"))
        #expect(content["inspectionOnly"] == .bool(true))
        #expect(content["applicationAvailable"] == .bool(false))
        #expect(content["destinationStateRequired"] == .bool(true))
        #expect(content["layerIdentifiersMustBeRegenerated"] == .bool(true))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
        let definition = try #require(tools.toolDefinitions(configuration: try authorization.load()).first {
            $0.objectValue?["name"] == .string("inspect_develop_template")
        }?.objectValue)
        #expect(definition["annotations"]?.objectValue?["readOnlyHint"] == .bool(true))
        #expect(definition["inputSchema"]?.objectValue?["additionalProperties"] == .bool(false))
    }

    @Test("Develop inspection refuses stale identity, malformed production settings and inventory drift")
    func developInspectionRefusals() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Develop")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let template = DevelopTemplate(name: "Exposure")
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try JSONEncoder().encode(template).write(to: url)
        let authorization = try store(root: root)
        let access = reader(authorization, root)
        let arguments = try developArguments(access, id: template.id)
        var stale = arguments; stale["templateRevision"] = .string("sha256:" + String(repeating: "0", count: 64))
        #expect(throws: MCPMetadataTemplatePreview.Failure.staleTemplate) { _ = try access.inspectDevelopTemplate(arguments: stale) }
        let changed = reader(authorization, root, checkpoint: { try? Data("changed".utf8).write(to: url) })
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try changed.inspectDevelopTemplate(arguments: arguments) }
        let malformed: [String: MCPJSONValue] = ["schemaVersion": .integer(1), "id": .string(template.id.uuidString),
            "name": .string("Malformed"), "settings": .object(["exposure2012": .string("bad")])]
        try JSONEncoder().encode(MCPJSONValue.object(malformed)).write(to: url)
        let malformedArguments = try developArguments(access, id: template.id)
        #expect(throws: MCPTemplateDiscoveryError.invalidInventory) { _ = try access.inspectDevelopTemplate(arguments: malformedArguments) }
    }

    @Test("Develop inspection refuses extra/noncanonical arguments and disabled authority before access")
    func developInspectionArguments() throws {
        let authorization = try store(enabled: false)
        let access = MCPTemplateDiscovery(authorizationStore: authorization, resolveScope: {
            Issue.record("Invalid/disabled inspection resolved template storage")
            throw MCPTemplateDiscoveryError.invalidInventory
        })
        let tools = MCPFoundationTools(authorizationStore: authorization, templateDiscovery: access)
        let valid: [String: MCPJSONValue] = ["templateID": .string(UUID().uuidString.lowercased()),
            "templateRevision": .string("sha256:" + String(repeating: "a", count: 64))]
        var extra = valid; extra["path"] = .string("/photos/frame.jpg")
        var uppercase = valid; uppercase["templateID"] = .string(UUID().uuidString.uppercased())
        var invalidRevision = valid; invalidRevision["templateRevision"] = .string("sha256:" + String(repeating: "A", count: 64))
        for arguments in [[:], extra, uppercase, invalidRevision] {
            #expect(tools.callTool(name: "inspect_develop_template", arguments: arguments)
                .objectValue?["structuredContent"]?.objectValue?["code"] == .string("invalid_arguments"))
        }
        #expect(throws: MCPAuthorizationError.disabled) { _ = try access.inspectDevelopTemplate(arguments: valid) }
    }

    @Test("Develop inspection preserves legacy crop semantics and refuses revoked authority and oversized controls")
    func developInspectionLegacyAndBounds() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Develop")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        let legacy: [String: MCPJSONValue] = ["id": .string(id.uuidString), "name": .string("Legacy"),
            "settings": .object(["crop": .object(["hasCrop": .bool(true), "top": .number(0.1), "left": .number(0.2),
                "bottom": .number(0.9), "right": .number(0.8), "angle": .integer(0)])])]
        let original = try JSONEncoder().encode(MCPJSONValue.object(legacy))
        try original.write(to: url)
        let authorization = try store(root: root)
        let access = reader(authorization, root)
        let arguments = try developArguments(access, id: id)
        let content = try access.inspectDevelopTemplate(arguments: arguments)
        #expect(content["cropPolicy"] == .string("apply-template-crop"))
        #expect(content["controls"]?.objectValue?["crop"]?.objectValue?["hasCrop"] == .bool(true))
        let revoked = reader(authorization, root, checkpoint: { try? authorization.setEnabled(false) })
        #expect(throws: MCPTemplateDiscoveryError.self) { _ = try revoked.inspectDevelopTemplate(arguments: arguments) }
        #expect(try Data(contentsOf: url) == original)
        try authorization.setEnabled(true)
        var oversized = legacy
        oversized["settings"] = .object(["version": .string(String(repeating: "v", count: MCPServerConstants.maximumToolResultBytes))])
        let oversizedBytes = try JSONEncoder().encode(MCPJSONValue.object(oversized))
        try oversizedBytes.write(to: url)
        let oversizedArguments = try developArguments(access, id: id)
        #expect(throws: MCPMetadataTemplatePreview.Failure.outputLimit) {
            _ = try access.inspectDevelopTemplate(arguments: oversizedArguments)
        }
        #expect(try Data(contentsOf: url) == oversizedBytes)
    }
}
