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
            case .invalidArguments: "Patch requires exact revision strings and unique supported fields with typed set or clear operations."
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
                operations.append(Operation(field: field, kind: kind, after: normalized))
            }
            self.path = path; self.revisions = revisions
            self.operations = operations.sorted { $0.field < $1.field }
        }
    }

    struct Operation: Sendable {
        let field: String
        let kind: String
        let after: MCPJSONValue
    }

    static func prepare(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade) throws -> MCPJSONValue {
        let request = try Request(arguments: arguments)
        return try facade.withPhotoSnapshot(path: request.path) { snapshot in
            // Compare before parsing expensive carrier content, while descriptors and lease remain held.
            try checkRevisions(request, source: snapshot.sourceRevision,
                xmp: snapshot.xmpSidecarRevision, app: snapshot.appSidecarRevision)
            let read = try MCPMetadataSnapshotReader.read(snapshot).protocolValue()
            return try preview(request: request, metadata: read, now: Date())
        }
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
        // Legacy IIM byte limits are informational here; richer XMP text is never truncated.
        let iimLimits = Dictionary(uniqueKeysWithValues: MetadataValidationProfile.iptcIIMCompatibility.rules.compactMap { rule -> (String, Int)? in
            guard case let .maximumUTF8Bytes(field, count) = rule.requirement else { return nil }
            return (field.rawValue, count)
        })
        var issues: [MCPJSONValue] = []
        let changes = try request.operations.map { operation -> MCPJSONValue in
            guard let before = fields[operation.field] else { throw Failure.invalidArguments }
            let strings: [String]
            if case .array(let values) = operation.after { strings = values.compactMap(\.stringValue) }
            else { strings = [operation.after.stringValue ?? ""] }
            if let limit = iimLimits[operation.field], strings.contains(where: { $0.utf8.count > limit }) {
                issues.append(.object(["field": .string(operation.field), "severity": .string("warning"),
                    "code": .string("iptc_iim_byte_limit"), "maximumUTF8BytesPerValue": .integer(Int64(limit))]))
            }
            return .object(["field": .string(operation.field), "operation": .string(operation.kind),
                            "before": before, "after": operation.after, "changed": .bool(before != operation.after)])
        }
        var result = request.revisions
        result["schemaVersion"] = .integer(1)
        result["canonicalPath"] = .string(canonicalPath)
        result["rootID"] = .string(rootID)
        result["changes"] = .array(changes)
        result["expiresAt"] = .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(300)))
        result["valueSemantics"] = .string("exact-proposed-values; physical-write-normalization-not-evaluated")
        result["previewOnly"] = .bool(true)
        result["commitAvailable"] = .bool(false)
        result["validation"] = .object(["scope": .string("typed-input-and-legacy-IIM-byte-limits"), "issues": .array(issues),
            "publicationApprovalEvaluated": .bool(false)])
        result["preservationWarnings"] = .array(warnings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(MCPJSONValue.object(result)))
        result["previewID"] = .string(digest.map { String(format: "%02x", $0) }.joined())
        let output = MCPJSONValue.object(result)
        guard try encoder.encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }
}
