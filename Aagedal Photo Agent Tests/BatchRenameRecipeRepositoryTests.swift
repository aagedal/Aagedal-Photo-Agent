import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Batch rename recipe repository")
struct BatchRenameRecipeRepositoryTests {
    private let alphaID = UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
    private let zuluID = UUID(uuidString: "42000000-0000-0000-0000-000000000002")!

    @Test("cancelled portable operations skip source access and leave storage unchanged", arguments: [false, true])
    func cancelledPortableOperation(isExport: Bool) async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL, importFile: { _ in
            Issue.record("A cancelled import accessed its source")
            throw CancellationError()
        }, stageExport: { _, _ in
            Issue.record("A cancelled export staged output")
        })
        _ = try await repository.create(recipe: recipe(name: "Existing", literal: "a.jpg"), id: alphaID)
        let original = try Data(contentsOf: fixture.repositoryURL)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            if isExport {
                try await repository.exportPreset(id: alphaID, to: fixture.exportURL)
            } else {
                _ = try await repository.importPreset(from: fixture.exportURL)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.repositoryURL) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.exportURL.path))
    }

    @Test("portable import preserves task context and stops before mutation when its read is cancelled")
    @MainActor
    func cancelledPortableRead() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let imported = BatchRenameRecipePreset(id: zuluID, recipe: recipe(name: "Imported", literal: "i.jpg"))
        let queue = DispatchSerialQueue(label: "test.recipe.portable-read")
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL, filesystemQueue: queue, importFile: { _ in
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(RecipePortableFileContext.marker == "portable-file")
            withUnsafeCurrentTask { $0?.cancel() }
            return imported
        })
        _ = try await repository.create(recipe: recipe(name: "Existing", literal: "a.jpg"), id: alphaID)
        let original = try Data(contentsOf: fixture.repositoryURL)
        let task = Task {
            try await RecipePortableFileContext.$marker.withValue("portable-file") {
                _ = try await repository.importPreset(from: fixture.exportURL)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.repositoryURL) == original)
    }

    @Test("cancelled staging removes temporary output before export promotion")
    @MainActor
    func cancelledPortableStaging() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let queue = DispatchSerialQueue(label: "test.recipe.portable-stage")
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL, filesystemQueue: queue, stageExport: { value, url in
            #expect(queue.isIsolatingCurrentContext() == true)
            #expect(!Thread.isMainThread)
            #expect(RecipePortableFileContext.marker == "portable-file")
            try BatchRenameRecipePresetIO().encode(value).write(to: url, options: .atomic)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        _ = try await repository.create(recipe: recipe(name: "Existing", literal: "a.jpg"), id: alphaID)
        let original = try Data(contentsOf: fixture.repositoryURL)
        let task = Task {
            try await RecipePortableFileContext.$marker.withValue("portable-file") {
                try await repository.exportPreset(id: alphaID, to: fixture.exportURL)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.repositoryURL) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.exportURL.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.directoryURL.path)
        #expect(!contents.contains { $0.contains(".export-") })
    }

    @Test("stable IDs, deterministic listing, selection, and deletion survive reopening")
    func stableIdentityAndSelection() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)

        let zulu = try await repository.create(
            recipe: recipe(name: "  Zulu  ", literal: "z.jpg"),
            collisionChoice: .skip,
            id: zuluID
        )
        let alpha = try await repository.create(
            recipe: recipe(name: "Alpha", literal: "a.jpg"),
            id: alphaID
        )
        #expect(zulu.name == "Zulu")
        #expect(alpha.id == alphaID)

        var snapshot = try await repository.snapshot()
        #expect(snapshot.presets.map(\.id) == [alphaID, zuluID])
        #expect(snapshot.selectedPresetID == zuluID)

        try await repository.select(id: alphaID)
        let reopened = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.selectedPreset?.id == alphaID)
        #expect(snapshot.selectedPreset?.collisionChoice == .block)

        try await reopened.delete(id: alphaID)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.selectedPresetID == zuluID)
        try await reopened.delete(id: zuluID)
        snapshot = try await reopened.snapshot()
        #expect(snapshot.presets.isEmpty)
        #expect(snapshot.selectedPresetID == nil)
    }

    @Test("overlapping creates are serialized as one read-modify-write transaction")
    func overlappingCreatesCannotLoseAnUpdate() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let pause = MutationPause()
        let repository = BatchRenameRecipeRepository(
            documentURL: fixture.repositoryURL,
            testingPauseAfterLoad: { await pause.pause() }
        )

        async let first = repository.create(
            recipe: recipe(name: "Alpha", literal: "a.jpg"),
            id: alphaID
        )
        await pause.waitUntilFirstLoadIsPaused()
        async let second = repository.create(
            recipe: recipe(name: "Zulu", literal: "z.jpg"),
            id: zuluID
        )
        for _ in 0..<20 { await Task.yield() }
        await pause.release()

        _ = try await (first, second)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.presets.map(\.id) == [alphaID, zuluID])
    }

    @Test("cancelling portable work behind an active mutation releases its turn without output", arguments: [false, true])
    func cancelledPortableWorkBehindMutation(isExport: Bool) async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let pause = MutationPause()
        let repository = BatchRenameRecipeRepository(
            documentURL: fixture.repositoryURL,
            testingPauseAfterLoad: { await pause.pause() },
            importFile: { _ in
                Issue.record("Cancelled queued import accessed its source")
                throw CancellationError()
            },
            stageExport: { _, _ in Issue.record("Cancelled queued export staged output") }
        )
        let first = Task {
            try await repository.create(recipe: recipe(name: "Alpha", literal: "a.jpg"), id: alphaID)
        }
        await pause.waitUntilFirstLoadIsPaused()
        let portable = Task {
            if isExport {
                try await repository.exportPreset(id: alphaID, to: fixture.exportURL)
            } else {
                _ = try await repository.importPreset(from: fixture.exportURL)
            }
        }
        for _ in 0..<20 { await Task.yield() }
        portable.cancel()
        await pause.release()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await portable.value }
        #expect(try await repository.snapshot().presets.map(\.id) == [alphaID])
        #expect(!FileManager.default.fileExists(atPath: fixture.exportURL.path))
        // A cancelled waiter must relinquish its gate so the next mutation can commit.
        _ = try await repository.create(recipe: recipe(name: "Zulu", literal: "z.jpg"), id: zuluID)
        #expect(try await repository.snapshot().presets.map(\.id) == [alphaID, zuluID])
    }

    @Test("update, duplicate, and rename collisions do not replace existing recipes")
    func mutationAndNameCollisions() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)
        _ = try await repository.create(
            recipe: recipe(name: "Alpha", literal: "a.jpg"),
            id: alphaID
        )
        _ = try await repository.create(
            recipe: recipe(name: "Zulu", literal: "z.jpg"),
            id: zuluID
        )
        let originalBytes = try Data(contentsOf: fixture.repositoryURL)

        await #expect(throws: BatchRenameRecipeRepositoryError.duplicatePresetName("alpha")) {
            _ = try await repository.rename(id: zuluID, to: "alpha")
        }
        #expect(try Data(contentsOf: fixture.repositoryURL) == originalBytes)

        let copy = try await repository.duplicate(id: alphaID)
        #expect(copy.id != alphaID)
        #expect(copy.name == "Alpha Copy")
        #expect(copy.recipe.components == [BatchRenameComponent.literal("a.jpg")])

        let updated = try await repository.update(
            id: copy.id,
            recipe: recipe(name: copy.name, literal: "updated.jpg"),
            collisionChoice: .deterministicSuffix
        )
        #expect(updated.recipe.components == [.literal("updated.jpg")])
        #expect(updated.collisionChoice == .deterministicSuffix)
    }

    @Test("portable import and export preserve rich renderer semantics and never overwrite")
    func portableRoundTripNeverOverwrites() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)
        let rich = BatchRenameRecipe(
            name: "Wire",
            components: [
                .token(.metadata(.event)),
                .literal("-"),
                .token(.jobTitle),
                .token(.date(BatchRenameDateToken(
                    source: .capture(fallback: .fileCreation),
                    format: "yyyy-MM-dd"
                ))),
            ],
            substitutions: [.regularExpression(pattern: #"\s+"#, replacement: "-")],
            caseConversion: .lowercase,
            whitespace: .replace(with: "_"),
            sanitization: .filesystemSafe(replacement: "-"),
            missingValuePolicy: .fallback("unknown"),
            unicodeNormalization: .compatibilityComposed,
            originalFilenameMetadata: .preserveInXMP,
            timeZoneIdentifier: "Europe/Oslo"
        )
        let saved = try await repository.create(
            recipe: rich,
            collisionChoice: .deterministicSuffix,
            id: alphaID
        )

        try await repository.exportPreset(id: alphaID, to: fixture.exportURL)
        let exportedBytes = try Data(contentsOf: fixture.exportURL)
        let decoded = try BatchRenameRecipePresetIO().decode(exportedBytes)
        #expect(decoded == saved)
        let firstExport = exportedBytes

        await #expect(
            throws: BatchRenameRecipeRepositoryError.exportDestinationExists(fixture.exportURL)
        ) {
            try await repository.exportPreset(id: alphaID, to: fixture.exportURL)
        }
        #expect(try Data(contentsOf: fixture.exportURL) == firstExport)

        let importedRepository = BatchRenameRecipeRepository(documentURL: fixture.secondRepositoryURL)
        let imported = try await importedRepository.importPreset(from: fixture.exportURL)
        #expect(imported == saved)
        let persisted = String(
            decoding: try Data(contentsOf: fixture.secondRepositoryURL),
            as: UTF8.self
        )
        #expect(!persisted.localizedCaseInsensitiveContains("securityScopedBookmark"))
        #expect(!persisted.localizedCaseInsensitiveContains("privateKey"))
        #expect(!persisted.localizedCaseInsensitiveContains("credential"))

        await #expect(throws: BatchRenameRecipeRepositoryError.presetAlreadyExists(alphaID)) {
            _ = try await importedRepository.importPreset(from: fixture.exportURL)
        }
    }

    @Test("version one libraries migrate with deterministic selection and stable persisted IDs")
    func versionOneMigration() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        try fixture.writeVersionOneLibrary(
            recipes: [
                recipe(name: "Zulu", literal: "z.jpg"),
                recipe(name: "Alpha", literal: "a.jpg"),
            ],
            selectedRecipeName: "Zulu"
        )

        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.presets.map(\.name) == ["Alpha", "Zulu"])
        #expect(snapshot.selectedPreset?.name == "Zulu")

        let migrated = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.repositoryURL))
                as? [String: Any]
        )
        #expect(migrated["schemaVersion"] as? Int == 2)
        let reopened = try await BatchRenameRecipeRepository(
            documentURL: fixture.repositoryURL
        ).snapshot()
        #expect(reopened.presets.map(\.id) == snapshot.presets.map(\.id))
        #expect(reopened.selectedPresetID == snapshot.selectedPresetID)
    }

    @Test("invalid persisted selection is rejected without rewriting the library")
    func invalidSelectionDoesNotRewrite() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        try fixture.writeVersionTwoLibrary(
            presets: [BatchRenameRecipePreset(
                id: alphaID,
                recipe: recipe(name: "Alpha", literal: "a.jpg")
            )],
            selectedPresetID: zuluID
        )
        let original = try Data(contentsOf: fixture.repositoryURL)
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)

        await #expect(
            throws: BatchRenameRecipeRepositoryError.selectedPresetMissing(zuluID)
        ) {
            _ = try await repository.snapshot()
        }
        #expect(try Data(contentsOf: fixture.repositoryURL) == original)
    }

    @Test("a newer nested recipe cannot downgrade through an older valid backup")
    func nestedFutureRecipeProtectsPrimaryAndBackup() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)
        _ = try await repository.create(
            recipe: recipe(name: "Alpha", literal: "a.jpg"),
            id: alphaID
        )
        _ = try await repository.create(
            recipe: recipe(name: "Zulu", literal: "z.jpg"),
            id: zuluID
        )
        let backupURL = fixture.repositoryURL.appendingPathExtension("backup")
        let backup = try Data(contentsOf: backupURL)

        var library = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.repositoryURL))
                as? [String: Any]
        )
        var presets = try #require(library["presets"] as? [[String: Any]])
        var recipe = try #require(presets[0]["recipe"] as? [String: Any])
        recipe["schemaVersion"] = 99
        recipe["future"] = ["keep": true]
        presets[0]["recipe"] = recipe
        library["presets"] = presets
        let future = try JSONSerialization.data(withJSONObject: library, options: [.sortedKeys])
        try future.write(to: fixture.repositoryURL)

        await #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "batch rename recipe",
            found: 99,
            supported: BatchRenameRecipe.currentSchemaVersion
        )) {
            _ = try await BatchRenameRecipeRepository(
                documentURL: fixture.repositoryURL
            ).snapshot()
        }
        #expect(try Data(contentsOf: fixture.repositoryURL) == future)
        #expect(try Data(contentsOf: backupURL) == backup)
    }

    @Test("invalid recipes are refused before persistence")
    func strictValidation() async throws {
        let fixture = try RecipeRepositoryFixture()
        defer { fixture.remove() }
        let repository = BatchRenameRecipeRepository(documentURL: fixture.repositoryURL)
        let invalidRegex = BatchRenameRecipe(
            name: "Broken",
            components: [.token(.originalFilename)],
            substitutions: [.regularExpression(pattern: "(", replacement: "")]
        )

        await #expect(
            throws: BatchRenameRecipeValidationError.invalidRegularExpression(
                substitutionIndex: 0,
                pattern: "("
            )
        ) {
            _ = try await repository.create(recipe: invalidRegex)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.repositoryURL.path))

        let invalidTimeZone = BatchRenameRecipe(
            name: "Broken timezone",
            components: [.literal("x.jpg")],
            timeZoneIdentifier: "Not/A_Timezone"
        )
        await #expect(
            throws: BatchRenameRecipeValidationError.invalidTimeZone("Not/A_Timezone")
        ) {
            _ = try await repository.create(recipe: invalidTimeZone)
        }
    }

    @Test("editor round-trips every recipe token and non-visual transform")
    func editorRoundTrip() {
        let original = BatchRenameRecipe(
            name: "Everything",
            components: [
                .token(.originalFilename),
                .token(.originalStem),
                .token(.originalExtension),
                .token(.sequence(BatchRenameSequence(start: 5, step: 2, padding: 4))),
                .token(.date(BatchRenameDateToken(source: .capture(fallback: .fileCreation), format: "HHmm"))),
                .token(.date(BatchRenameDateToken(source: .fileCreation, format: "yyyy"))),
                .token(.date(BatchRenameDateToken(source: .fileModification, format: "MM"))),
                .token(.metadata(.cameraSerial)),
                .token(.jobTitle),
                .token(.importTitle),
            ],
            substitutions: [.literal(find: "x", replacement: "y")],
            caseConversion: .uppercase,
            whitespace: .replace(with: "-", collapseRuns: false),
            sanitization: .disabled,
            missingValuePolicy: .skip,
            unicodeNormalization: .canonicalDecomposed,
            originalFilenameMetadata: .preserveInXMP,
            timeZoneIdentifier: "America/New_York"
        )
        let editor = BatchRenameEditorState(recipe: original, collisionChoice: .skip)

        #expect(editor.recipe == original)
        #expect(editor.collisionChoice == .skip)
    }

    @MainActor
    @Test("sheet keeps ad-hoc and per-preset drafts while rebuilding immutable plans")
    func sheetDraftsSurvivePresetSwitches() async throws {
        let root = URL(fileURLWithPath: "/rename-library", isDirectory: true)
        let request = BatchRenameSheetRequest(
            folderURL: root,
            items: [RenamePlanningItem(sourceImageURL: root.appendingPathComponent("old.jpg"))]
        )
        let session = BatchRenameSheetSession(
            request: request,
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        session.editor.components[0].literal = "ad-hoc.jpg"
        let preset = BatchRenameRecipePreset(
            id: alphaID,
            recipe: recipe(name: "Saved", literal: "saved.jpg"),
            collisionChoice: .block
        )

        session.selectRecipePreset(preset)
        await session.waitForPlanning()
        #expect(session.plan?.entries.first?.requestedDestinationImageURL?.lastPathComponent == "saved.jpg")
        session.editor.components[0].literal = "draft.jpg"
        #expect(session.hasUnsavedPresetChanges)

        session.useAdHocRecipe()
        #expect(session.editor.components[0].literal == "ad-hoc.jpg")
        session.selectRecipePreset(preset)
        await session.waitForPlanning()
        #expect(session.editor.components[0].literal == "draft.jpg")
        #expect(session.plan?.entries.first?.requestedDestinationImageURL?.lastPathComponent == "draft.jpg")

        let updated = BatchRenameRecipePreset(
            id: alphaID,
            recipe: recipe(name: "Saved", literal: "draft.jpg"),
            collisionChoice: .block
        )
        session.markRecipePresetSaved(updated)
        await session.waitForPlanning()
        #expect(!session.hasUnsavedPresetChanges)

        session.preserveDeletedPresetAsAdHoc(id: alphaID)
        #expect(session.selectedRecipePresetID == nil)
        #expect(session.editor.components[0].literal == "draft.jpg")
    }

    private func recipe(name: String, literal: String) -> BatchRenameRecipe {
        BatchRenameRecipe(name: name, components: [.literal(literal)])
    }
}

private actor MutationPause {
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstLoadObserved = false
    private var isReleased = false

    func pause() async {
        if !firstLoadObserved {
            firstLoadObserved = true
            firstLoadContinuation?.resume()
            firstLoadContinuation = nil
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilFirstLoadIsPaused() async {
        guard !firstLoadObserved else { return }
        await withCheckedContinuation { continuation in
            firstLoadContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private struct RecipeRepositoryFixture {
    let directoryURL: URL
    let repositoryURL: URL
    let secondRepositoryURL: URL
    let exportURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-rename-recipe-repository-\(UUID().uuidString)",
            isDirectory: true
        )
        repositoryURL = directoryURL.appendingPathComponent("recipes.json")
        secondRepositoryURL = directoryURL.appendingPathComponent("imported-recipes.json")
        exportURL = directoryURL.appendingPathComponent("wire.rename-recipe.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func writeVersionOneLibrary(
        recipes: [BatchRenameRecipe],
        selectedRecipeName: String?
    ) throws {
        let encoder = JSONEncoder()
        let recipeObjects = try recipes.map {
            try JSONSerialization.jsonObject(with: encoder.encode($0))
        }
        var object: [String: Any] = [
            "schemaVersion": 1,
            "recipes": recipeObjects,
        ]
        if let selectedRecipeName { object["selectedRecipeName"] = selectedRecipeName }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: repositoryURL)
    }

    func writeVersionTwoLibrary(
        presets: [BatchRenameRecipePreset],
        selectedPresetID: UUID
    ) throws {
        let encoder = JSONEncoder()
        let presetObjects = try presets.map {
            try JSONSerialization.jsonObject(with: encoder.encode($0))
        }
        let object: [String: Any] = [
            "schemaVersion": 2,
            "presets": presetObjects,
            "selectedPresetID": selectedPresetID.uuidString,
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: repositoryURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private nonisolated enum RecipePortableFileContext {
    @TaskLocal static var marker: String?
}
