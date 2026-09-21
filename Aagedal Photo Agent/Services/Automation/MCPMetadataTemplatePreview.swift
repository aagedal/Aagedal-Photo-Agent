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
            case .unsupportedTemplate: "Preview supports literal descriptive, creator, organisation, scene/subject, date, country, and source-type fields only. Variables, instant processing, keywords, and structured fields require Photo Agent."
            case .staleRevision: "Photo metadata changed. Read its revisions again."
            case .conflict: "Resolve the XMP conflict in Photo Agent before previewing a template."
            case .outputLimit: "The template preview exceeds the output limit."
            }
        }
    }

    // Template editor keys differ from the persisted editorial keys exposed by metadata reads.
    static let editorialKeys = ["creator": "creators", "organisationShownName": "organisationsShownNames",
                                "organisationShownCode": "organisationsShownCodes", "sceneCode": "sceneCodes",
                                "subjectCode": "subjectCodes"]
    static let supportedFields = MCPIPTCPatchPreparation.scalarFields.union([
        "personShown", "creator", "organisationShownName", "organisationShownCode", "sceneCode", "subjectCode",
        "webStatementOfRights", "digitalImageGUID", "dateCreated", "countryCode", "digitalSourceType", "urgency",
    ])
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
                  !value.contains("{"), !value.contains("}"), !value.contains("(number)"), !value.contains("\0") else {
                throw Failure.unsupportedTemplate
            }
            // Creator transport may encode text via JSON escapes; inspect decoded entries too.
            if key == "creator" {
                guard IPTCMetadata.creators(fromTransportValue: value).allSatisfy({
                    !$0.contains("{") && !$0.contains("}") && !$0.contains("(number)") && !$0.contains("\0")
                }) else { throw Failure.unsupportedTemplate }
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
            let editorialKey = editorialKeys[key] ?? key
            guard supportedFields.contains(key), let before = fields[editorialKey], let value = templateFields[key],
                  !value.contains("{"), !value.contains("}"), !value.contains("(number)"), !value.contains("\0") else { throw Failure.invalidArguments }
            let after: MCPJSONValue
            if ["personShown", "creator", "organisationShownName", "organisationShownCode", "sceneCode", "subjectCode"].contains(key) {
                guard case .array(let current) = before, current.allSatisfy({ $0.stringValue != nil }) else {
                    throw Failure.invalidArguments
                }
                let existing = current.compactMap(\.stringValue)
                let incoming: [String]
                switch key {
                case "creator": incoming = IPTCMetadata.creators(fromTransportValue: value)
                case "sceneCode": incoming = IPTCSceneCode.normalizedValues(value.components(separatedBy: CharacterSet(charactersIn: ",;")))
                case "subjectCode": incoming = IPTCSubjectCode.normalizedValues(value.components(separatedBy: CharacterSet(charactersIn: ",;")))
                default:
                    let whitespace: CharacterSet = key == "personShown" ? .whitespaces : .whitespacesAndNewlines
                    incoming = value.split(separator: ",").map { String($0).trimmingCharacters(in: whitespace) }
                }
                let combined: [String]
                if request.mode == "replace" { combined = incoming }
                else if key == "creator" { combined = IPTCMetadata.normalizedCreators(existing + incoming) }
                else if key == "subjectCode" { combined = IPTCSubjectCode.normalizedValues(existing + incoming) }
                else {
                    let known = Set(existing)
                    // The editor retains duplicate incoming people/organisations, and existing scene values.
                    combined = existing + incoming.filter { !known.contains($0) }
                }
                after = .array(combined.map(MCPJSONValue.string))
            } else if key == "urgency" {
                switch before {
                case .null, .integer: break
                default: throw Failure.invalidArguments
                }
                // Match the editor's Int conversion, including its nil result for malformed input.
                after = Int(value).map { .integer(Int64($0)) } ?? .null
            } else {
                guard before == .null || before.stringValue != nil else { throw Failure.invalidArguments }
                switch key {
                case "countryCode": after = ISO3166Country.normalizedAlpha3(value).map(MCPJSONValue.string) ?? .null
                case "digitalSourceType": after = DigitalSourceType(metadataValue: value).map { .string($0.rawValue) } ?? .null
                case "dateCreated":
                    // Invalid dates are ignored by applyTemplateFields, including an empty literal.
                    after = (try? EditorialDateCreated(parsing: value)) != nil ? .string(value) : before
                default:
                    let existing = before.stringValue ?? ""
                    let append = request.mode == "append" && !["imageSupplierImageID", "digitalImageGUID"].contains(key)
                    after = .string(append && !existing.isEmpty ? (value.isEmpty ? existing : existing + " " + value) : value)
                }
            }
            var change: [String: MCPJSONValue] = ["field": .string(editorialKey), "before": before, "after": after,
                "templateValue": .string(value), "changed": .bool(before != after)]
            if editorialKey != key { change["templateField"] = .string(key) }
            return .object(change)
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
