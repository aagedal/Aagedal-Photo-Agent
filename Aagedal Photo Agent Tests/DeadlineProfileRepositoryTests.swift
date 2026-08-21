import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Deadline profile repository")
struct DeadlineProfileRepositoryTests {
    private let alphaID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let zuluID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    @Test("stable IDs, deterministic listing, and selection survive reopening")
    func stableIdentityAndSelection() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)

        let zulu = try await repository.create(name: "  Zulu  ", id: zuluID)
        let alpha = try await repository.create(name: "Alpha", id: alphaID)
        #expect(zulu.id == zuluID)
        #expect(zulu.name == "Zulu")
        #expect(alpha.id == alphaID)

        var snapshot = try await repository.snapshot()
        #expect(snapshot.profiles.map(\.id) == [alphaID, zuluID])
        #expect(snapshot.selectedProfileID == zuluID)

        try await repository.select(id: alphaID)
        let reopened = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.selectedProfile?.id == alphaID)

        try await reopened.delete(id: alphaID)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.profiles.map(\.id) == [zuluID])
        #expect(snapshot.selectedProfileID == zuluID)

        try await reopened.delete(id: zuluID)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.profiles.isEmpty)
        #expect(snapshot.selectedProfileID == nil)
    }

    @Test("duplicate creates a new identity without copying connection credentials")
    func duplicateIsSecretFree() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        var original = try await repository.create(name: "Wire", id: alphaID)
        let connectionID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        original.destination = DeadlineDestinationConfiguration(
            connectionIdentifier: connectionID.uuidString.lowercased(),
            remotePathTemplate: "/incoming"
        )
        try await repository.update(original)

        let copy = try await repository.duplicate(id: alphaID, newID: zuluID)

        #expect(copy.id == zuluID)
        #expect(copy.name == "Wire Copy")
        #expect(copy.destination == original.destination)
        #expect(try await repository.snapshot().selectedProfileID == alphaID)
        let persisted = String(decoding: try Data(contentsOf: fixture.repositoryURL), as: UTF8.self)
        #expect(persisted.localizedCaseInsensitiveContains(connectionID.uuidString))
        #expect(!persisted.localizedCaseInsensitiveContains("password"))
        #expect(!persisted.localizedCaseInsensitiveContains("privateKey"))
    }

    @Test("failed rename and import collisions never overwrite stored profiles")
    func mutationCollisionsDoNotOverwrite() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        _ = try await repository.create(name: "Alpha", id: alphaID)
        _ = try await repository.create(name: "Zulu", id: zuluID)
        let bytesBeforeRename = try Data(contentsOf: fixture.repositoryURL)

        await #expect(throws: DeadlineProfileRepositoryError.duplicateProfileName("alpha")) {
            _ = try await repository.rename(id: zuluID, to: "alpha")
        }
        #expect(try Data(contentsOf: fixture.repositoryURL) == bytesBeforeRename)

        let conflicting = DeadlineProfile(id: alphaID, name: "Replacement")
        try DeadlineProfileIO().export(conflicting, to: fixture.importURL)
        await #expect(throws: DeadlineProfileRepositoryError.profileAlreadyExists(alphaID)) {
            _ = try await repository.importProfile(from: fixture.importURL)
        }

        let snapshot = try await repository.snapshot()
        #expect(snapshot.profiles.first(where: { $0.id == alphaID })?.name == "Alpha")
    }

    @Test("export is portable and never overwrites an existing destination")
    func exportNeverOverwrites() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        _ = try await repository.create(name: "Wire", id: alphaID)

        try await repository.exportProfile(id: alphaID, to: fixture.exportURL)
        #expect(try DeadlineProfileIO().importProfile(from: fixture.exportURL).id == alphaID)
        let firstExport = try Data(contentsOf: fixture.exportURL)

        await #expect(
            throws: DeadlineProfileRepositoryError.exportDestinationExists(fixture.exportURL)
        ) {
            try await repository.exportProfile(id: alphaID, to: fixture.exportURL)
        }
        #expect(try Data(contentsOf: fixture.exportURL) == firstExport)
    }

    @Test("version one catalogs migrate and select their deterministic first profile")
    func versionOneMigration() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        try fixture.writeVersionOneCatalog(profiles: [
            DeadlineProfile(id: zuluID, name: "Zulu"),
            DeadlineProfile(id: alphaID, name: "Alpha"),
        ])

        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        let snapshot = try await repository.snapshot()

        #expect(snapshot.profiles.map(\.id) == [alphaID, zuluID])
        #expect(snapshot.selectedProfileID == alphaID)
        let migrated = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.repositoryURL))
                as? [String: Any]
        )
        #expect(migrated["schemaVersion"] as? Int == 2)
        #expect(migrated["selectedProfileID"] as? String == alphaID.uuidString)
    }

    @Test("an invalid persisted selection is rejected without rewriting the catalog")
    func invalidSelectionIsRejected() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let missingID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        try fixture.writeVersionTwoCatalog(
            profiles: [DeadlineProfile(id: alphaID, name: "Alpha")],
            selectedProfileID: missingID
        )
        let original = try Data(contentsOf: fixture.repositoryURL)
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)

        await #expect(
            throws: DeadlineProfileRepositoryError.selectedProfileMissing(missingID)
        ) {
            _ = try await repository.snapshot()
        }
        #expect(try Data(contentsOf: fixture.repositoryURL) == original)
    }

    @Test("a newer nested profile cannot downgrade through an older valid backup")
    func nestedFutureProfileProtectsPrimaryAndBackup() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        _ = try await repository.create(name: "Alpha", id: alphaID)
        _ = try await repository.create(name: "Zulu", id: zuluID)
        let backupURL = fixture.repositoryURL.appendingPathExtension("backup")
        let backup = try Data(contentsOf: backupURL)

        var catalog = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.repositoryURL))
                as? [String: Any]
        )
        var profiles = try #require(catalog["profiles"] as? [[String: Any]])
        profiles[0]["schemaVersion"] = 99
        profiles[0]["future"] = ["keep": true]
        catalog["profiles"] = profiles
        let future = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
        try future.write(to: fixture.repositoryURL)

        await #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "deadline profile",
            found: 99,
            supported: DeadlineProfile.currentSchemaVersion
        )) {
            _ = try await DeadlineProfileRepository(
                documentURL: fixture.repositoryURL
            ).snapshot()
        }
        #expect(try Data(contentsOf: fixture.repositoryURL) == future)
        #expect(try Data(contentsOf: backupURL) == backup)
    }

    @Test("overlapping mutations serialize one complete read-modify-write transaction at a time")
    func overlappingMutationsDoNotLoseProfiles() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        let profileIDs = (0..<24).map { index in
            UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", index))!
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, id) in profileIDs.enumerated() {
                group.addTask {
                    _ = try await repository.create(name: "Concurrent \(index)", id: id)
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await repository.snapshot()
        #expect(Set(snapshot.profiles.map(\.id)) == Set(profileIDs))
        #expect(snapshot.profiles.count == profileIDs.count)

        let reopened = DeadlineProfileRepository(documentURL: fixture.repositoryURL)
        let reopenedSnapshot = try await reopened.snapshot()
        #expect(Set(reopenedSnapshot.profiles.map(\.id)) == Set(profileIDs))
    }
}

private struct RepositoryFixture {
    let directoryURL: URL
    let repositoryURL: URL
    let importURL: URL
    let exportURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-deadline-profile-repository-\(UUID().uuidString)",
            isDirectory: true
        )
        repositoryURL = directoryURL.appendingPathComponent("deadline-profiles.json")
        importURL = directoryURL.appendingPathComponent("import.deadline-profile.json")
        exportURL = directoryURL.appendingPathComponent("export.deadline-profile.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func writeVersionOneCatalog(profiles: [DeadlineProfile]) throws {
        try writeCatalog(schemaVersion: 1, profiles: profiles, selectedProfileID: nil)
    }

    func writeVersionTwoCatalog(profiles: [DeadlineProfile], selectedProfileID: UUID) throws {
        try writeCatalog(
            schemaVersion: 2,
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func writeCatalog(
        schemaVersion: Int,
        profiles: [DeadlineProfile],
        selectedProfileID: UUID?
    ) throws {
        let io = DeadlineProfileIO()
        let profileObjects = try profiles.map { profile in
            try JSONSerialization.jsonObject(with: io.encode(profile))
        }
        var object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "profiles": profileObjects,
        ]
        if let selectedProfileID {
            object["selectedProfileID"] = selectedProfileID.uuidString
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: repositoryURL)
    }
}
