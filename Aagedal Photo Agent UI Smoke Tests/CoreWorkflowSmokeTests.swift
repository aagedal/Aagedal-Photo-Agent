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

        XCTAssertTrue(app.otherElements["browser.workspace"].waitForExistence(timeout: 12))
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
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
        let resultsReturned = NSPredicate { _, _ in
            !self.app.staticTexts["No Results"].exists
        }
        expectation(for: resultsReturned, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        app.typeText("-1")
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

        XCTAssertTrue(app.otherElements["import.workspace"].waitForExistence(timeout: 10))
        app.buttons["import.start"].click()

        let alert = app.alerts["Confirm overwrite"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.buttons["Replace 1 existing files"].exists)
        alert.buttons["Cancel"].click()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing destination bytes".utf8))
    }

    @MainActor
    func testCaptionEditSavesBeforeAdvancing() throws {
        let photos = try makePhotoFolder(count: 2)
        launch(workflow: "caption", folder: photos)

        XCTAssertTrue(app.otherElements["caption.workspace"].waitForExistence(timeout: 15))
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

        XCTAssertTrue(app.otherElements["caption.workspace"].waitForExistence(timeout: 15))
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
        XCTAssertFalse(relaunchedApproval.isEnabled)
        XCTAssertEqual(try Data(contentsOf: fixture.relationshipURL), originalRelationship)
        XCTAssertEqual(try Data(contentsOf: fixture.memoURL), originalMemo)
    }

    @MainActor
    func testBatchRenameOpensPreparedPreviewForSelection() throws {
        let photos = try makePhotoFolder(count: 2)
        launch(workflow: "batch-rename", folder: photos)

        XCTAssertTrue(app.otherElements["batchRename.workspace"].waitForExistence(timeout: 15))
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

        XCTAssertTrue(app.otherElements["deadline.workspace"].waitForExistence(timeout: 15))
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

        XCTAssertTrue(app.otherElements["known-people-main-content"].waitForExistence(timeout: 12))
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
        knownPeopleRoot: URL? = nil
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
        append("--ui-test-folder", folder)
        append("--ui-test-source", source)
        append("--ui-test-destination", destination)
        append("--ui-test-profile-store", profileStore)
        append("--ui-test-known-people-root", knownPeopleRoot)
        app.launch()
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
        let memoURL: URL
        let relationshipURL: URL
        let sidecarURL: URL
    }

    private func makeApprovedVoiceMemoFolder() throws -> VoiceMemoFixture {
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
        try writeJSON([
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
        ], to: sidecarURL)

        return VoiceMemoFixture(
            folder: folder,
            memoURL: memoURL,
            relationshipURL: relationshipURL,
            sidecarURL: sidecarURL
        )
    }

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
