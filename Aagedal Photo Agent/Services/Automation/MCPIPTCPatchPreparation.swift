import CoreFoundation
import CryptoKit
import Darwin
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
        var editsKeywords: Bool { operations.contains { $0.field == "keywords" } }
        func evaluatingKeywords(_ policy: ApprovedKeywordPolicyValues) throws -> Request {
            var arguments = revisions
            arguments["path"] = .string(path)
            arguments["operations"] = .array(try operations.map { operation in
                var value: [String: MCPJSONValue] = ["field": .string(operation.field), "operation": .string(operation.kind)]
                if operation.kind == "set" {
                    var after = operation.after
                    if operation.field == "keywords", case .array(let entries) = after {
                        let validated = policy.validateBulk(entries.compactMap(\.stringValue))
                        guard validated.rejected.isEmpty else { throw MCPKeywordAuthority.Failure.rejected }
                        after = .array(validated.accepted.map(MCPJSONValue.string))
                    }
                    value["value"] = after
                }
                return .object(value)
            })
            return try Request(arguments: arguments)
        }
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
                        plans: MCPIPTCPatchPlanStore? = nil,
                        keywordAuthority: MCPKeywordAuthority = .init()) throws -> MCPJSONValue {
        let request = try Request(arguments: arguments)
        let configuration = try facade.authorizationStore.load()
        let createdAt = Date()
        let authority = plans?.keywordAuthority ?? keywordAuthority
        let keywords = request.editsKeywords ? try authority.capture() : nil
        let result = try facade.withPhotoSnapshot(path: request.path) { snapshot in
            // Compare before parsing expensive carrier content, while descriptors and lease remain held.
            try checkRevisions(request, source: snapshot.sourceRevision,
                xmp: snapshot.xmpSidecarRevision, app: snapshot.appSidecarRevision)
            return try preview(request: request, snapshot: snapshot, now: createdAt, keywordAuthority: keywords)
        }
        if let keywords { try authority.revalidate(keywords) }
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
    static func preview(request: Request, snapshot: MCPPhotoCarrierSnapshot, now: Date,
                        keywordAuthority: MCPKeywordAuthority.Snapshot? = nil) throws -> MCPJSONValue {
        let read = try MCPMetadataSnapshotReader.read(snapshot, includePreservation: true)
        let metadata = try read.protocolValue()
        var preflight = try preservationPreflight(snapshot: snapshot, baseline: read.preservationSnapshot)
        if var evidence = preflight.objectValue {
            evidence["schemaVersion"] = .integer(2)
            evidence["effectiveSemanticExpectations"] = try semanticExpectations(request: keywordAuthority.map { try request.evaluatingKeywords($0.policy) } ?? request, metadata: read.resolution.metadata)
            preflight = .object(evidence)
        }
        return try preview(request: request, metadata: metadata, now: now, preflight: preflight, keywordAuthority: keywordAuthority)
    }

    static func preview(request: Request, metadata: MCPJSONValue, now: Date,
                        preflight: MCPJSONValue? = nil, keywordAuthority: MCPKeywordAuthority.Snapshot? = nil) throws -> MCPJSONValue {
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
        let evaluatedRequest = try keywordAuthority.map { try request.evaluatingKeywords($0.policy) } ?? request
        for operation in evaluatedRequest.operations { try operation.apply(to: &proposed) }
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
        // Foundation may round the final fraction of a second up when formatting.
        // Floor explicitly so the published deadline never exceeds the five-minute
        // authority bound checked by both retention and durable restoration.
        let deadline = Date(timeIntervalSince1970:
            floor(now.addingTimeInterval(MCPIPTCPatchPlanStore.lifetime).timeIntervalSince1970))
        result["expiresAt"] = .string(ISO8601DateFormatter().string(from: deadline))
        result["valueSemantics"] = .string("production-semantic-normalization; sourceValue-and-requestedValue-retain-exact-inputs; physical-write-not-evaluated")
        result["previewOnly"] = .bool(true)
        result["commitAvailable"] = .bool(false)
        result["validation"] = .object(["scope": .string("production-typed-mutations-and-edited-field-IIM-compatibility"), "issues": .array(issues),
            "publicationApprovalEvaluated": .bool(false), "publicationProfileEvaluated": .bool(false),
            "physicalCarrierSupportEvaluated": .bool(false)])
        result["preservationWarnings"] = .array(warnings)
        if let preflight { result["preservationPreflight"] = preflight }
        if let keywordAuthority { result["keywordAuthority"] = keywordAuthority.evidence }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(MCPJSONValue.object(result)))
        result["previewID"] = .string(digest.map { String(format: "%02x", $0) }.joined())
        let output = MCPJSONValue.object(result)
        guard try encoder.encode(output).count <= MCPServerConstants.maximumToolResultBytes else { throw Failure.outputLimit }
        return output
    }

    /// Complete effective-field expectations complement the physical source baseline, which
    /// deliberately excludes descriptive fields. These hashes are evidence, never verification:
    /// a writer still needs independent physical-carrier read-back and recovery admission.
    static func semanticExpectations(request: Request, metadata: IPTCMetadata) throws -> MCPJSONValue {
        var expected = metadata
        for operation in request.operations { try operation.apply(to: &expected) }
        let edited = Set(request.operations.map(\.verificationField))
        let fields = try IPTCMetadataVerificationField.allCases.map { field -> MCPJSONValue in
            func fingerprint(_ value: IPTCMetadataCanonicalValue) throws -> MCPJSONValue {
                // Tag every canonical value so absent, text, decimal and integer cannot alias.
                func tagged(_ value: IPTCMetadataCanonicalValue) -> MCPJSONValue {
                    switch value {
                    case .absent: return .array([.string("absent")])
                    case .text(let text): return .array([.string("text"), .string(text)])
                    case .integer(let number): return .array([.string("integer"), .integer(Int64(number))])
                    case .decimal(let number): return .array([.string("decimal"), .string(number)])
                    case .array(let values): return .array([.string("array"), .array(values.map(tagged))])
                    case .object(let values): return .array([.string("object"), .object(values.mapValues(tagged))])
                    }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let domain = MCPJSONValue.array([.string("iptc-effective-semantic-v1"),
                    .string(field.rawValue), .string(IPTCMetadataVerifier.rule(for: field).rawValue), tagged(value)])
                let digest = SHA256.hash(data: try encoder.encode(domain)).map { String(format: "%02x", $0) }.joined()
                return .string(digest)
            }
            return .object([
                "field": .string(field.rawValue),
                "comparisonRule": .string(IPTCMetadataVerifier.rule(for: field).rawValue),
                "edited": .bool(edited.contains(field)),
                "beforeSHA256": try fingerprint(IPTCMetadataVerifier.canonicalValue(for: field, in: metadata)),
                "expectedAfterSHA256": try fingerprint(IPTCMetadataVerifier.canonicalValue(for: field, in: expected)),
            ])
        }
        return .object([
            "schemaVersion": .integer(1),
            "scope": .string("all-production-verification-fields; effective-values-including-pending-drafts; not-physical-carrier-verification"),
            "fingerprintEncoding": .string("sha256-domain-field-rule-tagged-canonical-json-v1"),
            "fields": .array(fields),
            "verified": .bool(false),
        ])
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

/// Exact local policy evidence for keyword previews. Cooperating app preference writers
/// retain a generation, including changes away and back. This is not write permission.
/// The captured policy uses shared GUI canonical rules, treating all MCP inputs as user input.
/// Kept in the helper's existing compilation unit to avoid a GUI-store dependency.
nonisolated struct MCPKeywordAuthority: Sendable {
    enum Failure: String, LocalizedError {
        case unavailable = "keyword_authority_unavailable"
        case changed = "keyword_authority_changed"
        case rejected = "keyword_policy_rejected"

        var errorDescription: String? {
            switch self {
            case .unavailable: "The local Approved Keywords settings or managed list could not be captured safely. iCloud keyword lists are not supported by this preview."
            case .changed: "Approved Keywords settings or managed-list bytes changed. Prepare and review a new patch."
            case .rejected: "A requested keyword is not in the active strict Approved Keywords list. Review the keyword values before preparing a patch."
            }
        }
    }

    struct Configuration: Sendable, Equatable, Encodable {
        let enabled: Bool
        let mode: String
        let allowStructuredBypass: Bool
        let iCloudEnabled: Bool
        let listURL: URL
        var settingsGeneration: String = "legacy-untracked"
    }

    struct Snapshot: Sendable, Equatable {
        let evidence: MCPJSONValue
        let policy: ApprovedKeywordPolicyValues
    }

    var resolveConfiguration: @Sendable () throws -> Configuration = Self.configured
    var checkpoint: @Sendable () throws -> Void = {}
    static let maximumListBytes = 50 * 1_024 * 1_024

    static func configured() throws -> Configuration {
        let domain = MCPServerConstants.preferencesSuiteName as CFString
        // The helper must refresh its independent preferences cache before copying both
        // the effective values and their cooperative generation envelope.
        guard CFPreferencesAppSynchronize(domain),
              let values = CFPreferencesCopyMultiple(MCPKeywordSettingsHistory.keys as CFArray, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any],
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.unavailable
        }
        return try configured(values: values,
            listURL: support.appendingPathComponent("Aagedal Photo Agent/Lists/approved/keywords.txt"))
    }

    /// Also used by isolated preference tests; never writes or initializes history.
    static func configured(values: [String: Any], listURL: URL) throws -> Configuration {
        let settings = try MCPKeywordSettingsHistory.effectiveSettings(values)
        let generation = try MCPKeywordSettingsHistory.generation(values, settings: settings)
        return Configuration(enabled: settings.enabled, mode: settings.mode,
            allowStructuredBypass: settings.allowStructuredBypass,
            iCloudEnabled: settings.iCloudEnabled, listURL: listURL, settingsGeneration: generation)
    }

    func capture() throws -> Snapshot {
        let configuration = try resolveConfiguration()
        guard !configuration.iCloudEnabled,
              ["suggest", "warn", "strict"].contains(configuration.mode) else { throw Failure.unavailable }
        let list = try Self.read(configuration.listURL)
        try checkpoint()
        guard try resolveConfiguration() == configuration,
              try Self.read(configuration.listURL) == list else { throw Failure.changed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let entries: [String]
        if let bytes = list.bytes {
            guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.unavailable }
            entries = ApprovedKeywordPolicyValues.parseString(text, csv: false)
        } else { entries = [] }
        let policy = ApprovedKeywordPolicyValues(enabled: configuration.enabled, strict: configuration.mode == "strict", entries: entries)
        return Snapshot(evidence: .object([
            "schemaVersion": .integer(2),
            "settingsGeneration": .string(configuration.settingsGeneration),
            "settingsSHA256": .string(Self.digest(try encoder.encode(configuration))),
            "settingsComparison": .string(configuration.settingsGeneration == "legacy-untracked"
                ? "legacy-current-effective-content; no historical-change detection"
                : "cooperating-app-writer-generation-and-current-effective-content"),
            "managedList": list.evidence,
            "policyEvaluated": .bool(true),
            "keywordSource": .string("user; structured bypass unavailable"),
        ]), policy: policy)
    }

    func revalidate(_ snapshot: Snapshot) throws {
        guard try capture() == snapshot else { throw Failure.changed }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Open every component without following symlinks. No directory or missing list
    /// is created. The two captures compare opened ancestor identity and exact bytes.
    private struct List: Equatable {
        let evidence: MCPJSONValue
        let bytes: Data?
    }

    private static func read(_ url: URL) throws -> List {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw Failure.unavailable }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else { throw Failure.unavailable }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(directory) }
        var ancestors: [MCPJSONValue] = []
        func identity(_ status: stat) -> MCPJSONValue {
            .object(["device": .integer(Int64(status.st_dev)), "inode": .string(String(status.st_ino))])
        }
        func absent() -> List {
            List(evidence: .object(["present": .bool(false), "ancestors": .array(ancestors)]), bytes: nil)
        }
        for component in components.dropLast() {
            let next = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { return absent() }
                throw Failure.unavailable
            }
            Darwin.close(directory); directory = next
            var status = stat()
            guard fstat(directory, &status) == 0 else { throw Failure.unavailable }
            ancestors.append(identity(status))
        }
        let name = components.last!
        let file = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return absent() }
            throw Failure.unavailable
        }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximumListBytes else { throw Failure.unavailable }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximumListBytes - bytes.count else { throw Failure.unavailable }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), named = stat()
        guard fstat(file, &after) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              bytes.count == before.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino else { throw Failure.changed }
        return List(evidence: .object(["present": .bool(true), "ancestors": .array(ancestors),
            "identity": identity(after), "byteCount": .integer(Int64(bytes.count)), "sha256": .string(digest(bytes))]), bytes: bytes)
    }
}


/// Preference history for cooperating app writers, kept in the helper's shared unit.
/// A synchronized pending envelope precedes the preference mutation; a ready envelope
/// binds all four effective values after synchronization. A stopped/failed transition
/// therefore leaves preview authority unavailable instead of reusing an old generation.
/// Raw preference editors and malicious rollback are outside this cooperative evidence.
nonisolated enum MCPKeywordSettingsHistory {
    static let historyKey = "approvedList.keywords.authorityHistory"
    static let settingKeys = ["approvedList.keywords.enabled", "approvedList.keywords.mode",
        "approvedList.keywords.allowStructuredBypass", "keywordLists.iCloudEnabled"]
    static var keys: [String] { settingKeys + [historyKey] }

    struct Settings: Codable, Equatable {
        let enabled: Bool
        let mode: String
        let allowStructuredBypass: Bool
        let iCloudEnabled: Bool
    }

    struct Envelope: Codable {
        let schemaVersion: Int
        let generation: UUID
        let pending: Bool
        let settings: Settings
    }

    static func effectiveSettings(_ values: [String: Any]) throws -> Settings {
        func bool(_ key: String, fallback: Bool) throws -> Bool {
            guard let value = values[key] else { return fallback }
            // NSNumber bridges arbitrary numbers to Bool. Require an actual CFBoolean.
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { throw MCPKeywordAuthority.Failure.unavailable }
            return number.boolValue
        }
        let mode = values[settingKeys[1]] as? String ?? "warn"
        guard values[settingKeys[1]] == nil || values[settingKeys[1]] is String,
              ["suggest", "warn", "strict"].contains(mode) else { throw MCPKeywordAuthority.Failure.unavailable }
        return Settings(enabled: try bool(settingKeys[0], fallback: false), mode: mode,
            allowStructuredBypass: try bool(settingKeys[2], fallback: true),
            iCloudEnabled: try bool(settingKeys[3], fallback: false))
    }

    static func generation(_ values: [String: Any], settings: Settings) throws -> String {
        guard let stored = values[historyKey] else { return "legacy-untracked" }
        guard let data = stored as? Data,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1, !envelope.pending,
              envelope.settings == settings else { throw MCPKeywordAuthority.Failure.unavailable }
        return envelope.generation.uuidString.lowercased()
    }

    /// App setters are serialized on MainActor. The injected checkpoint/synchronizer
    /// permit interruption tests without changing production preferences or disk files.
    @MainActor
    static func set(_ value: Any, forKey key: String, defaults: UserDefaults,
                    synchronize: ((UserDefaults) -> Bool)? = nil,
                    checkpoint: (() throws -> Void)? = nil) {
        guard settingKeys.contains(key) else {
            defaults.set(value, forKey: key)
            return
        }
        let sync = synchronize ?? { $0.synchronize() }
        let generation = UUID()
        func retain(pending: Bool) -> Bool {
            guard let settings = try? effectiveSettings(defaults.dictionaryRepresentation()),
                  let data = try? JSONEncoder().encode(Envelope(schemaVersion: 1,
                    generation: generation, pending: pending, settings: settings)) else {
                // Malformed old settings may be repaired one key at a time. A sentinel
                // remains unavailable until a fully valid transition completes.
                defaults.set(Data(), forKey: historyKey)
                // A synchronized invalid sentinel revokes old authority and permits an
                // explicit setting repair; malformed ready evidence never succeeds.
                return sync(defaults) && pending
            }
            defaults.set(data, forKey: historyKey)
            return sync(defaults)
        }
        guard retain(pending: true) else { return }
        do { try checkpoint?() } catch { return }
        defaults.set(value, forKey: key)
        let settingsSynchronized = sync(defaults)
        guard settingsSynchronized else { return }
        if !retain(pending: false) { _ = retain(pending: true) }
    }
}


/// Pure canonical rules shared by the GUI's immutable policy and the STDIO helper.
/// Managed UTF-8 parsing uses the same first normalized spelling in both paths.
nonisolated struct ApprovedKeywordPolicyValues: Sendable, Equatable {
    let enabled: Bool
    let strict: Bool
    let canonicalByNormalized: [String: String]

    init(enabled: Bool, strict: Bool, entries: [String]) {
        var canonical: [String: String] = [:]
        for entry in entries {
            let normalized = Self.normalize(entry)
            if !normalized.isEmpty, canonical[normalized] == nil { canonical[normalized] = entry }
        }
        self.enabled = enabled; self.strict = strict; self.canonicalByNormalized = canonical
    }

    init(enabled: Bool, strict: Bool, canonicalByNormalized: [String: String]) {
        self.enabled = enabled; self.strict = strict; self.canonicalByNormalized = canonicalByNormalized
    }

    var isActive: Bool { enabled && !canonicalByNormalized.isEmpty }
    func canonical(_ value: String) -> String? {
        isActive ? canonicalByNormalized[Self.normalize(value)] : nil
    }
    func allows(_ value: String) -> Bool { !isActive || !strict || canonical(value) != nil }
    func validateBulk(_ values: [String]) -> (accepted: [String], rejected: [String]) {
        var accepted: [String] = [], rejected: [String] = []
        var seen = Set<String>()
        for value in values {
            guard allows(value) else { rejected.append(value); continue }
            let result = canonical(value) ?? value
            if seen.insert(Self.normalize(result)).inserted { accepted.append(result) }
        }
        return (accepted, rejected)
    }
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
    static func parseString(_ raw: String, csv: Bool) -> [String] {
        let cleaned = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")

        var seen = Set<String>()
        var result: [String] = []
        cleaned.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }

            let payload: String
            if csv {
                if let comma = trimmed.firstIndex(of: ",") {
                    payload = String(trimmed[..<comma])
                } else {
                    payload = trimmed
                }
            } else {
                payload = trimmed
            }

            let unquoted = stripSurroundingQuotes(payload)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unquoted.isEmpty else { return }

            if seen.insert(unquoted).inserted {
                result.append(unquoted)
            }
        }
        return result
    }

    private static func stripSurroundingQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

}
