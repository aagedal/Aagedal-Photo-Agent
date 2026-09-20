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
            return try preview(request: request, snapshot: snapshot, now: createdAt)
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

    /// Capture physical baselines inside the retained read lease. Retrieval reconstructs this
    /// entire value so no baseline from an older carrier generation can survive revalidation.
    static func preview(request: Request, snapshot: MCPPhotoCarrierSnapshot, now: Date) throws -> MCPJSONValue {
        let read = try MCPMetadataSnapshotReader.read(snapshot, includePreservation: true)
        let preflight = try preservationPreflight(snapshot: snapshot, baseline: read.preservationSnapshot)
        return try preview(request: request, metadata: read.protocolValue(), now: now, preflight: preflight)
    }

    static func preview(request: Request, metadata: MCPJSONValue, now: Date,
                        preflight: MCPJSONValue? = nil) throws -> MCPJSONValue {
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
        result["schemaVersion"] = .integer(preflight == nil ? 2 : 3)
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
        if let preflight { result["preservationPreflight"] = preflight }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(MCPJSONValue.object(result)))
        result["previewID"] = .string(digest.map { String(format: "%02x", $0) }.joined())
        let output = MCPJSONValue.object(result)
        guard try encoder.encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }

    /// The production preservation builder excludes all writer-controlled descriptive fields,
    /// not only the edited subset. Therefore this baseline is necessary but never sufficient for
    /// approving a patch: unedited descriptive values need their own complete semantic check.
    static func preservationPreflight(snapshot: MCPPhotoCarrierSnapshot,
                                      baseline: MetadataPreservationSnapshot?) throws -> MCPJSONValue {
        guard let baseline else { throw Failure.invalidArguments }
        func carrier(_ bytes: Data?) -> MCPJSONValue {
            guard let bytes else { return .object(["present": .bool(false), "sha256": .null, "byteCount": .integer(0)]) }
            return .object(["present": .bool(true), "byteCount": .integer(Int64(bytes.count)),
                "sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        }
        let parsedRaw = baseline.capability.formatIdentifier.hasPrefix("raw.")
        let extensionRaw = MCPPhotoFormatCatalog.rawExtensions.contains(snapshot.target.url.pathExtension.lowercased())
        let targets: [MCPJSONValue] = MetadataWriteMode.allCases.map { mode in
            let target = DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: snapshot.target.url, requestedMode: mode)
            let name: String
            switch target {
            case .historyOnly: name = "historyOnly"
            case .embedded: name = "embedded"
            case .xmpSidecar: name = "xmpSidecar"
            case .embeddedAndXMPSidecar: name = "embeddedAndXMPSidecar"
            }
            return .object(["requestedMode": .string(mode.rawValue), "resolvedTarget": .string(name),
                "writesEmbedded": .bool(target.writesEmbedded), "writesXMPSidecar": .bool(target.writesXMPSidecar),
                "requiresSourceByteIdentity": .bool(!target.writesEmbedded)])
        }
        let semantic = try JSONDecoder().decode(MCPJSONValue.self, from: JSONEncoder().encode(baseline))
        return .object([
            "schemaVersion": .integer(1),
            "scope": .string("captured-carrier-baselines-and-production-target-policy; not-write-verification"),
            "sourceRevision": .string(snapshot.sourceRevision),
            "xmpSidecarRevision": .string(snapshot.xmpSidecarRevision),
            "appSidecarRevision": .string(snapshot.appSidecarRevision),
            "carriers": .object(["source": carrier(snapshot.sourceBytes), "xmpSidecar": carrier(snapshot.xmpBytes),
                                 "appSidecar": carrier(snapshot.appSidecarBytes)]),
            "sourceSemanticBaseline": semantic,
            "semanticBaselineScope": .string("production-exactCopy-policy; excludes-all-writer-controlled-descriptive-fields"),
            "targetPolicyAlternatives": .array(targets),
            "selectedWriteMode": .null,
            "rawClassificationAgrees": .bool(parsedRaw == extensionRaw),
            "writeSupportVerified": .bool(false),
            "preservationVerified": .bool(false),
            "c2paTrustEvaluated": .bool(false),
            "requiredBeforeCommit": .array([
                "explicit-write-mode-and-publication-approval",
                "complete-unedited-descriptive-field-preservation",
                "unrelated-source-and-sidecar-metadata-preservation",
                "source-pixels-or-codestream-preservation",
                "c2pa-consequences-and-approval",
                "staged-physical-write-and-semantic-readback",
                "revision-and-authority-revalidation",
                "durable-recovery-and-verified-installation",
            ].map(MCPJSONValue.string)),
        ])
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
