import Foundation

/// A read-only, exact-revision preview of the literal template subset whose editor
/// semantics do not depend on preferences, approved lists, or variable context.
nonisolated enum MCPMetadataTemplatePreview {
    enum Failure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case staleTemplate = "stale_template"
        case unsupportedTemplate = "unsupported_template"
        case staleRevision = "stale_revision"
        case conflict = "metadata_conflict"
        case outputLimit = "result_too_large"

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Template preview requires an exact template UUID/revision, explicit photo revisions, and append or replace mode."
            case .staleTemplate: "The template UUID or revision changed. Discover templates again."
            case .unsupportedTemplate: "Preview supports nonempty literal descriptive scalar and Person Shown templates only. Variables, instant processing, keywords, and other fields require Photo Agent."
            case .staleRevision: "Photo metadata changed. Read its revisions again."
            case .conflict: "Resolve the XMP conflict in Photo Agent before previewing a template."
            case .outputLimit: "The template preview exceeds the output limit."
            }
        }
    }

    static let supportedFields = MCPIPTCPatchPreparation.scalarFields.union(["personShown"])
    static let argumentKeys: Set<String> = ["templateID", "templateRevision", "mode", "path",
                                          "sourceRevision", "xmpSidecarRevision", "appSidecarRevision"]

    struct Request: Sendable {
        let templateID: UUID
        let templateRevision: String
        let mode: String
        let path: String
        let revisions: [String: MCPJSONValue]

        init(arguments: [String: MCPJSONValue]) throws {
            guard Set(arguments.keys) == argumentKeys,
                  let id = arguments["templateID"]?.stringValue, let uuid = UUID(uuidString: id),
                  let revision = arguments["templateRevision"]?.stringValue,
                  revision.hasPrefix("sha256:"), revision.count == 71,
                  revision.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }),
                  let mode = arguments["mode"]?.stringValue, ["append", "replace"].contains(mode),
                  let path = arguments["path"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
                throw Failure.invalidArguments
            }
            var revisions: [String: MCPJSONValue] = [:]
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] {
                guard let value = arguments[key]?.stringValue, !value.isEmpty, value.utf8.count <= 256 else {
                    throw Failure.invalidArguments
                }
                revisions[key] = .string(value)
            }
            self.templateID = uuid; self.templateRevision = revision
            self.mode = mode; self.path = path; self.revisions = revisions
        }
    }

    static func prepare(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade,
                        discovery: MCPTemplateDiscovery) throws -> MCPJSONValue {
        let request = try Request(arguments: arguments)
        // Photo carriers stay retained until the template's final authority and inventory
        // checks finish. The facade then revalidates the photo before publication.
        return try facade.withPhotoSnapshot(path: request.path) { snapshot in
            guard request.revisions == ["sourceRevision": .string(snapshot.sourceRevision),
                                        "xmpSidecarRevision": .string(snapshot.xmpSidecarRevision),
                                        "appSidecarRevision": .string(snapshot.appSidecarRevision)] else {
                throw Failure.staleRevision
            }
            return try discovery.withMetadataTemplate(id: request.templateID, revision: request.templateRevision) { data in
                let fields = try templateFields(data)
                return try preview(request: request, templateFields: fields,
                                   metadata: MCPMetadataSnapshotReader.read(snapshot).protocolValue())
            }
        }
    }

    static func templateFields(_ data: Data) throws -> [String: String] {
        guard let object = try? JSONDecoder().decode(MCPJSONValue.self, from: data).objectValue,
              Set(object.keys).isSubset(of: ["schemaVersion", "id", "name", "templateType", "presetType",
                                            "fields", "shortcutSlot", "processInstantly"]),
              object["schemaVersion"] == nil || object["schemaVersion"] == .integer(1),
              let id = object["id"]?.stringValue, UUID(uuidString: id) != nil,
              object["name"]?.stringValue != nil,
              [MCPJSONValue.string("Full"), .string("Per Field")].contains(object["templateType"] ?? object["presetType"] ?? .null),
              object["processInstantly"] == nil || object["processInstantly"] == .bool(false),
              case .array(let fields) = object["fields"], !fields.isEmpty, fields.count <= 128 else {
            throw Failure.unsupportedTemplate
        }
        // The production decoder accepts only an optional integer shortcut slot.
        // Even unused malformed settings must not preview an unloadable template.
        if let slot = object["shortcutSlot"], slot != .null {
            guard case .integer = slot else { throw Failure.unsupportedTemplate }
        }
        var result: [String: String] = [:]
        for item in fields {
            guard let field = item.objectValue, Set(field.keys) == ["id", "fieldKey", "templateValue"],
                  let id = field["id"]?.stringValue, UUID(uuidString: id) != nil,
                  let key = field["fieldKey"]?.stringValue, supportedFields.contains(key),
                  let value = field["templateValue"]?.stringValue, value.utf8.count <= 32_768,
                  !value.contains("{"), !value.contains("}"), !value.contains("\0") else {
                throw Failure.unsupportedTemplate
            }
            // ContentView builds the same dictionary: the last field with a given key wins.
            result[key] = value
        }
        return result
    }

    static func preview(request: Request, templateFields: [String: String], metadata: MCPJSONValue) throws -> MCPJSONValue {
        guard let record = metadata.objectValue, let fields = record["fields"]?.objectValue,
              record["hasXMPConflict"] == .bool(false) else { throw Failure.conflict }
        for (key, value) in request.revisions where record[key] != value { throw Failure.staleRevision }
        let changes = try templateFields.keys.sorted().map { key -> MCPJSONValue in
            guard let before = fields[key], let value = templateFields[key] else { throw Failure.invalidArguments }
            let after: MCPJSONValue
            if key == "personShown" {
                guard case .array(let current) = before, current.allSatisfy({ $0.stringValue != nil }) else {
                    throw Failure.invalidArguments
                }
                let incoming = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let existing = Set(current.compactMap(\.stringValue))
                // Match the editor exactly, including duplicates within incoming values.
                after = .array(request.mode == "append"
                    ? current + incoming.filter { !existing.contains($0) }.map(MCPJSONValue.string)
                    : incoming.map(MCPJSONValue.string))
            } else {
                guard before == .null || before.stringValue != nil else { throw Failure.invalidArguments }
                let existing = before.stringValue ?? ""
                // Supplier image IDs are atomic even in the editor's Append mode.
                let append = request.mode == "append" && key != "imageSupplierImageID"
                after = .string(append && !existing.isEmpty ? (value.isEmpty ? existing : existing + " " + value) : value)
            }
            return .object(["field": .string(key), "before": before, "after": after,
                            "templateValue": .string(value), "changed": .bool(before != after)])
        }
        var result = request.revisions
        result["schemaVersion"] = .integer(1)
        result["templateID"] = .string(request.templateID.uuidString.lowercased())
        result["templateRevision"] = .string(request.templateRevision)
        result["mode"] = .string(request.mode)
        result["canonicalPath"] = record["canonicalPath"]
        result["rootID"] = record["rootID"]
        result["hasPendingChanges"] = record["hasPendingChanges"]
        result["changes"] = .array(changes)
        result["previewOnly"] = .bool(true)
        result["commitAvailable"] = .bool(false)
        result["valueSemantics"] = .string("literal-template-editor-values; no-physical-write-or-publication-validation")
        result["warnings"] = .array([.string("Read-only preview of current effective metadata, including pending drafts. No plan, approval, variable resolution, or write is created.")])
        let output = MCPJSONValue.object(result)
        guard try JSONEncoder().encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }
}
