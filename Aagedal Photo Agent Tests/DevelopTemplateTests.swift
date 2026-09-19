import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop templates")
struct DevelopTemplateTests {

    @Test("Existing editor binds its inventory root across folder switches and reloads",
          arguments: ["beforeOpen", "afterOpen", "sameRoot"])
    @MainActor
    func editorStorageRootConflict(timing: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        let alias = root.appendingPathComponent("Selected")
        let firstStorage = DevelopTemplateStorageService(directoryURL: first)
        let secondStorage = DevelopTemplateStorageService(directoryURL: second)
        let original = DevelopTemplate(name: "Original")
        let peer = DevelopTemplate(name: "Shortcut owner", shortcutSlot: 2)
        for storage in [firstStorage, secondStorage] {
            try storage.save(original)
            try storage.save(peer)
        }
        let tracked = [first, second].flatMap { directory in
            [original.id, peer.id].map { directory.appendingPathComponent("\($0.uuidString).json") }
        }
        let before = try tracked.map { try Data(contentsOf: $0) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let editor = DevelopTemplateViewModel(storage: DevelopTemplateStorageService(directoryURL: alias))
        await withCheckedContinuation { continuation in
            editor.loadTemplates { _ in continuation.resume() }
        }
        if timing != "beforeOpen" { editor.startEditing(original) }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: timing == "sameRoot" ? first : second
        )
        if timing == "beforeOpen" { editor.startEditing(original) }
        editor.editingTemplate.name = "Retained draft"
        editor.editingTemplate.shortcutSlot = 2
        if timing != "sameRoot" {
            editor.deleteTemplate(original)
            let deadline = ContinuousClock.now + .seconds(10)
            while editor.errorMessage == nil {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Root-bound delete did not complete"); return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(editor.errorMessage?.contains("folder changed") == true)
            #expect(try tracked.map { try Data(contentsOf: $0) } == before)
            // Refusal did not read the new root, so it cannot authorize a retry.
            editor.deleteTemplate(original)
            #expect(editor.errorMessage == "Reload the template list before deleting.")
            #expect(try tracked.map { try Data(contentsOf: $0) } == before)
        }
        // Refreshing a list cannot replace the open editor's original root.
        await withCheckedContinuation { continuation in
            editor.loadTemplates { _ in continuation.resume() }
        }
        let result = await editor.saveEditingTemplate()
        if timing == "sameRoot" {
            guard case .success = result else { Issue.record("Same canonical root refused"); return }
            #expect(try firstStorage.loadAll().first { $0.id == original.id }?.name == "Retained draft")
            #expect(try secondStorage.loadAll().first { $0.id == original.id } == original)
            return
        }
        guard case .failure(let failure) = result else { Issue.record("Different store authorized stale editor"); return }
        #expect(failure.isSnapshotConflict)
        #expect(failure.reason.contains("folder changed"))
        #expect(editor.isEditing)
        #expect(editor.editingTemplate.name == "Retained draft")
        #expect(try tracked.map { try Data(contentsOf: $0) } == before)
        editor.editingTemplate.shortcutSlot = nil
        guard case .success(let copy) = await editor.saveEditingTemplateAsNew() else {
            Issue.record("Explicit new copy failed"); return
        }
        #expect(copy.id != original.id)
        #expect(try secondStorage.loadAll().contains(copy))
        #expect(try !firstStorage.loadAll().contains(copy))
        #expect(try tracked.map { try Data(contentsOf: $0) } == before)
    }

    @Test("Existing editor saves refuse stale snapshots before shortcut writes and retain recovery",
          arguments: ["changed", "removed", "corrupt", "duplicate", "unchanged"])
    @MainActor
    func editorSnapshotConflict(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root)
        let original = DevelopTemplate(name: "Original")
        let peer = DevelopTemplate(name: "Shortcut owner", shortcutSlot: 2)
        try storage.save(original)
        try storage.save(peer)
        let source = root.appendingPathComponent("\(original.id.uuidString).json")
        let peerURL = root.appendingPathComponent("\(peer.id.uuidString).json")
        let peerBytes = try Data(contentsOf: peerURL)
        let editor = DevelopTemplateViewModel(storage: storage)
        await withCheckedContinuation { continuation in
            editor.loadTemplates { _ in continuation.resume() }
        }
        editor.startEditing(original)
        editor.editingTemplate.name = "My draft"
        editor.editingTemplate.shortcutSlot = 2
        switch state {
        case "changed":
            var changed = original
            changed.name = "Newer peer edit"
            try storage.save(changed)
        case "removed": try FileManager.default.removeItem(at: source)
        case "corrupt": try Data("broken JSON".utf8).write(to: source)
        case "duplicate":
            try Data(contentsOf: source).write(to: root.appendingPathComponent("duplicate.json"))
        default: break
        }
        let before = try? Data(contentsOf: source)
        let result = await editor.saveEditingTemplate()
        if state == "unchanged" {
            guard case .success = result else { Issue.record("Unchanged baseline refused"); return }
            #expect(!editor.isEditing)
            #expect(try storage.loadAll().first { $0.id == original.id }?.name == "My draft")
            #expect(try storage.loadAll().first { $0.id == peer.id }?.shortcutSlot == nil)
            return
        }
        guard case .failure = result else { Issue.record("Stale editor saved"); return }
        #expect(editor.isEditing)
        #expect(editor.editingTemplate.name == "My draft")
        #expect(editor.saveError?.reason.contains("changed or is no longer available") == true)
        #expect((try? Data(contentsOf: source)) == before)
        #expect(try Data(contentsOf: peerURL) == peerBytes)

        // An inventory reload must not silently bless the open editor's stale draft.
        await withCheckedContinuation { continuation in
            editor.loadTemplates { _ in continuation.resume() }
        }
        guard case .failure = await editor.saveEditingTemplate() else {
            Issue.record("Reload authorized a stale editor"); return
        }
        #expect((try? Data(contentsOf: source)) == before)
        #expect(try Data(contentsOf: peerURL) == peerBytes)
        editor.editingTemplate.shortcutSlot = nil
        guard case .success(let copy) = await editor.saveEditingTemplateAsNew() else {
            Issue.record("Save as New failed"); return
        }
        #expect(copy.id != original.id)
        #expect(copy.name == "My draft")
        #expect(!editor.isEditing)
        #expect((try? Data(contentsOf: source)) == before)
        #expect(try Data(contentsOf: peerURL) == peerBytes)
        #expect(try storage.loadAll().contains { $0.id == copy.id })
    }

    @Test("Develop template CRUD refuses a process owner and releases admission after retry",
          arguments: ["load", "save", "delete", "export"])
    func processReservationForCRUD(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("DevelopTemplates")
        let recovery = root.appendingPathComponent("recovered.json")
        let storage = DevelopTemplateStorageService(directoryURL: folder, trashAccess: .init(moveItem: {
            try FileManager.default.moveItem(at: $0, to: recovery)
        }))
        let original = DevelopTemplate(name: "Original", shortcutSlot: 1)
        let replacement = DevelopTemplate(name: "Replacement", shortcutSlot: 1)
        try storage.save(original)
        let source = folder.appendingPathComponent("\(original.id.uuidString).json")
        let before = try Data(contentsOf: source)
        let exported = root.appendingPathComponent("export.json")
        let sentinel = Data("Previous export".utf8)
        try sentinel.write(to: exported)
        let owner = try MCPProcessReservation.acquireFolder(folder)
        defer { owner.release() }
        let service = TemplateCRUDService(access: .storage(storage))
        let run: @Sendable () async throws -> Void = {
            switch operation {
            case "load": _ = try await service.load(requestID: UUID())
            case "save": _ = try await service.save(replacement, requestID: UUID())
            case "delete": _ = try await service.delete(original, requestID: UUID())
            default: _ = try await service.exportAll(to: exported, requestID: UUID())
            }
        }
        do {
            try await run()
            Issue.record("Busy Develop template transaction was admitted")
        } catch let error as MCPProcessReservationError {
            guard case .busy = error else { throw error }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(try Data(contentsOf: exported) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
        owner.release()
        try await run()
        switch operation {
        case "save":
            let inventory = try storage.loadAll()
            #expect(inventory.first(where: { $0.id == original.id })?.shortcutSlot == nil)
            #expect(inventory.first(where: { $0.id == replacement.id })?.shortcutSlot == 1)
        case "delete":
            #expect(try storage.loadAll().isEmpty)
            #expect(try Data(contentsOf: recovery) == before)
        case "export":
            #expect(try JSONDecoder().decode([DevelopTemplate].self,
                from: Data(contentsOf: exported)).map(\.id) == [original.id])
        default: #expect(try Data(contentsOf: source) == before)
        }
        let released = try MCPProcessReservation.acquireFolder(folder)
        released.release()
    }

    @Test("Develop services serialize complete shortcut transactions across instances")
    @MainActor
    func sharedRootShortcutTransactions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DevelopTemplateStorageService(directoryURL: root)
        let key = SafePathComponent.resolvingExistingSymlinks(in: root)
        let gate = TemplateRootAdmissionGate()
        let owner = Task {
            await StorageTransactionAdmission.shared.withAccess(to: [key]) { await gate.hold() }
        }
        defer { Task { await gate.open() } }
        try await gate.waitUntilEntered()
        let first = DevelopTemplate(name: "First", shortcutSlot: 1)
        let second = DevelopTemplate(name: "Second", shortcutSlot: 1)
        let firstService = TemplateCRUDService<DevelopTemplate>(access: .storage(storage))
        let secondService = TemplateCRUDService<DevelopTemplate>(access: .storage(storage))
        let firstTask = Task { try await firstService.save(first, requestID: UUID()) }
        try await waitForTemplateAdmission(key, count: 1)
        let secondTask = Task { try await secondService.save(second, requestID: UUID()) }
        try await waitForTemplateAdmission(key, count: 2)
        await gate.open()
        await owner.value
        _ = try await firstTask.value
        guard case .committed(let commit) = try await secondTask.value else {
            Issue.record("Expected the complete second Develop transaction")
            return
        }
        #expect(commit.durableTemplateIDs == [first.id, second.id])
        let templates = try storage.loadAll()
        #expect(templates.first(where: { $0.id == first.id })?.shortcutSlot == nil)
        #expect(templates.first(where: { $0.id == second.id })?.shortcutSlot == 1)
    }

    @MainActor
    @Test("Develop deletion preserves exact bytes and failed trash preserves the template")
    func recoverableDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("DevelopTemplates")
        let template = DevelopTemplate(name: "Recover Develop")
        let failingStorage = DevelopTemplateStorageService(directoryURL: folder, trashAccess: .init(moveItem: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }))
        try failingStorage.save(template)
        let source = folder.appendingPathComponent("\(template.id.uuidString).json")
        let bytes = try Data(contentsOf: source)
        #expect(throws: (any Error).self) { try failingStorage.delete(template) }
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try failingStorage.loadAll().map(\.id) == [template.id])
        let viewModel = DevelopTemplateViewModel(storage: failingStorage)
        await withCheckedContinuation { continuation in
            viewModel.loadTemplates { _ in continuation.resume() }
        }
        viewModel.deleteTemplate(template)
        let deadline = ContinuousClock.now + .seconds(30)
        while viewModel.errorMessage == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for Develop trash failure")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.templates.map(\.id) == [template.id])

        let recovered = root.appendingPathComponent("trashed.json")
        let storage = DevelopTemplateStorageService(directoryURL: folder, trashAccess: .init(moveItem: {
            try FileManager.default.moveItem(at: $0, to: recovered)
        }))
        try storage.delete(template)
        #expect(try Data(contentsOf: recovered) == bytes)
        #expect(try storage.loadAll().isEmpty)
        try storage.delete(template)

        // A file restored from Trash becomes available on the next inventory refresh.
        try FileManager.default.moveItem(at: recovered, to: source)
        #expect(try storage.loadAll().map(\.id) == [template.id])
        #expect(try storage.loadAll().first?.name == template.name)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("Creation strips image-specific decoder state")
    func stripsImageSpecificState() {
        var settings = CameraRawSettings()
        settings.exposure2012 = 1.25
        settings.sharpness = 50
        settings.clarity2012 = 24
        settings.dehaze = 19
        settings.asShotNeutralTemperature = 5_400
        settings.asShotNeutralTint = 8
        settings.sourceHasHDRHeadroom = true
        settings.unparsedMaskCorrections = [
            PreservedMaskCorrection(fields: ["crs:Unknown": .string("image-bound")])
        ]

        let template = DevelopTemplate(name: "Bright", settings: settings)

        #expect(template.settings.exposure2012 == 1.25)
        #expect(template.settings.sharpness == 50)
        #expect(template.settings.clarity2012 == 24)
        #expect(template.settings.dehaze == 19)
        #expect(template.settings.asShotNeutralTemperature == nil)
        #expect(template.settings.asShotNeutralTint == nil)
        #expect(template.settings.sourceHasHDRHeadroom == nil)
        #expect(template.settings.unparsedMaskCorrections == nil)
    }

    @Test("Application preserves target state and gives layers fresh identities")
    func applicationPreparesIndependentSettings() {
        var mask = MaskAdjustment()
        mask.id = UUID()
        mask.exposure = 0.75
        var watermark = WatermarkLayer(libraryAssetID: UUID())
        watermark.id = UUID()

        var source = CameraRawSettings()
        source.exposure2012 = 1
        source.localAdjustments = [mask]
        source.watermarkLayers = [watermark]
        source.layerOrder = [.mask(mask.id), .global, .watermark(watermark.id)]
        let template = DevelopTemplate(name: "Layered", settings: source)

        let preserved = PreservedMaskCorrection(fields: ["crs:Unknown": .string("keep")])
        var target = CameraRawSettings()
        target.asShotNeutralTemperature = 6_100
        target.asShotNeutralTint = -4
        target.sourceHasHDRHeadroom = true
        target.unparsedMaskCorrections = [preserved]

        let applied = template.settingsForApplication(preserving: target)
        let newMaskID = applied.localAdjustments?.first?.id
        let newWatermarkID = applied.watermarkLayers?.first?.id

        #expect(newMaskID != nil && newMaskID != mask.id)
        #expect(newWatermarkID != nil && newWatermarkID != watermark.id)
        #expect(applied.layerOrder == [
            newMaskID.map(LayerRef.mask),
            .global,
            newWatermarkID.map(LayerRef.watermark),
        ].compactMap { $0 })
        #expect(applied.asShotNeutralTemperature == 6_100)
        #expect(applied.asShotNeutralTint == -4)
        #expect(applied.sourceHasHDRHeadroom == true)
        #expect(applied.unparsedMaskCorrections == [preserved])
    }

    @Test("Develop template JSON round-trips shortcut and settings")
    func codableRoundTrip() throws {
        var settings = CameraRawSettings()
        settings.contrast2012 = 20
        settings.crop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 0, hasCrop: true)
        let original = DevelopTemplate(name: "Punch", settings: settings, shortcutSlot: 3)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DevelopTemplate.self, from: data)

        #expect(decoded == original)
        #expect(decoded.summary == "Global • Crop")
    }

    @Test("Excluded crop preserves the destination crop")
    func excludedCropPreservesDestination() {
        let sourceCrop = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 3, hasCrop: true)
        let targetCrop = CameraRawCrop(top: 0.2, left: 0.1, bottom: 0.8, right: 0.9, angle: -2, hasCrop: true)
        var source = CameraRawSettings()
        source.exposure2012 = 0.5
        source.crop = sourceCrop
        var target = CameraRawSettings()
        target.crop = targetCrop

        let withoutCrop = DevelopTemplate(name: "No Crop", settings: source, includesCrop: false)
        let withCrop = DevelopTemplate(name: "With Crop", settings: source, includesCrop: true)

        #expect(withoutCrop.settingsForApplication(preserving: target).crop == targetCrop)
        #expect(withCrop.settingsForApplication(preserving: target).crop == sourceCrop)
        #expect(withoutCrop.summary == "Global")
        #expect(withCrop.summary == "Global • Crop")
    }

    @Test("Templates saved before crop options continue to include crop")
    func legacyTemplatesIncludeCrop() throws {
        let legacy = LegacyDevelopTemplate(
            id: UUID(),
            name: "Legacy",
            settings: CameraRawSettings(),
            shortcutSlot: 4
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(DevelopTemplate.self, from: data)

        #expect(decoded.includesCrop)
    }

    @Test("failed editor saves keep the develop draft open and allow saving a new copy")
    @MainActor
    func failedEditorSaveKeepsDevelopDraftAndSavesCopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevelopTemplateSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageLocation = root.appendingPathComponent("templates")

        var settings = CameraRawSettings()
        settings.exposure2012 = 1.5
        let original = DevelopTemplate(name: "Original", settings: settings)
        let viewModel = DevelopTemplateViewModel(
            storage: DevelopTemplateStorageService(directoryURL: storageLocation)
        )
        try DevelopTemplateStorageService(directoryURL: storageLocation).save(original)
        await withCheckedContinuation { continuation in
            viewModel.loadTemplates { _ in continuation.resume() }
        }
        viewModel.startEditing(original)
        try FileManager.default.removeItem(at: storageLocation)
        try Data("blocks directory creation".utf8).write(to: storageLocation)
        viewModel.editingTemplate.name = "Edited develop draft"

        let failedResult = await viewModel.saveEditingTemplate()

        guard case let .failure(failure) = failedResult else {
            Issue.record("Expected the injected storage failure")
            return
        }
        #expect(failure.templateKind == .develop)
        #expect(viewModel.saveError == failure)
        #expect(viewModel.isEditing)
        #expect(viewModel.isEditingExistingTemplate)
        #expect(viewModel.editingTemplate.id == original.id)
        #expect(viewModel.editingTemplate.name == "Edited develop draft")
        #expect(viewModel.editingTemplate.settings.exposure2012 == 1.5)

        try FileManager.default.removeItem(at: storageLocation)
        try FileManager.default.createDirectory(at: storageLocation, withIntermediateDirectories: false)

        let saveAsResult = await viewModel.saveEditingTemplateAsNew()

        guard case let .success(saved) = saveAsResult else {
            Issue.record("Expected Save as New to succeed after restoring writable storage")
            return
        }
        #expect(saved.id != original.id)
        #expect(viewModel.editingTemplate.id == saved.id)
        #expect(!viewModel.isEditing)
        #expect(viewModel.saveError == nil)
        #expect(try DevelopTemplateStorageService(directoryURL: storageLocation).loadAll() == [saved])
    }

    @MainActor
    @Test("Develop template CRUD runs storage away from MainActor and returns refreshed values")
    func developTemplateCRUDRunsOffMainActor() async throws {
        let probe = DevelopTemplateCRUDProbe()
        let service = TemplateCRUDService(access: probe.access)
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.75
        let template = DevelopTemplate(name: "Bright", settings: settings, shortcutSlot: 2)
        let requestID = UUID()

        let result = try await service.save(template, requestID: requestID)

        guard case .committed(let commit) = result else {
            Issue.record("Expected a durable Develop template save")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.requestedTemplateCommitted)
        #expect(commit.refreshedTemplates == [template])
        #expect(commit.durableTemplateIDs == [template.id])
        #expect(!probe.observedMainThreadStorage)
        #expect(probe.maximumConcurrentOperations == 1)
    }
}

private struct LegacyDevelopTemplate: Codable {
    let id: UUID
    let name: String
    let settings: CameraRawSettings
    let shortcutSlot: Int?
}

nonisolated private final class DevelopTemplateCRUDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inventory: [DevelopTemplate] = []
    private var sawMainThread = false
    private var activeOperations = 0
    private var maximumActiveOperations = 0

    var access: TemplateCRUDAccess<DevelopTemplate> {
        TemplateCRUDAccess(
            loadAll: { [self] in operation { inventory } },
            save: { [self] template in
                operation {
                    if let index = inventory.firstIndex(where: { $0.id == template.id }) {
                        inventory[index] = template
                    } else {
                        inventory.append(template)
                    }
                }
            },
            delete: { [self] template in
                operation { inventory.removeAll { $0.id == template.id } }
            },
            exportAll: { [self] _ in operation { inventory.count } },
            shortcutSlot: { $0.shortcutSlot },
            clearingShortcutSlot: {
                var copy = $0
                copy.shortcutSlot = nil
                return copy
            },
            sorted: { $0.sorted { $0.name < $1.name } }
        )
    }

    private func operation<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        sawMainThread = sawMainThread || Thread.isMainThread
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        defer {
            activeOperations -= 1
            lock.unlock()
        }
        return try body()
    }

    var observedMainThreadStorage: Bool { lock.withLock { sawMainThread } }
    var maximumConcurrentOperations: Int { lock.withLock { maximumActiveOperations } }
}

@Suite("Template command routing")
struct TemplateCommandRoutingTests {
    @Test("Only the edit workspace routes shared shortcuts to develop templates")
    func routeByMainViewMode() {
        #expect(MainViewMode.editing.templateCommandTarget == .develop)
        #expect(MainViewMode.browser.templateCommandTarget == .metadata)
        #expect(MainViewMode.metadataReview.templateCommandTarget == .metadata)
        #expect(MainViewMode.imageAnalysis.templateCommandTarget == .metadata)
        #expect(MainViewMode.faceManagement.templateCommandTarget == .metadata)
        #expect(MainViewMode.peopleDatabase.templateCommandTarget == .metadata)
    }
}
