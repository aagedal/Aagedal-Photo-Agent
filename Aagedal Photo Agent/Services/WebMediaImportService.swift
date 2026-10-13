import Foundation

/// Imports into a new batch folder. The original is never passed to a metadata writer.
@MainActor
final class WebMediaImportService {
    typealias Download = @Sendable (WebPostInspection, Set<String>, URL?, URL) async throws -> WebDownloadResult
    private let download: Download
    private let writer = DescriptiveMetadataWriteBoundary(writeEngine: SwiftExifWriteEngine())
    private let reader = SwiftExifReadService()

    init(download: @escaping Download = { inspection, selected, cookies, destination in
        try await WebDownloadRuntimeService.shared.download(inspection, selected: selected, cookies: cookies, to: destination)
    }) {
        self.download = download
    }

    func importMedia(
        inspection: WebPostInspection, selected: Set<String>, cookies: URL?,
        destination: URL, caption: String, progress: @escaping (String) -> Void
    ) async throws -> URL {
        let batch = destination.appendingPathComponent("Web Import \(UUID().uuidString)", isDirectory: true)
        let originals = batch.appendingPathComponent("Originals", isDirectory: true)
        let working = batch.appendingPathComponent("Working", isDirectory: true)
        let provenance = batch.appendingPathComponent("Provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer {
            // Keep completed and partial downloads on failure/cancellation for recovery.
            if (try? FileManager.default.contentsOfDirectory(atPath: originals.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: batch)
            }
        }
        try FileManager.default.createDirectory(at: provenance, withIntermediateDirectories: true)
        let postEncoder = JSONEncoder()
        postEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try postEncoder.encode(inspection).write(to: provenance.appendingPathComponent("post.json"), options: .atomic)
        progress("Downloading selected media…")
        let result = try await download(inspection, selected, cookies, originals)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        for (index, file) in result.files.enumerated() {
            try Task.checkCancellation()
            guard file.filename == URL(fileURLWithPath: file.filename).lastPathComponent,
                  !file.filename.hasPrefix(".") else { throw WebDownloadRuntimeService.RuntimeError.invalidResponse }
            progress("Writing metadata \(index + 1) of \(result.files.count)…")
            let original = originals.appendingPathComponent(file.filename)
            let copy = working.appendingPathComponent(file.filename)
            let digest = try await Task.detached {
                try FileManager.default.copyItem(at: original, to: copy)
                let hash = try HashStream.hashFileSynchronously(at: original)
                guard try HashStream.hashFileSynchronously(at: copy) == hash else {
                    throw WebDownloadRuntimeService.RuntimeError.failed("The working copy could not be verified.")
                }
                return hash.map { String(format: "%02x", $0) }.joined()
            }.value
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
            let mode: MetadataWriteMode = isJPEG && !hasCredential ? .writeToFile : .writeToXMPSidecar
            _ = try await writer.write(metadata: metadata, for: copy, requestedMode: mode, semantics: .merge)
            if mode == .writeToFile {
                let readBack = try await reader.readFullMetadata(url: copy)
                guard readBack.description == metadata.description,
                      readBack.source == metadata.source,
                      readBack.instructions == metadata.instructions else {
                    throw WebDownloadRuntimeService.RuntimeError.failed("Downloaded metadata could not be verified. The original is retained.")
                }
            } else {
                let readBack = XMPSidecarService().loadSidecar(for: copy)
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: provenance.appendingPathComponent(file.filename + ".json"), options: .atomic)
        }
        return working
    }
}
