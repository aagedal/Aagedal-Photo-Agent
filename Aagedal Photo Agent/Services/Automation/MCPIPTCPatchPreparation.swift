import CryptoKit
import Foundation

/// Pure, revision-bound proofreading previews. No result from this service authorizes a write.
nonisolated enum MCPIPTCPatchPreparation {
    enum Failure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unsupportedField = "unsupported_patch_field"
        case staleRevision = "stale_revision"
        case conflict = "metadata_conflict"
        case outputLimit = "result_too_large"
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Patch requires exact revision strings and unique supported fields with typed set or clear operations. Empty set values require an explicit clear."
            case .unsupportedField: "This field is not supported by the descriptive proofreading preview."
            case .staleRevision: "Photo metadata changed since it was read. Read it again before preparing a patch."
            case .conflict: "Resolve the existing XMP conflict in Photo Agent before preparing a patch."
            case .outputLimit: "The patch preview exceeds the output limit."
            }
        }
    }

    static let scalarFields: Set<String> = [
        "title", "description", "extendedDescription", "creatorJobTitle", "descriptionWriter",
        "credit", "copyright", "rightsUsageTerms", "imageSupplierImageID", "jobId", "city",
        "sublocation", "provinceState", "country", "event", "instructions", "source",
    ]
    static let arrayFields: Set<String> = ["keywords", "personShown"]
    static let supportedFields = scalarFields.union(arrayFields)
    static let argumentKeys: Set<String> = ["path", "sourceRevision", "xmpSidecarRevision", "appSidecarRevision", "operations"]

    struct Request: Sendable {
        let path: String
        let revisions: [String: MCPJSONValue]
        let operations: [Operation]
        init(arguments: [String: MCPJSONValue]) throws {
            guard Set(arguments.keys) == argumentKeys,
                  let path = arguments["path"]?.stringValue, path.hasPrefix("/"),
                  case .array(let values) = arguments["operations"],
                  !values.isEmpty, values.count <= supportedFields.count else { throw Failure.invalidArguments }
            var revisions: [String: MCPJSONValue] = [:]
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] {
                guard let value = arguments[key]?.stringValue, !value.isEmpty, value.utf8.count <= 256 else {
                    throw Failure.invalidArguments
                }
                revisions[key] = .string(value)
            }
            var seen = Set<String>()
            var operations: [Operation] = []
            var bytes = 0
            for value in values {
                guard let object = value.objectValue, let field = object["field"]?.stringValue,
                      let kind = object["operation"]?.stringValue else { throw Failure.invalidArguments }
                guard supportedFields.contains(field) else { throw Failure.unsupportedField }
                guard seen.insert(field).inserted else { throw Failure.invalidArguments }
                let normalized: MCPJSONValue
                if kind == "clear" {
                    guard Set(object.keys) == ["field", "operation"] else { throw Failure.invalidArguments }
                    normalized = arrayFields.contains(field) ? .array([]) : .string("")
                } else if kind == "set" {
                    guard Set(object.keys) == ["field", "operation", "value"] else { throw Failure.invalidArguments }
                    if scalarFields.contains(field) {
                        guard let text = object["value"]?.stringValue, text.utf8.count <= 32_768,
                              !text.contains("\0") else { throw Failure.invalidArguments }
                        bytes += text.utf8.count
                        normalized = .string(text)
                    } else {
                        guard case .array(let items) = object["value"], items.count <= 128 else { throw Failure.invalidArguments }
                        for item in items {
                            guard let text = item.stringValue, text.utf8.count <= 1_024, !text.contains("\0") else {
                                throw Failure.invalidArguments
                            }
                            bytes += text.utf8.count
                        }
                        normalized = .array(items)
                    }
                } else { throw Failure.invalidArguments }
                guard bytes <= 65_536 else { throw Failure.invalidArguments }
                let operation = Operation(field: field, kind: kind, after: normalized)
                // Share the editor's typed intent boundary, including explicit-empty rejection.
                var candidate = IPTCMetadata()
                try operation.apply(to: &candidate)
                operations.append(operation)
            }
            self.path = path; self.revisions = revisions
            self.operations = operations.sorted { $0.field < $1.field }
        }
    }

    struct Operation: Sendable {
        let field: String
        let kind: String
        let after: MCPJSONValue

        var fieldID: MetadataFieldID { MetadataFieldID(rawValue: field)! }
        var verificationField: IPTCMetadataVerificationField {
            field == "title" ? .headline : IPTCMetadataVerificationField(rawValue: field)!
        }

        func apply(to metadata: inout IPTCMetadata) throws {
            let mutation: MetadataFieldMutation
            if kind == "clear" { mutation = .clear }
            else if case .array(let values) = after { mutation = .overwrite(.repeatable(values.compactMap(\.stringValue))) }
            else { mutation = .overwrite(.scalar(after.stringValue!)) }
            do { try metadata.apply(mutation, to: fieldID) }
            catch { throw Failure.invalidArguments }
        }
    }

    static func prepare(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade,
                        plans: MCPIPTCPatchPlanStore? = nil) throws -> MCPJSONValue {
        let request = try Request(arguments: arguments)
        let configuration = try facade.authorizationStore.load()
        let createdAt = Date()
        let result = try facade.withPhotoSnapshot(path: request.path) { snapshot in
            // Compare before parsing expensive carrier content, while descriptors and lease remain held.
            try checkRevisions(request, source: snapshot.sourceRevision,
                xmp: snapshot.xmpSidecarRevision, app: snapshot.appSidecarRevision)
            let read = try MCPMetadataSnapshotReader.read(snapshot).protocolValue()
            return try preview(request: request, metadata: read, now: createdAt)
        }
        guard let plans else { return result }
        // Publish only after the retained snapshot's final carrier and authorization checks.
        guard try facade.authorizationStore.load() == configuration else {
            throw MCPIPTCPatchPlanStore.Failure.authorityChanged
        }
        return try plans.retain(request: request, preview: result, configuration: configuration, createdAt: createdAt)
    }

    static func checkRevisions(_ request: Request, source: String, xmp: String, app: String) throws {
        guard request.revisions == ["sourceRevision": .string(source), "xmpSidecarRevision": .string(xmp),
                                    "appSidecarRevision": .string(app)] else { throw Failure.staleRevision }
    }

    static func preview(request: Request, metadata: MCPJSONValue, now: Date) throws -> MCPJSONValue {
        guard let record = metadata.objectValue, let fields = record["fields"]?.objectValue,
              let canonicalPath = record["canonicalPath"]?.stringValue,
              let rootID = record["rootID"]?.stringValue,
              let source = record["sourceRevision"]?.stringValue,
              let xmp = record["xmpSidecarRevision"]?.stringValue,
              let app = record["appSidecarRevision"]?.stringValue,
              record["hasXMPConflict"] == .bool(false) else { throw Failure.conflict }
        try checkRevisions(request, source: source, xmp: xmp, app: app)
        var warnings: [MCPJSONValue] = [
            .string("Preview only: physical carrier support, preservation, approval, and semantic read-back have not been verified. Commit is unavailable."),
        ]
        if record["hasPendingChanges"] == .bool(true) {
            warnings.append(.string("Before values include the current pending Photo Agent draft."))
        }
        // Decode only the supported field subset. Other effective/private values do not
        // become edit intent, and absent scalar values keep their production nil semantics.
        let selected = fields.filter { supportedFields.contains($0.key) }
        let beforeMetadata: IPTCMetadata
        do {
            beforeMetadata = try JSONDecoder().decode(IPTCMetadata.self,
                from: JSONEncoder().encode(MCPJSONValue.object(selected)))
        } catch { throw Failure.invalidArguments }
        var proposed = beforeMetadata
        for operation in request.operations { try operation.apply(to: &proposed) }
        let editedFields = Set(request.operations.map(\.fieldID))
        let report = MetadataValidationEngine().validate(proposed,
            imageURL: URL(fileURLWithPath: canonicalPath), profile: .iptcIIMCompatibility)
        // Report compatibility only for edited fields, without claiming the active user
        // publication profile or the physical destination was evaluated.
        let issues: [MCPJSONValue] = report.issues.filter { editedFields.contains($0.field) }.map { issue in
            .object(["field": .string(issue.field.rawValue), "severity": .string(issue.severity.rawValue),
                "code": .string("iptc_iim_byte_limit"), "issueID": .string(issue.id),
                "message": .string(issue.message), "technicalDetail": issue.technicalDetail.map(MCPJSONValue.string) ?? .null])
        }
        let changes = try request.operations.map { operation -> MCPJSONValue in
            guard let sourceValue = fields[operation.field] else { throw Failure.invalidArguments }
            let before = try protocolValue(IPTCMetadataVerifier.canonicalValue(for: operation.verificationField, in: beforeMetadata),
                isArray: arrayFields.contains(operation.field))
            let after = try protocolValue(IPTCMetadataVerifier.canonicalValue(for: operation.verificationField, in: proposed),
                isArray: arrayFields.contains(operation.field))
            return .object(["field": .string(operation.field), "operation": .string(operation.kind),
                "sourceValue": sourceValue, "requestedValue": operation.after,
                "before": before, "after": after, "changed": .bool(before != after),
                "comparisonRule": .string(IPTCMetadataVerifier.rule(for: operation.verificationField).rawValue)])
        }
        var result = request.revisions
        result["schemaVersion"] = .integer(2)
        result["canonicalPath"] = .string(canonicalPath)
        result["rootID"] = .string(rootID)
        result["changes"] = .array(changes)
        result["expiresAt"] = .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(MCPIPTCPatchPlanStore.lifetime)))
        result["valueSemantics"] = .string("production-semantic-normalization; sourceValue-and-requestedValue-retain-exact-inputs; physical-write-not-evaluated")
        result["previewOnly"] = .bool(true)
        result["commitAvailable"] = .bool(false)
        result["validation"] = .object(["scope": .string("production-typed-mutations-and-edited-field-IIM-compatibility"), "issues": .array(issues),
            "publicationApprovalEvaluated": .bool(false), "publicationProfileEvaluated": .bool(false),
            "physicalCarrierSupportEvaluated": .bool(false)])
        result["preservationWarnings"] = .array(warnings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(MCPJSONValue.object(result)))
        result["previewID"] = .string(digest.map { String(format: "%02x", $0) }.joined())
        let output = MCPJSONValue.object(result)
        guard try encoder.encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }

    /// Match production read-back equivalence, without implying these are physical bytes.
    /// Only text and text bags are admitted by this preview's field registry.
    private static func protocolValue(_ value: IPTCMetadataCanonicalValue, isArray: Bool) throws -> MCPJSONValue {
        switch value {
        case .absent: return isArray ? .array([]) : .null
        case .text(let text): return .string(text)
        case .array(let values): return .array(try values.map { try protocolValue($0, isArray: false) })
        default: throw Failure.invalidArguments
        }
    }

}
