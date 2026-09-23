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
            let suiteName = "com.aagedal.photo-agent.ui-tests.whisper.\(fixtureRoot.lastPathComponent)"
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
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
    func testAutomationPatchReviewRefusesInvalidPlanWithoutChangingPhotos() throws {
        let photos = try makePhotoFolder(count: 1)
        let image = photos.appendingPathComponent("smoke-1.jpg")
        let before = try Data(contentsOf: image)
        launch(workflow: "open-folder", folder: photos)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.click()
        input.typeText("not-a-plan")
        app.buttons["automation.inspectPatchPlan"].click()
        let error = app.staticTexts["automation.patchPlanError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let expectedError = "Enter the exact plan ID returned by prepare_iptc_patch."
        XCTAssertTrue(error.label == expectedError || (error.value as? String) == expectedError)
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(error.exists)
        XCTAssertFalse(app.buttons["automation.inspectPatchPlan"].isEnabled)
        XCTAssertEqual(try Data(contentsOf: image), before)
    }

    @MainActor
    func testAutomationPatchReviewDisplaysExactPlanAndRefusesChangedPhoto() throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifestURL = fixtureRoot.appendingPathComponent("patch-review-fixture.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: String])
        let planID = try XCTUnwrap(manifest["planID"])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let before = try Data(contentsOf: photo)
        input.click()
        input.typeText(planID)
        app.buttons["automation.inspectPatchPlan"].click()
        let proposed = app.staticTexts[try XCTUnwrap(manifest["afterTitle"])]
        XCTAssertTrue(proposed.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[try XCTUnwrap(manifest["beforeTitle"])].exists)
        XCTAssertTrue(app.staticTexts[try XCTUnwrap(manifest["beforeCity"])].exists)
        XCTAssertTrue(app.staticTexts["(empty)"].exists)
        XCTAssertEqual(try Data(contentsOf: photo), before)
        app.buttons["Clear Review"].click()
        XCTAssertFalse(proposed.exists)
        app.staticTexts["Shortcuts"].click()
        automation.click()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: String], manifest)
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeText(planID)
        // An external same-path replacement invalidates the exact source revision.
        try before.write(to: photo, options: .atomic)
        app.buttons["automation.inspectPatchPlan"].click()
        XCTAssertTrue(app.staticTexts["automation.patchPlanError"].waitForExistence(timeout: 8))
        XCTAssertFalse(proposed.exists)
        XCTAssertEqual(try Data(contentsOf: photo), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photo.deletingLastPathComponent().path), ["review.jpg"])
    }

    @MainActor
    func testAutomationPatchApprovalRevokesAndRefusesChangedPhoto() throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifestURL = fixtureRoot.appendingPathComponent("patch-review-fixture.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: String])
        let planID = try XCTUnwrap(manifest["planID"])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let before = try Data(contentsOf: photo)
        input.click()
        input.typeText(planID)
        app.buttons["automation.inspectPatchPlan"].click()
        let approve = app.buttons["automation.approvePatchPlan"]
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        approve.click()
        let status = app.staticTexts["automation.patchApprovalStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(try Data(contentsOf: photo), before)
        app.buttons["automation.revokePatchApproval"].click()
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        XCTAssertFalse(status.exists)
        approve.click()
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        app.buttons["Clear Review"].click()
        XCTAssertFalse(status.exists)
        app.buttons["automation.inspectPatchPlan"].click()
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        approve.click()
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        app.staticTexts["Shortcuts"].click()
        automation.click()
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertFalse(status.exists)
        input.click()
        input.typeKey("a", modifierFlags: .command)
        input.typeText(planID)
        app.buttons["automation.inspectPatchPlan"].click()
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        // A source replaced after inspection must fail the consent-time revalidation.
        try before.write(to: photo, options: .atomic)
        approve.click()
        XCTAssertTrue(app.staticTexts["automation.patchPlanError"].waitForExistence(timeout: 8))
        XCTAssertFalse(status.exists)
        XCTAssertEqual(try Data(contentsOf: photo), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photo.deletingLastPathComponent().path), ["review.jpg"])
    }

    @MainActor
    func testAutomationResolvesInterruptedUnchangedXMPStaging() throws {
        try exerciseInterruptedXMPStaging(conflict: nil)
    }

    @MainActor
    func testAutomationRecoveryRefusesPhotoReplacementAfterInspection() throws {
        try exerciseInterruptedXMPStaging(conflict: .photoReplacement)
    }

    @MainActor
    func testAutomationRecoveryPreservesExternalXMPAfterInspection() throws {
        try exerciseInterruptedXMPStaging(conflict: .externalXMP)
    }

    private enum RecoveryConflict { case photoReplacement, externalXMP }

    @MainActor
    private func exerciseInterruptedXMPStaging(conflict: RecoveryConflict?) throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot,
            xmpStagingInterruption: true)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixtureRoot.appendingPathComponent("patch-review-fixture.json"))) as? [String: String])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let original = try Data(contentsOf: photo)
        let xmp = photo.deletingPathExtension().appendingPathExtension("xmp")
        let history = photo.deletingLastPathComponent().appendingPathComponent(".photo_metadata/review.jpg.meta.json")
        input.click()
        input.typeText(try XCTUnwrap(manifest["planID"]))
        app.buttons["automation.inspectPatchPlan"].click()
        let dryRun = app.buttons["automation.verifyPatchXMP"]
        XCTAssertTrue(dryRun.waitForExistence(timeout: 8))
        dryRun.click()
        let acknowledgement = app.descendants(matching: .any)["automation.acknowledgeXMPC2PA"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 12))
        acknowledgement.click()
        app.buttons["automation.approveXMPCandidate"].click()
        let publish = app.buttons["automation.publishApprovedXMP"]
        XCTAssertTrue(publish.waitForExistence(timeout: 8))
        publish.click()
        XCTAssertTrue(app.staticTexts["automation.patchDraftStatus"].waitForExistence(timeout: 12))
        app.buttons["Clear Review"].click()
        let inspect = app.buttons["automation.inspectRecovery"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 8))
        inspect.click()
        let resolve = app.buttons["automation.resolveUnchangedRecovery"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 8))
        XCTAssertTrue(resolve.isEnabled)
        let journal = fixtureRoot.appendingPathComponent("patch-operations/iptc-xmp-recovery/operations.json")
        let stagedJournal = try Data(contentsOf: journal)
        let externalXMP = Data("<?xml version=\"1.0\"?><external>Keep this peer edit</external>".utf8)
        if let conflict {
            switch conflict {
            case .photoReplacement: try original.write(to: photo, options: .atomic)
            case .externalXMP: try externalXMP.write(to: xmp, options: .withoutOverwriting)
            }
        }
        resolve.click()
        let status = app.staticTexts["automation.recoveryStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        if let conflict {
            let refusal = "Staging could not be resolved."
            XCTAssertTrue(status.label.hasPrefix(refusal) || (status.value as? String)?.hasPrefix(refusal) == true)
            XCTAssertEqual(try Data(contentsOf: journal), stagedJournal)
            XCTAssertEqual(try Data(contentsOf: photo), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
            if conflict == .externalXMP { XCTAssertEqual(try Data(contentsOf: xmp), externalXMP) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: xmp.path)) }
            inspect.click()
            XCTAssertTrue(resolve.waitForExistence(timeout: 8))
            XCTAssertFalse(resolve.isEnabled)
            XCTAssertEqual(try Data(contentsOf: journal), stagedJournal)
            app.terminate()
            launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
            XCTAssertEqual(try Data(contentsOf: journal), stagedJournal)
            XCTAssertEqual(try Data(contentsOf: photo), original)
            if conflict == .externalXMP { XCTAssertEqual(try Data(contentsOf: xmp), externalXMP) }
            return
        }
        let expected = "Unchanged staging resolved. No photo or metadata files were changed. Recovery material remains retained until the next publication is staged."
        XCTAssertTrue(status.label == expected || status.value as? String == expected)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        let receipt = try Data(contentsOf: journal)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 5)
        inspect.click()
        let empty = "No unresolved XMP publication staging is retained."
        let emptyStatus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && (status.label == empty || status.value as? String == empty)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [emptyStatus], timeout: 8), .completed)
        app.terminate()
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        XCTAssertEqual(try Data(contentsOf: journal), receipt)
        XCTAssertEqual(try Data(contentsOf: photo), original)
    }

    @MainActor
    func testAutomationRestoresInterruptedXMPAfterExplicitConfirmation() throws {
        try exercisePartialPublicationRestoration(replaceAfterInspection: false, originalCarriersPresent: false)
    }

    @MainActor
    func testAutomationRestoresExistingXMPAndHistoryAfterExplicitConfirmation() throws {
        try exercisePartialPublicationRestoration(replaceAfterInspection: false, originalCarriersPresent: true)
    }

    @MainActor
    func testAutomationRestorationRefusesReplacedXMPAfterInspection() throws {
        try exercisePartialPublicationRestoration(replaceAfterInspection: true, originalCarriersPresent: false)
    }

    @MainActor
    func testAutomationRestorationRefusesReplacedHistoryAfterInspection() throws {
        try exercisePartialPublicationRestoration(replaceAfterInspection: false,
            originalCarriersPresent: true, replaceHistoryAfterInspection: true)
    }

    @MainActor
    private func exercisePartialPublicationRestoration(replaceAfterInspection: Bool,
                                                       originalCarriersPresent: Bool,
                                                       replaceHistoryAfterInspection: Bool = false) throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot,
            xmpPublicationInterruption: true, existingRecoveryCarriers: originalCarriersPresent)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixtureRoot.appendingPathComponent("patch-review-fixture.json"))) as? [String: String])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let original = try Data(contentsOf: photo)
        let xmp = photo.deletingPathExtension().appendingPathExtension("xmp")
        let history = photo.deletingLastPathComponent().appendingPathComponent(".photo_metadata/review.jpg.meta.json")
        let originalXMP = originalCarriersPresent ? try Data(contentsOf: xmp) : nil
        let originalHistory = originalCarriersPresent ? try Data(contentsOf: history) : nil
        input.click()
        input.typeText(try XCTUnwrap(manifest["planID"]))
        app.buttons["automation.inspectPatchPlan"].click()
        let dryRun = app.buttons["automation.verifyPatchXMP"]
        XCTAssertTrue(dryRun.waitForExistence(timeout: 8))
        dryRun.click()
        let acknowledgement = app.descendants(matching: .any)["automation.acknowledgeXMPC2PA"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 12))
        acknowledgement.click()
        if originalCarriersPresent {
            let pendingAcknowledgement = app.descendants(matching: .any)["automation.acknowledgeXMPPendingDraft"]
            XCTAssertTrue(pendingAcknowledgement.waitForExistence(timeout: 8))
            pendingAcknowledgement.click()
        }
        app.buttons["automation.approveXMPCandidate"].click()
        let publish = app.buttons["automation.publishApprovedXMP"]
        XCTAssertTrue(publish.waitForExistence(timeout: 8))
        publish.click()
        XCTAssertTrue(app.staticTexts["automation.patchDraftStatus"].waitForExistence(timeout: 12))
        let published = try Data(contentsOf: xmp)
        XCTAssertFalse(published.isEmpty)
        XCTAssertEqual(try? Data(contentsOf: history), originalHistory)
        app.buttons["Clear Review"].click()
        let inspect = app.buttons["automation.inspectRecovery"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 8))
        inspect.click()
        let restore = app.buttons["automation.restoreOriginalMetadata"]
        XCTAssertTrue(restore.waitForExistence(timeout: 8))
        XCTAssertTrue(restore.isEnabled)
        let journal = fixtureRoot.appendingPathComponent("patch-operations/iptc-xmp-recovery/operations.json")
        let staged = try Data(contentsOf: journal)
        restore.click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(try Data(contentsOf: xmp), published)
        XCTAssertEqual(try Data(contentsOf: journal), staged)
        restore.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        if replaceAfterInspection { try published.write(to: xmp, options: .atomic) }
        if replaceHistoryAfterInspection, let originalHistory {
            try originalHistory.write(to: history, options: .atomic)
        }
        confirmation.buttons["Restore Original Metadata"].click()
        let status = app.staticTexts["automation.recoveryStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 12))
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try? Data(contentsOf: history), originalHistory)
        if replaceAfterInspection || replaceHistoryAfterInspection {
            XCTAssertEqual(try Data(contentsOf: journal), staged)
            XCTAssertEqual(try Data(contentsOf: xmp), published)
            inspect.click()
            XCTAssertTrue(restore.waitForExistence(timeout: 8))
            XCTAssertFalse(restore.isEnabled)
        } else {
            XCTAssertTrue(status.label.hasPrefix("Original metadata restored.") ||
                (status.value as? String)?.hasPrefix("Original metadata restored.") == true)
            XCTAssertEqual(try? Data(contentsOf: xmp), originalXMP)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
            XCTAssertEqual(envelope["version"] as? Int, 8)
        }
        let finalJournal = try Data(contentsOf: journal)
        app.terminate()
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        XCTAssertEqual(try Data(contentsOf: journal), finalJournal)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try? Data(contentsOf: xmp),
            replaceAfterInspection || replaceHistoryAfterInspection ? published : originalXMP)
        XCTAssertEqual(try? Data(contentsOf: history), originalHistory)
    }

    @MainActor
    func testAutomationXMPPublicationPersistsAndRecordsVerifiedOutcome() throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixtureRoot.appendingPathComponent("patch-review-fixture.json"))) as? [String: String])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let original = try Data(contentsOf: photo)
        input.click()
        input.typeText(try XCTUnwrap(manifest["planID"]))
        app.buttons["automation.inspectPatchPlan"].click()
        let dryRun = app.buttons["automation.verifyPatchXMP"]
        XCTAssertTrue(dryRun.waitForExistence(timeout: 8))
        dryRun.click()
        let acknowledgement = app.descendants(matching: .any)["automation.acknowledgeXMPC2PA"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 12))
        acknowledgement.click()
        app.buttons["automation.approveXMPCandidate"].click()
        let publish = app.buttons["automation.publishApprovedXMP"]
        XCTAssertTrue(publish.waitForExistence(timeout: 8))
        XCTAssertEqual(try Data(contentsOf: photo), original)
        publish.click()
        let status = app.staticTexts["automation.patchDraftStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 12))
        let expected = "XMP published and local metadata history verified. Original photo bytes were unchanged."
        XCTAssertTrue(status.label == expected || status.value as? String == expected)
        XCTAssertFalse(publish.exists)
        let xmp = photo.deletingPathExtension().appendingPathExtension("xmp")
        let published = try Data(contentsOf: xmp)
        XCTAssertFalse(published.isEmpty)
        let history = photo.deletingLastPathComponent().appendingPathComponent(".photo_metadata/review.jpg.meta.json")
        let saved = try Data(contentsOf: history)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(record["pendingChanges"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        app.terminate()
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try Data(contentsOf: xmp), published)
        XCTAssertEqual(try Data(contentsOf: history), saved)
    }

    @MainActor
    func testAutomationPatchXMPDryRunPreservesPhotosAndRevokesConsent() throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixtureRoot.appendingPathComponent("patch-review-fixture.json"))) as? [String: String])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let original = try Data(contentsOf: photo)
        input.click()
        input.typeText(try XCTUnwrap(manifest["planID"]))
        app.buttons["automation.inspectPatchPlan"].click()
        let approve = app.buttons["automation.approvePatchPlan"]
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        approve.click()
        let approval = app.staticTexts["automation.patchApprovalStatus"]
        XCTAssertTrue(approval.waitForExistence(timeout: 8))
        let dryRun = app.buttons["automation.verifyPatchXMP"]
        XCTAssertTrue(dryRun.waitForExistence(timeout: 8))
        dryRun.click()
        let status = app.staticTexts["automation.patchXMPStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 12))
        XCTAssertFalse(approval.exists)
        XCTAssertFalse(app.buttons["automation.applyPatchDraft"].exists)
        XCTAssertTrue(approve.exists)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photo.deletingLastPathComponent().path), ["review.jpg"])
        let xmpApprove = app.buttons["automation.approveXMPCandidate"]
        XCTAssertTrue(xmpApprove.waitForExistence(timeout: 8))
        XCTAssertFalse(xmpApprove.isEnabled)
        let acknowledgement = app.descendants(matching: .any)["automation.acknowledgeXMPC2PA"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 8))
        acknowledgement.click()
        XCTAssertTrue(xmpApprove.isEnabled)
        xmpApprove.click()
        let xmpApproval = app.staticTexts["automation.patchXMPApprovalStatus"]
        XCTAssertTrue(xmpApproval.waitForExistence(timeout: 8))
        XCTAssertFalse(approval.exists)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photo.deletingLastPathComponent().path), ["review.jpg"])
        app.buttons["automation.revokeXMPApproval"].click()
        XCTAssertFalse(xmpApproval.exists)
        XCTAssertFalse(xmpApprove.isEnabled)
        // Evidence remains a checked snapshot; a repeated dry run must reject source replacement.
        try original.write(to: photo, options: .atomic)
        dryRun.click()
        XCTAssertTrue(app.staticTexts["automation.patchPlanError"].waitForExistence(timeout: 8))
        XCTAssertFalse(status.exists)
        XCTAssertFalse(approve.exists)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photo.deletingLastPathComponent().path), ["review.jpg"])
    }

    @MainActor
    func testAutomationPatchAppliesOnlyToPendingDraft() throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let input = app.textFields["automation.patchPlanID"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let manifestURL = fixtureRoot.appendingPathComponent("patch-review-fixture.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: String])
        let photo = URL(fileURLWithPath: try XCTUnwrap(manifest["photoPath"]))
        let before = try Data(contentsOf: photo)
        let draftURL = photo.deletingLastPathComponent().appendingPathComponent(".photo_metadata/review.jpg.meta.json")
        input.click()
        input.typeText(try XCTUnwrap(manifest["planID"]))
        app.buttons["automation.inspectPatchPlan"].click()
        let approve = app.buttons["automation.approvePatchPlan"]
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        approve.click()
        let apply = app.buttons["automation.applyPatchDraft"]
        XCTAssertTrue(apply.waitForExistence(timeout: 8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftURL.path))
        apply.click()
        let result = app.staticTexts["automation.patchDraftStatus"]
        XCTAssertTrue(result.waitForExistence(timeout: 12))
        XCTAssertTrue(result.label.contains("saved and verified") || (result.value as? String)?.contains("saved and verified") == true)
        XCTAssertFalse(apply.exists)
        XCTAssertEqual(try Data(contentsOf: photo), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.deletingPathExtension().appendingPathExtension("xmp").path))
        let draftBytes = try Data(contentsOf: draftURL)
        let draft = try XCTUnwrap(JSONSerialization.jsonObject(with: draftBytes) as? [String: Any])
        XCTAssertEqual(draft["pendingChanges"] as? Bool, true)
        let metadata = try XCTUnwrap(draft["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["title"] as? String, manifest["afterTitle"])
        XCTAssertTrue(metadata["city"] == nil || metadata["city"] is NSNull)
        let refresh = app.buttons["automation.refreshOperations"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        refresh.click()
        let historyStatus = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "automation.operationStatus.")).firstMatch
        XCTAssertTrue(historyStatus.waitForExistence(timeout: 8))
        XCTAssertTrue(historyStatus.label.contains("not published") || (historyStatus.value as? String)?.contains("not published") == true)
        let remove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove completed operation record")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(historyStatus.exists)
        remove.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Remove Record"].click()
        XCTAssertTrue(app.staticTexts["No retained operations"].waitForExistence(timeout: 8))
        XCTAssertEqual(try Data(contentsOf: draftURL), draftBytes)
        app.terminate()
        launch(workflow: "open-folder", folder: photos)
        XCTAssertTrue(app.descendants(matching: .any)["browser.workspace"].waitForExistence(timeout: 12))
        XCTAssertEqual(try Data(contentsOf: draftURL), draftBytes)
        XCTAssertEqual(try Data(contentsOf: photo), before)
    }

    @MainActor
    func testAutomationHistoryRecoversStoppedOwnerAfterRelaunch() throws {
        let photos = try makePhotoFolder(count: 1)
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot, operationRecovery: true)
        app.typeKey(",", modifierFlags: .command)
        let automation = app.staticTexts["Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 8))
        automation.click()
        let refresh = app.buttons["automation.refreshOperations"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        let operationID = try String(contentsOf: fixtureRoot.appendingPathComponent("recovery-operation-id.txt"), encoding: .utf8)
        let identifier = "automation.operationStatus.\(operationID)"
        refresh.click()
        let status = app.staticTexts[identifier]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(status.label.contains("Cancellation requested") || (status.value as? String)?.contains("Cancellation requested") == true)
        // Terminating the process releases its kernel lease; no executor completion is fabricated.
        app.terminate()
        launch(workflow: "open-folder", folder: photos, patchReviewFolder: fixtureRoot)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Automation"].waitForExistence(timeout: 8))
        app.staticTexts["Automation"].click()
        let recovered = app.staticTexts[identifier]
        XCTAssertTrue(recovered.waitForExistence(timeout: 8))
        XCTAssertTrue(recovered.label.contains("Recovery required") || (recovered.value as? String)?.contains("Recovery required") == true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Remove completed operation record")).firstMatch.exists)
        app.buttons["automation.refreshOperations"].click()
        XCTAssertTrue(recovered.exists)
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
        try exercisePersistedTranscriptReview(whisper: false)
    }

    @MainActor
    func testWhisperEvidenceSurvivesNativeReviewApprovalAndRelaunch() throws {
        try exercisePersistedTranscriptReview(whisper: true)
    }

    @MainActor
    func testManagedWhisperUsesSettingsAndWaitsForExplicitModelDownload() throws {
        let fixture = try makeApprovedVoiceMemoFolder(whisper: true)
        let protectedFiles = [fixture.imageURL, fixture.memoURL, fixture.relationshipURL, fixture.sidecarURL]
        let originalBytes = try protectedFiles.map { try Data(contentsOf: $0) }
        let modelRoot = fixtureRoot.appendingPathComponent("WhisperModels", isDirectory: true)
        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "whisper")

        let draft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        assertCaptionHasNoTranscriptionSetup()
        XCTAssertFalse(app.descendants(matching: .any)["settings.transcription.whisper.model"].exists)
        XCTAssertFalse(app.buttons["settings.transcription.whisper.download"].exists)
        XCTAssertFalse(app.buttons["caption.voiceMemo.transcribe"].isEnabled)

        // Opening settings and revisiting the selected model never starts a network download.
        for _ in 0..<2 {
            app.buttons["caption.voiceMemo.transcriptionSettings"].click()
            let picker = app.descendants(matching: .any)["settings.transcription.whisper.model"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            let download = app.buttons["settings.transcription.whisper.download"]
            XCTAssertTrue(download.waitForExistence(timeout: 10))
            XCTAssertTrue(download.isEnabled)
            XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.selectExecutable"].exists)
            XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.selectModel"].exists)
            XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.enable"].exists)
            XCTAssertFalse(app.checkBoxes["caption.voiceMemo.whisper.executionConsent"].exists)
            XCTAssertTrue(app.textFields["caption.voiceMemo.whisper.language"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["settings.transcription.whisper.downloadProgress"].exists)
            XCTAssertFalse(app.buttons["settings.transcription.whisper.cancelDownload"].exists)
            XCTAssertFalse(app.buttons["settings.transcription.whisper.removeModel"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["settings.transcription.whisper.ready"].exists)
            if FileManager.default.fileExists(atPath: modelRoot.path) {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: modelRoot.path), [])
            }
            app.typeKey("w", modifierFlags: .command)
            let settingsClosed = NSPredicate { _, _ in !picker.exists }
            expectation(for: settingsClosed, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(draft.waitForExistence(timeout: 10))
            assertCaptionHasNoTranscriptionSetup()
        }
        XCTAssertTrue((draft.value as? String)?.contains("Approved UI smoke review") == true)
        XCTAssertFalse(app.descendants(matching: .any)["caption.voiceMemo.approveTranscript"].isEnabled)
        for (index, file) in protectedFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), originalBytes[index], file.lastPathComponent)
        }
    }

    @MainActor
    func testManagedWhisperRefusesCorruptCachedModelAcrossRelaunch() throws {
        let fixture = try makeApprovedVoiceMemoFolder(whisper: true)
        let protectedFiles = [fixture.imageURL, fixture.memoURL, fixture.relationshipURL, fixture.sidecarURL]
        let originalBytes = try protectedFiles.map { try Data(contentsOf: $0) }
        let modelRoot = fixtureRoot.appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let model = modelRoot.appendingPathComponent("ggml-base.bin")
        let corruptBytes = Data("incomplete model download".utf8)
        try corruptBytes.write(to: model)

        for _ in 0..<2 {
            launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "whisper")
            let draft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
            XCTAssertTrue(draft.waitForExistence(timeout: 15))
            app.buttons["caption.voiceMemo.transcriptionSettings"].click()
            let error = app.staticTexts["The downloaded model has an unexpected size. Please try again."]
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["settings.transcription.whisper.download"].isEnabled)
            XCTAssertFalse(app.descendants(matching: .any)["settings.transcription.whisper.ready"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["settings.transcription.whisper.downloadProgress"].exists)
            XCTAssertEqual(try Data(contentsOf: model), corruptBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: modelRoot.path), [model.lastPathComponent])
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(draft.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["caption.voiceMemo.transcribe"].isEnabled)
            XCTAssertTrue((draft.value as? String)?.contains("Approved UI smoke review") == true)
            for (index, file) in protectedFiles.enumerated() {
                XCTAssertEqual(try Data(contentsOf: file), originalBytes[index], file.lastPathComponent)
            }
            app.terminate()
        }
    }

    @MainActor
    func testCustomWhisperSetupRequiresFilesAndConsentWithoutChangingReview() throws {
        let fixture = try makeApprovedVoiceMemoFolder(whisper: true)
        let originalSidecar = try Data(contentsOf: fixture.sidecarURL)
        let originalImage = try Data(contentsOf: fixture.imageURL)
        let originalMemo = try Data(contentsOf: fixture.memoURL)
        let originalRelationship = try Data(contentsOf: fixture.relationshipURL)
        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")

        let draft = app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        openTranscriptionSettings()
        let enable = app.buttons["caption.voiceMemo.whisper.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        XCTAssertFalse(enable.isEnabled)
        XCTAssertFalse(app.buttons["caption.voiceMemo.downloadLanguage"].exists)
        let transcribe = app.buttons["caption.voiceMemo.transcribe"]
        XCTAssertFalse(transcribe.exists && transcribe.isEnabled)

        // Cancelling each real file panel must leave both setup and the approved draft intact.
        for identifier in ["caption.voiceMemo.whisper.selectExecutable", "caption.voiceMemo.whisper.selectModel"] {
            let choose = app.buttons[identifier]
            XCTAssertTrue(choose.exists)
            choose.click()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10))
            // macOS can expose a Touch Bar Cancel before the file-panel button.
            // Escape exercises the standard keyboard cancellation without selecting that proxy.
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(enable.waitForExistence(timeout: 5))
            XCTAssertFalse(enable.isEnabled)
        }
        closeTranscriptionSettings()
        XCTAssertTrue((draft.value as? String)?.contains("Approved UI smoke review") == true)
        XCTAssertFalse(app.descendants(matching: .any)["caption.voiceMemo.approveTranscript"].isEnabled)
        app.terminate()
        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")
        openTranscriptionSettings()
        XCTAssertTrue(app.buttons["caption.voiceMemo.whisper.enable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.enable"].isEnabled)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), originalSidecar)
        XCTAssertEqual(try Data(contentsOf: fixture.imageURL), originalImage)
        XCTAssertEqual(try Data(contentsOf: fixture.memoURL), originalMemo)
        XCTAssertEqual(try Data(contentsOf: fixture.relationshipURL), originalRelationship)
    }

    @MainActor
    func testCustomWhisperFileBookmarksSurviveRelaunchWithoutConsentAndClearPermanently() throws {
        let fixture = try makeApprovedVoiceMemoFolder(whisper: true)
        let executable = fixtureRoot.appendingPathComponent("smoke-custom-ffmpeg")
        let model = fixtureRoot.appendingPathComponent("smoke-custom-model.bin")
        // Setup records identities only. These disposable files are never used for inference.
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("Disposable native picker model fixture".utf8).write(to: model)
        let protectedFiles = [fixture.imageURL, fixture.memoURL, fixture.relationshipURL,
                              fixture.sidecarURL, executable, model]
        let originalBytes = try protectedFiles.map { try Data(contentsOf: $0) }

        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")
        openTranscriptionSettings()
        let enable = app.buttons["caption.voiceMemo.whisper.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 15))
        XCTAssertFalse(enable.isEnabled)
        chooseCustomWhisperFile(executable, button: "caption.voiceMemo.whisper.selectExecutable")
        chooseCustomWhisperFile(model, button: "caption.voiceMemo.whisper.selectModel")
        let consent = app.checkBoxes["caption.voiceMemo.whisper.executionConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertEqual(checkboxState(consent), false)
        XCTAssertFalse(enable.isEnabled)
        consent.click()
        XCTAssertTrue(waitForEnabled(enable, expected: true))
        enable.click()
        closeTranscriptionSettings()
        let transcribe = app.buttons["caption.voiceMemo.transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(transcribe, expected: true))

        app.terminate()
        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")
        openTranscriptionSettings()
        let restoredEnable = app.buttons["caption.voiceMemo.whisper.enable"]
        XCTAssertTrue(restoredEnable.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[executable.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[model.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.executionConsent"]), false)
        XCTAssertFalse(restoredEnable.isEnabled)
        XCTAssertFalse(app.buttons["caption.voiceMemo.transcribe"].exists
            && app.buttons["caption.voiceMemo.transcribe"].isEnabled)
        app.checkBoxes["caption.voiceMemo.whisper.executionConsent"].click()
        XCTAssertTrue(waitForEnabled(restoredEnable, expected: true))

        app.buttons["caption.voiceMemo.whisper.clear"].click()
        XCTAssertTrue(app.staticTexts["No executable selected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No model selected"].exists)
        XCTAssertFalse(restoredEnable.isEnabled)
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.executionConsent"]), false)
        app.terminate()
        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")
        openTranscriptionSettings()
        XCTAssertTrue(app.buttons["caption.voiceMemo.whisper.enable"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["No executable selected"].exists)
        XCTAssertTrue(app.staticTexts["No model selected"].exists)
        XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.enable"].isEnabled)
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.executionConsent"]), false)
        closeTranscriptionSettings()
        XCTAssertTrue((app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"].value as? String)?
            .contains("Approved UI smoke review") == true)
        XCTAssertFalse(app.descendants(matching: .any)["caption.voiceMemo.approveTranscript"].isEnabled)
        for (index, file) in protectedFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), originalBytes[index], file.lastPathComponent)
        }
    }

    @MainActor
    func testCustomWhisperOptionsPersistWithoutApprovingOrChangingTranscript() throws {
        let fixture = try makeApprovedVoiceMemoFolder(whisper: true)
        let protectedFiles = [fixture.imageURL, fixture.memoURL, fixture.relationshipURL, fixture.sidecarURL]
        let originalBytes = try protectedFiles.map { try Data(contentsOf: $0) }
        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")
        openTranscriptionSettings()
        let language = app.textFields["caption.voiceMemo.whisper.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 15))
        XCTAssertEqual(language.value as? String, "auto")
        language.click()
        language.typeKey("a", modifierFlags: .command)
        language.typeText("no")
        let translation = app.checkBoxes["caption.voiceMemo.whisper.translateToEnglish"]
        let gpu = app.checkBoxes["caption.voiceMemo.whisper.useGPU"]
        XCTAssertEqual(checkboxState(translation), false)
        translation.click()
        let originalGPU = try XCTUnwrap(checkboxState(gpu))
        gpu.click()
        XCTAssertEqual(checkboxState(gpu), !originalGPU)
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.executionConsent"]), false)
        XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.enable"].isEnabled)
        app.terminate()

        launch(workflow: "caption", folder: fixture.folder, transcriptionProvider: "customWhisper")
        openTranscriptionSettings()
        let restoredLanguage = app.textFields["caption.voiceMemo.whisper.language"]
        XCTAssertTrue(restoredLanguage.waitForExistence(timeout: 15))
        XCTAssertEqual(restoredLanguage.value as? String, "no")
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.translateToEnglish"]), true)
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.useGPU"]), !originalGPU)
        XCTAssertEqual(checkboxState(app.checkBoxes["caption.voiceMemo.whisper.executionConsent"]), false)
        XCTAssertFalse(app.buttons["caption.voiceMemo.whisper.enable"].isEnabled)
        closeTranscriptionSettings()
        XCTAssertTrue((app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"].value as? String)?
            .contains("Approved UI smoke review") == true)
        for (index, file) in protectedFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: file), originalBytes[index], file.lastPathComponent)
        }
    }

    @MainActor
    private func assertCaptionHasNoTranscriptionSetup() {
        for identifier in [
            "caption.voiceMemo.whisper.selectExecutable", "caption.voiceMemo.whisper.selectModel",
            "caption.voiceMemo.whisper.language", "caption.voiceMemo.whisper.translateToEnglish",
            "caption.voiceMemo.whisper.useGPU", "caption.voiceMemo.whisper.executionConsent",
            "caption.voiceMemo.whisper.enable", "caption.voiceMemo.whisper.clear"
        ] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists, identifier)
        }
        XCTAssertTrue(app.buttons["caption.voiceMemo.transcriptionSettings"].exists)
    }

    @MainActor
    private func openTranscriptionSettings() {
        XCTAssertTrue(app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
            .waitForExistence(timeout: 15))
        assertCaptionHasNoTranscriptionSetup()
        app.buttons["caption.voiceMemo.transcriptionSettings"].click()
        XCTAssertTrue(app.staticTexts["Transcription"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["caption.voiceMemo.whisper.enable"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func closeTranscriptionSettings() {
        app.typeKey("w", modifierFlags: .command)
        let settingsClosed = NSPredicate { [self] _, _ in
            !app.buttons["caption.voiceMemo.whisper.enable"].exists
        }
        expectation(for: settingsClosed, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any)["caption.voiceMemo.transcriptDraft"]
            .waitForExistence(timeout: 10))
        assertCaptionHasNoTranscriptionSetup()
    }

    @MainActor
    private func chooseCustomWhisperFile(_ url: URL, button identifier: String) {
        app.buttons[identifier].click()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        let selectedName = app.staticTexts[url.lastPathComponent]
        // The panel itself also shows the filename. Wait for the chooser to close
        // before deciding whether Go to Folder already accepted the selection.
        if !app.buttons[identifier].waitForExistence(timeout: 2)
            || app.buttons["Open"].firstMatch.exists {
            app.typeKey(.return, modifierFlags: [])
        }
        XCTAssertTrue(selectedName.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
    }

    @MainActor
    private func exercisePersistedTranscriptReview(whisper: Bool) throws {
        let fixture = try makeApprovedVoiceMemoFolder(whisper: whisper)
        func evidence() throws -> NSDictionary? {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.sidecarURL)) as? [String: Any]
            return (json?["voiceMemoTranscript"] as? [String: Any])?["whisperProvenance"] as? NSDictionary
        }
        let originalEvidence = try evidence()
        if whisper { XCTAssertNotNil(originalEvidence) }
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
        XCTAssertEqual(try evidence(), originalEvidence)
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
    func testTemplateEditorActionsAndByteConflictRecovery() throws {
        let root = fixtureRoot.appendingPathComponent("Templates", isDirectory: true)
        let developRoot = root.appendingPathComponent("Develop", isDirectory: true)
        try FileManager.default.createDirectory(at: developRoot, withIntermediateDirectories: true)
        let metadataID = UUID().uuidString
        let developID = UUID().uuidString
        let metadataURL = root.appendingPathComponent("\(metadataID).json")
        let developURL = developRoot.appendingPathComponent("\(developID).json")
        let metadataData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "id": metadataID, "name": "Smoke Metadata",
            "templateType": "Full", "fields": [], "processInstantly": false,
        ])
        let developData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "id": developID, "name": "Smoke Develop",
            "settings": ["exposure2012": 0.5], "includesCrop": true,
        ])
        try metadataData.write(to: metadataURL)
        try developData.write(to: developURL)
        launch(workflow: "open-folder", folder: try makePhotoFolder(count: 1), templateRoot: root)
        app.typeKey(",", modifierFlags: .command)
        let templates = app.staticTexts["Templates"].firstMatch
        XCTAssertTrue(templates.waitForExistence(timeout: 10))
        templates.click()

        var preservedMetadataData = metadataData
        var preservedDevelopData = developData
        for (kind, id, name) in [
            ("metadata", metadataID, "Smoke Metadata"),
            ("develop", developID, "Smoke Develop"),
        ] {
            if kind == "develop" {
                let selector = app.radioButtons["Develop"]
                XCTAssertTrue(selector.waitForExistence(timeout: 5))
                selector.click()
            }
            let edit = app.buttons["\(kind)-template-edit-\(id)"]
            let trash = app.buttons["\(kind)-template-trash-\(id)"]
            XCTAssertTrue(edit.waitForExistence(timeout: 10))
            XCTAssertTrue(trash.exists)
            XCTAssertEqual(edit.label, "Edit \(name)")
            XCTAssertEqual(trash.label, "Move \(name) to Trash")
            edit.click()
            let templateName = app.textFields["Template Name"]
            XCTAssertTrue(templateName.waitForExistence(timeout: 5))
            // Do not refocus: typing must reach the editor's initial responder.
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Cancelled draft")
            XCTAssertEqual(templateName.value as? String, "Cancelled draft")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            let editorClosed = NSPredicate { _, _ in !templateName.exists }
            expectation(for: editorClosed, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(try Data(contentsOf: metadataURL), preservedMetadataData)
            XCTAssertEqual(try Data(contentsOf: developURL), preservedDevelopData)

            let templateDirectory = kind == "metadata" ? root : developRoot
            let beforeRecovery = Set(try FileManager.default.contentsOfDirectory(
                at: templateDirectory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" })
            edit.click()
            XCTAssertTrue(templateName.waitForExistence(timeout: 5))
            app.typeKey("a", modifierFlags: .command)
            let recoveredName = "Recovered \(name)"
            app.typeText(recoveredName)
            let peerURL = kind == "metadata" ? metadataURL : developURL
            var peerBytes = try Data(contentsOf: peerURL)
            peerBytes.append(10) // A peer change invisible to the typed template model.
            try peerBytes.write(to: peerURL)
            if kind == "metadata" { preservedMetadataData = peerBytes }
            else { preservedDevelopData = peerBytes }
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(app.buttons["Retry Save"].waitForExistence(timeout: 10))
            XCTAssertEqual(templateName.value as? String, recoveredName)
            XCTAssertEqual(try Data(contentsOf: peerURL), peerBytes)
            app.buttons["Save as New"].click()
            expectation(for: editorClosed, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(try Data(contentsOf: peerURL), peerBytes)
            let documents = try FileManager.default.contentsOfDirectory(
                at: templateDirectory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            XCTAssertEqual(documents.count, beforeRecovery.count + 1)
            let copy = try XCTUnwrap(documents.first { !beforeRecovery.contains($0) })
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
            XCTAssertEqual(saved["name"] as? String, recoveredName)
            XCTAssertNotEqual(saved["id"] as? String, id)
        }
    }

    @MainActor
    func testTemplateImportRefusesChangedPreviewAndAllowsFreshConfirmation() throws {
        let root = fixtureRoot.appendingPathComponent("ImportTemplates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let destination = root.appendingPathComponent("\(id).json")
        var template: [String: Any] = [
            "schemaVersion": 1, "id": id, "name": "Original Import Template",
            "templateType": "Full", "fields": [], "processInstantly": false,
        ]
        let original = try JSONSerialization.data(withJSONObject: template)
        try original.write(to: destination)
        template["name"] = "Imported Replacement"
        let bundle = fixtureRoot.appendingPathComponent("ImportBundle.json")
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "exportedAt": "2026-09-20T12:00:00Z", "templates": [template],
        ]).write(to: bundle)
        launch(workflow: "open-folder", folder: try makePhotoFolder(count: 1), templateRoot: root)
        app.typeKey(",", modifierFlags: .command)
        let templates = app.staticTexts["Templates"].firstMatch
        XCTAssertTrue(templates.waitForExistence(timeout: 10))
        templates.click()

        func openPreview() {
            let importButton = app.buttons["Import…"]
            XCTAssertTrue(importButton.waitForExistence(timeout: 10))
            importButton.click()
            app.typeKey("g", modifierFlags: [.command, .shift])
            // Go to Folder focuses its path editor, whose accessibility type
            // differs across supported macOS releases. Use its native keyboard flow.
            app.typeKey("a", modifierFlags: .command)
            app.typeText(bundle.path)
            app.typeKey(.return, modifierFlags: [])
            let previewTitle = app.staticTexts["Import Templates"]
            // Revisiting the already-selected file may accept the picker immediately.
            // Only activate Open if we have not reached the confirmation yet, so an
            // extra Return cannot accidentally confirm an already-present preview.
            if !previewTitle.waitForExistence(timeout: 2) {
                app.typeKey(.return, modifierFlags: [])
            }
            XCTAssertTrue(previewTitle.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["1 will overwrite existing templates"].exists)
        }

        openPreview()
        var peerBytes = original
        peerBytes.append(10)
        try peerBytes.write(to: destination)
        app.buttons["Import"].click()
        let conflict = app.staticTexts[
            "The template folder changed or contains an ambiguous import target. Preview the bundle again before importing."
        ]
        XCTAssertTrue(conflict.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(try Data(contentsOf: destination), peerBytes)
        XCTAssertFalse(app.buttons["metadata-template-edit-\(id)"].label.contains("Imported Replacement"))

        openPreview()
        app.buttons["Import"].click()
        let imported = app.buttons["metadata-template-edit-\(id)"]
        let replacementAppears = NSPredicate { _, _ in imported.label == "Edit Imported Replacement" }
        expectation(for: replacementAppears, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
        XCTAssertEqual(saved["name"] as? String, "Imported Replacement")
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
        localeIdentifier: String? = nil,
        transcriptionProvider: String = "appleSpeech",
        patchReviewFolder: URL? = nil,
        operationRecovery: Bool = false,
        xmpStagingInterruption: Bool = false,
        xmpPublicationInterruption: Bool = false,
        existingRecoveryCarriers: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--ui-testing",
            "--ui-test-workflow", workflow,
            "--ui-test-whisper-defaults-suite", fixtureRoot.lastPathComponent,
            "--ui-test-whisper-model-root", fixtureRoot.appendingPathComponent("WhisperModels").path,
            "-voiceMemo.transcriptionProvider", transcriptionProvider,
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
        append("--ui-test-patch-review-folder", patchReviewFolder)
        if operationRecovery { app.launchArguments.append("--ui-test-operation-recovery") }
        if xmpStagingInterruption { app.launchArguments.append("--ui-test-xmp-staging-interruption") }
        if xmpPublicationInterruption { app.launchArguments.append("--ui-test-xmp-publication-interruption") }
        if existingRecoveryCarriers { app.launchArguments.append("--ui-test-existing-recovery-carriers") }
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

    private func makeApprovedVoiceMemoFolder(includePendingMetadata: Bool = false, whisper: Bool = false) throws -> VoiceMemoFixture {
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
        if whisper {
            var transcript = sidecar["voiceMemoTranscript"] as! [String: Any]
            transcript["provider"] = "FFmpeg Whisper"
            transcript["providerModel"] = "synthetic-ui-model"
            transcript["localeIdentifier"] = "en"
            transcript["whisperProvenance"] = [
                "schemaVersion": 1, "buildIdentifier": "synthetic-ui-build",
                "executableSHA256": String(repeating: "a", count: 64), "executableByteCount": 10,
                "modelIdentifier": "synthetic-ui-model",
                "modelSHA256": String(repeating: "b", count: 64), "modelByteCount": 20,
                "requestedLanguage": "en", "useGPU": false, "translate": false,
                "segments": [["start": 0, "end": 100, "text": " Generated UI smoke transcript "]],
            ] as [String: Any]
            sidecar["voiceMemoTranscript"] = transcript
        }
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
    private func checkboxState(_ element: XCUIElement) -> Bool? {
        // AppKit exposes AXValue as NSNumber on some macOS releases and as text
        // on others. Unknown/mixed/missing values remain nil so an off check fails.
        let value = element.value
        if let number = value as? NSNumber {
            if number == NSNumber(value: 0) { return false }
            if number == NSNumber(value: 1) { return true }
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "0", "false": return false
            case "1", "true": return true
            default: break
            }
        }
        return nil
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
