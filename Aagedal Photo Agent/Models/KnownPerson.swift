import Foundation

// MARK: - Known People Mode

nonisolated enum KnownPeopleMode: String, CaseIterable, Codable, Sendable {
    case off = "off"
    case onDemand = "onDemand"
    case alwaysOn = "alwaysOn"

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .onDemand: return "On Demand"
        case .alwaysOn: return "Always On"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Known people recognition is disabled"
        case .onDemand:
            return "Manually check against known people database"
        case .alwaysOn:
            return "Automatically match known people during scans"
        }
    }
}

// MARK: - Known Person

nonisolated struct KnownPerson: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var role: String?
    var embeddings: [PersonEmbedding]
    var representativeThumbnailID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        role: String? = nil,
        embeddings: [PersonEmbedding] = [],
        representativeThumbnailID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.embeddings = embeddings
        self.representativeThumbnailID = representativeThumbnailID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Person Embedding

nonisolated struct PersonEmbedding: Codable, Identifiable, Sendable {
    let id: UUID
    let featurePrintData: Data
    let sourceDescription: String?
    let addedAt: Date

    /// Recognition mode used to generate this embedding
    let recognitionMode: FaceRecognitionMode?

    init(
        id: UUID = UUID(),
        featurePrintData: Data,
        sourceDescription: String? = nil,
        addedAt: Date = Date(),
        recognitionMode: FaceRecognitionMode? = nil
    ) {
        self.id = id
        self.featurePrintData = featurePrintData
        self.sourceDescription = sourceDescription
        self.addedAt = addedAt
        self.recognitionMode = recognitionMode
    }
}

// MARK: - Known People Database

nonisolated struct KnownPeopleDatabase: Codable, Sendable {
    var people: [KnownPerson]
    var lastModified: Date

    init(people: [KnownPerson] = [], lastModified: Date = Date()) {
        self.people = people
        self.lastModified = lastModified
    }
}

// MARK: - Export Manifest

nonisolated struct KnownPeopleManifest: Codable, Sendable {
    let version: String
    let macOSVersion: String
    let createdAt: Date
    let exportedBy: String?
    let peopleCount: Int
    let embeddingCount: Int

    init(
        version: String = "1.0",
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        createdAt: Date = Date(),
        exportedBy: String? = nil,
        peopleCount: Int,
        embeddingCount: Int
    ) {
        self.version = version
        self.macOSVersion = macOSVersion
        self.createdAt = createdAt
        self.exportedBy = exportedBy
        self.peopleCount = peopleCount
        self.embeddingCount = embeddingCount
    }
}

// MARK: - Match Result

nonisolated struct KnownPersonMatch: Sendable {
    let person: KnownPerson
    let confidence: Float
    let matchedEmbeddingID: UUID
}
