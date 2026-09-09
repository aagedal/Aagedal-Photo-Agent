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

nonisolated enum AtomicJSONDocumentSource: Equatable, Sendable {
    case primary
    case backup
}

nonisolated enum AtomicJSONDocumentLoad<Document: VersionedJSONDocument>: Sendable {
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

/// Serializes the complete primary/backup transaction across all in-process store instances.
/// Canonicalization and file operations run on the retained worker; admission only tracks paths.
actor AtomicJSONDocumentStore<Document: VersionedJSONDocument> {
    let documentURL: URL
    let backupURL: URL
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }
    private let validateCompatibility: @Sendable (Data) throws -> Void

    init(
        documentURL: URL,
        backupURL: URL? = nil,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.atomic-json", qos: .utility
        ),
        validateCompatibility: @escaping @Sendable (Data) throws -> Void = { _ in }
    ) {
        self.documentURL = documentURL
        self.backupURL = backupURL ?? documentURL.appendingPathExtension("backup")
        self.filesystemQueue = filesystemQueue
        self.validateCompatibility = validateCompatibility
    }

    func load() async throws -> AtomicJSONDocumentLoad<Document> {
        let transaction = makeTransaction()
        return try await StorageTransactionAdmission.shared.withAccess(
            to: [transaction.documentURL, transaction.backupURL]
        ) {
            try await transaction.load()
        }
    }

    func save(_ document: Document) async throws {
        let transaction = makeTransaction()
        try await StorageTransactionAdmission.shared.withAccess(
            to: [transaction.documentURL, transaction.backupURL]
        ) {
            // Preserve the durable-save contract, including callers already cancelled.
            try await transaction.save(document)
        }
    }

    private func makeTransaction() -> AtomicJSONDocumentTransaction<Document> {
        AtomicJSONDocumentTransaction(
            documentURL: SafePathComponent.resolvingExistingSymlinks(in: documentURL),
            backupURL: SafePathComponent.resolvingExistingSymlinks(in: backupURL),
            filesystemQueue: filesystemQueue,
            validateCompatibility: validateCompatibility
        )
    }
}

/// Process-wide admission spans all overlapping primary/backup paths and template roots.
/// Awaiting ownership does not block a worker or manufacture another task, so task locals,
/// priority and cancellation survive admission. Callers decide their own cancellation policy.
actor StorageTransactionAdmission {
    static let shared = StorageTransactionAdmission()
    private var activePaths: Set<String> = []
    private var waiters: [Waiter] = []

    private struct Waiter {
        let paths: Set<String>
        let continuation: CheckedContinuation<Void, Never>
    }

    func withAccess<Value: Sendable>(
        to canonicalURLs: Set<URL>,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        // URL equality includes its directory hint; admission identifies the filesystem path.
        let paths = Set(canonicalURLs.map(\.path))
        if !activePaths.isDisjoint(with: paths)
            || waiters.contains(where: { !$0.paths.isDisjoint(with: paths) }) {
            await withCheckedContinuation {
                waiters.append(Waiter(paths: paths, continuation: $0))
            }
        } else {
            activePaths.formUnion(paths)
        }
        defer { release(paths) }
        return try await operation()
    }

    func waiterCount(for path: URL) -> Int {
        waiters.filter { $0.paths.contains(path.path) }.count
    }

    private func release(_ paths: Set<String>) {
        activePaths.subtract(paths)
        var blockedPaths: Set<String> = []
        var remaining: [Waiter] = []
        for waiter in waiters {
            if activePaths.isDisjoint(with: waiter.paths)
                && blockedPaths.isDisjoint(with: waiter.paths) {
                activePaths.formUnion(waiter.paths)
                waiter.continuation.resume()
            } else {
                blockedPaths.formUnion(waiter.paths)
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

/// Writes and validates staging bytes, preserves the previous valid primary as a bounded
/// backup, then atomically replaces the primary. There is no suspension inside the transaction.
private actor AtomicJSONDocumentTransaction<Document: VersionedJSONDocument> {
    let documentURL: URL
    let backupURL: URL

    // Reads, fsync and atomic replacement may block on storage. The actor retains
    // a Dispatch executor for the complete transaction, including schema validation.
    // Admitted saves still finish despite cancellation so callers receive durable evidence.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    /// Runs on this actor against the exact bytes being decoded or replaced. A compatibility
    /// rejection is read-only evidence, never corruption eligible for backup recovery.
    private let validateCompatibility: @Sendable (Data) throws -> Void

    init(
        documentURL: URL,
        backupURL: URL? = nil,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.atomic-json", qos: .utility
        ),
        validateCompatibility: @escaping @Sendable (Data) throws -> Void = { _ in }
    ) {
        self.documentURL = documentURL
        self.backupURL = backupURL ?? documentURL.appendingPathExtension("backup")
        self.validateCompatibility = validateCompatibility
        self.filesystemQueue = filesystemQueue
    }

    func load() throws -> AtomicJSONDocumentLoad<Document> {
        let data: Data
        do {
            data = try Data(contentsOf: documentURL)
        } catch {
            return try recoverBackup(primaryError: error)
        }
        try validateCompatibility(data)
        do {
            return try decode(data, source: .primary)
        } catch {
            return try recoverBackup(primaryError: error)
        }
    }

    private func recoverBackup(primaryError: Error) throws -> AtomicJSONDocumentLoad<Document> {
        let data: Data
        do {
            data = try Data(contentsOf: backupURL)
        } catch {
            throw primaryError
        }
        try validateCompatibility(data)
        do {
            return try decode(data, source: .backup)
        } catch {
            throw primaryError
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

        try validateExistingCompatibility(at: documentURL)
        // A backup can be the sole surviving future document after a crash or corrupt primary.
        // Refuse direct saves too, rather than protecting it only when callers load first.
        try validateExistingCompatibility(at: backupURL)

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

    private func validateExistingCompatibility(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        try validateCompatibility(data)
        if let schema = try? Self.schemaVersion(in: data), schema > Document.currentSchemaVersion {
            throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                found: schema,
                supported: Document.currentSchemaVersion
            )
        }
    }

    private func validCurrentPrimaryData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: documentURL)
        try validateCompatibility(data)
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
        try validateExistingCompatibility(at: backupURL)
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
        try validateCompatibility(data)
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
