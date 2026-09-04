import AppKit
import Foundation
import SwiftMediaMetadata
import os.log

nonisolated private let swiftExifReadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "SwiftExifReadService"
)
nonisolated private let swiftExifReadPerf = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "MetadataPerf"
)

/// Builds the complete immutable technical-metadata snapshot while the per-photo metadata
/// executor still owns the operation. The production closure includes the optional ImageIO
/// header read performed by `TechnicalMetadata.init(from:fileURL:)`; keeping it injectable lets
/// tests prove that read never drifts back onto MainActor after the serialized metadata read.
nonisolated struct SwiftExifTechnicalMetadataAccess: Sendable {
    let makeSnapshot: @Sendable ([String: Any], URL?) -> TechnicalMetadata

    static let system = SwiftExifTechnicalMetadataAccess { dictionary, fileURL in
        TechnicalMetadata(from: dictionary, fileURL: fileURL)
    }
}

/// In-process metadata reader backed by SwiftExif. There is no process
/// lifecycle to manage, so callers no longer need to `start()`.
@Observable
final class SwiftExifReadService {
    @ObservationIgnored private let technicalMetadataAccess: SwiftExifTechnicalMetadataAccess

    init(
        technicalMetadataAccess: SwiftExifTechnicalMetadataAccess = .system
    ) {
        self.technicalMetadataAccess = technicalMetadataAccess
    }

    /// SwiftExif is always available — there is no external binary.
    var isAvailable: Bool { true }

    /// No-op kept for source compatibility during migration.
    func start() throws {}

    /// No-op kept for source compatibility during migration.
    func stop() {}

    // MARK: - Batch reads

    /// Read basic metadata (rating, label, persons, Camera Raw flags, orientation, C2PA presence)
    /// for a batch of files, in a flat tag-name dictionary keyed by `MetadataDictKey` constants.
    func readBatchBasicMetadata(urls: [URL]) async throws -> [[String: Any]] {
        guard !urls.isEmpty else { return [] }
        let batchStart = ContinuousClock.now
        swiftExifReadPerf.info("[Batch] readBatchBasicMetadata START — \(urls.count) files")

        let dicts = await readDicts(for: urls)

        let batchMs = batchStart.elapsedMilliseconds()
        swiftExifReadPerf.info("[Batch] readBatchBasicMetadata DONE — \(urls.count) files in \(batchMs)ms")
        return dicts
    }

    /// Read full IPTC + XMP + EXIF metadata for a batch, keyed by URL.
    /// Files that fail to parse are omitted.
    func readBatchFullMetadata(urls: [URL]) async throws -> [URL: IPTCMetadata] {
        guard !urls.isEmpty else { return [:] }

        var results: [URL: IPTCMetadata] = [:]
        results.reserveCapacity(urls.count)

        await withTaskGroup(of: (URL, IPTCMetadata?).self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self else { return (url, nil) }
                    let dict = await self.lockedReadDict(for: url)?.value
                    return (url, dict.map(iptcMetadataFromDict))
                }
            }
            for await (url, meta) in group {
                if let meta { results[url] = meta }
            }
        }
        return results
    }

    // MARK: - Single-file reads

    /// Read full IPTC + XMP + EXIF metadata for a single file.
    func readFullMetadata(url: URL) async throws -> IPTCMetadata {
        swiftExifReadLog.debug("readFullMetadata: \(url.lastPathComponent, privacy: .private(mask: .hash))")
        guard let dict = await lockedReadDict(for: url)?.value else { return IPTCMetadata() }
        return iptcMetadataFromDict(dict)
    }

    /// Read full metadata for a single file plus a XMP-Description vs IPTC-Caption-Abstract conflict probe.
    func readFullMetadataWithConflictCheck(
        url: URL
    ) async throws -> (IPTCMetadata, DescriptionConflict?) {
        let singleStart = ContinuousClock.now
        swiftExifReadPerf.info(
            "[Single] readFullMetadataWithConflictCheck START — \(url.lastPathComponent, privacy: .private(mask: .hash))"
        )
        guard let dict = await lockedReadDict(for: url)?.value else {
            return (IPTCMetadata(), nil)
        }
        let singleMs = singleStart.elapsedMilliseconds()
        swiftExifReadPerf.info(
            "[Single] readFullMetadataWithConflictCheck DONE — \(url.lastPathComponent, privacy: .private(mask: .hash)) in \(singleMs)ms"
        )
        return (iptcMetadataFromDict(dict), descriptionConflict(in: dict))
    }

    /// Read all metadata for a single file as a pretty-printed JSON string.
    /// The format is presentational only; callers display this verbatim.
    func readRawJSON(url: URL) async throws -> String {
        let metadata = try await lockedReadMetadata(for: url)
        let pretty = MetadataExporter.toJSONString(metadata)
        return pretty
    }

    /// Read camera / lens / dimension / ICC / C2PA-presence fields for the technical inspector.
    func readTechnicalMetadata(url: URL, includeNativeImageInfo: Bool = true) async throws -> TechnicalMetadata {
        await lockedReadTechnicalMetadata(
            for: url,
            includeNativeImageInfo: includeNativeImageInfo,
            access: technicalMetadataAccess
        )
    }

    /// Read detailed C2PA manifest data.
    func readC2PAMetadata(url: URL) async throws -> C2PAMetadata {
        let metadata = try await lockedReadMetadata(for: url)
        guard let c2pa = metadata.c2pa else { return C2PAMetadata(manifests: []) }
        return C2PAMetadata(from: c2pa)
    }

    /// Read embedded C2PA assertion thumbnails (claim + ingredient).
    func readC2PAThumbnails(url: URL) async throws -> C2PAThumbnails {
        let metadata = try await lockedReadMetadata(for: url)
        guard let c2pa = metadata.c2pa else {
            return C2PAThumbnails(claimThumbnail: nil, ingredientThumbnail: nil)
        }
        return C2PAThumbnails(from: c2pa)
    }

    // MARK: - Internal

    /// `readDict`, but serialized against writes to the same photo via `MetadataIOCoordinator`,
    /// so a read never observes a half-written file. Returns a `DictBox` because `[String: Any]`
    /// isn't `Sendable` and must cross the coordinator's task boundary.
    nonisolated private func lockedReadDict(for url: URL) async -> DictBox? {
        await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
            self.readDict(for: url).map(DictBox.init)
        }
    }

    /// `ImageMetadata.read`, serialized against writes to the same photo.
    nonisolated private func lockedReadMetadata(for url: URL) async throws -> ImageMetadata {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
            try ImageMetadata.read(from: url)
        }
    }

    /// Keep snapshot assembly in the same off-main serialized operation as the source read.
    /// `TechnicalMetadata` is Sendable, so unlike the generic dictionary it can cross directly
    /// back to the observable owner without a second filesystem-capable step on MainActor.
    nonisolated private func lockedReadTechnicalMetadata(
        for url: URL,
        includeNativeImageInfo: Bool,
        access: SwiftExifTechnicalMetadataAccess
    ) async -> TechnicalMetadata {
        await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
            let dictionary = self.readDict(for: url) ?? [:]
            return access.makeSnapshot(
                dictionary,
                includeNativeImageInfo ? url : nil
            )
        }
    }

    /// Read one file and return the canonical tag-name dict, or nil on parse error.
    /// `nonisolated` so background tasks can call it without bouncing onto the main actor.
    nonisolated private func readDict(for url: URL) -> [String: Any]? {
        do {
            let metadata = try ImageMetadata.read(from: url)
            var dict = metadata.asMetadataDict(fileURL: url)
            // Mark files that have a C2PA manifest with the legacy sentinel
            // key so `TechnicalMetadata.dictHasC2PA` returns true.
            if let c2pa = metadata.c2pa, !c2pa.manifests.isEmpty {
                dict["JUMD-c2pa-marker"] = "present"
            }
            // The ACR crop-convention conversion needs the sensor-frame aspect.
            // When the EXIF block doesn't carry dimensions but the file has an
            // angled crop, back-fill them from the container header.
            if dict[MetadataDictKey.imageWidth] == nil || dict[MetadataDictKey.imageHeight] == nil,
               abs(parseDoubleValue(dict[MetadataDictKey.crsCropAngle]) ?? 0) > 0.0001,
               let size = ImagePixelAspect.pixelSize(at: url) {
                dict[MetadataDictKey.imageWidth] = size.width
                dict[MetadataDictKey.imageHeight] = size.height
            }
            return dict
        } catch {
            swiftExifReadLog.warning(
                "readDict failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    /// Read many files concurrently, returning their dicts (failures omitted).
    /// Each result carries `SourceFile` so callers can re-key by URL when needed.
    /// Result order is not guaranteed to match input order.
    nonisolated private func readDicts(for urls: [URL]) async -> [[String: Any]] {
        var collected: [[String: Any]] = []
        collected.reserveCapacity(urls.count)

        await withTaskGroup(of: DictBox?.self) { group in
            for url in urls {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    if Task.isCancelled { return nil }
                    return await self.lockedReadDict(for: url)
                }
            }
            for await result in group {
                if let result { collected.append(result.value) }
            }
        }
        return collected
    }
}

/// `[String: Any]` is not Sendable because `Any` isn't, but the dict instances
/// produced by `readDict` are constructed inside the task and never mutated
/// after they cross the task-group boundary — handing them off is safe in
/// practice. This box exists solely to satisfy strict concurrency.
nonisolated private struct DictBox: @unchecked Sendable {
    let value: [String: Any]
}
