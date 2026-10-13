import CryptoKit
import Foundation
import ImageIO
import SwiftMediaMetadata

/// Independent native admission evidence. No protocol preview values can initialize this
/// capture; template and carrier descriptors remain retained until the complete batch returns.
nonisolated struct DevelopTemplateBatchCapture: Sendable {
    struct PhotoEvidence: Sendable {
        let requestID: UUID
        let rootID: UUID
        let sourceRevision: String
        let xmpSidecarRevision: String
        let appSidecarRevision: String
        let decoder: MCPDevelopTemplatePreview.DecoderState
    }
    let intent: DevelopTemplateBatchIntent
    let template: DevelopTemplate
    let photos: [PhotoEvidence]
}

/// Pure app-side capture, with no persistence, native approval or physical writer. The
/// caller must separately retain this exact intent and authenticate consent before execution.
/// Synchronous parsing/decoding should run off the main actor.
nonisolated struct DevelopTemplateBatchCaptureService: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidSelection, invalidTemplateRevision, metadataConflict, pendingOrientation, byteLimit
    }
    typealias Decoder = @Sendable (Data, URL) throws -> MCPDevelopTemplatePreview.DecoderState
    let facade: MCPAutomationFacade
    let discovery: MCPTemplateDiscovery
    let resolveDecoder: Decoder

    init(facade: MCPAutomationFacade, discovery: MCPTemplateDiscovery,
         resolveDecoder: @escaping Decoder = MCPDevelopTemplatePreview.resolveDecoderState) {
        self.facade = facade; self.discovery = discovery; self.resolveDecoder = resolveDecoder
    }

    func capture(templateID: UUID, templateRevision: String, photos: [URL],
                 mode: MetadataWriteMode, timestamp: Date = Date()) throws -> DevelopTemplateBatchCapture {
        guard !photos.isEmpty, photos.count <= DevelopTemplateBatchIntent.maximumPhotos,
              mode != .historyOnly, photos.allSatisfy({ $0.isFileURL }) else {
            throw Failure.invalidSelection
        }
        guard templateRevision.utf8.count == 71, templateRevision.hasPrefix("sha256:"),
              templateRevision.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidTemplateRevision
        }
        var identities = Set<String>()
        for photo in photos {
            let key = photo.standardizedFileURL.resolvingSymlinksInPath().deletingPathExtension().path.lowercased()
            guard identities.insert(key).inserted else { throw DevelopTemplateBatchFailure.duplicatePhoto }
        }
        try Task.checkCancellation()
        return try discovery.withDevelopTemplate(id: templateID, revision: templateRevision) { template in
            guard (template.settings.watermarkLayers ?? []).isEmpty else {
                throw DevelopTemplateBatchFailure.unsupportedWatermarkDependencies
            }
            // Recursion is bounded to eight targets. Each outer snapshot holds its photo
            // reservation/anchored carriers until all later targets have been resolved.
            func collect(_ index: Int, requests: [PrimaryDevelopWriteRequest],
                         evidence: [DevelopTemplateBatchCapture.PhotoEvidence], bytes: Int) throws -> DevelopTemplateBatchCapture {
                try Task.checkCancellation()
                guard index < photos.count else {
                    let intent = try DevelopTemplateBatchIntent(templateID: templateID,
                        templateRevision: templateRevision, requests: requests)
                    guard try JSONEncoder().encode(DevelopTemplateBatchExecutionResult(intent: intent,
                        results: Array(repeating: nil, count: requests.count)).recoveryPayload).count
                            <= DevelopTemplateBatchExecutionService.maximumRecoveryBytes else { throw Failure.byteLimit }
                    return .init(intent: intent, template: template, photos: evidence)
                }
                return try facade.withPhotoSnapshot(path: photos[index].path) { snapshot in
                    let total = bytes + snapshot.sourceBytes.count + (snapshot.xmpBytes?.count ?? 0)
                        + (snapshot.appSidecarBytes?.count ?? 0)
                    guard total <= DevelopTemplateBatchExecutionService.maximumRecoveryBytes else { throw Failure.byteLimit }
                    let read = try MCPMetadataSnapshotReader.read(snapshot)
                    guard !read.resolution.hasXMPConflict else { throw Failure.metadataConflict }
                    let record = try snapshot.appSidecarBytes.map { data in
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                        return try decoder.decode(MetadataSidecar.self, from: data)
                    }
                    guard record?.orientationDraft == nil else { throw Failure.pendingOrientation }
                    let embedded = try Self.embeddedMetadata(snapshot)
                    let original = record?.imageMetadataSnapshot ?? embedded
                    let previous = read.resolution.metadata
                    // Include baselines even when application would remove a watermark;
                    // execution still needs admission of every affected library dependency.
                    guard PrimaryDevelopWriteRequestBuilder.watermarkDependencyIDs(edited: previous,
                        previous: original, original: embedded).isEmpty else {
                        throw DevelopTemplateBatchFailure.unsupportedWatermarkDependencies
                    }
                    let decoder = try resolveDecoder(snapshot.sourceBytes, snapshot.target.url)
                    try decoder.validate(for: snapshot.target.url)
                    try Task.checkCancellation()
                    var destination = previous.cameraRaw ?? CameraRawSettings()
                    destination.asShotNeutralTemperature = decoder.neutralTemperature
                    destination.asShotNeutralTint = decoder.neutralTint
                    destination.sourceHasHDRHeadroom = decoder.sourceHasHDRHeadroom
                    var edited = previous
                    edited.cameraRaw = template.settingsForApplication(preserving: destination)
                    let source = SourceImageRevision(canonicalURL: snapshot.target.url,
                        fileResourceIdentifier: nil, filenameAtCreation: snapshot.target.url.lastPathComponent,
                        byteCount: Int64(snapshot.sourceBytes.count), contentModificationDate: snapshot.sourceModificationDate,
                        pixelWidth: nil, pixelHeight: nil, exifOrientation: embedded.exifOrientation,
                        sha256: SHA256.hash(data: snapshot.sourceBytes).map { String(format: "%02x", $0) }.joined(),
                        hashCompletedAt: timestamp)
                    let aspect = Self.imageAspect(snapshot.sourceBytes)
                    let xmp = snapshot.xmpBytes.flatMap { XMPMetadataReader.read($0, imageAspect: { aspect }) }
                    guard (xmp?.cameraRaw?.watermarkLayers ?? []).isEmpty else {
                        throw DevelopTemplateBatchFailure.unsupportedWatermarkDependencies
                    }
                    let request = PrimaryDevelopWriteRequestBuilder.build(.init(imageURL: snapshot.target.url,
                        folderURL: snapshot.target.url.deletingLastPathComponent(), loadID: UUID(), mode: mode,
                        edited: edited, previous: previous, original: original, xmpBaseline: xmp,
                        embeddedBaseline: embedded, expectedRecord: record, expectedXMP: .init(data: snapshot.xmpBytes),
                        sourceRevision: source, captureFailure: nil, history: record?.history ?? [], timestamp: timestamp,
                        predecessor: nil, watermarkDependencies: []))
                    let witness = DevelopTemplateBatchCapture.PhotoEvidence(requestID: request.id,
                        rootID: snapshot.target.rootID, sourceRevision: snapshot.sourceRevision,
                        xmpSidecarRevision: snapshot.xmpSidecarRevision, appSidecarRevision: snapshot.appSidecarRevision,
                        decoder: decoder)
                    return try collect(index + 1, requests: requests + [request], evidence: evidence + [witness], bytes: total)
                }
            }
            return try collect(0, requests: [], evidence: [], bytes: 0)
        }
    }

    private static func embeddedMetadata(_ snapshot: MCPPhotoCarrierSnapshot) throws -> IPTCMetadata {
        let hint = FormatDetector.detectFromExtension(snapshot.target.url.pathExtension)
        var format = FormatDetector.detect(snapshot.sourceBytes) ?? hint
        if format == .tiff, MCPPhotoFormatCatalog.rawExtensions.contains(snapshot.target.url.pathExtension.lowercased()) {
            format = hint
        }
        guard let format else { throw MetadataError.unsupportedFormat }
        return iptcMetadataFromDict(try ImageMetadata.read(from: snapshot.sourceBytes, format: format).asMetadataDict())
    }

    private static func imageAspect(_ data: Data) -> Double? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return width / height
    }
}
