import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop templates")
struct DevelopTemplateTests {
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
        try Data("blocks directory creation".utf8).write(to: storageLocation)

        var settings = CameraRawSettings()
        settings.exposure2012 = 1.5
        let original = DevelopTemplate(name: "Original", settings: settings)
        let viewModel = DevelopTemplateViewModel(
            storage: DevelopTemplateStorageService(directoryURL: storageLocation)
        )
        viewModel.startEditing(original)
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
