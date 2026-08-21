import Foundation

@MainActor
@Observable
final class DeadlineProfileLibraryModel {
    private(set) var profiles: [DeadlineProfile] = []
    private(set) var selectedProfileID: UUID?
    private(set) var isLoaded = false
    private(set) var isBusy = false
    var errorMessage: String?

    @ObservationIgnored private let repository: DeadlineProfileRepository

    var selectedProfile: DeadlineProfile? {
        guard let selectedProfileID else { return nil }
        return profiles.first { $0.id == selectedProfileID }
    }

    init(repository: DeadlineProfileRepository? = nil) {
        self.repository = repository ?? DeadlineProfileRepository(
            documentURL: AppPaths.applicationSupport
                .appendingPathComponent("DeadlineProfiles", isDirectory: true)
                .appendingPathComponent("profiles.json")
        )
    }

    func loadIfNeeded() async {
        guard !isLoaded, !isBusy else { return }
        await reload()
    }

    func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await repository.snapshot())
            errorMessage = nil
            isLoaded = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A missing catalog is a valid first-run state. It is not created until the user
            // explicitly creates or imports a profile.
            profiles = []
            selectedProfileID = nil
            errorMessage = nil
            isLoaded = true
        } catch {
            errorMessage = error.localizedDescription
            isLoaded = true
        }
    }

    func select(_ id: UUID) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.select(id: id)
            apply(try await repository.snapshot())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(name: String) async {
        guard !isBusy else { return }
        await mutate {
            let profile = try await repository.create(name: name)
            try await repository.select(id: profile.id)
        }
    }

    func duplicateSelected(name: String?) async {
        guard !isBusy, let selectedProfileID else { return }
        await mutate {
            let duplicate = try await repository.duplicate(id: selectedProfileID, newName: name)
            try await repository.select(id: duplicate.id)
        }
    }

    func renameSelected(to name: String) async {
        guard !isBusy, let selectedProfileID else { return }
        await mutate {
            _ = try await repository.rename(id: selectedProfileID, to: name)
        }
    }

    func importProfile(from source: URL) async {
        guard !isBusy else { return }
        await mutate {
            let imported = try await repository.importProfile(from: source)
            try await repository.select(id: imported.id)
        }
    }

    func exportSelected(to destination: URL) async {
        guard !isBusy, let selectedProfileID else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.exportProfile(id: selectedProfileID, to: destination)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() async {
        guard !isBusy, let selectedProfileID else { return }
        await mutate {
            try await repository.delete(id: selectedProfileID)
        }
    }

    private func mutate(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            apply(try await repository.snapshot())
            errorMessage = nil
            isLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ snapshot: DeadlineProfileRepositorySnapshot) {
        profiles = snapshot.profiles
        selectedProfileID = snapshot.selectedProfileID
    }
}
