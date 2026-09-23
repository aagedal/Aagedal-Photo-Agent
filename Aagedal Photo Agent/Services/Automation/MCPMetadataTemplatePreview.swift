import Foundation

/// A read-only, exact-revision preview of the literal template subset whose editor
/// semantics do not depend on preferences or approved lists. Recursive scalar and list field references
/// use the retained effective metadata and refuse sources changed by the template. The bounded filename
/// and list shorthand variables use only the retained photo snapshot. Sequence uses explicit request order.
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
            case .unsupportedTemplate: "Preview supports literal descriptive, creator, organisation, scene/subject, date, country, source-type, Media Topic/Genre, and Image Supplier fields only. {filename}, {persons}, {keywords}, {gps}, {latitude}, {longitude}, {dateCreated}, {dateCaptured}, {seq}, and {seq:1} through {seq:9} in title, description, extendedDescription and instructions are resolved. Recursive scalar, urgency, and canonical list {field:key} references are also supported when every source is unchanged by the template and the reference graph is acyclic. Other variables, instant processing, keyword template fields, and other structured fields require Photo Agent."
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
    // Exact canonical keys only. Formatting-dependent fields and aliases remain outside
    // this subset; scalar text matches the interpolator, and urgency uses its decimal Int form.
    static let fieldVariableSources: Set<String> = [
        "title", "description", "extendedDescription", "creatorJobTitle", "descriptionWriter",
        "credit", "copyright", "rightsUsageTerms", "webStatementOfRights", "digitalImageGUID",
        "imageSupplierImageID", "jobId", "dateCreated", "city", "sublocation", "provinceState",
        "country", "countryCode", "event", "instructions", "source", "urgency",
    ]
    // Canonical template keys map to the effective metadata's persisted array keys.
    // A reference to retained keywords is read-only. Authoring a keywords template
    // field still requires the separate Approved Keywords authority.
    static let listFieldVariableSources: Set<String> = [
        "keywords", "personShown", "creator", "organisationShownName", "organisationShownCode", "sceneCode", "subjectCode",
    ]
    static var allFieldVariableSources: Set<String> { fieldVariableSources.union(listFieldVariableSources) }
    static var fieldTokens: [String] { allFieldVariableSources.sorted().map { "{field:\($0)}" } }
    static let sequenceTokens = ["{seq}"] + (1...9).map { "{seq:\($0)}" }
    static let coordinateTokens = ["{gps}", "{latitude}", "{longitude}"]
    static let metadataDateTokens = ["{dateCreated}", "{dateCaptured}"]
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
        let tokens = ["{filename}", "{persons}", "{keywords}"] + coordinateTokens + metadataDateTokens + sequenceTokens + fieldTokens
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

    /// Check expansion before Foundation allocates the substituted string. Count ranges
    /// in the bounded template and divide the remaining capacity to avoid multiplication overflow.
    static func replacingBounded(_ token: String, in value: String, with replacement: String) throws -> String {
        let count = value.utf8.count
        guard count <= 32_768 else { throw Failure.outputLimit }
        let growth = replacement.utf8.count - token.utf8.count
        if growth > 0 {
            var occurrences = 0
            var start = value.startIndex
            while let range = value.range(of: token, range: start..<value.endIndex) {
                occurrences += 1
                start = range.upperBound
            }
            guard occurrences == 0 || growth <= (32_768 - count) / occurrences else { throw Failure.outputLimit }
        }
        return value.replacingOccurrences(of: token, with: replacement)
    }

    private static func contextualList(_ source: String, fields: [String: MCPJSONValue],
                                       templateFields: [String: String]) throws -> String {
        guard templateFields[source] == nil else { throw Failure.unsupportedTemplate }
        guard case .array(let items) = fields[source] else { throw Failure.invalidArguments }
        var remaining = 32_768
        var strings: [String] = []
        for item in items {
            guard let string = item.stringValue else { throw Failure.invalidArguments }
            let separatorBytes = strings.isEmpty ? 0 : 2
            guard string.utf8.count <= remaining - separatorBytes else { throw Failure.outputLimit }
            remaining -= string.utf8.count + separatorBytes
            guard isLiteralValue(string, for: source) else { throw Failure.unsupportedTemplate }
            strings.append(string)
        }
        return strings.joined(separator: ", ")
    }

    private static func coordinate(_ source: String, fields: [String: MCPJSONValue]) throws -> String {
        guard let captured = fields[source] else { throw Failure.invalidArguments }
        switch captured {
        case .null: return ""
        case .integer(let value): return String(format: "%.6f", Double(value))
        case .number(let value) where value.isFinite: return String(format: "%.6f", value)
        default: throw Failure.invalidArguments
        }
    }

    /// Match the production interpolator's retained-date parse and medium date style.
    /// The raw retained value is never interpolated as template text.
    private static func metadataDate(_ source: String, fields: [String: MCPJSONValue],
                                     templateFields: [String: String]) throws -> String {
        guard source != "dateCreated" || templateFields[source] == nil else { throw Failure.unsupportedTemplate }
        guard let captured = fields[source == "dateCaptured" ? "captureDate" : source],
              captured == .null || captured.stringValue != nil else { throw Failure.invalidArguments }
        let raw = captured.stringValue
        if let raw {
            guard raw.utf8.count <= 32_768, isLiteralValue(raw, for: source) else {
                throw Failure.unsupportedTemplate
            }
        }
        guard let raw, !raw.isEmpty else { return "" }
        let formats = ["yyyy:MM:dd HH:mm:ssxxx", "yyyy:MM:dd HH:mm:ss",
                       "yyyy-MM-dd'T'HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd", "yyyy-MM-dd"]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        var parsed: Date?
        for format in formats {
            parser.dateFormat = format
            if let date = parser.date(from: raw) { parsed = date; break }
        }
        if parsed == nil, raw.trimmingCharacters(in: .whitespaces).hasSuffix("Z") {
            for format in ["yyyy:MM:dd HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
                parser.dateFormat = format
                if let date = parser.date(from: raw.trimmingCharacters(in: .whitespaces)) {
                    parsed = date; break
                }
            }
        }
        guard let parsed else { return "" }
        let output = DateFormatter()
        output.dateStyle = .medium
        output.timeStyle = .none
        return output.string(from: parsed)
    }

    /// Resolve canonical field references in retained scalar and string-list values. Memoization
    /// bounds graph traversal; the active chain rejects cycles instead of publishing
    /// the production interpolator's partially unresolved cyclic result.
    private static func resolveField(_ source: String, fields: [String: MCPJSONValue],
                                     templateFields: [String: String], active: Set<String>,
                                     cache: inout [String: (value: String, sources: Set<String>)], dependencies: inout Set<String>) throws -> String {
        guard !active.contains(source), templateFields[source] == nil else { throw Failure.unsupportedTemplate }
        if let cached = cache[source] {
            dependencies.formUnion(cached.sources)
            return cached.value
        }
        var sourceDependencies: Set<String> = [source]
        guard let captured = fields[editorialKeys[source] ?? source] else { throw Failure.invalidArguments }
        var text: String
        if listFieldVariableSources.contains(source) {
            guard case .array(let items) = captured else { throw Failure.invalidArguments }
            // Bound the joined result before allocating it, including separators.
            var remaining = 32_768
            var strings: [String] = []
            for item in items {
                guard let string = item.stringValue else { throw Failure.invalidArguments }
                let separatorBytes = strings.isEmpty ? 0 : 2
                guard string.utf8.count <= remaining - separatorBytes else { throw Failure.outputLimit }
                remaining -= string.utf8.count + separatorBytes
                strings.append(string)
            }
            text = strings.joined(separator: ", ")
        } else if source == "urgency" {
            switch captured {
            case .null: text = ""
            case .integer(let number):
                guard let integer = Int(exactly: number) else { throw Failure.invalidArguments }
                text = String(integer)
            default: throw Failure.invalidArguments
            }
        } else {
            guard captured == .null || captured.stringValue != nil else { throw Failure.invalidArguments }
            text = captured.stringValue ?? ""
        }
        guard text.utf8.count <= 32_768 else { throw Failure.outputLimit }
        let literal = fieldTokens.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
        guard isLiteralValue(literal, for: source) else { throw Failure.unsupportedTemplate }
        let nestedSources = allFieldVariableSources.sorted().filter { text.contains("{field:\($0)}") }
        for dependency in nestedSources {
            let replacement = try resolveField(dependency, fields: fields, templateFields: templateFields,
                                               active: active.union([source]), cache: &cache, dependencies: &sourceDependencies)
            text = try replacingBounded("{field:\(dependency)}", in: text, with: replacement)
        }
        guard isLiteralValue(text, for: source) else { throw Failure.unsupportedTemplate }
        cache[source] = (text, sourceDependencies)
        dependencies.formUnion(sourceDependencies)
        return text
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
                value = try replacingBounded("{filename}", in: templateValue,
                    with: (filename as NSString).deletingPathExtension)
                guard value.utf8.count <= 32_768, isSupportedValue(value, for: key) else { throw Failure.outputLimit }
            } else { value = templateValue }
            let usedContextualLists = ["persons", "keywords"].filter { templateValue.contains("{\($0)}") }
            for source in usedContextualLists {
                let field = source == "persons" ? "personShown" : "keywords"
                let text = try contextualList(field, fields: fields, templateFields: templateFields)
                value = try replacingBounded("{\(source)}", in: value, with: text)
            }
            let usedCoordinateTokens = coordinateTokens.filter { templateValue.contains($0) }
            if !usedCoordinateTokens.isEmpty {
                let latitude = try coordinate("latitude", fields: fields)
                let longitude = try coordinate("longitude", fields: fields)
                let gps = latitude.isEmpty || longitude.isEmpty ? "" : "\(latitude), \(longitude)"
                for (token, text) in [("{gps}", gps), ("{latitude}", latitude), ("{longitude}", longitude)]
                    where usedCoordinateTokens.contains(token) {
                    value = try replacingBounded(token, in: value, with: text)
                }
            }
            let usedMetadataDates = metadataDateTokens.filter { templateValue.contains($0) }
            for token in usedMetadataDates {
                let source = String(token.dropFirst().dropLast())
                value = try replacingBounded(token, in: value,
                    with: metadataDate(source, fields: fields, templateFields: templateFields))
            }
            let directFieldSources = allFieldVariableSources.sorted().filter { templateValue.contains("{field:\($0)}") }
            var fieldCache: [String: (value: String, sources: Set<String>)] = [:]
            var fieldDependencies: Set<String> = []
            for source in directFieldSources {
                let text = try resolveField(source, fields: fields, templateFields: templateFields,
                                            active: [], cache: &fieldCache, dependencies: &fieldDependencies)
                value = try replacingBounded("{field:\(source)}", in: value, with: text)
                guard value.utf8.count <= 32_768 else { throw Failure.outputLimit }
            }
            let usedFieldSources = fieldDependencies.sorted()
            let usedSequenceTokens = sequenceTokens.filter { templateValue.contains($0) }
            // Width is selected from the fixed allowlist, never arbitrary template input.
            for token in usedSequenceTokens {
                let width = token == "{seq}" ? 1 : Int(token.dropFirst(5).dropLast())!
                value = value.replacingOccurrences(of: token, with: String(format: "%0\(width)d", sequenceIndex))
            }
            guard value.utf8.count <= 32_768 else { throw Failure.outputLimit }
            if templateValue.contains("{filename}") || !usedContextualLists.isEmpty || !usedCoordinateTokens.isEmpty || !usedMetadataDates.isEmpty || !usedSequenceTokens.isEmpty || !usedFieldSources.isEmpty {
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
            if templateValue.contains("{filename}") || !usedContextualLists.isEmpty || !usedCoordinateTokens.isEmpty || !usedMetadataDates.isEmpty || !usedSequenceTokens.isEmpty || !usedFieldSources.isEmpty {
                change["resolvedTemplateValue"] = .string(value)
                change["resolvedVariables"] = .array(
                    (templateValue.contains("{filename}") ? [.string("filename")] : [])
                    + usedContextualLists.map(MCPJSONValue.string)
                    + usedCoordinateTokens.map { .string(String($0.dropFirst().dropLast())) }
                    + usedMetadataDates.map { .string(String($0.dropFirst().dropLast())) }
                    + (usedSequenceTokens.isEmpty ? [] : [.string("seq")])
                    + usedFieldSources.map { .string("field:\($0)") })
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
        let resolvesContextualLists = templateFields.values.contains { $0.contains("{persons}") || $0.contains("{keywords}") }
        let resolvesCoordinates = templateFields.values.contains { value in coordinateTokens.contains { value.contains($0) } }
        let resolvesMetadataDates = templateFields.values.contains { value in metadataDateTokens.contains { value.contains($0) } }
        let resolvesSequence = templateFields.values.contains { value in sequenceTokens.contains { value.contains($0) } }
        let resolvesFields = templateFields.values.contains { value in fieldTokens.contains { value.contains($0) } }
        result["valueSemantics"] = .string(resolvesFields
            ? "retained-field-and-snapshot-template-editor-values; no-physical-write-or-publication-validation"
            : resolvesContextualLists
            ? "retained-list-and-snapshot-template-editor-values; no-physical-write-or-publication-validation"
            : resolvesCoordinates
            ? "retained-coordinate-and-snapshot-template-editor-values; no-physical-write-or-publication-validation"
            : resolvesMetadataDates
            ? "retained-date-and-snapshot-template-editor-values; no-physical-write-or-publication-validation"
            : resolvesSequence
            ? "request-order-sequence-and-snapshot-template-editor-values; no-physical-write-or-publication-validation"
            : resolvesFilename
            ? "snapshot-filename-and-literal-template-editor-values; no-physical-write-or-publication-validation"
            : "literal-template-editor-values; no-physical-write-or-publication-validation")
        result["warnings"] = .array([.string("Read-only preview of current effective metadata, including pending drafts. Supported filename, person/keyword list, GPS coordinate, metadata date, and acyclic recursive scalar/list field variables use the retained photo; sequence variables use explicit request order. No plan, approval, or write is created.")])
        let output = MCPJSONValue.object(result)
        guard try JSONEncoder().encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }
}
