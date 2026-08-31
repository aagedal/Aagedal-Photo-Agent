import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop version session coordinator")
struct DevelopVersionSessionCoordinatorTests {
    @Test("version dialogs consume typed intents and reset as one image-scoped session")
    func dialogIntentLifecycle() {
        let coordinator = DevelopVersionDialogsCoordinator()
        let deleteID = UUID()
        let promotionID = UUID()

        coordinator.beginNameAction(.create, catalog: nil)
        #expect(coordinator.nameDraft == "Version 1")
        coordinator.nameDraft = "  Editorial  "
        let consumed = coordinator.consumeNameAction()
        #expect(consumed?.0 == .create)
        #expect(consumed?.1 == "  Editorial  ")
        #expect(coordinator.nameAction == nil)
        #expect(coordinator.nameDraft.isEmpty)

        coordinator.requestDelete(deleteID)
        coordinator.requestPromotion(promotionID)
        #expect(coordinator.consumeDelete() == deleteID)
        #expect(coordinator.pendingDeleteID == nil)
        #expect(coordinator.pendingPromotionID == promotionID)

        coordinator.reset()
        #expect(coordinator.pendingPromotionID == nil)
        #expect(!coordinator.isNameActionPresented)
        #expect(!coordinator.isDeletePresented)
        #expect(!coordinator.isPromotionPresented)
    }

    @Test("a replacement image session rejects a cancelled loader's late result")
    func replacementSessionRejectsLateLoad() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/session-a/source.raw")
        let secondURL = URL(fileURLWithPath: "/tmp/session-b/source.raw")
        let firstRevision = revision(url: firstURL, hashCharacter: "a")
        let secondRevision = revision(url: secondURL, hashCharacter: "b")
        let persistence = SessionPersistence()
        let coordinator = DevelopVersionSessionCoordinator(
            revisionCapture: { url, _ in
                if url == firstURL {
                    // Deliberately ignore cancellation to characterize the coordinator's token
                    // guard independently of well-behaved production dependencies.
                    try? await Task.sleep(for: .milliseconds(80))
                    return firstRevision
                }
                return secondRevision
            },
            repositoryFactory: { _ in persistence }
        )
        var firstReadyCount = 0
        var secondReadyCount = 0

        coordinator.beginLoading(imageURL: firstURL, orientation: 1) {
            firstReadyCount += 1
        }
        await Task.yield()
        coordinator.beginLoading(imageURL: secondURL, orientation: 1) {
            secondReadyCount += 1
        }

        try await eventually { coordinator.persistenceState == .clean }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.revision == secondRevision)
        #expect(coordinator.catalog?.source == secondRevision)
        #expect(firstReadyCount == 0)
        #expect(secondReadyCount == 1)
    }

    @Test("reset cancels a pending debounced catalog save")
    func resetCancelsDebouncedSave() async throws {
        let url = URL(fileURLWithPath: "/tmp/session-reset/source.raw")
        let sourceRevision = revision(url: url, hashCharacter: "c")
        let persistence = SessionPersistence()
        let coordinator = DevelopVersionSessionCoordinator(
            saveDelay: .milliseconds(100),
            revisionCapture: { _, _ in sourceRevision },
            repositoryFactory: { _ in persistence }
        )
        coordinator.beginLoading(imageURL: url, orientation: 1) {}
        try await eventually { coordinator.persistenceState == .clean }

        var catalog = try #require(coordinator.catalog)
        _ = try catalog.createVersion(name: "Editorial", settings: CameraRawSettings())
        coordinator.catalog = catalog
        coordinator.scheduleActiveSave(
            settings: CameraRawSettings(),
            watermarkDataProvider: { _ in nil },
            onSaved: {}
        )
        #expect(coordinator.persistenceState == .dirty)

        coordinator.reset()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await persistence.saveCount == 0)
        #expect(coordinator.catalog == nil)
        #expect(coordinator.persistenceState == .unavailable)
    }

    @Test("flush persists active settings through the injected boundary")
    func flushUsesPersistenceBoundary() async throws {
        let url = URL(fileURLWithPath: "/tmp/session-flush/source.raw")
        let sourceRevision = revision(url: url, hashCharacter: "d")
        let persistence = SessionPersistence()
        let coordinator = DevelopVersionSessionCoordinator(
            revisionCapture: { _, _ in sourceRevision },
            repositoryFactory: { _ in persistence }
        )
        coordinator.beginLoading(imageURL: url, orientation: 1) {}
        try await eventually { coordinator.persistenceState == .clean }

        var catalog = try #require(coordinator.catalog)
        _ = try catalog.createVersion(name: "Editorial", settings: CameraRawSettings())
        coordinator.catalog = catalog
        var edited = CameraRawSettings()
        edited.exposure2012 = 1.25
        var didSave = false

        let outcome = await coordinator.flushActive(
            reason: .workspaceExit,
            settings: edited,
            watermarkDataProvider: { _ in nil }
        ) {
            didSave = true
        }

        #expect(outcome == .succeeded)
        #expect(didSave)
        #expect(coordinator.persistenceState == .saved)
        #expect(await persistence.saveCount == 1)
        #expect(await persistence.lastSaved?.versions.first?.snapshot.settings.exposure2012 == 1.25)
    }

    @Test("Develop view delegates all named-version modal state to the coordinator")
    func dialogOwnerSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "@State private var developVersionDialogs = DevelopVersionDialogsCoordinator()"
        ))
        #expect(source.contains("developVersionDialogs.beginNameAction("))
        #expect(source.contains("developVersionDialogs.consumeNameAction()"))
        #expect(source.contains("developVersionDialogs.requestDelete("))
        #expect(source.contains("developVersionDialogs.requestPromotion("))
        #expect(source.contains("developVersionDialogs.reset()"))
        #expect(!source.contains("@State private var developVersionNameAction"))
        #expect(!source.contains("@State private var developVersionPendingDeleteID"))
        #expect(!source.contains("@State private var developVersionPendingPromotionID"))
    }

    private func revision(url: URL, hashCharacter: Character) -> SourceImageRevision {
        SourceImageRevision(
            canonicalURL: url,
            fileResourceIdentifier: nil,
            filenameAtCreation: url.lastPathComponent,
            byteCount: 10,
            contentModificationDate: Date(timeIntervalSince1970: 100),
            pixelWidth: 10,
            pixelHeight: 10,
            exifOrientation: 1,
            sha256: String(repeating: hashCharacter, count: 64),
            hashCompletedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func eventually(
        timeout: Duration = .seconds(30),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for coordinator state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SessionPersistence: DevelopVersionCatalogPersisting {
    private(set) var saveCount = 0
    private(set) var lastSaved: DevelopVersionCatalog?

    func loadMostRelevantCatalog(
        for revision: SourceImageRevision
    ) async -> DevelopVersionCatalogMatch {
        .none
    }

    func save(
        _ catalog: DevelopVersionCatalog
    ) async throws -> DevelopVersionCatalogStorage {
        saveCount += 1
        lastSaved = catalog
        return .folderLocal
    }
}
