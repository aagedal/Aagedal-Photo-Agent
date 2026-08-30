import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KeywordListsArchive")

/// Sendable archive facts produced by the blocking unzip/manifest inspection. Logical list-key
/// resolution stays on MainActor because those keys are presentation/store types; the filesystem
/// actor only transports stable strings, counts, and dates.
nonisolated struct KeywordListsArchivePreviewPayload: Equatable, Sendable {
    nonisolated struct Entry: Equatable, Sendable {
        let path: String
        let kind: String
        let entryCount: Int
    }

    let entries: [Entry]
    let schemaVersion: Int
    let exportedAt: Date
}

nonisolated struct KeywordListsArchivePreviewSnapshot: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let payload: KeywordListsArchivePreviewPayload
}

nonisolated enum KeywordListsArchivePreviewResult: Equatable, Sendable {
    case loaded(KeywordListsArchivePreviewSnapshot)
    case cancelledBeforeInspection(requestID: UUID)
    case cancelledAfterInspection(requestID: UUID, sourceURL: URL, discoveredEntryCount: Int)
}

nonisolated struct KeywordListsArchivePreviewReader: Sendable {
    let inspect: @Sendable (URL) throws -> KeywordListsArchivePreviewPayload

    static let system = KeywordListsArchivePreviewReader { sourceURL in
        try KeywordListsArchive.readPreviewPayload(from: sourceURL)
    }
}

/// Serializes archive extraction and manifest reads away from MainActor. `ditto` and Foundation
/// reads cannot be preempted once entered, so cancellation on either side of inspection is
/// represented explicitly and a superseded payload is never returned as loaded.
actor KeywordListsArchivePreviewService {
    static let shared = KeywordListsArchivePreviewService()

    private let reader: KeywordListsArchivePreviewReader

    init(reader: KeywordListsArchivePreviewReader = .system) {
        self.reader = reader
    }

    func loadPreview(
        from sourceURL: URL,
        requestID: UUID
    ) throws -> KeywordListsArchivePreviewResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeInspection(requestID: requestID)
        }

        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard !Task.isCancelled else {
            return .cancelledBeforeInspection(requestID: requestID)
        }

        let payload = try reader.inspect(sourceURL)
        guard !Task.isCancelled else {
            return .cancelledAfterInspection(
                requestID: requestID,
                sourceURL: sourceURL,
                discoveredEntryCount: payload.entries.count
            )
        }

        return .loaded(KeywordListsArchivePreviewSnapshot(
            requestID: requestID,
            sourceURL: sourceURL,
            payload: payload
        ))
    }
}

/// Bundles every keyword list managed by `KeywordListsStore` into a single .zip
/// for backup, migration, or sharing. Layout inside the archive:
///
/// ```
/// manifest.json
/// quick/<type>.txt
/// approved/<field>.txt
/// structured/keywords.txt
/// ```
///
/// `manifest.json` records the schema version, the list of files, and an entry
/// count per file so import can pre-flight the contents.
enum KeywordListsArchive {
    /// Per-list policy when importing.
    enum ImportMode: Equatable {
        /// Replace the existing list with the imported one.
        case replace
        /// Append imported entries to the existing list, preserving local order
        /// and adding only entries not already present (case-insensitive).
        case append
        /// Leave the existing list untouched. Used to opt a specific list out of
        /// the import even when it's present in the archive.
        case skip

        /// Legacy alias retained for the original "merge" naming used in tests
        /// and any external callers. `.merge` behaves identically to `.append`.
        static let merge: ImportMode = .append
    }

    /// What's inside an archive, surfaced ahead of import so the UI can render a
    /// per-list picker and the user can decide what to do with each entry.
    struct ManifestPreview {
        struct Entry: Identifiable {
            let key: KeywordListKey
            let entryCount: Int
            var id: String { key.relativePath }
        }
        let entries: [Entry]
        let schemaVersion: Int
        let exportedAt: Date
    }

    nonisolated struct Manifest: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let files: [File]

        nonisolated struct File: Codable {
            /// Relative path inside the archive (e.g. `quick/keywords.txt`).
            let path: String
            /// Logical list key, used by importers to route content even if we
            /// rename the on-disk path in a future schema version.
            let kind: String
            let entryCount: Int
        }
    }

    nonisolated enum ArchiveError: LocalizedError {
        case dittoFailed(Int32)
        case manifestMissing
        case manifestDecodeFailed(String)
        case unsupportedSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case .dittoFailed(let code):
                return "ditto exited with status \(code)"
            case .manifestMissing:
                return "Archive does not contain a manifest.json"
            case .manifestDecodeFailed(let reason):
                return "Could not parse manifest.json: \(reason)"
            case .unsupportedSchemaVersion(let v):
                return "Archive schema version \(v) is newer than this app supports."
            }
        }
    }

    nonisolated static let currentSchemaVersion = 1

    /// Writes every list currently in the managed store to `destination`.
    /// Returns the number of files included in the archive.
    @discardableResult
    static func exportAll(to destination: URL) throws -> Int {
        try exportSelected(Set(enumerateKeys()), to: destination)
    }

    /// Writes only the requested lists to `destination`. Keys not present in
    /// the store (or not in `keys`) are skipped. Returns the number of files
    /// actually written.
    @discardableResult
    static func exportSelected(_ keys: Set<KeywordListKey>, to destination: URL) throws -> Int {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("klists-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var files: [Manifest.File] = []
        let store = KeywordListsStore.shared

        // Iterate the canonical ordering so the archive is stable across runs
        // (helps with diffs and snapshot-testing of export bundles).
        for key in enumerateKeys() {
            guard keys.contains(key), store.exists(key) else { continue }
            let source = store.url(for: key)
            let relPath = key.relativePath
            let stagedURL = stagingRoot.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: stagedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: stagedURL)

            let entryCount = entryCount(for: key, in: store)
            files.append(Manifest.File(path: relPath, kind: kindString(for: key), entryCount: entryCount))
        }

        let manifest = Manifest(
            schemaVersion: currentSchemaVersion,
            exportedAt: Date(),
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingRoot.appendingPathComponent("manifest.json"))

        try ditto(zip: stagingRoot, into: destination)
        return files.count
    }

    /// Reads `source`'s manifest without importing anything, so the UI can
    /// render a per-list picker before the user commits.
    static func inspect(_ source: URL) throws -> ManifestPreview {
        manifestPreview(from: try readPreviewPayload(from: source))
    }

    /// Blocking, transport-only half of archive inspection. This is nonisolated so the dedicated
    /// preview actor can own extraction and manifest I/O without moving store/UI types off their
    /// actor. Callers on MainActor convert the payload with `manifestPreview(from:)`.
    nonisolated static func readPreviewPayload(
        from source: URL
    ) throws -> KeywordListsArchivePreviewPayload {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("klists-inspect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try ditto(unzip: source, into: stagingRoot)
        let payloadRoot = resolvePayloadRoot(in: stagingRoot)

        let manifest = try readManifest(in: payloadRoot)
        return KeywordListsArchivePreviewPayload(
            entries: manifest.files.map {
                KeywordListsArchivePreviewPayload.Entry(
                    path: $0.path,
                    kind: $0.kind,
                    entryCount: $0.entryCount
                )
            },
            schemaVersion: manifest.schemaVersion,
            exportedAt: manifest.exportedAt
        )
    }

    static func manifestPreview(
        from payload: KeywordListsArchivePreviewPayload
    ) -> ManifestPreview {
        ManifestPreview(
            entries: payload.entries.compactMap { entry in
                guard let key = resolveKey(forKind: entry.kind, path: entry.path) else { return nil }
                return ManifestPreview.Entry(key: key, entryCount: entry.entryCount)
            },
            schemaVersion: payload.schemaVersion,
            exportedAt: payload.exportedAt
        )
    }

    /// Reads `source` and applies a per-list policy. Lists with `.skip` (or
    /// missing from `choices`) are left untouched. Returns the number of lists
    /// actually written.
    @discardableResult
    static func importSelected(from source: URL, choices: [KeywordListKey: ImportMode]) throws -> Int {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("klists-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try ditto(unzip: source, into: stagingRoot)
        let payloadRoot = resolvePayloadRoot(in: stagingRoot)

        let manifest = try readManifest(in: payloadRoot)
        var imported = 0
        for entry in manifest.files {
            guard let key = resolveKey(forKind: entry.kind, path: entry.path) else { continue }
            let mode = choices[key] ?? .skip
            if mode == .skip { continue }

            guard let fileURL = safeEntryURL(for: entry.path, in: payloadRoot) else {
                logger.warning("Skipping keyword-list import entry with unsafe path: \(entry.path, privacy: .private(mask: .hash))")
                continue
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

            switch key {
            case .structured, .structuredPersonShown:
                // Append-mode on a tab-indented tree isn't meaningfully defined
                // (two trees may collide on the same parent), so for the
                // structured file `.append` falls through to `.replace`. The
                // surfaced UI choice therefore reads as Replace / Skip only for
                // structured. Documented in the import sheet caption.
                try KeywordListsStore.shared.writeText(text, to: key)
            case .quick, .approved:
                let newEntries = text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                switch mode {
                case .replace:
                    try KeywordListsStore.shared.writeEntries(newEntries, to: key)
                case .append:
                    let existing = KeywordListsStore.shared.readEntries(key)
                    var seen = Set(existing.map { $0.lowercased() })
                    var combined = existing
                    for entry in newEntries where seen.insert(entry.lowercased()).inserted {
                        combined.append(entry)
                    }
                    try KeywordListsStore.shared.writeEntries(combined, to: key)
                case .skip:
                    continue
                }
            }
            imported += 1
        }
        return imported
    }

    /// Convenience for the old "import every list in the archive with the same
    /// mode" entry point. Retained so existing callers and tests keep working.
    @discardableResult
    static func importAll(from source: URL, mode: ImportMode = .replace) throws -> Int {
        let preview = try inspect(source)
        var choices: [KeywordListKey: ImportMode] = [:]
        for entry in preview.entries {
            choices[entry.key] = mode
        }
        return try importSelected(from: source, choices: choices)
    }

    nonisolated private static func readManifest(in payloadRoot: URL) throws -> Manifest {
        let manifestURL = payloadRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.manifestMissing
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let manifest = try decoder.decode(Manifest.self, from: manifestData)
            guard manifest.schemaVersion <= currentSchemaVersion else {
                throw ArchiveError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch let archiveError as ArchiveError {
            throw archiveError
        } catch {
            throw ArchiveError.manifestDecodeFailed(error.localizedDescription)
        }
    }

    // MARK: - Internals

    private static func enumerateKeys() -> [KeywordListKey] {
        var keys: [KeywordListKey] = []
        keys.append(contentsOf: QuickListType.allCases.map { KeywordListKey.quick($0) })
        keys.append(contentsOf: ApprovedListField.allCases.map { KeywordListKey.approved($0) })
        keys.append(.structured)
        keys.append(.structuredPersonShown)
        return keys
    }

    private static func entryCount(for key: KeywordListKey, in store: KeywordListsStore) -> Int {
        switch key {
        case .structured, .structuredPersonShown:
            // Count keyword (not container) lines in the text.
            let text = store.readText(key) ?? ""
            return StructuredKeywordParser.parseString(text).reduce(0) { $0 + countKeywords(in: $1) }
        case .quick, .approved:
            return store.readEntries(key).count
        }
    }

    private static func countKeywords(in node: StructuredKeyword) -> Int {
        var n = node.isKeyword ? 1 : 0
        for child in node.children { n += countKeywords(in: child) }
        return n
    }

    private static func kindString(for key: KeywordListKey) -> String {
        switch key {
        case .quick(let type): return "quick.\(type.rawValue)"
        case .approved(let field): return "approved.\(field.rawValue)"
        case .structured: return "structured"
        case .structuredPersonShown: return "structuredPersonShown"
        }
    }

    private static func resolveKey(forKind kind: String, path: String) -> KeywordListKey? {
        if kind == "structured" { return .structured }
        if kind == "structuredPersonShown" { return .structuredPersonShown }
        if kind.hasPrefix("quick.") {
            let raw = String(kind.dropFirst("quick.".count))
            return QuickListType(rawValue: raw).map { .quick($0) }
        }
        if kind.hasPrefix("approved.") {
            let raw = String(kind.dropFirst("approved.".count))
            return ApprovedListField(rawValue: raw).map { .approved($0) }
        }
        return nil
    }

    /// Resolves a manifest entry's relative `path` to a file inside `payloadRoot`,
    /// returning `nil` if it would escape that root. `manifest.json` is fully
    /// attacker-controlled when a user imports a shared `.klists` archive, so its
    /// `path` values are untrusted: a crafted entry like `../../../../etc/passwd`
    /// — or a symlink planted inside the archive — would otherwise make us read an
    /// arbitrary file and copy it into one of the user's keyword lists. Mirrors the
    /// containment guard in `MetadataSidecarService`.
    private static func safeEntryURL(for path: String, in payloadRoot: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return nil }

        let candidate = payloadRoot.appendingPathComponent(path)
        // Resolve symlinks (and macOS's /var -> /private/var aliasing) on both
        // sides so a symlink inside the archive can't redirect the read outside
        // the payload, then confirm the resolved path is still contained.
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = payloadRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }

    nonisolated private static func resolvePayloadRoot(in stagingRoot: URL) -> URL {
        // ditto's --keepParent wraps the source dir as the archive's top-level
        // entry. After unzip the staging root contains exactly that one folder.
        if let children = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ),
           children.count == 1,
           let first = children.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        {
            return first
        }
        return stagingRoot
    }

    private static func ditto(zip source: URL, into destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ArchiveError.dittoFailed(process.terminationStatus)
        }
    }

    nonisolated private static func ditto(unzip source: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ArchiveError.dittoFailed(process.terminationStatus)
        }
    }
}
