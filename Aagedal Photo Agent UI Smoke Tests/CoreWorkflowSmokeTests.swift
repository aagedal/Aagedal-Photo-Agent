import AppKit
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
    private func launch(
        workflow: String,
        folder: URL? = nil,
        source: URL? = nil,
        destination: URL? = nil,
        profileStore: URL? = nil
    ) {
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing",
            "--ui-test-workflow", workflow,
        ]
        append("--ui-test-folder", folder)
        append("--ui-test-source", source)
        append("--ui-test-destination", destination)
        append("--ui-test-profile-store", profileStore)
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
