import Foundation

@MainActor
@Observable
final class BatchRenameRecipeLibraryModel {
    private(set) var presets: [BatchRenameRecipePreset] = []
    private(set) var selectedPresetID: UUID?
    private(set) var isLoaded = false
    private(set) var isBusy = false
    var errorMessage: String?

    @ObservationIgnored private let repository: BatchRenameRecipeRepository

    var selectedPreset: BatchRenameRecipePreset? {
        guard let selectedPresetID else { return nil }
        return presets.first { $0.id == selectedPresetID }
    }

    init(repository: BatchRenameRecipeRepository? = nil) {
        self.repository = repository ?? BatchRenameRecipeRepository(
            documentURL: AppPaths.applicationSupport
                .appendingPathComponent("BatchRenameRecipes", isDirectory: true)
                .appendingPathComponent("recipes.json")
        )
    }

    func loadIfNeeded() async {
        guard !isLoaded, !isBusy else { return }
        await reload()
    }

    func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            apply(try await repository.snapshot())
            errorMessage = nil
            isLoaded = true
        } catch {
            errorMessage = error.localizedDescription
            isLoaded = true
        }
    }

    @discardableResult
    func select(_ id: UUID) async -> BatchRenameRecipePreset? {
        await mutate {
            try await repository.select(id: id)
            let snapshot = try await repository.snapshot()
            return snapshot.selectedPreset
        }
    }

    @discardableResult
    func create(name: String, from editor: BatchRenameEditorState) async -> BatchRenameRecipePreset? {
        await mutate {
            let preset = try await repository.create(
                recipe: editor.recipe(named: name),
                collisionChoice: editor.collisionChoice
            )
            try await repository.select(id: preset.id)
            return preset
        }
    }

    @discardableResult
    func update(id: UUID, from editor: BatchRenameEditorState) async -> BatchRenameRecipePreset? {
        guard let stored = presets.first(where: { $0.id == id }) else { return nil }
        return await mutate {
            try await repository.update(
                id: id,
                recipe: editor.recipe(named: stored.name),
                collisionChoice: editor.collisionChoice
            )
        }
    }

    @discardableResult
    func duplicate(id: UUID, name: String?) async -> BatchRenameRecipePreset? {
        await mutate {
            let duplicate = try await repository.duplicate(id: id, newName: name)
            try await repository.select(id: duplicate.id)
            return duplicate
        }
    }

    @discardableResult
    func rename(id: UUID, to name: String) async -> BatchRenameRecipePreset? {
        await mutate { try await repository.rename(id: id, to: name) }
    }

    @discardableResult
    func importPreset(from source: URL) async -> BatchRenameRecipePreset? {
        await mutate {
            let imported = try await repository.importPreset(from: source)
            try await repository.select(id: imported.id)
            return imported
        }
    }

    func export(id: UUID, to destination: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.exportPreset(id: id, to: destination)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.delete(id: id)
            apply(try await repository.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func mutate(
        _ operation: () async throws -> BatchRenameRecipePreset?
    ) async -> BatchRenameRecipePreset? {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await operation()
            apply(try await repository.snapshot())
            errorMessage = nil
            isLoaded = true
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func apply(_ snapshot: BatchRenameRecipeRepositorySnapshot) {
        presets = snapshot.presets
        selectedPresetID = snapshot.selectedPresetID
    }
}
