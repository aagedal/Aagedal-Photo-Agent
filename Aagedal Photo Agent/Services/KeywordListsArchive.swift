import Foundation
import os

private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "KeywordListsArchive")

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
    enum ImportMode {
        /// Replace each existing list with the imported one (deletes the local
        /// copy of any list missing from the archive? No — leaves untouched.)
        case replace
        /// Merge imported entries into existing lists, preserving local order
        /// and appending new entries at the end.
        case merge
    }

    struct Manifest: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let files: [File]

        struct File: Codable {
            /// Relative path inside the archive (e.g. `quick/keywords.txt`).
            let path: String
            /// Logical list key, used by importers to route content even if we
            /// rename the on-disk path in a future schema version.
            let kind: String
            let entryCount: Int
        }
    }

    enum ArchiveError: LocalizedError {
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

    static let currentSchemaVersion = 1

    /// Writes every list currently in the managed store to `destination`.
    /// Returns the number of files included in the archive.
    @discardableResult
    static func exportAll(to destination: URL) throws -> Int {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("klists-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var files: [Manifest.File] = []
        let store = KeywordListsStore.shared

        for key in enumerateKeys() {
            guard store.exists(key) else { continue }
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

    /// Reads `source`, validates the manifest, and writes the contained files
    /// into the managed store. Returns the number of lists imported.
    @discardableResult
    static func importAll(from source: URL, mode: ImportMode = .replace) throws -> Int {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("klists-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        try ditto(unzip: source, into: stagingRoot)

        // ditto -c -k --keepParent wraps everything in a top-level folder named
        // after the staging root. After unzip we find a single child directory.
        let payloadRoot = resolvePayloadRoot(in: stagingRoot)

        let manifestURL = payloadRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.manifestMissing
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: manifestData)
        } catch {
            throw ArchiveError.manifestDecodeFailed(error.localizedDescription)
        }
        guard manifest.schemaVersion <= currentSchemaVersion else {
            throw ArchiveError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        var imported = 0
        for entry in manifest.files {
            guard let key = resolveKey(forKind: entry.kind, path: entry.path) else { continue }
            let fileURL = payloadRoot.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

            switch key {
            case .structured:
                // Preserve verbatim — only the structured file uses leading tabs.
                try KeywordListsStore.shared.writeText(text, to: key)
            case .quick, .approved:
                let newEntries = text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                switch mode {
                case .replace:
                    try KeywordListsStore.shared.writeEntries(newEntries, to: key)
                case .merge:
                    let existing = KeywordListsStore.shared.readEntries(key)
                    var seen = Set(existing.map { $0.lowercased() })
                    var combined = existing
                    for entry in newEntries where seen.insert(entry.lowercased()).inserted {
                        combined.append(entry)
                    }
                    try KeywordListsStore.shared.writeEntries(combined, to: key)
                }
            }
            imported += 1
        }
        return imported
    }

    // MARK: - Internals

    private static func enumerateKeys() -> [KeywordListKey] {
        var keys: [KeywordListKey] = []
        keys.append(contentsOf: QuickListType.allCases.map { KeywordListKey.quick($0) })
        keys.append(contentsOf: ApprovedListField.allCases.map { KeywordListKey.approved($0) })
        keys.append(.structured)
        return keys
    }

    private static func entryCount(for key: KeywordListKey, in store: KeywordListsStore) -> Int {
        switch key {
        case .structured:
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
        }
    }

    private static func resolveKey(forKind kind: String, path: String) -> KeywordListKey? {
        if kind == "structured" { return .structured }
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

    private static func resolvePayloadRoot(in stagingRoot: URL) -> URL {
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

    private static func ditto(unzip source: URL, into destination: URL) throws {
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
