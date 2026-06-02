import Foundation
import os

nonisolated private let cloudIOLog = Logger(subsystem: "com.aagedal.photo-agent", category: "CloudCoordinatedIO")

/// File access that may target the iCloud ubiquity container, wrapped in
/// `NSFileCoordinator`.
///
/// Uncoordinated `createDirectory`/`write` calls against a ubiquity-container
/// path race the iCloud daemon: when the app creates `Documents/Templates`
/// locally before the daemon has finished materialising the server's copy of
/// the same folder, iCloud cannot merge the two and forks one into
/// `Templates 2`, `Templates 3`, … — scattering files the app then can't find.
/// Routing every container create/read/write/delete through a coordinator lets
/// the app and the daemon agree on a single item.
///
/// All operations are safe for plain local paths too (coordination is cheap
/// when no presenter or remote peer is involved), so callers don't need to
/// branch on whether iCloud is currently the backing store.
nonisolated enum CloudCoordinatedIO {
    /// Coordinated creation of a directory and any missing intermediates.
    static func ensureDirectory(_ url: URL) throws {
        try coordinateWrite(url, options: []) { dest in
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        }
    }

    /// Coordinated atomic write. Ensures the parent directory exists first (also
    /// coordinated) so the folder isn't forked by a concurrent daemon create.
    static func writeData(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try coordinateWrite(url, options: .forReplacing) { dest in
            try data.write(to: dest, options: .atomic)
        }
    }

    static func writeText(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    /// Coordinated read. Requests a download first if the item is an
    /// not-yet-materialised iCloud placeholder.
    static func readData(at url: URL) throws -> Data {
        kickDownloadIfNeeded(url)
        var result: Data?
        try coordinateRead(url, options: []) { src in
            result = try Data(contentsOf: src)
        }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    /// Coordinated delete. A missing item is treated as success.
    static func removeItem(at url: URL) throws {
        try coordinateWrite(url, options: .forDeleting) { dest in
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
        }
    }

    /// Whether an item exists, counting not-yet-downloaded iCloud placeholders
    /// (which live on disk as a hidden `.<name>.icloud` stub).
    static func itemExists(at url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    /// Coordinated directory listing. Surfaces not-yet-downloaded items by
    /// de-mangling their `.<name>.icloud` placeholders back to the real URL and
    /// kicking a download, so callers see the logical contents and a subsequent
    /// `readData` succeeds once the file lands.
    static func contentsOfDirectory(at url: URL) throws -> [URL] {
        var entries: [URL] = []
        try coordinateRead(url, options: []) { src in
            entries = try FileManager.default.contentsOfDirectory(
                at: src,
                includingPropertiesForKeys: nil,
                options: []
            )
        }
        var resolved: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                // ".Foo.json.icloud" -> "Foo.json"
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                let realURL = entry.deletingLastPathComponent().appendingPathComponent(realName)
                kickDownloadIfNeeded(realURL)
                resolved.append(realURL)
            } else if name.hasPrefix(".") {
                continue // .DS_Store and other hidden bookkeeping files
            } else {
                resolved.append(entry)
            }
        }
        return resolved
    }

    /// Coordinated recursive copy of `src`'s contents into `dst`, overwriting
    /// same-named files. Missing sources are treated as empty.
    static func mergeCopy(from src: URL, to dst: URL) throws {
        try ensureDirectory(dst)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let items = try contentsOfDirectory(at: src)
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let target = dst.appendingPathComponent(item.lastPathComponent)
            if isDir {
                try mergeCopy(from: item, to: target)
            } else {
                let data = try readData(at: item)
                try writeData(data, to: target)
            }
        }
    }

    // MARK: - Internals

    private static func kickDownloadIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard fm.isUbiquitousItem(at: url) else { return }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        if status == .current { return }
        try? fm.startDownloadingUbiquitousItem(at: url)
    }

    private static func coordinateWrite(
        _ url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: options, error: &coordError) { dest in
                do { try body(dest) } catch { thrown = error }
            }
        if let thrown { throw thrown }
        if let coordError { throw coordError }
    }

    private static func coordinateRead(
        _ url: URL,
        options: NSFileCoordinator.ReadingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: url, options: options, error: &coordError) { src in
                do { try body(src) } catch { thrown = error }
            }
        if let thrown { throw thrown }
        if let coordError { throw coordError }
    }
}
