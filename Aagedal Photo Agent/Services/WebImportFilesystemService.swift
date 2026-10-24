import Foundation

/// Retained serial worker for volume-facing web import operations. Actor hops retain the
/// caller's task locals, priority and cancellation; no detached task outlives import cleanup.
actor WebImportFilesystemService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    enum Operation: Sendable, Equatable {
        case prepare, workingDirectory, copy, originalHash, workingHash
        case sidecarRead, provenanceWrite, cleanup
    }

    private let beforeOperation: @Sendable (Operation) throws -> Void

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(label: "com.aagedal.photo-agent.web-import.filesystem", qos: .utility),
        beforeOperation: @escaping @Sendable (Operation) throws -> Void = { _ in }
    ) {
        self.filesystemQueue = filesystemQueue
        self.beforeOperation = beforeOperation
    }

    private func check(_ operation: Operation) throws {
        try Task.checkCancellation()
        try beforeOperation(operation)
        try Task.checkCancellation()
    }

    func prepare(batch: URL, inspection: WebPostInspection) throws {
        try check(.prepare)
        try FileManager.default.createDirectory(at: batch.appendingPathComponent("Originals"), withIntermediateDirectories: true)
        try Task.checkCancellation()
        let provenance = batch.appendingPathComponent("Provenance", isDirectory: true)
        try FileManager.default.createDirectory(at: provenance, withIntermediateDirectories: true)
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(inspection).write(to: provenance.appendingPathComponent("post.json"), options: .atomic)
        try Task.checkCancellation()
    }

    /// First unused `<baseName>`, `<baseName> 2`, … in `destination`, so a readable
    /// date/account name never merges two imports into one batch folder.
    func uniqueBatchURL(in destination: URL, baseName: String) throws -> URL {
        var candidate = destination.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            try Task.checkCancellation()
            candidate = destination.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    func createWorkingDirectory(_ working: URL) throws {
        try check(.workingDirectory)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try Task.checkCancellation()
    }

    func copyAndVerify(original: URL, copy: URL) throws -> String {
        try check(.copy)
        try FileManager.default.copyItem(at: original, to: copy)
        try check(.originalHash)
        let digest = try HashStream.hashFileSynchronously(at: original)
        try check(.workingHash)
        let copiedDigest = try HashStream.hashFileSynchronously(at: copy)
        try Task.checkCancellation()
        guard copiedDigest == digest else {
            throw WebDownloadRuntimeService.RuntimeError.failed("The working copy could not be verified.")
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func readSidecar(for copy: URL) throws -> IPTCMetadata? {
        try check(.sidecarRead)
        let result = XMPSidecarService().loadSidecar(for: copy)
        try Task.checkCancellation()
        return result
    }

    func writeProvenance(_ record: WebImportProvenance, to url: URL) throws {
        try check(.provenanceWrite)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
        try Task.checkCancellation()
    }

    /// Cancellation never skips cleanup. Empty batches can be removed; any downloaded or
    /// partial original, or inability to enumerate originals, preserves the entire batch.
    @discardableResult
    func cleanupEmptyBatch(_ batch: URL) -> URL? {
        try? beforeOperation(.cleanup)
        let originals = batch.appendingPathComponent("Originals", isDirectory: true)
        if (try? FileManager.default.contentsOfDirectory(atPath: originals.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: batch)
        }
        return FileManager.default.fileExists(atPath: batch.path) ? batch : nil
    }
}
