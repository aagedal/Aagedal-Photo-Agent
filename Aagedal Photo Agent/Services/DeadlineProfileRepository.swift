import Foundation

/// A stable, deterministic view of the locally stored deadline profiles.
nonisolated struct DeadlineProfileRepositorySnapshot: Equatable, Sendable {
    let profiles: [DeadlineProfile]
    let selectedProfileID: UUID?

    var selectedProfile: DeadlineProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }
}

nonisolated enum DeadlineProfileRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case profileNotFound(UUID)
    case profileAlreadyExists(UUID)
    case duplicateProfileName(String)
    case selectedProfileMissing(UUID)
    case selectionRequired
    case exportDestinationExists(URL)

    var errorDescription: String? {
        switch self {
        case let .profileNotFound(id):
            "No deadline profile exists with ID \(id.uuidString.lowercased())."
        case let .profileAlreadyExists(id):
            "A deadline profile with ID \(id.uuidString.lowercased()) already exists."
        case let .duplicateProfileName(name):
            "A deadline profile named “\(name)” already exists."
        case let .selectedProfileMissing(id):
            "The selected deadline profile \(id.uuidString.lowercased()) does not exist."
        case .selectionRequired:
            "A non-empty deadline profile repository must have a selected profile."
        case let .exportDestinationExists(url):
            "The export destination already exists: \(url.path)"
        }
    }
}

/// Local persistence and identity boundary for deadline profiles.
///
/// The repository owns no connection records or credentials. Profiles contain only the stable
/// connection identifiers accepted by `DeadlineProfileIO`.
actor DeadlineProfileRepository {
    let documentURL: URL

    private let profileIO: DeadlineProfileIO
    private let store: AtomicJSONDocumentStore<DeadlineProfileRepositoryDocument>
    /// Actor methods become reentrant whenever they await the document store. Keep each logical
    /// read/modify/write operation inside this explicit gate so two callers cannot both load the
    /// same revision and then overwrite one another's changes.
    private var hasExclusiveAccess = false
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []

    init(documentURL: URL, profileIO: DeadlineProfileIO = DeadlineProfileIO()) {
        self.documentURL = documentURL
        self.profileIO = profileIO
        store = AtomicJSONDocumentStore(documentURL: documentURL)
    }

    func snapshot() async throws -> DeadlineProfileRepositorySnapshot {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        return snapshot(from: try await loadDocument())
    }

    @discardableResult
    func create(name: String, id: UUID = UUID()) async throws -> DeadlineProfile {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard !document.profiles.contains(where: { $0.id == id }) else {
            throw DeadlineProfileRepositoryError.profileAlreadyExists(id)
        }

        let profile = DeadlineProfile(id: id, name: normalizedName(name))
        try validateUniqueName(profile.name, excluding: nil, in: document.profiles)
        try profileIO.validate(profile)
        document.profiles.append(profile)
        document.selectedProfileID = document.selectedProfileID ?? profile.id
        try await save(document)
        return profile
    }

    func update(_ profile: DeadlineProfile) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard let index = document.profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw DeadlineProfileRepositoryError.profileNotFound(profile.id)
        }

        var normalized = profile
        normalized.name = normalizedName(profile.name)
        try validateUniqueName(normalized.name, excluding: normalized.id, in: document.profiles)
        try profileIO.validate(normalized)
        document.profiles[index] = normalized
        try await save(document)
    }

    @discardableResult
    func duplicate(
        id: UUID,
        newName: String? = nil,
        newID: UUID = UUID()
    ) async throws -> DeadlineProfile {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard let source = document.profiles.first(where: { $0.id == id }) else {
            throw DeadlineProfileRepositoryError.profileNotFound(id)
        }
        guard !document.profiles.contains(where: { $0.id == newID }) else {
            throw DeadlineProfileRepositoryError.profileAlreadyExists(newID)
        }

        let duplicateName: String
        if let newName {
            duplicateName = normalizedName(newName)
            try validateUniqueName(duplicateName, excluding: nil, in: document.profiles)
        } else {
            duplicateName = nextCopyName(for: source.name, profiles: document.profiles)
        }

        var copy = source
        copy.id = newID
        copy.name = duplicateName
        try profileIO.validate(copy)
        document.profiles.append(copy)
        try await save(document)
        return copy
    }

    @discardableResult
    func rename(id: UUID, to name: String) async throws -> DeadlineProfile {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
            throw DeadlineProfileRepositoryError.profileNotFound(id)
        }

        var profile = document.profiles[index]
        profile.name = normalizedName(name)
        try validateUniqueName(profile.name, excluding: id, in: document.profiles)
        try profileIO.validate(profile)
        document.profiles[index] = profile
        try await save(document)
        return profile
    }

    @discardableResult
    func importProfile(from source: URL) async throws -> DeadlineProfile {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        let imported = try profileIO.importProfile(from: source)
        var document = try await loadDocument()
        guard !document.profiles.contains(where: { $0.id == imported.id }) else {
            throw DeadlineProfileRepositoryError.profileAlreadyExists(imported.id)
        }
        try validateUniqueName(imported.name, excluding: nil, in: document.profiles)

        document.profiles.append(imported)
        document.selectedProfileID = document.selectedProfileID ?? imported.id
        try await save(document)
        return imported
    }

    func exportProfile(id: UUID, to destination: URL) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        let document = try await loadDocument()
        guard let profile = document.profiles.first(where: { $0.id == id }) else {
            throw DeadlineProfileRepositoryError.profileNotFound(id)
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw DeadlineProfileRepositoryError.exportDestinationExists(destination)
        }

        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).export-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try profileIO.export(profile, to: stagingURL)
        do {
            try fileManager.moveItem(at: stagingURL, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw DeadlineProfileRepositoryError.exportDestinationExists(destination)
        }
    }

    func delete(id: UUID) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard document.profiles.contains(where: { $0.id == id }) else {
            throw DeadlineProfileRepositoryError.profileNotFound(id)
        }

        document.profiles.removeAll { $0.id == id }
        if document.selectedProfileID == id {
            document.selectedProfileID = sortedProfiles(document.profiles).first?.id
        }
        try await save(document)
    }

    func select(id: UUID) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        var document = try await loadDocument()
        guard document.profiles.contains(where: { $0.id == id }) else {
            throw DeadlineProfileRepositoryError.profileNotFound(id)
        }
        document.selectedProfileID = id
        try await save(document)
    }

    private func beginExclusiveAccess() async {
        if !hasExclusiveAccess {
            hasExclusiveAccess = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
        }
    }

    private func endExclusiveAccess() {
        guard !accessWaiters.isEmpty else {
            hasExclusiveAccess = false
            return
        }
        accessWaiters.removeFirst().resume()
    }

    private func loadDocument() async throws -> DeadlineProfileRepositoryDocument {
        // A newer nested profile is not corruption. Detect it before the generic store can
        // recover an older backup and later overwrite the future primary through this build.
        try rejectNewerProfileSchemaInPrimary()
        do {
            switch try await store.load() {
            case let .document(document, source):
                if document.migratedFromSchemaVersion != nil, source == .primary {
                    let migrated = document.readyForPersistence
                    try await store.save(migrated)
                    return migrated
                }
                return document.readyForPersistence
            case let .newerSchema(schemaVersion, _, _):
                throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                    found: schemaVersion,
                    supported: DeadlineProfileRepositoryDocument.currentSchemaVersion
                )
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DeadlineProfileRepositoryDocument()
        }
    }

    private func rejectNewerProfileSchemaInPrimary() throws {
        guard FileManager.default.fileExists(atPath: documentURL.path),
              let data = try? Data(contentsOf: documentURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = object["profiles"] as? [[String: Any]] else {
            return
        }
        for profile in profiles {
            guard let version = profile["schemaVersion"] as? Int,
                  version > DeadlineProfile.currentSchemaVersion else { continue }
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "deadline profile",
                found: version,
                supported: DeadlineProfile.currentSchemaVersion
            )
        }
    }

    private func save(_ document: DeadlineProfileRepositoryDocument) async throws {
        var deterministic = document.readyForPersistence
        deterministic.profiles = sortedProfiles(document.profiles)
        try await store.save(deterministic)
    }

    private func snapshot(
        from document: DeadlineProfileRepositoryDocument
    ) -> DeadlineProfileRepositorySnapshot {
        DeadlineProfileRepositorySnapshot(
            profiles: sortedProfiles(document.profiles),
            selectedProfileID: document.selectedProfileID
        )
    }

    private func validateUniqueName(
        _ name: String,
        excluding excludedID: UUID?,
        in profiles: [DeadlineProfile]
    ) throws {
        let key = canonicalProfileName(name)
        if profiles.contains(where: { $0.id != excludedID && canonicalProfileName($0.name) == key }) {
            throw DeadlineProfileRepositoryError.duplicateProfileName(name)
        }
    }

    private func nextCopyName(for sourceName: String, profiles: [DeadlineProfile]) -> String {
        let existing = Set(profiles.map { canonicalProfileName($0.name) })
        let first = "\(sourceName) Copy"
        if !existing.contains(canonicalProfileName(first)) {
            return first
        }

        var suffix = 2
        while existing.contains(canonicalProfileName("\(first) \(suffix)")) {
            suffix += 1
        }
        return "\(first) \(suffix)"
    }
}

private nonisolated struct DeadlineProfileRepositoryDocument: VersionedJSONDocument, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var profiles: [DeadlineProfile]
    var selectedProfileID: UUID?
    var migratedFromSchemaVersion: Int?

    init(
        profiles: [DeadlineProfile] = [],
        selectedProfileID: UUID? = nil,
        migratedFromSchemaVersion: Int? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.migratedFromSchemaVersion = migratedFromSchemaVersion
    }

    var readyForPersistence: Self {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.migratedFromSchemaVersion = nil
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles, selectedProfileID
    }

    static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> Self {
        switch schemaVersion {
        case 1:
            let legacy = try decoder.decode(VersionOne.self, from: data)
            let profiles = sortedProfiles(legacy.profiles)
            return Self(
                profiles: profiles,
                selectedProfileID: profiles.first?.id,
                migratedFromSchemaVersion: 1
            )
        case Self.currentSchemaVersion:
            return try decoder.decode(Self.self, from: data)
        default:
            throw AtomicJSONDocumentStoreError.unsupportedOlderSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
    }

    func validateForPersistence() throws {
        var ids = Set<UUID>()
        var names = Set<String>()
        let io = DeadlineProfileIO()
        for profile in profiles {
            try io.validate(profile)
            guard ids.insert(profile.id).inserted else {
                throw DeadlineProfileRepositoryError.profileAlreadyExists(profile.id)
            }
            guard names.insert(canonicalProfileName(profile.name)).inserted else {
                throw DeadlineProfileRepositoryError.duplicateProfileName(profile.name)
            }
        }

        if profiles.isEmpty {
            if let selectedProfileID {
                throw DeadlineProfileRepositoryError.selectedProfileMissing(selectedProfileID)
            }
        } else if let selectedProfileID {
            guard ids.contains(selectedProfileID) else {
                throw DeadlineProfileRepositoryError.selectedProfileMissing(selectedProfileID)
            }
        } else {
            throw DeadlineProfileRepositoryError.selectionRequired
        }
    }

    private struct VersionOne: Decodable {
        let profiles: [DeadlineProfile]
    }
}

private nonisolated func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
}

private nonisolated func canonicalProfileName(_ name: String) -> String {
    normalizedName(name).folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
}

private nonisolated func sortedProfiles(_ profiles: [DeadlineProfile]) -> [DeadlineProfile] {
    profiles.sorted { lhs, rhs in
        let leftKey = canonicalProfileName(lhs.name)
        let rightKey = canonicalProfileName(rhs.name)
        if leftKey != rightKey { return leftKey < rightKey }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
