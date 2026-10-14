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
        destination: URL, caption: String, progress: @escaping (String) -> Void
    ) async throws -> URL {
        let batch = destination.appendingPathComponent("Web Import \(UUID().uuidString)", isDirectory: true)
        let originals = batch.appendingPathComponent("Originals", isDirectory: true)
        let working = batch.appendingPathComponent("Working", isDirectory: true)
        let provenance = batch.appendingPathComponent("Provenance", isDirectory: true)
        do {
            try await filesystem.prepare(batch: batch, inspection: inspection)
            progress("Downloading selected media…")
            let result = try await download(inspection, selected, cookies, originals)
            try Task.checkCancellation()
            try await filesystem.createWorkingDirectory(working)
            for (index, file) in result.files.enumerated() {
                try Task.checkCancellation()
                guard file.filename == URL(fileURLWithPath: file.filename).lastPathComponent,
                      !file.filename.hasPrefix(".") else { throw WebDownloadRuntimeService.RuntimeError.invalidResponse }
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
                let isJPEG = ["jpg", "jpeg"].contains(copy.pathExtension.lowercased())
                let hasCredential = isJPEG ? (try await reader.readTechnicalMetadata(url: copy)).hasC2PA : false
                try Task.checkCancellation()
                let mode: MetadataWriteMode = isJPEG && !hasCredential ? .writeToFile : .writeToXMPSidecar
                _ = try await writer.write(metadata: metadata, for: copy, requestedMode: mode, semantics: .merge)
                try Task.checkCancellation()
                if mode == .writeToFile {
                    let readBack = try await reader.readFullMetadata(url: copy)
                    guard readBack.description == metadata.description,
                          readBack.source == metadata.source,
                          readBack.instructions == metadata.instructions else {
                        throw WebDownloadRuntimeService.RuntimeError.failed("Downloaded metadata could not be verified. The original is retained.")
                    }
                } else {
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
                    metadataStorage: mode == .writeToFile ? "embedded IPTC/XMP" : "XMP sidecar")
                try await filesystem.writeProvenance(record, to: provenance.appendingPathComponent(file.filename + ".json"))
            }
            try Task.checkCancellation()
            await filesystem.cleanupEmptyBatch(batch)
            return working
        } catch {
            await filesystem.cleanupEmptyBatch(batch)
            throw error
        }
    }
}
