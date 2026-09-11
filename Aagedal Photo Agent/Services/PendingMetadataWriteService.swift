import Foundation

nonisolated struct PendingMetadataDiscoveryFailure: Sendable {
    let url: URL
    let message: String
}
nonisolated struct PendingMetadataDiscoveryResult: Sendable {
    let records: [URL: MetadataSidecar]
    let failures: [PendingMetadataDiscoveryFailure]
    var wasCancelled: Bool = false
}
nonisolated struct PendingMetadataSourceFacts: Sendable {
    let metadata: IPTCMetadata
    let hasC2PA: Bool
}
nonisolated struct PendingMetadataWriteRequest: Sendable {
    let id: UUID
    let imageURL: URL
    let folderURL: URL
    let expectedSidecar: MetadataSidecar
    let skipC2PA: Bool
    let requestedMode: MetadataWriteMode
    let expectedPhysicalBaseline: MetadataSidecarReplayCreationEvidence?
    init(imageURL: URL, folderURL: URL, expectedSidecar: MetadataSidecar,
         skipC2PA: Bool = true, id: UUID = UUID(), requestedMode: MetadataWriteMode = .writeToFile,
         expectedPhysicalBaseline: MetadataSidecarReplayCreationEvidence? = nil) {
        self.id = id; self.imageURL = imageURL; self.folderURL = folderURL
        self.expectedSidecar = expectedSidecar; self.skipC2PA = skipC2PA
        self.requestedMode = requestedMode; self.expectedPhysicalBaseline = expectedPhysicalBaseline
    }
}
nonisolated struct PendingMetadataWriteResult: Sendable {
    let requestID: UUID
    let imageURL: URL
    var installedSidecar: MetadataSidecar? = nil
    var didWriteEmbedded = false
    var didWriteXMP = false
    var embeddedWriteMayHaveOccurred = false
    var wasCancelled = false
    var wasSkipped = false
    var committedButUnverifiedSidecarURL: URL? = nil
    var failure: String? = nil
    var resultingPhysicalBaseline: MetadataSidecarReplayCreationEvidence? = nil
    var completed: Bool {
        installedSidecar?.pendingChanges == false && !wasCancelled && !wasSkipped && failure == nil
    }
    static func failed(request: PendingMetadataWriteRequest, message: String) -> Self {
        .init(requestID: request.id, imageURL: request.imageURL, failure: message)
    }
}
nonisolated struct PendingMetadataPhysicalReceipt: Sendable {
    let metadata: IPTCMetadata
    let sourceRevision: SourceImageRevision
}
nonisolated protocol PendingMetadataWriting: Sendable {
    func writePendingMetadata(_ metadata: IPTCMetadata, to url: URL,
        validatePreparedIntent: @escaping @Sendable () async throws -> Void) async throws -> PendingMetadataPhysicalReceipt
}
nonisolated struct PendingMetadataWriteHooks: Sendable {
    var afterAdmission: @Sendable () async throws -> Void = {}
    var afterEmbeddedWrite: @Sendable () async throws -> Void = {}
    var beforeXMPCommit: @Sendable () throws -> Void = {}
    var beforeJSONCommit: @Sendable () throws -> Void = {}
    var afterJSONCommit: @Sendable () throws -> Void = {}
}

/// Write All acknowledges a complete persisted editorial record. It never deletes its audit or
/// opaque JSON, and never interprets a successful Void engine return as destination evidence.
nonisolated struct PendingMetadataWriteService: Sendable {
    private let writeEngine: any MetadataWriteEngine
    private let readSourceFacts: @Sendable (URL) async throws -> PendingMetadataSourceFacts
    private let hooks: PendingMetadataWriteHooks
    init(writeEngine: any MetadataWriteEngine,
         readSourceFacts: @escaping @Sendable (URL) async throws -> PendingMetadataSourceFacts,
         hooks: PendingMetadataWriteHooks = .init()) {
        self.writeEngine = writeEngine; self.readSourceFacts = readSourceFacts; self.hooks = hooks
    }

    func execute(_ request: PendingMetadataWriteRequest) async -> PendingMetadataWriteResult {
        var result = PendingMetadataWriteResult(requestID: request.id, imageURL: request.imageURL)
        do {
            try Task.checkCancellation()
            guard request.requestedMode != .historyOnly, request.expectedSidecar.pendingChanges else { throw CocoaError(.fileWriteFileExists) }
            let service = MetadataSidecarService()
            try await service.requireNoPendingOrientation(for: request.imageURL, in: request.folderURL)
            let before = try await SourceImageRevision.capture(at: request.imageURL)
            let facts = try await readSourceFacts(request.imageURL)
            let after = try await SourceImageRevision.capture(at: request.imageURL)
            guard before.canonicalURL == after.canonicalURL, before.sha256 == after.sha256 else {
                throw MetadataFieldMutationConflict()
            }
            if facts.hasC2PA && request.skipC2PA { result.wasSkipped = true; return result }
            let xmp = try await Self.strictXMP(for: request.imageURL)
            if let expected = request.expectedPhysicalBaseline {
                guard before.canonicalURL == expected.sourceRevision.canonicalURL,
                      before.sha256 == expected.sourceRevision.sha256, xmp.snapshot.data == expected.xmpData else {
                    throw MetadataFieldMutationConflict()
                }
            }
            result.resultingPhysicalBaseline = .init(sourceRevision: after, xmpData: xmp.snapshot.data)
            let snapshot = try await service.captureWriteCompletionSnapshot(for: request.imageURL,
                in: request.folderURL, expectedSidecar: request.expectedSidecar,
                expectedTechnicalMetadata: xmp.metadata, expectedXMPSnapshot: xmp.snapshot)
            try await hooks.afterAdmission()
            try Task.checkCancellation()
            let target = DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: request.imageURL,
                requestedMode: request.requestedMode)
            var writtenRevision = after
            if target.writesEmbedded {
                guard let engine = writeEngine as? any PendingMetadataWriting else {
                    throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey:
                        "This writer cannot verify a complete pending record. The pending draft was retained."])
                }
                let receipt = try await engine.writePendingMetadata(request.expectedSidecar.metadata,
                    to: request.imageURL, validatePreparedIntent: {
                        try await service.validateWriteCompletionInHeldTransaction(snapshot, sourceRevision: after)
                    })
                result.didWriteEmbedded = true
                writtenRevision = receipt.sourceRevision
                result.resultingPhysicalBaseline = .init(sourceRevision: writtenRevision, xmpData: xmp.snapshot.data)
                try Self.verifyEditorial(receipt.metadata, expected: request.expectedSidecar.metadata)
                try await hooks.afterEmbeddedWrite()
            }
            var completed = request.expectedSidecar
            completed.pendingChanges = false
            // Original means the original saved baseline, including an explicitly unknown nil.
            // Completion does not turn that baseline into the newly written record.
            let persisted = await service.completeSidecarAndMirrorXMP(completed, snapshot: snapshot,
                mirrorOnlyIfExisting: !target.writesXMPSidecar,
                expectedSourceRevision: writtenRevision,
                verifyWrittenMetadata: { try Self.verifyEditorial($0, expected: request.expectedSidecar.metadata) },
                beforeXMPCommit: hooks.beforeXMPCommit, beforeJSONCommit: hooks.beforeJSONCommit,
                afterJSONCommit: hooks.afterJSONCommit)
            if let installedXMP = persisted.writtenXMPSnapshot {
                result.resultingPhysicalBaseline = .init(sourceRevision: writtenRevision, xmpData: installedXMP.data)
            }
            result.installedSidecar = persisted.installedSidecar
            result.didWriteXMP = persisted.wroteXMPSidecar
            result.wasCancelled = persisted.wasCancelled
            result.failure = persisted.failure?.message
            result.committedButUnverifiedSidecarURL = persisted.committedButUnverifiedSidecarURL
        } catch let error as MetadataFieldMutationPhysicalError {
            result.embeddedWriteMayHaveOccurred = error.mayHaveWritten
            result.wasCancelled = error.wasCancelled
            result.failure = error.wasCancelled ? nil : error.localizedDescription
        } catch {
            result.wasCancelled = error is CancellationError
            result.failure = result.wasCancelled ? nil : error.localizedDescription
        }
        return result
    }

    @MetadataSidecarFilesystemActor
    static func strictXMP(for imageURL: URL) async throws -> (metadata: IPTCMetadata?, snapshot: XMPSidecarWriteSnapshot) {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            let service = XMPSidecarService()
            let url = service.sidecarURL(for: imageURL)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return (nil, .init(data: nil)) }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            guard let metadata = service.loadSidecar(fromData: data,
                imageAspect: { ImagePixelAspect.aspect(at: imageURL) }) else { throw CocoaError(.fileReadCorruptFile) }
            return (metadata, .init(data: data))
        }
    }

    /// Compare the actual modeled editorial values. Capture Date is a read-only physical fact;
    /// technical fields are excluded by IPTCMetadata Codable. Unknown JSON is retained separately.
    static func verifyEditorial(_ actual: IPTCMetadata, expected: IPTCMetadata) throws {
        func data(_ record: IPTCMetadata) throws -> Data {
            var value = record
            value.captureDate = nil
            value.rating = MetadataPhysicalFieldMutation.normalizedRating(value.rating)
            value.label = MetadataPhysicalFieldMutation.normalizedLabel(value.label)
            if expected.localizedTitles == nil { value.localizedTitles = nil }
            // XMP GPS uses six decimal places; comparing that represented precision is deliberate.
            value.latitude = value.latitude.map { ($0 * 1_000_000).rounded() / 1_000_000 }
            value.longitude = value.longitude.map { ($0 * 1_000_000).rounded() / 1_000_000 }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }
        guard try data(actual) == data(expected) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "The physical metadata did not match every pending editorial value. The pending record was retained."])
        }
    }
}
