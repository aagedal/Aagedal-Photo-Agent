import Foundation

nonisolated struct MetadataHistoryEntry: Codable, Sendable, Identifiable {
    var id: Date { timestamp }
    let timestamp: Date
    let fieldName: String
    let oldValue: String?
    let newValue: String?
}

nonisolated struct MetadataSidecar: Codable, Sendable {
    static let currentSchemaVersion = 1
    /// Source compatibility for call sites that used the original name.
    static let currentVersion = currentSchemaVersion
    static let historyLimit = 20

    var schemaVersion: Int
    /// Source compatibility for code that still refers to the legacy JSON key.
    var version: Int { schemaVersion }
    var sourceFile: String
    var lastModified: Date
    var pendingChanges: Bool
    var metadata: IPTCMetadata
    var imageMetadataSnapshot: IPTCMetadata?
    var history: [MetadataHistoryEntry]

    init(
        sourceFile: String,
        lastModified: Date = Date(),
        pendingChanges: Bool = false,
        metadata: IPTCMetadata = IPTCMetadata(),
        imageMetadataSnapshot: IPTCMetadata? = nil,
        history: [MetadataHistoryEntry] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sourceFile = sourceFile
        self.lastModified = lastModified
        self.pendingChanges = pendingChanges
        self.metadata = metadata
        self.imageMetadataSnapshot = imageMetadataSnapshot
        self.history = history
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, version
        case sourceFile, lastModified, pendingChanges, metadata, imageMetadataSnapshot, history
    }

    static let persistedJSONFieldNames = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .version)
            ?? 1
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "metadata sidecar",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard decodedVersion == 1 else {
            throw EditorialJSONSchemaError.unsupportedOlderSchema(
                document: "metadata sidecar",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }

        schemaVersion = Self.currentSchemaVersion
        sourceFile = try container.decode(String.self, forKey: .sourceFile)
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? .distantPast
        pendingChanges = try container.decodeIfPresent(Bool.self, forKey: .pendingChanges) ?? false
        metadata = try container.decodeIfPresent(IPTCMetadata.self, forKey: .metadata) ?? IPTCMetadata()
        imageMetadataSnapshot = try container.decodeIfPresent(
            IPTCMetadata.self,
            forKey: .imageMetadataSnapshot
        )
        history = try container.decodeIfPresent([MetadataHistoryEntry].self, forKey: .history) ?? []
        history.trimToHistoryLimit()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sourceFile, forKey: .sourceFile)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(pendingChanges, forKey: .pendingChanges)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(imageMetadataSnapshot, forKey: .imageMetadataSnapshot)
        try container.encode(history, forKey: .history)
    }
}

extension Array where Element == MetadataHistoryEntry {
    nonisolated mutating func trimToHistoryLimit() {
        let limit = MetadataSidecar.historyLimit
        guard count > limit else { return }
        removeFirst(count - limit)
    }
}
