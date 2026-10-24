import Darwin
import Foundation
import os

private nonisolated let importLedgerLog = Logger(subsystem: "com.aagedal.photo-agent", category: "ImportLedger")

/// Append-only record of what the importer copied into a destination library, keyed by the
/// identity of the *source* file — original filename, size, capture date and sampled checksum.
///
/// "Import new only" checks this first. Destination files cannot identify a previous import on
/// their own: a JPEG changes as soon as metadata is embedded, a renamed copy (`-1`) no longer
/// carries the card's filename, and a flat import made on another day sits in another date
/// folder. The source identity recorded at copy time survives all three.
///
/// The ledger is a hidden JSON Lines file in the destination root
/// (`<root>/.aagedal_import_ledger.jsonl`) with paths relative to that root, so it travels with
/// the library: a drive moved to another Mac or remounted under another path keeps its history,
/// and a library on a shared volume is deduplicated for every machine that imports into it.
/// Each copied file appends one self-delimited line in a single `O_APPEND` write; a line torn
/// by a crash is skipped on read and never corrupts the lines around it.
nonisolated enum ImportLedger {
    static let fileName = ".aagedal_import_ledger.jsonl"

    struct Entry: Codable, Sendable, Equatable {
        /// Format version.
        var v: Int = 1
        /// Original source filename (as on the card).
        let name: String
        let size: Int64
        /// Capture time (ISO 8601) when the importer knew it; used only as a tie-breaker.
        let captureDate: String?
        /// Hex `HashStream.quickHashFile` of the source bytes.
        let quickHash: String
        /// Destination path relative to the ledger root.
        let destination: String
        let importedAt: String
    }

    static func url(forRoot root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Builds the entry for a file just copied from `source` to `destination` under `root`.
    static func entry(
        source: URL,
        destination: URL,
        root: URL,
        captureDate: Date?,
        now: Date = Date()
    ) throws -> Entry {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let hash = try HashStream.quickHashFile(at: source)
        guard let relative = ImportViewModel.relativePath(of: destination, under: root) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return Entry(
            name: source.lastPathComponent,
            size: Int64(size),
            captureDate: captureDateString(captureDate),
            quickHash: hash.map { String(format: "%02x", $0) }.joined(),
            destination: relative,
            importedAt: now.ISO8601Format()
        )
    }

    /// Appends `entries` to the ledger in one write, creating it if needed.
    static func append(_ entries: [Entry], root: URL) throws {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var payload = Data()
        for entry in entries {
            payload.append(try encoder.encode(entry))
            payload.append(0x0A)
        }

        let path = url(forRoot: root).path
        // Read access too: the torn-line check below reads the last byte.
        let descriptor = open(path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        // A crash may have left a torn last line without its newline; start on a fresh line so
        // the new record is never glued onto it.
        var size = stat()
        if fstat(descriptor, &size) == 0, size.st_size > 0 {
            var last: UInt8 = 0
            if pread(descriptor, &last, 1, size.st_size - 1) == 1, last != 0x0A {
                payload.insert(0x0A, at: 0)
            }
        }

        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    /// Every readable entry; malformed lines are skipped. Missing ledger → empty.
    static func load(root: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url(forRoot: root)), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var entries: [Entry] = []
        var skipped = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            importLedgerLog.warning("Skipped \(skipped) unreadable import-ledger lines.")
        }
        return entries
    }

    static func lookupKey(name: String, size: Int64) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased() + "|\(size)"
    }

    static func captureDateString(_ date: Date?) -> String? {
        date.map { $0.ISO8601Format() }
    }
}
