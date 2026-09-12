import Foundation

/// A content-bound pointer to one immutable Known People generation in the app's iCloud
/// container. Publishing a new pointer replaces the complete logical library without merging
/// filenames from an older generation, so deleted people cannot be resurrected by routing.
nonisolated struct KnownPeopleCloudGenerationPointer: Codable, Equatable, Sendable {
    static let fileName = "current-generation.json"
    static let generationsDirectory = "generations"
    static let format = "aagedal-known-people-cloud-generation"
    static let schemaVersion = 1

    let generationID: UUID
    let libraryID: UUID
    let revision: String
    let coreRevision: String
    let managedProjectionSHA256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, schemaVersion, generationID, libraryID, revision, coreRevision
        case managedProjectionSHA256
    }

    init(generationID: UUID, state: KnownPeopleManagedStoreState) throws {
        self.generationID = generationID
        libraryID = state.libraryID
        revision = state.currentRevision
        coreRevision = state.currentCoreRevision
        managedProjectionSHA256 = state.managedProjectionSHA256
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases),
              try container.decode(String.self, forKey: .format) == Self.format,
              try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw KnownPeopleCloudGenerationFailure.malformedPointer
        }
        let generationText = try container.decode(String.self, forKey: .generationID)
        let libraryText = try container.decode(String.self, forKey: .libraryID)
        guard generationText == generationText.lowercased(),
              libraryText == libraryText.lowercased(),
              let generationID = UUID(uuidString: generationText),
              generationID.uuidString.lowercased() == generationText,
              let libraryID = UUID(uuidString: libraryText),
              libraryID.uuidString.lowercased() == libraryText else {
            throw KnownPeopleCloudGenerationFailure.malformedPointer
        }
        self.generationID = generationID
        self.libraryID = libraryID
        revision = try container.decode(String.self, forKey: .revision)
        coreRevision = try container.decode(String.self, forKey: .coreRevision)
        managedProjectionSHA256 = try container.decode(String.self, forKey: .managedProjectionSHA256)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(generationID.uuidString.lowercased(), forKey: .generationID)
        try container.encode(libraryID.uuidString.lowercased(), forKey: .libraryID)
        try container.encode(revision, forKey: .revision)
        try container.encode(coreRevision, forKey: .coreRevision)
        try container.encode(managedProjectionSHA256, forKey: .managedProjectionSHA256)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw KnownPeopleCloudGenerationFailure.malformedPointer }
        do {
            try KnownPeoplePackageManifest.validateJSONStructure(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw KnownPeopleCloudGenerationFailure.malformedPointer
            }
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw KnownPeopleCloudGenerationFailure.malformedPointer
        }
    }

    func generationURL(in cloudRoot: URL) -> URL {
        cloudRoot.appendingPathComponent(Self.generationsDirectory, isDirectory: true)
            .appendingPathComponent(generationID.uuidString.lowercased(), isDirectory: true)
    }

    private func validate() throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard generationID != zero, libraryID != zero,
              Self.isHash(revision), Self.isHash(coreRevision),
              Self.isHash(managedProjectionSHA256) else {
            throw KnownPeopleCloudGenerationFailure.malformedPointer
        }
    }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

nonisolated enum KnownPeopleCloudGenerationFailure: Error, Equatable, LocalizedError {
    case invalidRoot, malformedPointer, invalidGeneration, publicationFailed

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "The Known People iCloud location is not a valid file URL."
        case .malformedPointer: "The Known People iCloud generation record is malformed."
        case .invalidGeneration: "The published Known People iCloud generation failed validation."
        case .publicationFailed: "The Known People iCloud generation could not be published safely."
        }
    }
}

nonisolated struct KnownPeopleCloudGenerationPublication: Sendable {
    let pointer: KnownPeopleCloudGenerationPointer
    let destinationURL: URL
    let recoveryDirectory: URL?
}

nonisolated struct KnownPeopleCloudGenerationAccess: Sendable {
    var ensureDirectory: @Sendable (URL) throws -> Void = CloudCoordinatedIO.ensureDirectory
    var readData: @Sendable (URL) throws -> Data = CloudCoordinatedIO.readData
    var writeData: @Sendable (Data, URL) throws -> Void = { try CloudCoordinatedIO.writeData($0, to: $1) }
    var itemExists: @Sendable (URL) -> Bool = CloudCoordinatedIO.itemExists
    var makeGenerationID: @Sendable () -> UUID = UUID.init
    var beforePointerPublication: @Sendable () throws -> Void = {}
}

/// Stages each authoritative local snapshot under a never-reused generation name, validates
/// the managed projection there, and publishes only the small pointer as the visibility commit.
/// An interrupted generation stays unreachable and cannot affect the active cloud library.
actor KnownPeopleCloudGenerationPublisher {
    static let shared = KnownPeopleCloudGenerationPublisher()

    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    private let access: KnownPeopleCloudGenerationAccess

    init(access: KnownPeopleCloudGenerationAccess = .init(),
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.icloud.known-people.generations", qos: .utility
         )) {
        self.access = access
        self.filesystemQueue = filesystemQueue
    }

    func publish(snapshot: KnownPeoplePackageSnapshot,
                 cloudRootURL: URL) async throws -> KnownPeopleCloudGenerationPublication {
        try Task.checkCancellation()
        guard cloudRootURL.isFileURL else { throw KnownPeopleCloudGenerationFailure.invalidRoot }
        try access.ensureDirectory(cloudRootURL)
        let cloudRoot = cloudRootURL.resolvingSymlinksInPath().standardizedFileURL
        let generations = cloudRoot.appendingPathComponent(
            KnownPeopleCloudGenerationPointer.generationsDirectory, isDirectory: true)
        try access.ensureDirectory(generations)
        guard generations.resolvingSymlinksInPath().standardizedFileURL == generations else {
            throw KnownPeopleCloudGenerationFailure.invalidRoot
        }
        try Task.checkCancellation()

        let generationID = access.makeGenerationID()
        let generation = generations.appendingPathComponent(
            generationID.uuidString.lowercased(), isDirectory: true)
        guard generation.deletingLastPathComponent().standardizedFileURL.path == generations.path else {
            throw KnownPeopleCloudGenerationFailure.invalidRoot
        }
        // A generation name is a write-once transaction identifier. Even a UUID collision or
        // a pre-positioned filesystem item must fail instead of adopting or replacing its bytes.
        guard !access.itemExists(generation) else {
            throw KnownPeopleCloudGenerationFailure.publicationFailed
        }
        try access.ensureDirectory(generation)
        guard generation.resolvingSymlinksInPath().standardizedFileURL == generation else {
            throw KnownPeopleCloudGenerationFailure.invalidRoot
        }

        let route = KnownPeopleManagedStoreRoute(rootURL: generation, generation: 1,
                                                  iCloudSyncActive: false, routingActive: false)
        let replacement = KnownPeopleManagedStoreReplacement()
        let plan = try await replacement.plan(snapshot: snapshot, route: route)
        let installed = await replacement.replace(plan: plan, decision: .replaceUntracked,
                                                   currentRoute: route)
        guard installed.committed, installed.failure == nil, !installed.wasCancelled,
              let installedState = installed.installedState else {
            throw KnownPeopleCloudGenerationFailure.publicationFailed
        }

        let reconciledState = try installedState.requiringCloudReconciliation(false)
        try await writeAndValidate(state: reconciledState, at: generation, replacement: replacement)
        let pointer = try KnownPeopleCloudGenerationPointer(generationID: generationID,
                                                            state: reconciledState)
        try access.beforePointerPublication()
        try Task.checkCancellation()
        let pointerURL = cloudRoot.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName)
        try access.writeData(pointer.encoded(), pointerURL)
        // The pointer write is the visibility commit. Cancellation arriving during that
        // non-preemptible write cannot turn a committed generation into a reported cancellation,
        // so readback runs in an uncancelled verification task.
        let activeGeneration = try await Task.detached(priority: .utility) { [self] in
            try await resolveActiveGeneration(in: cloudRoot)
        }.value
        guard try access.readData(pointerURL) == pointer.encoded(),
              activeGeneration == generation else {
            throw KnownPeopleCloudGenerationFailure.publicationFailed
        }
        return .init(pointer: pointer, destinationURL: generation,
                     recoveryDirectory: installed.recoveryDirectory)
    }

    func markLocalStateReconciled(rootURL: URL,
                                  expected pointer: KnownPeopleCloudGenerationPointer) async throws {
        let replacement = KnownPeopleManagedStoreReplacement()
        let state = try readState(at: rootURL)
        guard state.libraryID == pointer.libraryID,
              state.currentRevision == pointer.revision,
              state.currentCoreRevision == pointer.coreRevision,
              state.managedProjectionSHA256 == pointer.managedProjectionSHA256 else {
            throw KnownPeopleCloudGenerationFailure.invalidGeneration
        }
        try await writeAndValidate(state: state.requiringCloudReconciliation(false),
                                   at: rootURL, replacement: replacement)
    }

    func resolveActiveGeneration(in cloudRootURL: URL) async throws -> URL? {
        guard cloudRootURL.isFileURL else { throw KnownPeopleCloudGenerationFailure.invalidRoot }
        let root = cloudRootURL.resolvingSymlinksInPath().standardizedFileURL
        let pointerURL = root.appendingPathComponent(KnownPeopleCloudGenerationPointer.fileName)
        guard access.itemExists(pointerURL) else { return nil }
        let pointer = try KnownPeopleCloudGenerationPointer.decode(access.readData(pointerURL))
        let generations = root.appendingPathComponent(
            KnownPeopleCloudGenerationPointer.generationsDirectory, isDirectory: true
        ).standardizedFileURL
        let generation = pointer.generationURL(in: root).resolvingSymlinksInPath().standardizedFileURL
        guard generation.deletingLastPathComponent() == generations else {
            throw KnownPeopleCloudGenerationFailure.invalidGeneration
        }
        let state = try readState(at: generation)
        guard !state.needsCloudReconciliation,
              state.libraryID == pointer.libraryID,
              state.currentRevision == pointer.revision,
              state.currentCoreRevision == pointer.coreRevision,
              state.managedProjectionSHA256 == pointer.managedProjectionSHA256 else {
            throw KnownPeopleCloudGenerationFailure.invalidGeneration
        }
        do {
            let admitted = try await KnownPeoplePackageDirectoryReader().read(directoryURL:
                generation.appendingPathComponent(state.admittedPackageDirectory, isDirectory: true))
            guard KnownPeopleManagedStoreState.admittedPackageHash(admitted.files)
                    == state.admittedPackageSHA256,
                  admitted.manifest.libraryID == state.libraryID,
                  admitted.manifest.revision == state.currentRevision,
                  admitted.manifest.coreRevision == state.currentCoreRevision,
                  admitted.manifest.contract == state.contract,
                  try KnownPeopleLocalStoreSnapshotBuilder.admittedProjectionHash(admitted)
                    == state.managedProjectionSHA256 else {
                throw KnownPeopleCloudGenerationFailure.invalidGeneration
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KnownPeopleCloudGenerationFailure.invalidGeneration
        }
        return generation
    }

    private func writeAndValidate(state: KnownPeopleManagedStoreState, at root: URL,
                                  replacement: KnownPeopleManagedStoreReplacement) async throws {
        guard KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root) else {
            throw KnownPeopleCloudGenerationFailure.invalidGeneration
        }
        _ = try await replacement.admittedPackageFiles(root: root)
        let url = root.appendingPathComponent(KnownPeopleManagedStoreState.fileName)
        try access.writeData(state.encoded(), url)
        guard try readState(at: root) == state,
              KnownPeopleManagedStoreState.protectsCurrentEmbeddingStore(at: root) else {
            throw KnownPeopleCloudGenerationFailure.invalidGeneration
        }
    }

    private func readState(at root: URL) throws -> KnownPeopleManagedStoreState {
        try KnownPeopleManagedStoreState.decode(access.readData(
            root.appendingPathComponent(KnownPeopleManagedStoreState.fileName)))
    }
}

nonisolated struct KnownPeopleCloudReconciliationResult: Sendable {
    let cloudPublished: Bool
    let verified: Bool
    let destinationURL: URL?
    let localRecoveryDirectory: URL?
    let cloudRecoveryDirectory: URL?
    let failure: String?
    let wasCancelled: Bool
}
