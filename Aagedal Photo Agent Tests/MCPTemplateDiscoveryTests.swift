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
}
