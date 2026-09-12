import Foundation
import SwiftMediaMetadata

nonisolated struct PrimaryDevelopWriteError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct PrimaryDevelopWatermarkDependency: Codable, Sendable {
    let id: UUID
    let asset: WatermarkAsset?
    let imageData: Data?
    let imageURL: URL
    let metadataURL: URL
    let unavailableAtAdmission: Bool
}

/// A captured edit never borrows the currently selected editor on retry.
nonisolated final class PrimaryDevelopWriteRequest: Sendable {
    let id = UUID()
    let imageURL: URL
    let folderURL: URL
    let loadID: UUID
    let mode: MetadataWriteMode
    let predecessor: PrimaryDevelopWriteRequest?
    let watermarkDependencies: [PrimaryDevelopWatermarkDependency]
    let edited: IPTCMetadata
    let previous: IPTCMetadata?
    let original: IPTCMetadata?
    let embeddedBaseline: IPTCMetadata?
    let expectedRecord: MetadataSidecar?
    let expectedXMP: XMPSidecarWriteSnapshot?
    let sourceRevision: SourceImageRevision?
    let captureFailure: String?
    let sidecar: MetadataSidecar
    let changes: [MetadataHistoryEntry]
    let fields: [MetadataFieldKey: String]
    let structured: StructuredWriteData
    let replaceDevelop: Bool
    let replaceOrientation: Bool
    static func ancestry(of roots: [PrimaryDevelopWriteRequest]) -> [PrimaryDevelopWriteRequest] {
        var seen = Set<UUID>()
        var result: [PrimaryDevelopWriteRequest] = []
        for root in roots {
            var next: PrimaryDevelopWriteRequest? = root
            while let current = next, seen.insert(current.id).inserted {
                result.append(current)
                next = current.predecessor
            }
        }
        return result
    }
    static func protectedURLs(for roots: [PrimaryDevelopWriteRequest]) -> [URL] {
        ancestry(of: roots).flatMap { request in
            [request.imageURL] + request.watermarkDependencies.flatMap { [$0.imageURL, $0.metadataURL] }
        }
    }
    init(imageURL: URL, folderURL: URL, loadID: UUID, mode: MetadataWriteMode,
         edited: IPTCMetadata, previous: IPTCMetadata?, original: IPTCMetadata?,
         expectedRecord: MetadataSidecar?, expectedXMP: XMPSidecarWriteSnapshot?, sourceRevision: SourceImageRevision?,
         captureFailure: String?, sidecar: MetadataSidecar, changes: [MetadataHistoryEntry],
         fields: [MetadataFieldKey: String], structured: StructuredWriteData,
         replaceDevelop: Bool, replaceOrientation: Bool, predecessor: PrimaryDevelopWriteRequest? = nil, watermarkDependencies: [PrimaryDevelopWatermarkDependency] = [], embeddedBaseline: IPTCMetadata? = nil) {
        self.imageURL = imageURL; self.folderURL = folderURL; self.loadID = loadID; self.mode = mode; self.predecessor = predecessor; self.watermarkDependencies = watermarkDependencies
        self.edited = edited; self.previous = previous; self.original = original; self.embeddedBaseline = embeddedBaseline
        self.expectedRecord = expectedRecord; self.expectedXMP = expectedXMP; self.sourceRevision = sourceRevision
        self.captureFailure = captureFailure; self.sidecar = sidecar; self.changes = changes
        self.fields = fields; self.structured = structured
        self.replaceDevelop = replaceDevelop; self.replaceOrientation = replaceOrientation
    }
}
nonisolated struct PrimaryDevelopPhysicalReceipt: Sendable {
    let sourceRevision: SourceImageRevision
}
nonisolated struct PrimaryDevelopPhysicalError: LocalizedError, Sendable {
    let message: String
    let mayHaveWritten: Bool
    let sourceRevision: SourceImageRevision?
    let wasCancelled: Bool
    var errorDescription: String? { message }
}
nonisolated protocol PrimaryDevelopWriting: Sendable {
    func writePrimaryDevelop(_ request: PrimaryDevelopWriteRequest,
        validatePreparedIntent: @escaping @Sendable () async throws -> Void) async throws -> PrimaryDevelopPhysicalReceipt
}
nonisolated struct PrimaryDevelopWriteResult: Sendable {
    let requestID: UUID
    var completion: MetadataSidecarPersistenceResult?
    var sourceRevision: SourceImageRevision?
    var wroteEmbedded = false
    var embeddedMayHaveBeenWritten = false
    var wasCancelled = false
    var failure: String?
    var completed: Bool { completion?.completed == true && failure == nil && !wasCancelled }
    var requiresRecovery: Bool { wroteEmbedded || embeddedMayHaveBeenWritten || completion?.wroteXMPSidecar == true || completion?.committedButUnverifiedSidecarURL != nil }
}
nonisolated struct PrimaryDevelopWriteHooks: Sendable {
    var beforeAdmission: @Sendable () async throws -> Void = {}
    var afterEmbedded: @Sendable () async throws -> Void = {}
    var beforeXMP: @Sendable () throws -> Void = {}
    var beforeJSON: @Sendable () throws -> Void = {}
    var afterJSON: @Sendable () throws -> Void = {}
}
nonisolated struct PrimaryDevelopWriteService: Sendable {
    let engine: any MetadataWriteEngine
    var hooks = PrimaryDevelopWriteHooks()
    func execute(_ request: PrimaryDevelopWriteRequest, predecessorResult: PrimaryDevelopWriteResult? = nil) async -> PrimaryDevelopWriteResult {
        var result = PrimaryDevelopWriteResult(requestID: request.id)
        do {
            try Task.checkCancellation()
            if let message = request.captureFailure { throw PrimaryDevelopWriteError(message: message) }
            let admittedSource: SourceImageRevision?
            let admittedXMP: XMPSidecarWriteSnapshot?
            let admittedRecord: MetadataSidecar?
            if let predecessor = request.predecessor {
                guard let receipt = predecessorResult, receipt.requestID == predecessor.id, receipt.completed,
                      let completion = receipt.completion, let installed = completion.installedSidecar else {
                    throw PrimaryDevelopWriteError(message: "The earlier captured Primary Develop edit has no verified completion receipt.")
                }
                admittedSource = receipt.sourceRevision
                admittedXMP = completion.writtenXMPSnapshot ?? predecessor.expectedXMP
                admittedRecord = installed
            } else {
                admittedSource = request.sourceRevision; admittedXMP = request.expectedXMP; admittedRecord = request.expectedRecord
            }
            guard let source = admittedSource, let xmp = admittedXMP,
                  request.mode != .historyOnly else {
                throw PrimaryDevelopWriteError(message: "The original Develop source evidence is unavailable. The captured edit remains retained for recovery.")
            }
            try await hooks.beforeAdmission()
            let service = MetadataSidecarService()
            let snapshot = try await service.captureWriteCompletionSnapshot(for: request.imageURL,
                in: request.folderURL, expectedSidecar: admittedRecord,
                expectedTechnicalMetadata: nil, expectedXMPSnapshot: xmp)
            let currentSource = try await SourceImageRevision.capture(at: request.imageURL)
            guard currentSource.canonicalURL == source.canonicalURL, currentSource.sha256 == source.sha256 else {
                throw PrimaryDevelopWriteError(message: "The source image changed after this Develop edit was loaded. The original edit remains retained.")
            }
            var writtenSource = source
            let target = DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: request.imageURL, requestedMode: request.mode)
            if target.writesEmbedded {
                guard let engine = engine as? any PrimaryDevelopWriting else {
                    throw PrimaryDevelopWriteError(message: "This image writer cannot safely verify a retained Develop edit.")
                }
                let receipt = try await engine.writePrimaryDevelop(request) {
                    try await service.validateWriteCompletionInHeldTransaction(snapshot, sourceRevision: source)
                }
                result.wroteEmbedded = true; result.sourceRevision = receipt.sourceRevision
                writtenSource = receipt.sourceRevision
                try await hooks.afterEmbedded()
            }
            let completion = await service.completeSidecarAndMirrorXMP(request.sidecar, snapshot: snapshot,
                mirrorOnlyIfExisting: !target.writesXMPSidecar, replaceDevelopSettings: request.replaceDevelop,
                replaceOrientation: request.replaceOrientation, expectedSourceRevision: writtenSource,
                beforeXMPCommit: hooks.beforeXMP, beforeJSONCommit: hooks.beforeJSON, afterJSONCommit: hooks.afterJSON)
            result.completion = completion
            result.wasCancelled = completion.wasCancelled
            if !completion.completed {
                result.failure = completion.failure?.message ?? "The Develop save was cancelled."
            } else { result.sourceRevision = writtenSource }
        } catch let error as PrimaryDevelopPhysicalError {
            result.embeddedMayHaveBeenWritten = error.mayHaveWritten
            result.sourceRevision = error.sourceRevision
            result.wasCancelled = error.wasCancelled; result.failure = error.localizedDescription
        } catch {
            result.wasCancelled = error is CancellationError; result.failure = error.localizedDescription
        }
        return result
    }
}

/// Reference wrappers keep the complete technical payload off the encoder's small worker stack.
nonisolated final class PrimaryDevelopRecoveryPayload: Encodable, Sendable {
    let formatVersion = 1
    let kind = "Primary Develop"
    let requestID: UUID
    let imageURL: URL
    let folderURL: URL
    let selectionLoadID: UUID
    let predecessorID: UUID?
    let watermarkDependencies: [PrimaryDevelopWatermarkDependency]
    let mode: String
    let edited: VariableRecoveryMetadata
    let previous: VariableRecoveryMetadata?
    let original: VariableRecoveryMetadata?
    let embeddedBaseline: VariableRecoveryMetadata?
    let originalKnown: Bool
    let expectedRecord: VariableRecoverySidecar?
    let expectedRecordExisted: Bool
    let intendedRecord: VariableRecoverySidecar
    let fullChanges: [MetadataHistoryEntry]
    let expectedXMPData: Data?
    let expectedXMPKnown: Bool
    let sourceRevision: SourceImageRevision?
    let captureFailure: String?
    let replaceDevelop: Bool
    let replaceOrientation: Bool
    let wroteEmbedded: Bool
    let embeddedMayHaveBeenWritten: Bool
    let writtenSourceRevision: SourceImageRevision?
    let wroteXMP: Bool
    let writtenXMPData: Data?
    let committedButUnverifiedJSON: URL?
    let installedRecord: VariableRecoverySidecar?
    let wasCancelled: Bool
    let failure: String?
    init(_ request: PrimaryDevelopWriteRequest, result: PrimaryDevelopWriteResult?) {
        requestID = request.id; imageURL = request.imageURL; folderURL = request.folderURL
        selectionLoadID = request.loadID; predecessorID = request.predecessor?.id; watermarkDependencies = request.watermarkDependencies; mode = request.mode.rawValue
        edited = .init(request.edited); previous = request.previous.map(VariableRecoveryMetadata.init)
        original = request.original.map(VariableRecoveryMetadata.init); originalKnown = request.original != nil
        embeddedBaseline = request.embeddedBaseline.map(VariableRecoveryMetadata.init)
        expectedRecord = request.expectedRecord.map(VariableRecoverySidecar.init); expectedRecordExisted = request.expectedRecord != nil
        intendedRecord = .init(request.sidecar); fullChanges = request.changes
        expectedXMPData = request.expectedXMP?.data; expectedXMPKnown = request.expectedXMP != nil
        sourceRevision = request.sourceRevision; captureFailure = request.captureFailure
        replaceDevelop = request.replaceDevelop; replaceOrientation = request.replaceOrientation
        wroteEmbedded = result?.wroteEmbedded ?? false; embeddedMayHaveBeenWritten = result?.embeddedMayHaveBeenWritten ?? false
        writtenSourceRevision = result?.sourceRevision; wroteXMP = result?.completion?.wroteXMPSidecar ?? false
        writtenXMPData = result?.completion?.writtenXMPSnapshot?.data
        committedButUnverifiedJSON = result?.completion?.committedButUnverifiedSidecarURL
        installedRecord = result?.completion?.installedSidecar.map(VariableRecoverySidecar.init)
        wasCancelled = result?.wasCancelled ?? false; failure = result?.failure
    }
}
