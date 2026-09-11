import Foundation

nonisolated enum MetadataPhysicalFieldMutation: Sendable, Equatable {
    case rating(Int?)
    case label(String?)
    case addPersons([String])

    // A label mutation always carries an explicit value, including the empty standard clear.
    func apply(to metadata: inout IPTCMetadata) {
        switch self {
        case .rating(let value): metadata.rating = Self.normalizedRating(value)
        case .label(let value): metadata.label = Self.normalizedLabel(value) ?? ""
        case .addPersons(let names): metadata.personShown = Self.add(names, to: metadata.personShown)
        }
    }
    func value(in metadata: IPTCMetadata) -> MetadataPhysicalFieldValue {
        switch self {
        case .rating: return .rating(Self.normalizedRating(metadata.rating))
        case .label: return .label(Self.normalizedLabel(metadata.label))
        case .addPersons: return .persons(metadata.personShown)
        }
    }
    static func normalizedRating(_ value: Int?) -> Int? { value == 0 ? nil : value }
    static func normalizedLabel(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
    static func add(_ names: [String], to existing: [String]) -> [String] {
        var result = existing
        var seen = Set(existing.map { $0.lowercased() })
        for name in names where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }
}

nonisolated enum MetadataPhysicalFieldValue: Sendable, Equatable {
    case rating(Int?), label(String?), persons([String])
    func apply(to metadata: inout IPTCMetadata) {
        switch self {
        case .rating(let value): metadata.rating = value
        case .label(let value): metadata.label = value ?? ""
        case .persons(let value): metadata.personShown = value
        }
    }
}

nonisolated struct MetadataFieldMutationWriteRequest: Sendable {
    let id: UUID
    let imageURL: URL
    let folderURL: URL
    let requestedMode: MetadataWriteMode
    let mutation: MetadataPhysicalFieldMutation
    init(imageURL: URL, folderURL: URL, requestedMode: MetadataWriteMode,
         mutation: MetadataPhysicalFieldMutation, id: UUID = UUID()) {
        self.id = id; self.imageURL = imageURL; self.folderURL = folderURL
        self.requestedMode = requestedMode; self.mutation = mutation
    }
}

nonisolated struct MetadataFieldMutationWriteResult: Sendable {
    struct Failure: LocalizedError, Sendable {
        enum Stage: String, Sendable { case prepare, embedded, xmp, finalize }
        enum Kind: String, Sendable { case io, conflict }
        let stage: Stage
        let message: String
        let kind: Kind
        var errorDescription: String? { message }
    }
    let requestID: UUID
    let imageURL: URL
    let installedSidecar: MetadataSidecar?
    let didWriteEmbedded: Bool
    let didWriteXMP: Bool
    let embeddedWriteMayHaveOccurred: Bool
    let wasCancelled: Bool
    let committedButUnverifiedSidecarURL: URL?
    let failure: Failure?
    var completed: Bool { installedSidecar != nil && !wasCancelled && failure == nil }
    init(requestID: UUID, imageURL: URL, installedSidecar: MetadataSidecar? = nil,
         didWriteEmbedded: Bool = false, didWriteXMP: Bool = false,
         embeddedWriteMayHaveOccurred: Bool = false, wasCancelled: Bool = false,
         committedButUnverifiedSidecarURL: URL? = nil, failure: Failure? = nil) {
        self.requestID = requestID; self.imageURL = imageURL; self.installedSidecar = installedSidecar
        self.didWriteEmbedded = didWriteEmbedded; self.didWriteXMP = didWriteXMP
        self.embeddedWriteMayHaveOccurred = embeddedWriteMayHaveOccurred
        self.wasCancelled = wasCancelled; self.failure = failure
        self.committedButUnverifiedSidecarURL = committedButUnverifiedSidecarURL
    }
    static func failed(request: MetadataFieldMutationWriteRequest, message: String) -> Self {
        .init(requestID: request.id, imageURL: request.imageURL,
            failure: .init(stage: .prepare, message: message, kind: .io))
    }
}

nonisolated struct MetadataFieldMutationPhysicalReceipt: Sendable {
    let value: MetadataPhysicalFieldValue
    let sourceRevision: SourceImageRevision
    let didWrite: Bool
}

nonisolated struct MetadataFieldMutationPhysicalError: LocalizedError, Sendable {
    let message: String
    let mayHaveWritten: Bool
    let wasCancelled: Bool
    init(message: String, mayHaveWritten: Bool, wasCancelled: Bool = false) {
        self.message = message; self.mayHaveWritten = mayHaveWritten; self.wasCancelled = wasCancelled
    }
    var errorDescription: String? { message }
}

nonisolated struct MetadataFieldMutationConflict: LocalizedError, Sendable {
    var errorDescription: String? {
        "The photo or its metadata changed while this field write was prepared. Newer saved data and pending edits were retained."
    }
}

/// Optional capability: fixed-string list replacements cannot implement atomic append safely.
nonisolated protocol MetadataFieldMutationWriting: Sendable {
    func writeFieldMutation(_ mutation: MetadataPhysicalFieldMutation, to url: URL,
        validatePreparedIntent: @escaping @Sendable () async throws -> Void) async throws -> MetadataFieldMutationPhysicalReceipt
}

nonisolated struct MetadataFieldMutationWriteHooks: Sendable {
    var afterPrepareJSONCommit: @Sendable () throws -> Void = {}
    var afterPrepare: @Sendable () async throws -> Void = {}
    var afterEmbeddedWrite: @Sendable () async throws -> Void = {}
    var beforeXMPWrite: @Sendable () throws -> Void = {}
    var beforeFinalize: @Sendable () throws -> Void = {}
}

nonisolated final class MetadataFieldMutationXMPReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var committedJSON = false
    private var committedPreparation = false
    var prepareJSONWasCommitted: Bool { lock.withLock { committedPreparation } }
    func markPrepareJSONCommitted() { lock.withLock { committedPreparation = true } }
    var jsonWasCommitted: Bool { lock.withLock { committedJSON } }
    func markJSONCommitted() { lock.withLock { committedJSON = true } }
    var data: Data? { lock.withLock { stored } }
    func record(_ snapshot: XMPSidecarWriteSnapshot) { lock.withLock { stored = snapshot.data } }
}

/// Prepares one durable field intent, writes only that field, then acknowledges verified physical
/// values. The original snapshot and other pending fields are never replaced by the whole draft.
nonisolated struct MetadataFieldMutationWriteService: Sendable {
    private let writeEngine: any MetadataWriteEngine
    private let readEmbedded: @Sendable (URL) async throws -> IPTCMetadata
    private let hooks: MetadataFieldMutationWriteHooks
    init(writeEngine: any MetadataWriteEngine,
         readEmbedded: @escaping @Sendable (URL) async throws -> IPTCMetadata,
         hooks: MetadataFieldMutationWriteHooks = .init()) {
        self.writeEngine = writeEngine; self.readEmbedded = readEmbedded; self.hooks = hooks
    }

    private struct Prepared: Sendable {
        let sidecar: MetadataSidecar
        let tokens: [Data?]
        let xmpData: Data?
        let embedded: IPTCMetadata
        let sourceRevision: SourceImageRevision
    }

    @MetadataSidecarFilesystemActor
    func write(_ request: MetadataFieldMutationWriteRequest) async -> MetadataFieldMutationWriteResult {
        let target = DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: request.imageURL, requestedMode: request.requestedMode)
        var installed: MetadataSidecar?
        var physical: MetadataFieldMutationPhysicalReceipt?
        var mayHaveWritten = false
        let xmpReceipt = MetadataFieldMutationXMPReceipt()
        var stage = MetadataFieldMutationWriteResult.Failure.Stage.prepare
        do {
            try Task.checkCancellation()
            if case .rating(let value) = request.mutation, let value, !(0...5).contains(value) {
                throw MetadataFieldMutationWriteResult.Failure(stage: .prepare, message: "Rating must be between zero and five.", kind: .io)
            }
            let beforeRead = try await SourceImageRevision.capture(at: request.imageURL)
            let embedded = try await readEmbedded(request.imageURL)
            let afterRead = try await SourceImageRevision.capture(at: request.imageURL)
            guard beforeRead.relationship(to: afterRead) == .exactRevision else { throw MetadataFieldMutationConflict() }
            let prepared = try await prepare(request, embedded: embedded, revision: afterRead, evidence: xmpReceipt)
            installed = prepared.sidecar
            try await hooks.afterPrepare()
            try Task.checkCancellation()
            if target.writesEmbedded {
                stage = .embedded
                guard let writer = writeEngine as? any MetadataFieldMutationWriting else {
                    throw MetadataFieldMutationPhysicalError(message: "This metadata writer does not support verified atomic field mutations.", mayHaveWritten: false)
                }
                // The engine owns the photo lock while validating the captured intent and applying
                // a live destination mutation. It must not call another lock-taking helper inside.
                physical = try await writer.writeFieldMutation(request.mutation, to: request.imageURL) {
                    try await validate(prepared, request: request, checkSource: true)
                }
                try await hooks.afterEmbeddedWrite()
                try Task.checkCancellation()
            }
            if target == .historyOnly {
                return result(request, installed: installed)
            }
            stage = .finalize
            let frozenPhysical = physical
            installed = try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: request.imageURL)) { @MetadataSidecarFilesystemActor in
                try await validate(prepared, request: request, checkSource: frozenPhysical == nil)
                if let physical = frozenPhysical {
                    let current = try await SourceImageRevision.capture(at: request.imageURL)
                    guard current.relationship(to: physical.sourceRevision) == .exactRevision else { throw MetadataFieldMutationConflict() }
                }
                let xmp = XMPSidecarService()
                let shouldMirror = target.writesXMPSidecar || prepared.xmpData != nil
                var acknowledged = frozenPhysical?.value
                if shouldMirror {
                    try hooks.beforeXMPWrite()
                    try await validate(prepared, request: request, checkSource: false)
                    do {
                        _ = try await xmp.mutateFieldInHeldTransaction(request.mutation, for: request.imageURL,
                            expectedSnapshot: .init(data: prepared.xmpData), embeddedBaseline: prepared.embedded,
                            onInstalled: { xmpReceipt.record($0) })
                    } catch {
                        throw MetadataFieldMutationWriteResult.Failure(stage: .xmp, message: error.localizedDescription,
                            kind: error is MetadataFieldMutationConflict ? .conflict : .io)
                    }
                    guard let data = xmpReceipt.data,
                          let actual = xmp.loadSidecar(fromData: data, imageAspect: { nil }) else { throw CocoaError(.fileReadCorruptFile) }
                    let xmpValue = request.mutation.value(in: actual)
                    if let embeddedValue = frozenPhysical?.value, embeddedValue != xmpValue {
                        // Different preexisting destination lists remain distinct. One snapshot
                        // cannot assert that divergent physical records are fully synchronized.
                        acknowledged = nil
                    } else {
                        acknowledged = xmpValue
                    }
                }
                try hooks.beforeFinalize()
                let finalSource = try await SourceImageRevision.capture(at: request.imageURL)
                let expectedSource = frozenPhysical?.sourceRevision ?? prepared.sourceRevision
                guard finalSource.relationship(to: expectedSource) == .exactRevision else { throw MetadataFieldMutationConflict() }
                let service = MetadataSidecarService()
                guard try service.fieldMutationTokens(for: request.imageURL, in: request.folderURL) == prepared.tokens,
                      try xmp.fieldMutationData(for: request.imageURL) == (xmpReceipt.data ?? prepared.xmpData) else {
                    throw MetadataFieldMutationConflict()
                }
                var completed = prepared.sidecar
                if var snapshot = completed.imageMetadataSnapshot, let acknowledged {
                    acknowledged.apply(to: &snapshot)
                    completed.imageMetadataSnapshot = snapshot
                    completed.pendingChanges = !Self.persistedEqual(completed.metadata, snapshot)
                } else {
                    completed.pendingChanges = true
                }
                try service.saveSidecar(completed, for: request.imageURL, in: request.folderURL)
                xmpReceipt.markJSONCommitted()
                guard let readBack = try service.loadOwnedSidecarForMutation(for: request.imageURL, in: request.folderURL),
                      service.fieldMutationRecordsEqual(readBack, completed) else { throw CocoaError(.fileReadCorruptFile) }
                return readBack
            }
            return result(request, installed: installed, physical: physical, xmp: xmpReceipt.data != nil)
        } catch {
            if let error = error as? MetadataFieldMutationPhysicalError { mayHaveWritten = error.mayHaveWritten }
            let wasCancelled = error is CancellationError
                || (error as? MetadataFieldMutationPhysicalError)?.wasCancelled == true
            return .init(requestID: request.id, imageURL: request.imageURL,
                installedSidecar: xmpReceipt.jsonWasCommitted ? nil : installed,
                didWriteEmbedded: physical?.didWrite ?? false, didWriteXMP: xmpReceipt.data != nil,
                embeddedWriteMayHaveOccurred: mayHaveWritten,
                wasCancelled: wasCancelled,
                committedButUnverifiedSidecarURL: xmpReceipt.jsonWasCommitted || (xmpReceipt.prepareJSONWasCommitted && installed == nil)
                    ? request.folderURL.appendingPathComponent(".photo_metadata/\(request.imageURL.lastPathComponent).meta.json") : nil,
                failure: wasCancelled ? nil : (error as? MetadataFieldMutationWriteResult.Failure
                    ?? .init(stage: stage, message: error.localizedDescription,
                        kind: error is MetadataFieldMutationConflict ? .conflict : .io)))
        }
    }

    @MetadataSidecarFilesystemActor
    private func prepare(_ request: MetadataFieldMutationWriteRequest, embedded: IPTCMetadata,
                         revision: SourceImageRevision, evidence: MetadataFieldMutationXMPReceipt) async throws -> Prepared {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: request.imageURL)) { @MetadataSidecarFilesystemActor in
            let currentRevision = try await SourceImageRevision.capture(at: request.imageURL)
            guard revision.relationship(to: currentRevision) == .exactRevision else { throw MetadataFieldMutationConflict() }
            let service = MetadataSidecarService()
            let originalTokens = try service.fieldMutationTokens(for: request.imageURL, in: request.folderURL)
            let current = try service.loadOwnedSidecarForMutation(for: request.imageURL, in: request.folderURL)
            let xmp = XMPSidecarService()
            let xmpData = try xmp.fieldMutationData(for: request.imageURL)
            let xmpMetadata = xmpData.flatMap { xmp.loadSidecar(fromData: $0, imageAspect: { nil }) }
            guard xmpData == nil || xmpMetadata != nil else { throw CocoaError(.fileReadCorruptFile) }
            var source = embedded
            if let xmpMetadata {
                source = xmpMetadata.hasDescriptiveContent ? source.replacingDescriptiveFields(from: xmpMetadata)
                    : source.merged(preferring: xmpMetadata)
            }
            let previous = current?.metadata ?? source
            var metadata = previous
            request.mutation.apply(to: &metadata)
            var history = current?.history ?? []
            history += MetadataHistoryEntry.changes(from: previous, to: metadata, timestamp: Date())
            history.trimToHistoryLimit()
            let sidecar = MetadataSidecar(sourceFile: request.imageURL.lastPathComponent, pendingChanges: true,
                metadata: metadata, imageMetadataSnapshot: current == nil ? source : current?.imageMetadataSnapshot,
                history: history)
            guard try service.fieldMutationTokens(for: request.imageURL, in: request.folderURL) == originalTokens,
                  try xmp.fieldMutationData(for: request.imageURL) == xmpData else { throw MetadataFieldMutationConflict() }
            try service.saveSidecar(sidecar, for: request.imageURL, in: request.folderURL)
            evidence.markPrepareJSONCommitted()
            try hooks.afterPrepareJSONCommit()
            guard let installed = try service.loadOwnedSidecarForMutation(for: request.imageURL, in: request.folderURL),
                  service.fieldMutationRecordsEqual(installed, sidecar) else { throw CocoaError(.fileReadCorruptFile) }
            return Prepared(sidecar: installed,
                tokens: try service.fieldMutationTokens(for: request.imageURL, in: request.folderURL),
                xmpData: xmpData, embedded: embedded, sourceRevision: revision)
        }
    }

    @MetadataSidecarFilesystemActor
    private func validate(_ prepared: Prepared, request: MetadataFieldMutationWriteRequest, checkSource: Bool) async throws {
        guard try MetadataSidecarService().fieldMutationTokens(for: request.imageURL, in: request.folderURL) == prepared.tokens,
              try XMPSidecarService().fieldMutationData(for: request.imageURL) == prepared.xmpData else {
            throw MetadataFieldMutationConflict()
        }
        if checkSource {
            let revision = try await SourceImageRevision.capture(at: request.imageURL)
            guard revision.relationship(to: prepared.sourceRevision) == .exactRevision,
                  try MetadataSidecarService().fieldMutationTokens(for: request.imageURL, in: request.folderURL) == prepared.tokens,
                  try XMPSidecarService().fieldMutationData(for: request.imageURL) == prepared.xmpData else {
                throw MetadataFieldMutationConflict()
            }
        }
    }

    private func result(_ request: MetadataFieldMutationWriteRequest, installed: MetadataSidecar?,
                        physical: MetadataFieldMutationPhysicalReceipt? = nil, xmp: Bool = false) -> MetadataFieldMutationWriteResult {
        .init(requestID: request.id, imageURL: request.imageURL, installedSidecar: installed,
              didWriteEmbedded: physical?.didWrite ?? false, didWriteXMP: xmp)
    }
    private static func persistedEqual(_ lhs: IPTCMetadata, _ rhs: IPTCMetadata) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }
}
