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

/// A known person in the face recognition database.
///
/// **Important Architecture Note:**
/// The Known People database stores ONLY face-only feature prints (Vision VNFeaturePrintObservation).
/// This ensures consistent cross-context matching regardless of what the person is wearing.
/// Even when Face+Clothing mode is used during scanning, only the face feature is stored here.
/// Clothing features are used only for within-folder clustering, not for Known People matching.
nonisolated struct KnownPerson: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var role: String?
    var notes: String?
    var embeddings: [PersonEmbedding]
    var representativeThumbnailID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        role: String? = nil,
        notes: String? = nil,
        embeddings: [PersonEmbedding] = [],
        representativeThumbnailID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.notes = notes
        self.embeddings = embeddings
        self.representativeThumbnailID = representativeThumbnailID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Display subtitle combining role and notes
    var subtitle: String? {
        let parts = [role, notes].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

// MARK: - Person Embedding

/// A face embedding sample stored for a known person.
///
/// **Important:** `featurePrintData` always contains a face-only Vision feature print,
/// regardless of what recognition mode was active when the face was captured.
/// This ensures the Known People database works consistently across different contexts
/// (e.g., the same person wearing different clothes in different photos).
nonisolated struct PersonEmbedding: Codable, Identifiable, Sendable {
    let id: UUID

    /// The face-only Vision VNFeaturePrintObservation data.
    /// Always face-only, never includes clothing features.
    let featurePrintData: Data

    let sourceDescription: String?
    let addedAt: Date

    /// The recognition mode that was active when this face was captured.
    /// This is metadata only - the stored `featurePrintData` is always face-only regardless.
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
