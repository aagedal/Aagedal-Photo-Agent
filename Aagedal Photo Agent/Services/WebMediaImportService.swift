import Foundation

/// Imports into a new batch folder. The original is never passed to a metadata writer.
@MainActor
final class WebMediaImportService {
    typealias Download = @Sendable (WebPostInspection, Set<String>, URL?, URL) async throws -> WebDownloadResult
    private let download: Download
    private let writer = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
    private let reader = SwiftExifReadService()
    private let filesystem: WebImportFilesystemService

    init(download: @escaping Download = { inspection, selected, cookies, destination in
        try await WebDownloadRuntimeService.shared.download(inspection, selected: selected, cookies: cookies, to: destination)
    }, filesystem: WebImportFilesystemService = WebImportFilesystemService()) {
        self.download = download
        self.filesystem = filesystem
    }

    func importMedia(
        inspection: WebPostInspection, selected: Set<String>, cookies: URL?,
        destination: URL, caption: String,
        onRetainedBatch: (URL) -> Void = { _ in }, progress: @escaping (String) -> Void
    ) async throws -> URL {
        let batch = try await filesystem.uniqueBatchURL(
            in: destination,
            baseName: Self.batchFolderName(inspection: inspection, selected: selected, date: Date())
        )
        let originals = batch.appendingPathComponent("Originals", isDirectory: true)
        let working = batch.appendingPathComponent("Working", isDirectory: true)
        let provenance = batch.appendingPathComponent("Provenance", isDirectory: true)
        do {
            try await filesystem.prepare(batch: batch, inspection: inspection)
            progress("Downloading \(selected.count) selected media items…")
            let result = try await download(inspection, selected, cookies, originals)
            try Task.checkCancellation()
            guard !result.files.isEmpty else {
                throw WebDownloadRuntimeService.RuntimeError.failed("No media was downloaded. Try finding the media again before importing.")
            }
            let returnedIDs = Set(result.files.map { $0.item.id })
            guard returnedIDs == selected, result.files.count == selected.count,
                  selected.isSubset(of: Set(inspection.items.map(\.id))),
                  Set(result.files.map(\.filename)).count == result.files.count else {
                throw WebDownloadRuntimeService.RuntimeError.failed("The downloaded media did not match your selection. Find the media again before importing.")
            }
            guard result.files.allSatisfy({ file in
                !file.filename.isEmpty && file.filename == URL(fileURLWithPath: file.filename).lastPathComponent
                    && !file.filename.hasPrefix(".")
            }) else { throw WebDownloadRuntimeService.RuntimeError.invalidResponse }
            try await filesystem.createWorkingDirectory(working)
            for (index, file) in result.files.enumerated() {
                try Task.checkCancellation()
                progress("Writing metadata \(index + 1) of \(result.files.count)…")
                let original = originals.appendingPathComponent(file.filename)
                let copy = working.appendingPathComponent(file.filename)
                let digest = try await filesystem.copyAndVerify(original: original, copy: copy)
                try Task.checkCancellation()
                var metadata = IPTCMetadata()
                let normalizedCaption = caption.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                metadata.description = normalizedCaption.isEmpty ? nil : normalizedCaption
                metadata.source = file.item.username.isEmpty ? inspection.url : "@\(file.item.username)"
                metadata.instructions = "Source post: \(inspection.url)\nPosted: \(file.item.publishedAt)\nCarousel item: \(file.item.position)"
                // A posting account is not evidence of authorship or publication permission.
                let canEmbed = Self.embeddableExtensions.contains(copy.pathExtension.lowercased())
                let hasCredential = canEmbed ? (try await reader.readTechnicalMetadata(url: copy)).hasC2PA : false
                try Task.checkCancellation()
                let mode = Self.metadataWriteMode(for: copy, hasCredential: hasCredential)
                if mode != .historyOnly {
                    _ = try await writer.write(metadata: metadata, for: copy, requestedMode: mode, semantics: .merge)
                    try Task.checkCancellation()
                }
                if mode.writesEmbedded {
                    let readBack = try await reader.readFullMetadata(url: copy)
                    guard readBack.description == metadata.description,
                          readBack.source == metadata.source,
                          readBack.instructions == metadata.instructions else {
                        throw WebDownloadRuntimeService.RuntimeError.failed("Downloaded metadata could not be verified. The original is retained.")
                    }
                }
                if mode.writesXMPSidecar {
                    let readBack = try await filesystem.readSidecar(for: copy)
                    guard readBack?.description == metadata.description,
                          readBack?.source == metadata.source,
                          readBack?.instructions == metadata.instructions else {
                        throw WebDownloadRuntimeService.RuntimeError.failed("Downloaded sidecar metadata could not be verified. The original is retained.")
                    }
                }
                let record = WebImportProvenance(schemaVersion: 1, postURL: inspection.url,
                    downloadedAt: Date(), downloaderVersions: result.versions, media: file.item,
                    originalFilename: "Originals/\(file.filename)", originalSHA256: digest,
                    workingFilename: "Working/\(file.filename)",
                    metadataStorage: Self.metadataStorageDescription(for: mode))
                try await filesystem.writeProvenance(record, to: provenance.appendingPathComponent(file.filename + ".json"))
            }
            try Task.checkCancellation()
            await filesystem.cleanupEmptyBatch(batch)
            return working
        } catch {
            if let retained = await filesystem.cleanupEmptyBatch(batch) {
                onRetainedBatch(retained)
            }
            throw error
        }
    }

    /// Formats the metadata writer embeds into reliably; anything else (video, WebP, …) gets
    /// an XMP sidecar even when the preset asks for embedding.
    static let embeddableExtensions: Set<String> = ["jpg", "jpeg"]

    /// The user's write preset decides the destination, like every other descriptive write.
    static func metadataWriteMode(for url: URL, hasCredential: Bool) -> MetadataWriteMode {
        let mode = MetadataWriteMode.current(
            forC2PA: hasCredential, isRaw: SupportedImageFormats.isRaw(url: url)
        )
        guard mode.writesEmbedded,
              !embeddableExtensions.contains(url.pathExtension.lowercased()) else { return mode }
        return .writeToXMPSidecar
    }

    static func metadataStorageDescription(for mode: MetadataWriteMode) -> String {
        switch mode {
        case .writeToFile: return "embedded IPTC/XMP"
        case .writeToXMPSidecar: return "XMP sidecar"
        case .writeToFileAndXMPSidecar: return "embedded IPTC/XMP and XMP sidecar"
        case .historyOnly: return "not written (Save History Only)"
        }
    }

    /// "Web Import 2026-10-24 153012 @account <post>" — sortable and recognisable in Finder,
    /// unlike the old UUID names. Uniqueness comes from `uniqueBatchURL`.
    static func batchFolderName(inspection: WebPostInspection, selected: Set<String>, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        var parts = ["Web Import", formatter.string(from: date)]
        let items = inspection.items.filter { selected.contains($0.id) }
        if let account = items.first(where: { !$0.username.isEmpty })?.username {
            parts.append("@\(account)")
        }
        if let post = items.first(where: { !$0.postID.isEmpty })?.postID {
            parts.append(post)
        }
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        let name = parts.joined(separator: " ")
            .components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return String(name.prefix(120))
    }
}
