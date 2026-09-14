import AppKit
import CryptoKit
import XCTest

final class CoreWorkflowSmokeTests: XCTestCase {
    private var fixtureRoot: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalPhotoAgentUISmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    @MainActor
    func testLaunchAndOpenFolder() throws {
        let photos = try makePhotoFolder(count: 2)
        launch(workflow: "open-folder", folder: photos)

        XCTAssertTrue(app.descendants(matching: .any)["browser.workspace"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["No Images"].exists)
    }

    @MainActor
    func testSearchKeepsFocusWhenResultsReappear() throws {
        let photos = try makePhotoFolder(count: 2)
        launch(workflow: "open-folder", folder: photos)

        let search = app.textFields["browser.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 12))
        search.click()
        search.typeText("smoke")
        XCTAssertEqual(search.value as? String, "smoke")

        search.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 5))
        // Send keys to the current responder, without clicking/refocusing the field.
        for _ in 0..<4 {
            search.typeKey(.delete, modifierFlags: [])
        }
        XCTAssertEqual(search.value as? String, "smoke")
        let resultsReturned = NSPredicate { _, _ in
            !self.app.staticTexts["No Results"].exists
        }
        expectation(for: resultsReturned, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        search.typeText("-1")
        XCTAssertEqual(search.value as? String, "smoke-1")
    }

    @MainActor
    func testImportOverwriteRequiresExplicitPreflightConfirmation() throws {
        let source = try makePhotoFolder(count: 1)
        let destination = fixtureRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let importFolder = destination.appendingPathComponent(importFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: importFolder, withIntermediateDirectories: true)
        let existing = importFolder.appendingPathComponent("smoke-1.jpg")
        try Data("existing destination bytes".utf8).write(to: existing)

        launch(
            workflow: "import-preflight",
            source: source,
            destination: destination
        )

        XCTAssertTrue(app.staticTexts["Import Photos"].waitForExistence(timeout: 10))
        let startImport = app.buttons["import.start"]
        XCTAssertTrue(startImport.waitForExistence(timeout: 10))
        startImport.click()

        let replace = app.buttons["Replace 1 existing files"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Confirm overwrite"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(replace.waitForExistence(timeout: 2))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing destination bytes".utf8))
    }

    @MainActor
    func testCaptionEditSavesBeforeAdvancing() throws {
        let photos = try makePhotoFolder(count: 2)
        launch(workflow: "caption", folder: photos)

        XCTAssertTrue(app.descendants(matching: .any)["caption.workspace"].waitForExistence(timeout: 15))
        let headline = app.textFields["metadata.input.title"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        headline.click()
        headline.typeText("Smoke caption")

        let saveAndNext = app.buttons["Save & Next"]
        XCTAssertTrue(saveAndNext.isEnabled)
        saveAndNext.click()
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testApprovedVoiceMemoReviewPersistsCompleteNativeEditsAcrossRelaunch() throws {
        let fixture = try makeApprovedVoiceMemoFolder()
        let originalRelationship = try Data(contentsOf: fixture.relationshipURL)
        let originalMemo = try Data(contentsOf: fixture.memoURL)
        launch(workflow: "caption", folder: fixture.folder)

        XCTAssertTrue(app.descendants(matching: .any)["caption.workspace"].waitForExistence(timeout: 15))
        let draft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
        let approval = app.descendants(matching: .any)["caption.voiceMemo.approveTranscript"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertTrue(approval.exists)
        XCTAssertFalse(approval.isEnabled)
        XCTAssertTrue((draft.value as? String)?.contains("Approved UI smoke review") == true)

        draft.click()
        draft.typeKey("a", modifierFlags: .command)
        draft.typeText("Complete native review after many editor updates")
        XCTAssertTrue(waitForTranscript(
            "Complete native review after many editor updates",
            approved: false,
            at: fixture.sidecarURL
        ))
        XCTAssertTrue(approval.isEnabled)

        app.terminate()
        launch(workflow: "caption", folder: fixture.folder)
        let relaunchedDraft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
        let relaunchedApproval = app.descendants(matching: .any)["caption.voiceMemo.approveTranscript"]
        XCTAssertTrue(relaunchedDraft.waitForExistence(timeout: 15))
        XCTAssertTrue((relaunchedDraft.value as? String)?.contains(
            "Complete native review after many editor updates"
        ) == true)
        XCTAssertTrue(relaunchedApproval.isEnabled)

        relaunchedApproval.click()
        XCTAssertTrue(waitForTranscript(
            "Complete native review after many editor updates",
            approved: true,
            at: fixture.sidecarURL
        ))
        XCTAssertTrue(waitForEnabled(relaunchedApproval, expected: false))
        XCTAssertEqual(try Data(contentsOf: fixture.relationshipURL), originalRelationship)
        XCTAssertEqual(try Data(contentsOf: fixture.memoURL), originalMemo)
    }

    @MainActor
    func testInstalledLanguageTranscribesLocalSpeechAndPersistsReviewAcrossRelaunch() throws {
        guard ProcessInfo.processInfo.environment["APA_RUN_NATIVE_SPEECH"] == "1" else {
            throw XCTSkip("Set APA_RUN_NATIVE_SPEECH=1 for the installed-language release drill")
        }
        let fixture = try makeSyntheticSpeechVoiceMemoFolder()
        let originalRelationship = try Data(contentsOf: fixture.relationshipURL)
        let originalMemo = try Data(contentsOf: fixture.memoURL)
        launch(workflow: "caption", folder: fixture.folder, localeIdentifier: "en_US")

        XCTAssertTrue(app.descendants(matching: .any)["caption.workspace"].waitForExistence(timeout: 15))
        let transcribe = app.buttons["caption.voiceMemo.transcribe"]
        if !transcribe.waitForExistence(timeout: 10) {
            if app.buttons["caption.voiceMemo.downloadLanguage"].exists {
                throw XCTSkip("The English Apple on-device speech asset is not installed on this Mac")
            }
            throw XCTSkip("Apple on-device speech is unavailable for the disposable English fixture")
        }

        transcribe.click()
        let draft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 45))
        let generated = (draft.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(generated.isEmpty)
        XCTAssertTrue(generated.localizedCaseInsensitiveContains("photo"), "Unexpected transcript: \(generated)")

        draft.click()
        draft.typeKey("a", modifierFlags: .command)
        draft.typeText(syntheticReviewedTranscript)
        let approval = app.buttons["caption.voiceMemo.approveTranscript"]
        XCTAssertTrue(approval.waitForExistence(timeout: 5))
        XCTAssertTrue(approval.isEnabled)
        approval.click()
        XCTAssertTrue(waitForTranscript(
            syntheticReviewedTranscript,
            approved: true,
            at: fixture.sidecarURL
        ))

        app.terminate()
        launch(workflow: "caption", folder: fixture.folder, localeIdentifier: "en_US")
        let relaunchedDraft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
        XCTAssertTrue(relaunchedDraft.waitForExistence(timeout: 15))
        XCTAssertEqual(relaunchedDraft.value as? String, syntheticReviewedTranscript)
        XCTAssertFalse(app.buttons["caption.voiceMemo.approveTranscript"].isEnabled)
        XCTAssertEqual(try Data(contentsOf: fixture.relationshipURL), originalRelationship)
        XCTAssertEqual(try Data(contentsOf: fixture.memoURL), originalMemo)
    }

    @MainActor
    func testApprovedVoiceMemoAppliesOnlyAfterPreviewAndReadsBackAcrossRelaunch() throws {
        let fixture = try makeApprovedVoiceMemoFolder(includePendingMetadata: true)
        let templateRoot = try makeVoiceMemoTemplateRoot()
        let originalImage = try Data(contentsOf: fixture.imageURL)
        let originalRelationship = try Data(contentsOf: fixture.relationshipURL)
        let originalMemo = try Data(contentsOf: fixture.memoURL)
        let originalSidecar = try Data(contentsOf: fixture.sidecarURL)
        launch(workflow: "caption", folder: fixture.folder, templateRoot: templateRoot)

        XCTAssertTrue(app.descendants(matching: .any)["caption.workspace"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"].waitForExistence(timeout: 15))

        openVoiceMemoTemplate(action: "Replace…")
        let cancelledPreview = app.descendants(matching: .any)["voiceMemoTranscript.preview"]
        XCTAssertTrue(cancelledPreview.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Replace will change 4 fields across 1 photo. Nothing is written until you confirm."].exists)
        let cancel = app.buttons["voiceMemoTranscript.cancel"]
        XCTAssertTrue(cancel.exists)
        XCTAssertEqual(cancel.label, "Cancel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(cancelledPreview.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: fixture.imageURL), originalImage)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), originalSidecar)

        app.terminate()
        launch(workflow: "caption", folder: fixture.folder, templateRoot: templateRoot)
        XCTAssertTrue(app.descendants(matching: .any)["caption.workspace"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"].waitForExistence(timeout: 15))

        openVoiceMemoTemplate(action: "Append…")
        let confirmedPreview = app.descendants(matching: .any)["voiceMemoTranscript.preview"]
        XCTAssertTrue(confirmedPreview.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Append will change 4 fields across 1 photo. Nothing is written until you confirm."].exists)
        for field in ["Headline", "Description", "Extended Description", "Instructions"] {
            XCTAssertTrue(app.staticTexts[field].exists, "Missing \(field) from transcript preview")
        }
        let confirm = app.buttons["voiceMemoTranscript.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertEqual(confirm.label, "Confirm and Write")
        confirm.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForAppliedVoiceMemoMetadata(at: fixture.sidecarURL))
        XCTAssertFalse(confirmedPreview.waitForExistence(timeout: 5))
        XCTAssertNotEqual(try Data(contentsOf: fixture.imageURL), originalImage)
        XCTAssertEqual(try Data(contentsOf: fixture.relationshipURL), originalRelationship)
        XCTAssertEqual(try Data(contentsOf: fixture.memoURL), originalMemo)

        app.terminate()
        launch(workflow: "caption", folder: fixture.folder, templateRoot: templateRoot)
        let headline = app.textFields["metadata.input.title"]
        let description = app.descendants(matching: .any)["metadata.input.description"]
        XCTAssertTrue(headline.waitForExistence(timeout: 15))
        XCTAssertTrue(description.waitForExistence(timeout: 10))
        XCTAssertEqual(headline.value as? String, appliedHeadline)
        XCTAssertEqual(description.value as? String, appliedDescription)
        XCTAssertTrue(app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"].waitForExistence(timeout: 15))
    }

    @MainActor
    func testVoiceMemoBatchRefusesInvalidAuthorityThenAppliesTwoApprovedTranscripts() throws {
        let templateRoot = try makeVoiceMemoTemplateRoot()

        for invalidAuthority in [TranscriptAuthority.missing, .unapproved, .stale] {
            let fixture = try makeVoiceMemoBatch(authorities: [.approved, invalidAuthority])
            let originalImages = try fixture.items.map { try Data(contentsOf: $0.imageURL) }
            let originalSidecars = try fixture.items.map { try Data(contentsOf: $0.sidecarURL) }
            let originalRelationships = try fixture.items.map { try Data(contentsOf: $0.relationshipURL) }
            let originalMemos = try fixture.items.map { try Data(contentsOf: $0.memoURL) }

            launch(workflow: "voice-memo-variable-batch", folder: fixture.folder, templateRoot: templateRoot)
            XCTAssertTrue(app.descendants(matching: .any)["browser.workspace"].waitForExistence(timeout: 15))
            openBrowserVoiceMemoTemplate()

            let panel = app.descendants(matching: .any)["metadata.panel"]
            XCTAssertTrue(waitForValue(panel, containing: "0 photos were written"))
            XCTAssertFalse(app.descendants(matching: .any)["voiceMemoTranscript.preview"].exists)
            for (index, item) in fixture.items.enumerated() {
                XCTAssertEqual(try Data(contentsOf: item.imageURL), originalImages[index])
                XCTAssertEqual(try Data(contentsOf: item.sidecarURL), originalSidecars[index])
                XCTAssertEqual(try Data(contentsOf: item.relationshipURL), originalRelationships[index])
                XCTAssertEqual(try Data(contentsOf: item.memoURL), originalMemos[index])
            }
            app.terminate()
        }

        let fixture = try makeVoiceMemoBatch(authorities: [.approved, .approved])
        let originalImages = try fixture.items.map { try Data(contentsOf: $0.imageURL) }
        let originalRelationships = try fixture.items.map { try Data(contentsOf: $0.relationshipURL) }
        let originalMemos = try fixture.items.map { try Data(contentsOf: $0.memoURL) }
        launch(workflow: "voice-memo-variable-batch", folder: fixture.folder, templateRoot: templateRoot)
        XCTAssertTrue(app.descendants(matching: .any)["browser.workspace"].waitForExistence(timeout: 15))
        openBrowserVoiceMemoTemplate()

        let preview = app.descendants(matching: .any)["voiceMemoTranscript.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Replace will change 8 fields across 2 photos. Nothing is written until you confirm."].exists)
        let confirm = app.buttons["voiceMemoTranscript.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForAppliedVoiceMemoBatch(fixture.items))
        XCTAssertFalse(preview.waitForExistence(timeout: 5))
        for (index, item) in fixture.items.enumerated() {
            XCTAssertNotEqual(try Data(contentsOf: item.imageURL), originalImages[index])
            XCTAssertEqual(try Data(contentsOf: item.relationshipURL), originalRelationships[index])
            XCTAssertEqual(try Data(contentsOf: item.memoURL), originalMemos[index])
        }
    }

    @MainActor
    func testVoiceMemoBatchPreviewExportsAccessibleStructure() throws {
        let templateRoot = try makeVoiceMemoTemplateRoot()
        let fixture = try makeVoiceMemoBatch(authorities: [.approved, .approved])
        launch(workflow: "voice-memo-variable-batch", folder: fixture.folder, templateRoot: templateRoot)
        XCTAssertTrue(app.descendants(matching: .any)["browser.workspace"].waitForExistence(timeout: 15))
        openBrowserVoiceMemoTemplate()

        XCTAssertTrue(app.descendants(matching: .any)["voiceMemoTranscript.preview"].waitForExistence(timeout: 15))
        let summary = app.descendants(matching: .any)["voiceMemoTranscript.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "Transcript change summary")
        XCTAssertEqual(
            summary.value as? String,
            "Replace will change 8 fields across 2 photos. Nothing is written until you confirm."
        )
        for item in fixture.items {
            let photo = app.descendants(matching: .any)[
                "voiceMemoTranscript.photo.\(item.imageURL.lastPathComponent)"
            ]
            XCTAssertTrue(photo.exists)
            XCTAssertTrue(photo.label.contains("4 changed fields"))
            for field in ["title", "description", "extendedDescription", "instructions"] {
                XCTAssertTrue(app.descendants(matching: .any)[
                    "voiceMemoTranscript.field.\(item.imageURL.lastPathComponent).\(field)"
                ].exists)
            }
        }
        XCTAssertTrue(app.buttons["voiceMemoTranscript.confirm"].exists)
        XCTAssertTrue(app.buttons["voiceMemoTranscript.cancel"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any)["voiceMemoTranscript.preview"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBatchRenameOpensPreparedPreviewForSelection() throws {
        let photos = try makePhotoFolder(count: 2)
        launch(workflow: "batch-rename", folder: photos)

        XCTAssertTrue(app.descendants(matching: .any)["batchRename.workspace"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["2 selected files · recipe order follows the visible browser sort"].exists)
        XCTAssertTrue(app.buttons["Rename"].exists)
    }

    @MainActor
    func testDeadlineRunsPreflightAndPublishesReadiness() throws {
        let photos = try makePhotoFolder(count: 1)
        let profileStore = fixtureRoot
            .appendingPathComponent("DeadlineProfiles", isDirectory: true)
            .appendingPathComponent("profiles.json")
        launch(workflow: "deadline", folder: photos, profileStore: profileStore)

        XCTAssertTrue(app.descendants(matching: .any)["deadline.workspace"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["deadline.currentPhase"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["deadline.readinessSummary"].exists)
        XCTAssertTrue(app.staticTexts["deadline.nextRequiredAction"].exists)
    }

    @MainActor
    func testFolderLoadFailureOffersRecoveryActions() {
        let missing = fixtureRoot.appendingPathComponent("Missing Folder", isDirectory: true)
        launch(workflow: "recovery-error", folder: missing)

        XCTAssertTrue(app.staticTexts["Couldn’t Open Folder"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Open Another Folder"].exists)
        XCTAssertTrue(app.buttons["Dismiss"].exists)
    }

    @MainActor
    func testKnownPeopleInterchangeOpensDisposableDatabaseWithoutPanel() throws {
        let knownPeopleRoot = fixtureRoot.appendingPathComponent("KnownPeople", isDirectory: true)
        try FileManager.default.createDirectory(at: knownPeopleRoot, withIntermediateDirectories: true)

        launch(workflow: "known-people-interchange", knownPeopleRoot: knownPeopleRoot)

        XCTAssertTrue(app.descendants(matching: .any)["known-people-main-content"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.descendants(matching: .any)["known-people-interchange-menu"].exists)
        XCTAssertFalse(app.dialogs.firstMatch.exists)
    }

    @MainActor
    private func launch(
        workflow: String,
        folder: URL? = nil,
        source: URL? = nil,
        destination: URL? = nil,
        profileStore: URL? = nil,
        knownPeopleRoot: URL? = nil,
        templateRoot: URL? = nil,
        localeIdentifier: String? = nil
    ) {
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing",
            "--ui-test-workflow", workflow,
        ]
        if workflow == "known-people-interchange" {
            // Argument-domain defaults are process-only and keep this workflow away
            // from the user's iCloud-routed Known People store.
            app.launchArguments += ["-knownPeople.iCloudEnabled", "NO"]
        }
        if let localeIdentifier {
            app.launchArguments += ["-AppleLocale", localeIdentifier]
        }
        append("--ui-test-folder", folder)
        append("--ui-test-source", source)
        append("--ui-test-destination", destination)
        append("--ui-test-profile-store", profileStore)
        append("--ui-test-known-people-root", knownPeopleRoot)
        append("--ui-test-template-root", templateRoot)
        app.launch()
        reopenMainWindowIfNeeded()
    }

    @MainActor
    private func openVoiceMemoTemplate(action: String) {
        let applyTemplate = app.descendants(matching: .any)["caption.applyTemplate"]
        XCTAssertTrue(applyTemplate.waitForExistence(timeout: 10))
        applyTemplate.click()
        let actionButton = app.descendants(matching: .any)[action]
        XCTAssertTrue(actionButton.waitForExistence(timeout: 5))
        actionButton.click()
        let template = app.buttons["UI Smoke Voice Memo, 4 fields"]
        XCTAssertTrue(template.waitForExistence(timeout: 10))
        template.click()
    }

    @MainActor
    private func openBrowserVoiceMemoTemplate() {
        let applyTemplate = app.buttons["Apply metadata template"]
        XCTAssertTrue(applyTemplate.waitForExistence(timeout: 10))
        applyTemplate.click()
        let template = app.buttons["UI Smoke Voice Memo, 4 fields"]
        XCTAssertTrue(template.waitForExistence(timeout: 10))
        template.click()
    }

    @MainActor
    private func reopenMainWindowIfNeeded() {
        guard !app.windows.firstMatch.waitForExistence(timeout: 2) else { return }

        let windowMenu = app.menuBars.menuBarItems["Window"]
        guard windowMenu.waitForExistence(timeout: 3) else { return }
        windowMenu.click()

        let mainWindowItem = app.menuItems["Aagedal Photo Agent"]
        guard mainWindowItem.waitForExistence(timeout: 3) else { return }
        mainWindowItem.click()
    }

    @MainActor
    private func append(_ flag: String, _ url: URL?) {
        guard let url else { return }
        app.launchArguments += [flag, url.path]
    }

    private func makePhotoFolder(count: Int) throws -> URL {
        let folder = fixtureRoot.appendingPathComponent("Photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...count {
            try makeJPEG(index: index).write(
                to: folder.appendingPathComponent("smoke-\(index).jpg"),
                options: .atomic
            )
        }
        return folder
    }

    private struct VoiceMemoFixture {
        let folder: URL
        let imageURL: URL
        let memoURL: URL
        let relationshipURL: URL
        let sidecarURL: URL
    }

    private enum TranscriptAuthority: Equatable {
        case approved
        case missing
        case unapproved
        case stale
    }

    private struct VoiceMemoBatchItem {
        let imageURL: URL
        let memoURL: URL
        let relationshipURL: URL
        let sidecarURL: URL
        let transcript: String
    }

    private struct VoiceMemoBatchFixture {
        let folder: URL
        let items: [VoiceMemoBatchItem]
    }

    private func makeApprovedVoiceMemoFolder(includePendingMetadata: Bool = false) throws -> VoiceMemoFixture {
        let folder = fixtureRoot.appendingPathComponent(
            "ApprovedVoiceMemo-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageName = "voice-review.jpg"
        let memoName = "voice-review.WAV"
        let imageURL = folder.appendingPathComponent(imageName)
        let memoURL = folder.appendingPathComponent(memoName)
        let imageData = try makeJPEG(index: 2)
        let memoData = makeSilentWAV()
        try imageData.write(to: imageURL, options: .atomic)
        try memoData.write(to: memoURL, options: .atomic)

        let imageHash = sha256(imageData)
        let memoHash = sha256(memoData)
        let relationshipURL = folder.appendingPathComponent(".\(imageName).voice-memo.json")
        try writeJSON([
            "schemaVersion": 2,
            "profileIdentifier": "ui-smoke",
            "imageFilename": imageName,
            "memoFilename": memoName,
            "imageIdentity": ["byteCount": imageData.count, "sha256": imageHash],
            "memoIdentity": ["byteCount": memoData.count, "sha256": memoHash],
            "provenance": "capturedAssociation",
            "approvedTranscriptMemoSHA256": memoHash,
        ], to: relationshipURL)

        let sidecarDirectory = folder.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        let sidecarURL = sidecarDirectory.appendingPathComponent("\(imageName).meta.json")
        var sidecar: [String: Any] = [
            "schemaVersion": 1,
            "sourceFile": imageName,
            "voiceMemoTranscript": [
                "schemaVersion": 1,
                "sourceImageFilename": imageName,
                "sourceMemoFilename": memoName,
                "memoByteCount": memoData.count,
                "memoSHA256": memoHash,
                "associationProfileIdentifier": "ui-smoke",
                "localeIdentifier": "en-US",
                "provider": "Apple on-device speech",
                "providerModel": "System managed; exact version unavailable",
                "generatedAt": "2026-09-13T12:00:00Z",
                "generatedText": "Generated UI smoke transcript",
                "reviewedText": "Approved UI smoke review",
                "approvedAt": "2026-09-13T12:01:00Z",
            ],
        ]
        if includePendingMetadata {
            sidecar["pendingChanges"] = true
            sidecar["metadata"] = [
                "title": initialHeadline,
                "description": initialDescription,
                "extendedDescription": initialExtendedDescription,
                "instructions": initialInstructions,
            ]
        }
        try writeJSON(sidecar, to: sidecarURL)

        return VoiceMemoFixture(
            folder: folder,
            imageURL: imageURL,
            memoURL: memoURL,
            relationshipURL: relationshipURL,
            sidecarURL: sidecarURL
        )
    }

    @MainActor
    private func makeSyntheticSpeechVoiceMemoFolder() throws -> VoiceMemoFixture {
        let folder = fixtureRoot.appendingPathComponent(
            "SyntheticSpeechVoiceMemo-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageName = "spoken-review.jpg"
        let memoName = "spoken-review.WAV"
        let imageURL = folder.appendingPathComponent(imageName)
        let memoURL = folder.appendingPathComponent(memoName)
        let imageData = try makeJPEG(index: 3)
        try imageData.write(to: imageURL, options: .atomic)

        guard let synthesizer = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.defaultVoice),
              synthesizer.startSpeaking("Local photo memo for the picture desk.", to: memoURL) else {
            throw XCTSkip("Could not create the disposable local speech fixture")
        }
        let deadline = Date().addingTimeInterval(20)
        while synthesizer.isSpeaking, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !synthesizer.isSpeaking,
              let memoData = try? Data(contentsOf: memoURL),
              memoData.count > 44 else {
            synthesizer.stopSpeaking()
            throw XCTSkip("The disposable local speech fixture did not finish rendering")
        }

        let relationshipURL = folder.appendingPathComponent(".\(imageName).voice-memo.json")
        try writeJSON([
            "schemaVersion": 2,
            "profileIdentifier": "ui-smoke",
            "imageFilename": imageName,
            "memoFilename": memoName,
            "imageIdentity": ["byteCount": imageData.count, "sha256": sha256(imageData)],
            "memoIdentity": ["byteCount": memoData.count, "sha256": sha256(memoData)],
            "provenance": "capturedAssociation",
        ], to: relationshipURL)

        let sidecarDirectory = folder.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        return VoiceMemoFixture(
            folder: folder,
            imageURL: imageURL,
            memoURL: memoURL,
            relationshipURL: relationshipURL,
            sidecarURL: sidecarDirectory.appendingPathComponent("\(imageName).meta.json")
        )
    }

    private func makeVoiceMemoBatch(authorities: [TranscriptAuthority]) throws -> VoiceMemoBatchFixture {
        let folder = fixtureRoot.appendingPathComponent(
            "VoiceMemoBatch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecarDirectory = folder.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)

        var items: [VoiceMemoBatchItem] = []
        for (offset, authority) in authorities.enumerated() {
            let index = offset + 1
            let imageName = "voice-batch-\(index).jpg"
            let memoName = "voice-batch-\(index).WAV"
            let imageURL = folder.appendingPathComponent(imageName)
            let memoURL = folder.appendingPathComponent(memoName)
            let relationshipURL = folder.appendingPathComponent(".\(imageName).voice-memo.json")
            let sidecarURL = sidecarDirectory.appendingPathComponent("\(imageName).meta.json")
            let imageData = try makeJPEG(index: index)
            let memoData = makeSilentWAV()
            let imageHash = sha256(imageData)
            let memoHash = sha256(memoData)
            let transcript = "Approved batch review \(index)"
            try imageData.write(to: imageURL, options: .atomic)
            try memoData.write(to: memoURL, options: .atomic)

            var relationship: [String: Any] = [
                "schemaVersion": 2,
                "profileIdentifier": "ui-smoke",
                "imageFilename": imageName,
                "memoFilename": memoName,
                "imageIdentity": ["byteCount": imageData.count, "sha256": imageHash],
                "memoIdentity": ["byteCount": memoData.count, "sha256": memoHash],
                "provenance": "capturedAssociation",
            ]
            if authority == .approved || authority == .stale {
                relationship["approvedTranscriptMemoSHA256"] = memoHash
            }
            try writeJSON(relationship, to: relationshipURL)

            var sidecar: [String: Any] = [
                "schemaVersion": 1,
                "sourceFile": imageName,
                "pendingChanges": true,
                "metadata": [
                    "title": "Existing headline \(index)",
                    "description": "Existing description \(index)",
                    "extendedDescription": "Existing extended description \(index)",
                    "instructions": "Existing instructions \(index)",
                ],
            ]
            if authority != .missing {
                var transcriptRecord: [String: Any] = [
                    "schemaVersion": 1,
                    "sourceImageFilename": imageName,
                    "sourceMemoFilename": memoName,
                    "memoByteCount": memoData.count,
                    "memoSHA256": authority == .stale ? String(repeating: "f", count: 64) : memoHash,
                    "associationProfileIdentifier": "ui-smoke",
                    "localeIdentifier": "en-US",
                    "provider": "Apple on-device speech",
                    "providerModel": "System managed; exact version unavailable",
                    "generatedAt": "2026-09-13T12:00:00Z",
                    "generatedText": "Generated batch transcript \(index)",
                    "reviewedText": transcript,
                ]
                if authority != .unapproved {
                    transcriptRecord["approvedAt"] = "2026-09-13T12:01:00Z"
                }
                sidecar["voiceMemoTranscript"] = transcriptRecord
            }
            try writeJSON(sidecar, to: sidecarURL)
            items.append(.init(
                imageURL: imageURL,
                memoURL: memoURL,
                relationshipURL: relationshipURL,
                sidecarURL: sidecarURL,
                transcript: transcript
            ))
        }
        return .init(folder: folder, items: items)
    }

    private func makeVoiceMemoTemplateRoot() throws -> URL {
        let root = fixtureRoot.appendingPathComponent("Templates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func waitForAppliedVoiceMemoMetadata(at sidecarURL: URL) -> Bool {
        let predicate = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: sidecarURL),
                  let graph = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  graph["pendingChanges"] as? Bool == false,
                  let metadata = graph["metadata"] as? [String: Any] else { return false }
            return metadata["title"] as? String == self.appliedHeadline
                && metadata["description"] as? String == self.appliedDescription
                && metadata["extendedDescription"] as? String == self.appliedExtendedDescription
                && metadata["instructions"] as? String == self.appliedInstructions
        }
        expectation(for: predicate, evaluatedWith: NSObject())
        waitForExpectations(timeout: 20)
        return predicate.evaluate(with: NSObject())
    }

    @MainActor
    private func waitForAppliedVoiceMemoBatch(_ items: [VoiceMemoBatchItem]) -> Bool {
        let predicate = NSPredicate { _, _ in
            items.allSatisfy { item in
                guard let data = try? Data(contentsOf: item.sidecarURL),
                      let graph = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      graph["pendingChanges"] as? Bool == false,
                      let metadata = graph["metadata"] as? [String: Any] else { return false }
                return metadata["title"] as? String == item.transcript
                    && metadata["description"] as? String == item.transcript
                    && metadata["extendedDescription"] as? String == item.transcript
                    && metadata["instructions"] as? String == item.transcript
            }
        }
        expectation(for: predicate, evaluatedWith: NSObject())
        waitForExpectations(timeout: 30)
        return predicate.evaluate(with: NSObject())
    }

    private var transcriptText: String { "Approved UI smoke review" }
    private var syntheticReviewedTranscript: String { "Reviewed local speech after native transcription" }
    private var initialHeadline: String { "Existing headline" }
    private var initialDescription: String { "Existing description" }
    private var initialExtendedDescription: String { "Existing extended description" }
    private var initialInstructions: String { "Existing instructions" }
    private var appliedHeadline: String { "\(initialHeadline) \(transcriptText)" }
    private var appliedDescription: String { "\(initialDescription) \(transcriptText)" }
    private var appliedExtendedDescription: String { "\(initialExtendedDescription) \(transcriptText)" }
    private var appliedInstructions: String { "\(initialInstructions) \(transcriptText)" }

    @MainActor
    private func waitForTranscript(_ text: String, approved: Bool, at sidecarURL: URL) -> Bool {
        let predicate = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: sidecarURL),
                  let graph = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transcript = graph["voiceMemoTranscript"] as? [String: Any] else { return false }
            return transcript["reviewedText"] as? String == text
                && (transcript["approvedAt"] != nil) == approved
        }
        expectation(for: predicate, evaluatedWith: NSObject())
        waitForExpectations(timeout: 10)
        return predicate.evaluate(with: NSObject())
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, expected: Bool) -> Bool {
        let predicate = NSPredicate { _, _ in element.isEnabled == expected }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 5)
        return predicate.evaluate(with: element)
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate { _, _ in
            element.exists && (element.value as? String)?.contains(text) == true
        }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 20)
        return predicate.evaluate(with: element)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSilentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let sampleCount: UInt32 = 4_000
        let dataSize = sampleCount * 2
        var data = Data()
        data.append(Data("RIFF".utf8))
        appendLittleEndian(36 + dataSize, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func makeJPEG(index: Int) throws -> Data {
        let size = NSSize(width: 64, height: 48)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: CGFloat(index) * 0.2, green: 0.35, blue: 0.65, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw XCTSkip("Could not create the disposable JPEG fixture")
        }
        return jpeg
    }

    private var importFolderName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: Date())) – UI Smoke Import"
    }
}
