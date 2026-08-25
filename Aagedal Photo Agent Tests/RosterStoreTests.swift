import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("RosterStore", .serialized)
@MainActor
struct RosterStoreTests {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosterStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func activate(_ dir: URL) {
        RosterStore.deletionIO = .live
        RosterStore.storageOverrideURL = dir
        RosterStore.shared.reloadAfterStorageChange()
    }

    private func teardown(_ dir: URL) {
        RosterStore.deletionIO = .live
        RosterStore.storageOverrideURL = nil
        try? FileManager.default.removeItem(at: dir)
        RosterStore.shared.reloadAfterStorageChange()
    }

    private func makeTeam(name: String = "Test Team") -> Team {
        Team(name: name, primaryColor: TeamKitColor(r: 0.2, g: 0.4, b: 0.6))
    }

    @Test("delete installs a decodable marker, removes the record, and prevents resurrection")
    func durableDeletePreventsResurrection() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)
        let team = makeTeam()
        try RosterStore.shared.upsert(team)

        try RosterStore.shared.delete(id: team.id)

        let record = dir.appendingPathComponent("teams/\(team.id.uuidString).json")
        let marker = dir.appendingPathComponent("teams/\(team.id.uuidString).deleted")
        #expect(!FileManager.default.fileExists(atPath: record.path))
        let decoded = try JSONDecoder().decode(TeamTombstone.self, from: Data(contentsOf: marker))
        #expect(decoded.id == team.id)

        // Simulate a stale peer returning the old record. Reload must honor the marker.
        try JSONEncoder().encode(team).write(to: record, options: .atomic)
        RosterStore.shared.reloadAfterStorageChange()
        #expect(RosterStore.shared.allTeams().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test("failed marker persistence keeps the original team usable")
    func failedMarkerPersistencePreservesTeam() throws {
        let dir = makeTempDir()
        defer { teardown(dir) }
        activate(dir)
        let team = makeTeam(name: "Preserved")
        try RosterStore.shared.upsert(team)
        let record = dir.appendingPathComponent("teams/\(team.id.uuidString).json")
        let marker = dir.appendingPathComponent("teams/\(team.id.uuidString).deleted")
        RosterStore.deletionIO = DurableDeletionIO(
            writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            readData: { try CloudCoordinatedIO.readData(at: $0) },
            removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
        )

        #expect(throws: DurableDeletionError.self) {
            try RosterStore.shared.delete(id: team.id)
        }

        #expect(RosterStore.shared.team(byID: team.id)?.name == "Preserved")
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
