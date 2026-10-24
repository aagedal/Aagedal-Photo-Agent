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
    /// The JPEG of a RAW+JPEG pair: its embedded write carries only Camera Raw settings —
    /// descriptive metadata keeps going to its preset destination through the sidecar mirror.
    let embedsDevelopOnly: Bool
    /// Simple preset semantics: embedding into a credentialed file is accepted, like every
    /// other Simple write. Otherwise a develop-only embed refuses a file with Content Credentials.
    let allowsCredentialedEmbed: Bool
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
         replaceDevelop: Bool, replaceOrientation: Bool, predecessor: PrimaryDevelopWriteRequest? = nil, watermarkDependencies: [PrimaryDevelopWatermarkDependency] = [], embeddedBaseline: IPTCMetadata? = nil,
         embedsDevelopOnly: Bool = false, allowsCredentialedEmbed: Bool = false) {
        self.embedsDevelopOnly = embedsDevelopOnly; self.allowsCredentialedEmbed = allowsCredentialedEmbed
        self.imageURL = imageURL; self.folderURL = folderURL; self.loadID = loadID; self.mode = mode; self.predecessor = predecessor; self.watermarkDependencies = watermarkDependencies
        self.edited = edited; self.previous = previous; self.original = original; self.embeddedBaseline = embeddedBaseline
        self.expectedRecord = expectedRecord; self.expectedXMP = expectedXMP; self.sourceRevision = sourceRevision
        self.captureFailure = captureFailure; self.sidecar = sidecar; self.changes = changes
        self.fields = fields; self.structured = structured
        self.replaceDevelop = replaceDevelop; self.replaceOrientation = replaceOrientation
    }
}
/// Immutable admission inputs shared by native and future automation callers.
/// Evidence and watermark bytes must already be captured by the caller; building performs no I/O.
nonisolated struct PrimaryDevelopWriteCapture: Sendable {
    let imageURL: URL
    let folderURL: URL
    let loadID: UUID
    let mode: MetadataWriteMode
    let edited: IPTCMetadata
    let previous: IPTCMetadata?
    let original: IPTCMetadata?
    let xmpBaseline: IPTCMetadata?
    let embeddedBaseline: IPTCMetadata?
    let expectedRecord: MetadataSidecar?
    let expectedXMP: XMPSidecarWriteSnapshot?
    let sourceRevision: SourceImageRevision?
    let captureFailure: String?
    let history: [MetadataHistoryEntry]
    let timestamp: Date
    let predecessor: PrimaryDevelopWriteRequest?
    let watermarkDependencies: [PrimaryDevelopWatermarkDependency]
    var embedsDevelopOnly = false
    var allowsCredentialedEmbed = false
}

nonisolated enum PrimaryDevelopWriteRequestBuilder {
    static func build(_ capture: PrimaryDevelopWriteCapture) -> PrimaryDevelopWriteRequest {
        let edited = capture.edited
        let ancestry = PrimaryDevelopWriteRequest.ancestry(of: capture.predecessor.map { [$0] } ?? [])
        let identityMatches = ancestry.allSatisfy {
            $0.imageURL == capture.imageURL && $0.folderURL == capture.folderURL && $0.loadID == capture.loadID
        }
        // Invalid ancestry is retained as a failed capture, but never supplies another editor's baselines.
        let predecessor = identityMatches ? capture.predecessor : nil
        let previous = predecessor?.edited ?? capture.previous
        let changes = MetadataHistoryEntry.changes(from: previous ?? IPTCMetadata(), to: edited, timestamp: capture.timestamp)
        var history = predecessor?.sidecar.history ?? capture.history
        history.append(contentsOf: changes)
        history.trimToHistoryLimit()
        let sidecar = MetadataSidecar(sourceFile: capture.imageURL.lastPathComponent,
            lastModified: capture.timestamp, pendingChanges: false,
            metadata: edited, imageMetadataSnapshot: edited, history: history)
        let writesEmbedded = DescriptiveMetadataWriteTargetResolver().resolve(
            sourceURL: capture.imageURL, requestedMode: capture.mode).writesEmbedded
        let xmpBaseline = predecessor?.edited ?? capture.xmpBaseline
        // An XMP-only predecessor cannot acknowledge embedded technical state.
        let embeddedPredecessor = PrimaryDevelopWriteRequest.ancestry(of: predecessor.map { [$0] } ?? []).first {
            DescriptiveMetadataWriteTargetResolver().resolve(sourceURL: $0.imageURL, requestedMode: $0.mode).writesEmbedded
        }
        let embeddedBaseline = embeddedPredecessor?.edited ?? capture.embeddedBaseline
        let replaceDevelop = developSettingsChanged(edited.cameraRaw, xmpBaseline?.cameraRaw)
            || (writesEmbedded && developSettingsChanged(edited.cameraRaw, embeddedBaseline?.cameraRaw))
        let replaceOrientation = edited.exifOrientation != xmpBaseline?.exifOrientation
            || (writesEmbedded && edited.exifOrientation != embeddedBaseline?.exifOrientation)
        let structured = replaceDevelop ? StructuredWriteData(toneCurve: edited.cameraRaw?.toneCurve,
            masks: edited.cameraRaw?.localAdjustments, watermarkLayers: edited.cameraRaw?.watermarkLayers,
            hslAdjustments: edited.cameraRaw?.hslAdjustments, layerOrder: edited.cameraRaw?.layerOrder,
            anonymizer: edited.cameraRaw?.anonymizer, unparsedMaskCorrections: edited.cameraRaw?.unparsedMaskCorrections,
            editorial: .init(metadata: edited), replaceCameraRawBlock: true)
            : StructuredWriteData(editorial: .init(metadata: edited))
        var fields = overwriteFields(from: edited, original: capture.original, includeCameraRaw: replaceDevelop)
        if replaceDevelop && edited.cameraRaw == nil { clearAllCameraRawFields(into: &fields) }
        var structuredData = structured
        if capture.embedsDevelopOnly {
            // Develop-only embed: no descriptive field, clear or editorial structure.
            fields = [:]
            if replaceDevelop {
                if let cameraRaw = edited.cameraRaw { fields = cameraRaw.developWriteFields() }
                else { clearAllCameraRawFields(into: &fields) }
            }
            structuredData = replaceDevelop ? StructuredWriteData(toneCurve: edited.cameraRaw?.toneCurve,
                masks: edited.cameraRaw?.localAdjustments, watermarkLayers: edited.cameraRaw?.watermarkLayers,
                hslAdjustments: edited.cameraRaw?.hslAdjustments, layerOrder: edited.cameraRaw?.layerOrder,
                anonymizer: edited.cameraRaw?.anonymizer, unparsedMaskCorrections: edited.cameraRaw?.unparsedMaskCorrections,
                replaceCameraRawBlock: true) : .empty
        }
        let failure = capture.captureFailure
            ?? (!identityMatches ? "The earlier captured Primary Develop edit belongs to another photo or editor load. This edit remains retained for recovery." : nil)
            ?? (capture.sourceRevision == nil ? "The loaded source revision is unavailable. This Primary Develop edit remains retained for recovery." : nil)
            ?? (capture.expectedXMP == nil ? "The loaded XMP revision is unavailable. This Primary Develop edit remains retained for recovery." : nil)
        return PrimaryDevelopWriteRequest(imageURL: capture.imageURL, folderURL: capture.folderURL,
            loadID: capture.loadID, mode: capture.mode, edited: edited, previous: previous,
            original: capture.original, expectedRecord: capture.expectedRecord, expectedXMP: capture.expectedXMP,
            sourceRevision: capture.sourceRevision, captureFailure: failure, sidecar: sidecar, changes: changes,
            fields: fields, structured: structuredData, replaceDevelop: replaceDevelop,
            replaceOrientation: replaceOrientation, predecessor: predecessor,
            watermarkDependencies: capture.watermarkDependencies, embeddedBaseline: embeddedBaseline,
            embedsDevelopOnly: capture.embedsDevelopOnly, allowsCredentialedEmbed: capture.allowsCredentialedEmbed)
    }

    static func watermarkDependencyIDs(edited: IPTCMetadata, previous: IPTCMetadata?, original: IPTCMetadata?) -> Set<UUID> {
        Set(([edited, previous, original].compactMap { $0 }).flatMap {
            ($0.cameraRaw?.watermarkLayers ?? []).map(\.libraryAssetID)
        })
    }

    static func developSettingsChanged(_ a: CameraRawSettings?, _ b: CameraRawSettings?) -> Bool {
        func normalized(_ s: CameraRawSettings?) -> CameraRawSettings? {
            guard var s else { return nil }
            s.asShotNeutralTemperature = nil
            s.asShotNeutralTint = nil
            s.sourceHasHDRHeadroom = nil
            return s
        }
        return normalized(a) != normalized(b)
    }

    static func overwriteFields(from metadata: IPTCMetadata, original: IPTCMetadata?,
        includeCameraRaw: Bool = true, imageAspect: () -> Double? = { nil }) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        fields[.headline] = metadata.title ?? ""
        fields[.description] = metadata.description ?? ""
        fields[.extendedDescription] = metadata.extendedDescription ?? ""
        fields[.subject] = metadata.keywords.uniqued().joined(separator: ", ")
        fields[.personInImage] = metadata.personShown.uniqued().joined(separator: ", ")
        fields[.organisationInImageName] = metadata.organisationsShownNames.uniqued().joined(separator: ", ")
        fields[.organisationInImageCode] = metadata.organisationsShownCodes.uniqued().joined(separator: ", ")
        fields[.scene] = metadata.sceneCodes.uniqued().joined(separator: ", ")
        fields[.subjectCode] = metadata.subjectCodes.uniqued().joined(separator: ", ")
        fields[.mediaTopic] = metadata.mediaTopics.map(\.termIdentifier).uniqued().joined(separator: ", ")
        fields[.genre] = metadata.genres.map(\.termIdentifier).uniqued().joined(separator: ", ")
        fields[.digitalSourceType] = metadata.digitalSourceType?.newsCodeURI ?? ""
        fields[.urgency] = metadata.urgency.map(String.init) ?? ""
        fields[.creator] = metadata.creatorTransportValue ?? ""
        fields[.creatorJobTitle] = metadata.creatorJobTitle ?? ""
        fields[.descriptionWriter] = metadata.descriptionWriter ?? ""
        fields[.credit] = metadata.credit ?? ""
        fields[.rights] = metadata.copyright ?? ""
        fields[.rightsUsageTerms] = metadata.rightsUsageTerms ?? ""
        fields[.webStatementOfRights] = metadata.webStatementOfRights ?? ""
        fields[.digitalImageGUID] = metadata.digitalImageGUID ?? ""
        fields[.imageSupplierImageID] = metadata.imageSupplierImageID ?? ""
        fields[.transmissionReference] = metadata.jobId ?? ""
        fields[.dateCreated] = metadata.dateCreated ?? ""
        fields[.city] = metadata.city ?? ""
        fields[.sublocation] = metadata.sublocation ?? ""
        fields[.provinceState] = metadata.provinceState ?? ""
        fields[.country] = metadata.country ?? ""
        fields[.countryCode] = metadata.countryCode ?? ""
        fields[.event] = metadata.event ?? ""
        fields[.instructions] = metadata.instructions ?? ""
        fields[.source] = metadata.source ?? ""

        if let lat = metadata.latitude, let lon = metadata.longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        } else {
            fields[.gpsLatitude] = ""
            fields[.gpsLatitudeRef] = ""
            fields[.gpsLongitude] = ""
            fields[.gpsLongitudeRef] = ""
        }

        // Caption-only saves must not touch the crs block at all — rewriting it
        // (even merge-style) churns Adobe's develop settings for no reason.
        if includeCameraRaw {
            if let cameraRaw = metadata.cameraRaw {
                fields.merge(cameraRaw.developWriteFields(imageAspect: imageAspect)) { _, new in new }
            } else if original?.cameraRaw != nil {
                clearAllCameraRawFields(into: &fields)
            }
        }
        return fields
    }

    static func clearAllCameraRawFields(into fields: inout [MetadataFieldKey: String]) {
        fields[.crsVersion] = ""
        fields[.crsProcessVersion] = ""
        fields[.crsWhiteBalance] = ""
        fields[.crsTemperature] = ""
        fields[.crsTint] = ""
        fields[.crsIncrementalTemperature] = ""
        fields[.crsIncrementalTint] = ""
        fields[.crsExposure2012] = ""
        fields[.crsContrast2012] = ""
        fields[.crsHighlights2012] = ""
        fields[.crsShadows2012] = ""
        fields[.crsWhites2012] = ""
        fields[.crsBlacks2012] = ""
        fields[.crsSaturation] = ""
        fields[.crsVibrance] = ""
        fields[.aaphotoGlobalDensity] = ""
        fields[.crsSharpness] = ""
        fields[.crsClarity2012] = ""
        fields[.crsDehaze] = ""
        fields[.crsHasSettings] = "False"
        fields[.crsCropTop] = ""
        fields[.crsCropLeft] = ""
        fields[.crsCropBottom] = ""
        fields[.crsCropRight] = ""
        fields[.crsCropAngle] = ""
        fields[.crsHasCrop] = ""
        fields[.crsCropConstrainToWarp] = ""
        fields[.crsCropConstrainToUnitSquare] = ""
        fields[.crsHDREditMode] = ""
        fields[.crsHDRMaxValue] = ""
        fields[.crsSDRBrightness] = ""
        fields[.crsSDRContrast] = ""
        fields[.crsSDRClarity] = ""
        fields[.crsSDRHighlights] = ""
        fields[.crsSDRShadows] = ""
        fields[.crsSDRWhites] = ""
        fields[.crsSDRBlend] = ""
        fields[.crsToneCurveName2012] = ""
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
    var refusedForContentCredentials = false
    var errorDescription: String? { message }
}
nonisolated protocol PrimaryDevelopWriting: Sendable {
    func writePrimaryDevelop(_ request: PrimaryDevelopWriteRequest,
        validatePreparedIntent: @escaping @Sendable () async throws -> Void,
        validateCommitAuthority: @escaping @Sendable () throws -> Void) async throws -> PrimaryDevelopPhysicalReceipt
}
nonisolated struct PrimaryDevelopWriteResult: Sendable {
    let requestID: UUID
    var completion: MetadataSidecarPersistenceResult?
    var sourceRevision: SourceImageRevision?
    var wroteEmbedded = false
    var embeddedMayHaveBeenWritten = false
    var wasCancelled = false
    var failure: String?
    /// The paired JPEG turned out to carry Content Credentials; nothing was written.
    var refusedForContentCredentials = false
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
    func execute(_ request: PrimaryDevelopWriteRequest, predecessorResult: PrimaryDevelopWriteResult? = nil,
                 heldReservation: MCPProcessReservationLease? = nil,
                 validateAuthority: @escaping @Sendable () async throws -> Void = {},
                 validateCommitAuthority: @escaping @Sendable () throws -> Void = {}) async -> PrimaryDevelopWriteResult {
        var result = PrimaryDevelopWriteResult(requestID: request.id)
        do {
            try Task.checkCancellation()
            guard heldReservation?.coversPhoto(request.imageURL) != false else {
                throw MCPProcessReservationError.unavailable
            }
            let reservation = try heldReservation ?? MCPProcessReservation.acquirePhoto(request.imageURL)
            defer { if heldReservation == nil { reservation.release() } }
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
            // The JPEG of a RAW+JPEG pair keeps its develop settings embedded (Adobe); the shared
            // stem sidecar's crs belongs to the RAW and is never written for the JPEG. A
            // sidecar-only target would therefore drop the edit — refuse it visibly instead.
            if !target.writesEmbedded, request.replaceDevelop,
               PrimaryDevelopWriteRequestBuilder.developSettingsChanged(request.edited.cameraRaw, request.previous?.cameraRaw),
               let rawURL = PhotoSidecarOwnership.developOwningRawSibling(of: request.imageURL) {
                throw StemSidecarDevelopOwnedByRawError(imageURL: request.imageURL, rawURL: rawURL)
            }
            try await validateAuthority()
            // A develop-only embed with no develop change has nothing to put in the file.
            if target.writesEmbedded, !(request.embedsDevelopOnly && !request.replaceDevelop) {
                guard let engine = engine as? any PrimaryDevelopWriting else {
                    throw PrimaryDevelopWriteError(message: "This image writer cannot safely verify a retained Develop edit.")
                }
                let receipt = try await engine.writePrimaryDevelop(request, validatePreparedIntent: {
                    try await validateAuthority()
                    try await service.validateWriteCompletionInHeldTransaction(snapshot, sourceRevision: source)
                }, validateCommitAuthority: validateCommitAuthority)
                result.wroteEmbedded = true; result.sourceRevision = receipt.sourceRevision
                writtenSource = receipt.sourceRevision
                try await hooks.afterEmbedded()
            }
            try await validateAuthority()
            let completion = await service.completeSidecarAndMirrorXMP(request.sidecar, snapshot: snapshot,
                mirrorOnlyIfExisting: !target.writesXMPSidecar, replaceDevelopSettings: request.replaceDevelop,
                replaceOrientation: request.replaceOrientation, expectedSourceRevision: writtenSource,
                beforeXMPCommit: hooks.beforeXMP, beforeJSONCommit: hooks.beforeJSON,
                afterJSONCommit: hooks.afterJSON, validateCommitAuthority: validateCommitAuthority)
            result.completion = completion
            result.wasCancelled = completion.wasCancelled
            if !completion.completed {
                result.failure = completion.failure?.message ?? "The Develop save was cancelled."
            } else { result.sourceRevision = writtenSource }
        } catch let error as PrimaryDevelopPhysicalError {
            result.embeddedMayHaveBeenWritten = error.mayHaveWritten
            result.refusedForContentCredentials = error.refusedForContentCredentials
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
