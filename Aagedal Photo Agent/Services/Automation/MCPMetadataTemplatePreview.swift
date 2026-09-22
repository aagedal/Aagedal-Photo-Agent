import Foundation

/// A read-only, exact-revision preview of the literal template subset whose editor
/// semantics do not depend on preferences or approved lists. The bounded filename
/// variable uses only the retained photo snapshot. Sequence uses explicit request order.
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
            case .unsupportedTemplate: "Preview supports literal descriptive, creator, organisation, scene/subject, date, country, source-type, Media Topic/Genre, and Image Supplier fields only. Only {filename}, {seq}, and {seq:1} through {seq:9} in title, description, extendedDescription and instructions are resolved. Other variables, instant processing, keywords, and other structured fields require Photo Agent."
            case .staleRevision: "Photo metadata changed. Read its revisions again."
            case .conflict: "Resolve the XMP conflict in Photo Agent before previewing a template."
            case .outputLimit: "The template preview exceeds the output limit."
            }
        }
    }

    // Template editor keys differ from the persisted editorial keys exposed by metadata reads.
    static let editorialKeys = ["creator": "creators", "organisationShownName": "organisationsShownNames",
                                "organisationShownCode": "organisationsShownCodes", "sceneCode": "sceneCodes",
                                "subjectCode": "subjectCodes", "mediaTopic": "mediaTopics",
                                "genre": "genres", "imageSupplier": "imageSuppliers"]
    static let supportedFields = MCPIPTCPatchPreparation.scalarFields.union([
        "personShown", "creator", "organisationShownName", "organisationShownCode", "sceneCode", "subjectCode",
        "webStatementOfRights", "digitalImageGUID", "dateCreated", "countryCode", "digitalSourceType", "urgency",
        "mediaTopic", "genre", "imageSupplier",
    ])
    static let filenameVariableFields: Set<String> = ["title", "description", "extendedDescription", "instructions"]
    static let sequenceTokens = ["{seq}"] + (1...9).map { "{seq:\($0)}" }
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
                  isSupportedValue(value, for: key) else {
                throw Failure.unsupportedTemplate
            }
            // ContentView builds the same dictionary: the last field with a given key wins.
            result[key] = value
        }
        return result
    }

    private static func isSupportedValue(_ value: String, for key: String) -> Bool {
        let tokens = ["{filename}"] + sequenceTokens
        let candidate = filenameVariableFields.contains(key)
            ? tokens.reduce(value) { $0.replacingOccurrences(of: $1, with: "") } : value
        return isLiteralValue(candidate, for: key)
    }

    /// JSON punctuation is permitted in structured transport, but every decoded string is
    /// still literal. Inspect even ignored keys/values so escaped placeholders cannot cross
    /// this boundary and acquire variable-processing semantics in a later implementation.
    private static func isLiteralValue(_ value: String, for key: String) -> Bool {
        func literal(_ text: String) -> Bool {
            !text.contains("{") && !text.contains("}") && !text.contains("(number)") && !text.contains("\0")
        }
        if ["mediaTopic", "genre", "imageSupplier"].contains(key),
           (try? JSONDecoder().decode(MCPJSONValue.self, from: Data(value.utf8))) != nil {
            // Scan the transport's string tokens, not a decoded dictionary: duplicate
            // object keys may discard an earlier value that still contains a variable.
            // The complete JSON decode above establishes syntax; decoding each quoted
            // token below also exposes Unicode escapes in every key and value.
            let bytes = Array(value.utf8)
            var index = 0
            while index < bytes.count {
                guard bytes[index] == 0x22 else { index += 1; continue }
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x5C { index += 2; continue }
                    if bytes[index] == 0x22 { break }
                    index += 1
                }
                guard index < bytes.count,
                      let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index])),
                      literal(text) else { return false }
                index += 1
            }
            return true
        }
        guard literal(value) else { return false }
        return key != "creator" || IPTCMetadata.creators(fromTransportValue: value).allSatisfy(literal)
    }

    static func preview(request: Request, templateFields: [String: String], metadata: MCPJSONValue, sequenceIndex: Int = 1) throws -> MCPJSONValue {
        guard (1...MCPMetadataTemplateBatchPreview.maximumPhotos).contains(sequenceIndex) else { throw Failure.invalidArguments }
        guard let record = metadata.objectValue, let fields = record["fields"]?.objectValue,
              record["hasXMPConflict"] == .bool(false) else { throw Failure.conflict }
        for (key, value) in request.revisions where record[key] != value { throw Failure.staleRevision }
        let changes = try templateFields.keys.sorted().map { key -> MCPJSONValue in
            let editorialKey = editorialKeys[key] ?? key
            guard supportedFields.contains(key), let before = fields[editorialKey], let templateValue = templateFields[key],
                  templateValue.utf8.count <= 32_768, isSupportedValue(templateValue, for: key) else { throw Failure.invalidArguments }
            var value: String
            if templateValue.contains("{filename}") {
                guard let path = record["canonicalPath"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
                    throw Failure.invalidArguments
                }
                let filename = URL(fileURLWithPath: path).lastPathComponent
                // Refuse second-order placeholders in a filename before the production
                // interpolator can interpret them as additional variable authority, including
                // a sequence token also present in the approved template itself.
                guard isLiteralValue(filename, for: key) else { throw Failure.unsupportedTemplate }
                // Matches the production interpolator's filename-only substitution. The
                // helper target deliberately excludes its app/voice-memo dependencies;
                // parity is tested against PresetVariableInterpolator in the app target.
                value = templateValue.replacingOccurrences(of: "{filename}",
                    with: (filename as NSString).deletingPathExtension)
                guard value.utf8.count <= 32_768, isSupportedValue(value, for: key) else { throw Failure.outputLimit }
            } else { value = templateValue }
            let usedSequenceTokens = sequenceTokens.filter { templateValue.contains($0) }
            // Width is selected from the fixed allowlist, never arbitrary template input.
            for token in usedSequenceTokens {
                let width = token == "{seq}" ? 1 : Int(token.dropFirst(5).dropLast())!
                value = value.replacingOccurrences(of: token, with: String(format: "%0\(width)d", sequenceIndex))
            }
            guard value.utf8.count <= 32_768 else { throw Failure.outputLimit }
            if templateValue.contains("{filename}") || !usedSequenceTokens.isEmpty {
                guard isLiteralValue(value, for: key) else { throw Failure.unsupportedTemplate }
            }
            let after: MCPJSONValue
            if ["mediaTopic", "genre", "imageSupplier"].contains(key) {
                guard case .array = before else { throw Failure.invalidArguments }
                let beforeData = try JSONEncoder().encode(before)
                let afterData: Data
                if key == "imageSupplier" {
                    guard let existing = try? JSONDecoder().decode([EditorialImageSupplier].self, from: beforeData) else {
                        throw Failure.invalidArguments
                    }
                    if let incoming = EditorialImageSupplier.values(fromCanonicalJSONString: value) {
                        let combined = request.mode == "append"
                            ? EditorialImageSupplier.normalizedValues(existing + incoming) : incoming
                        afterData = try JSONEncoder().encode(combined)
                    } else {
                        // Invalid supplier transport is ignored by applyTemplateFields.
                        afterData = beforeData
                    }
                } else {
                    guard let existing = try? JSONDecoder().decode([IPTCControlledVocabularyTerm].self, from: beforeData) else {
                        throw Failure.invalidArguments
                    }
                    let incoming = IPTCControlledVocabularyTerm.terms(fromTemplateValue: value) {
                        key == "mediaTopic" ? IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0)
                            : IPTCControlledVocabularyTerm.genre(metadataValue: $0)
                    }
                    let combined = request.mode == "append"
                        ? IPTCControlledVocabularyTerm.normalizedValues(existing + incoming) : incoming
                    afterData = try JSONEncoder().encode(combined)
                }
                after = try JSONDecoder().decode(MCPJSONValue.self, from: afterData)
            } else if ["personShown", "creator", "organisationShownName", "organisationShownCode", "sceneCode", "subjectCode"].contains(key) {
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
                "templateValue": .string(templateValue), "changed": .bool(before != after)]
            if templateValue.contains("{filename}") || !usedSequenceTokens.isEmpty {
                change["resolvedTemplateValue"] = .string(value)
                change["resolvedVariables"] = .array(
                    (templateValue.contains("{filename}") ? [.string("filename")] : [])
                    + (usedSequenceTokens.isEmpty ? [] : [.string("seq")]))
                if !usedSequenceTokens.isEmpty { change["sequenceIndex"] = .integer(Int64(sequenceIndex)) }
            }
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
        let resolvesFilename = templateFields.values.contains { $0.contains("{filename}") }
        let resolvesSequence = templateFields.values.contains { value in sequenceTokens.contains { value.contains($0) } }
        result["valueSemantics"] = .string(resolvesSequence
            ? "request-order-sequence-and-snapshot-template-editor-values; no-physical-write-or-publication-validation"
            : resolvesFilename
            ? "snapshot-filename-and-literal-template-editor-values; no-physical-write-or-publication-validation"
            : "literal-template-editor-values; no-physical-write-or-publication-validation")
        result["warnings"] = .array([.string("Read-only preview of current effective metadata, including pending drafts. Supported filename variables use the retained photo; sequence variables use explicit request order. No plan, approval, or write is created.")])
        let output = MCPJSONValue.object(result)
        guard try JSONEncoder().encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }
}
