import AppKit
import Foundation
import SwiftExif
import os.log

nonisolated private let swiftExifReadLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "SwiftExifReadService"
)
nonisolated private let swiftExifReadPerf = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "MetadataPerf"
)

/// In-process metadata reader backed by SwiftExif. There is no process
/// lifecycle to manage, so callers no longer need to `start()`.
@Observable
final class SwiftExifReadService {
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
        swiftExifReadLog.debug("readFullMetadata: \(url.lastPathComponent, privacy: .public)")
        guard let dict = await lockedReadDict(for: url)?.value else { return IPTCMetadata() }
        return iptcMetadataFromDict(dict)
    }

    /// Read full metadata for a single file plus a XMP-Description vs IPTC-Caption-Abstract conflict probe.
    func readFullMetadataWithConflictCheck(
        url: URL
    ) async throws -> (IPTCMetadata, DescriptionConflict?) {
        let singleStart = ContinuousClock.now
        swiftExifReadPerf.info(
            "[Single] readFullMetadataWithConflictCheck START — \(url.lastPathComponent, privacy: .public)"
        )
        guard let dict = await lockedReadDict(for: url)?.value else {
            return (IPTCMetadata(), nil)
        }
        let singleMs = singleStart.elapsedMilliseconds()
        swiftExifReadPerf.info(
            "[Single] readFullMetadataWithConflictCheck DONE — \(url.lastPathComponent, privacy: .public) in \(singleMs)ms"
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
    func readTechnicalMetadata(url: URL) async throws -> TechnicalMetadata {
        guard let dict = await lockedReadDict(for: url)?.value else {
            return TechnicalMetadata(from: [:], fileURL: url)
        }
        return TechnicalMetadata(from: dict, fileURL: url)
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
                "readDict failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
