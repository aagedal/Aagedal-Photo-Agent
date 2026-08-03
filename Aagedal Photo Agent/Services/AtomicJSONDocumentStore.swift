import Foundation

/// A top-level JSON document whose schema can be checked before it is decoded or replaced.
///
/// Feature documents may provide their own decoding implementation later to migrate older
/// schemas. The default deliberately accepts only the current schema so an old or new document
/// is never rewritten through a type that does not understand it.
nonisolated protocol VersionedJSONDocument: Codable, Sendable {
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get }

    static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> Self

    func validateForPersistence() throws
}

extension VersionedJSONDocument {
    nonisolated static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> Self {
        guard schemaVersion == currentSchemaVersion else {
            throw AtomicJSONDocumentStoreError.unsupportedOlderSchema(
                found: schemaVersion,
                supported: currentSchemaVersion
            )
        }
        return try decoder.decode(Self.self, from: data)
    }

    nonisolated func validateForPersistence() throws {}
}

enum AtomicJSONDocumentSource: Equatable, Sendable {
    case primary
    case backup
}

enum AtomicJSONDocumentLoad<Document: VersionedJSONDocument>: Sendable {
    case document(Document, source: AtomicJSONDocumentSource)
    /// The bytes are returned intact for a read-only presentation or later migration.
    case newerSchema(
        schemaVersion: Int,
        data: Data,
        source: AtomicJSONDocumentSource
    )
}

enum AtomicJSONDocumentStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidTopLevelJSON
    case missingOrInvalidSchemaVersion
    case unsupportedOlderSchema(found: Int, supported: Int)
    case newerSchemaRequiresReadOnly(found: Int, supported: Int)
    case schemaVersionMismatch(found: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTopLevelJSON:
            "The JSON document must contain a top-level object."
        case .missingOrInvalidSchemaVersion:
            "The JSON document has no valid schema version."
        case .unsupportedOlderSchema(let found, let supported):
            "Schema version \(found) cannot be opened without a migration to version \(supported)."
        case .newerSchemaRequiresReadOnly(let found, let supported):
            "Schema version \(found) is newer than supported version \(supported) and can only be opened read-only."
        case .schemaVersionMismatch(let found, let expected):
            "The document uses schema version \(found), but version \(expected) is required when saving."
        }
    }
}

/// Serializes access to one versioned JSON document and its single bounded backup.
///
/// A save writes and validates a sibling staging file, synchronizes it to storage, preserves the
/// previous valid primary as `<filename>.backup`, and only then atomically replaces the primary.
/// A malformed primary is never allowed to displace a valid backup.
actor AtomicJSONDocumentStore<Document: VersionedJSONDocument> {
    let documentURL: URL
    let backupURL: URL

    init(documentURL: URL, backupURL: URL? = nil) {
        self.documentURL = documentURL
        self.backupURL = backupURL ?? documentURL.appendingPathExtension("backup")
    }

    func load() throws -> AtomicJSONDocumentLoad<Document> {
        do {
            let data = try Data(contentsOf: documentURL)
            return try decode(data, source: .primary)
        } catch {
            let primaryError = error
            do {
                let backupData = try Data(contentsOf: backupURL)
                return try decode(backupData, source: .backup)
            } catch let backupError as CocoaError
                where backupError.code == .fileReadNoSuchFile {
                throw primaryError
            } catch {
                throw primaryError
            }
        }
    }

    func save(_ document: Document) throws {
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw AtomicJSONDocumentStoreError.schemaVersionMismatch(
                found: document.schemaVersion,
                expected: Document.currentSchemaVersion
            )
        }
        try document.validateForPersistence()

        let encoder = Self.makeEncoder()
        let stagedData = try encoder.encode(document)
        _ = try decodeWritableDocument(stagedData)

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: documentURL.path) {
            let existingData = try Data(contentsOf: documentURL)
            if let existingSchema = try? Self.schemaVersion(in: existingData),
               existingSchema > Document.currentSchemaVersion {
                throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                    found: existingSchema,
                    supported: Document.currentSchemaVersion
                )
            }
        }

        let stagingURL = siblingTemporaryURL(label: "staging")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try Self.writeAndSynchronize(stagedData, to: stagingURL)
        let verifiedStagingData = try Data(contentsOf: stagingURL)
        _ = try decodeWritableDocument(verifiedStagingData)

        if let validPrimaryData = try validCurrentPrimaryData() {
            try installBackup(validPrimaryData)
        }

        try Self.atomicallyInstall(stagingURL, at: documentURL)
    }

    private func validCurrentPrimaryData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: documentURL)
        do {
            _ = try decodeWritableDocument(data)
            return data
        } catch AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly {
            throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                found: try Self.schemaVersion(in: data),
                supported: Document.currentSchemaVersion
            )
        } catch {
            // Keep the last known-good backup when an external writer corrupts the primary.
            return nil
        }
    }

    private func installBackup(_ data: Data) throws {
        let fileManager = FileManager.default
        let stagingBackupURL = siblingTemporaryURL(label: "backup-staging")
        defer { try? fileManager.removeItem(at: stagingBackupURL) }

        try Self.writeAndSynchronize(data, to: stagingBackupURL)
        let verifiedData = try Data(contentsOf: stagingBackupURL)
        _ = try decodeWritableDocument(verifiedData)
        try Self.atomicallyInstall(stagingBackupURL, at: backupURL)
    }

    private func decode(
        _ data: Data,
        source: AtomicJSONDocumentSource
    ) throws -> AtomicJSONDocumentLoad<Document> {
        let schemaVersion = try Self.schemaVersion(in: data)
        if schemaVersion > Document.currentSchemaVersion {
            return .newerSchema(
                schemaVersion: schemaVersion,
                data: data,
                source: source
            )
        }

        let document = try Document.decodeVersion(
            from: data,
            schemaVersion: schemaVersion,
            using: Self.makeDecoder()
        )
        try document.validateForPersistence()
        return .document(document, source: source)
    }

    private func decodeWritableDocument(_ data: Data) throws -> Document {
        let schemaVersion = try Self.schemaVersion(in: data)
        if schemaVersion > Document.currentSchemaVersion {
            throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                found: schemaVersion,
                supported: Document.currentSchemaVersion
            )
        }
        let document = try Document.decodeVersion(
            from: data,
            schemaVersion: schemaVersion,
            using: Self.makeDecoder()
        )
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw AtomicJSONDocumentStoreError.schemaVersionMismatch(
                found: document.schemaVersion,
                expected: Document.currentSchemaVersion
            )
        }
        try document.validateForPersistence()
        return document
    }

    private func siblingTemporaryURL(label: String) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent(
            ".\(documentURL.lastPathComponent).\(label)-\(UUID().uuidString)"
        )
    }

    private static func schemaVersion(in data: Data) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            throw AtomicJSONDocumentStoreError.invalidTopLevelJSON
        }
        guard let schemaVersion = object["schemaVersion"] as? Int,
              schemaVersion > 0 else {
            throw AtomicJSONDocumentStoreError.missingOrInvalidSchemaVersion
        }
        return schemaVersion
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func writeAndSynchronize(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func atomicallyInstall(_ stagedURL: URL, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }
}
