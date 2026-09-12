import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Known People shared interchange controller")
@MainActor
struct KnownPeopleInterchangeControllerTests {
    private func prompt(relationship: KnownPeopleInterchangeImportPrompt.Relationship = .untracked,
                        count: Int = 1) -> KnownPeopleInterchangeImportPrompt {
        .init(token: .init(), sourceURL: URL(fileURLWithPath: "/private/tmp/input.aagedalpeople"),
              libraryID: UUID(), relationship: relationship, peopleCount: count, embeddingCount: count)
    }

    @Test("One shared presenter state holds exact import prompt until explicit confirmation",
          arguments: ["same", "different", "untracked", "empty"])
    func explicitConfirmation(kind: String) async throws {
        let operations = ScriptedInterchangeOperations()
        let value = prompt(relationship: kind == "same" ? .sameLibrary : kind == "different" ? .differentLibrary : .untracked,
                           count: kind == "empty" ? 0 : 1)
        operations.preparation = .ready(value)
        let controller = KnownPeopleInterchangeController(operations: operations), a = UUID(), b = UUID()
        let request = try #require(controller.beginImport(at: value.sourceURL, presenterID: a))
        #expect(controller.isBusy)
        #expect(controller.beginImport(at: value.sourceURL, presenterID: b) == nil)
        await controller.waitForCurrentRequest()
        let pending = try #require(controller.pendingImport)
        #expect(pending.id == request && pending.presenterID == a && pending.prompt.token == value.token)
        #expect(pending.prompt.replacesWithEmptyLibrary == (kind == "empty"))
        #expect(controller.isBusy && operations.committed.isEmpty)
        #expect(controller.confirmImport(promptID: pending.id, presenterID: b) == nil)
        #expect(controller.beginExport(to: value.sourceURL, format: .directory, overwrite: false, presenterID: b) == nil)
        #expect(controller.confirmImport(promptID: pending.id, presenterID: a) != nil)
        await controller.waitForCurrentRequest()
        #expect(operations.committed == [value.token])
        #expect(!controller.isBusy && controller.pendingImport == nil)
        #expect(controller.notice(for: a)?.kind == .success && controller.notice(for: b) == nil)
    }

    @Test("Explicit prompt cancellation discards only that retained token")
    func discardPending() async throws {
        let operations = ScriptedInterchangeOperations(), value = prompt(), presenter = UUID()
        operations.preparation = .ready(value)
        let controller = KnownPeopleInterchangeController(operations: operations)
        _ = controller.beginImport(at: value.sourceURL, presenterID: presenter)
        await controller.waitForCurrentRequest()
        let pending = try #require(controller.pendingImport)
        controller.cancelPendingImport(promptID: UUID(), presenterID: presenter)
        #expect(controller.isBusy && operations.discarded.isEmpty)
        controller.cancelPendingImport(promptID: pending.id, presenterID: presenter)
        #expect(!controller.isBusy && operations.discarded == [value.token] && operations.committed.isEmpty)
    }

    @Test("Cancellation keeps global busy until cleanup returns and discards a late prepared token")
    func cancelWhilePreparing() async throws {
        let operations = ScriptedInterchangeOperations(), value = prompt(), presenter = UUID()
        let gate = InterchangeTestGate()
        operations.prepareBody = { await gate.wait(); return .ready(value) }
        let controller = KnownPeopleInterchangeController(operations: operations)
        _ = controller.beginImport(at: value.sourceURL, presenterID: presenter)
        await gate.waitForEntry()
        controller.cancelActiveRequest()
        #expect(controller.isBusy && controller.activeRequest?.cancellationRequested == true)
        #expect(controller.beginImport(at: value.sourceURL, presenterID: UUID()) == nil)
        gate.release()
        await controller.waitForCurrentRequest()
        #expect(!controller.isBusy && controller.pendingImport == nil)
        #expect(operations.discarded == [value.token])
        #expect(controller.notice(for: presenter)?.kind == .cancelled)
    }

    @Test("A cancelled committed import remains a warning with exact recovery evidence")
    func committedCancellation() async throws {
        let operations = ScriptedInterchangeOperations(), value = prompt(), presenter = UUID()
        let recovery = URL(fileURLWithPath: "/private/tmp/retained-old-root")
        operations.preparation = .ready(value)
        let gate = InterchangeTestGate()
        operations.commitBody = { _ in
            await gate.wait()
            return .committed(.init(committed: true, verified: false, wasCancelled: true,
                                    detail: "Installed readback did not finish", recoveryURLs: [recovery]))
        }
        let controller = KnownPeopleInterchangeController(operations: operations)
        _ = controller.beginImport(at: value.sourceURL, presenterID: presenter)
        await controller.waitForCurrentRequest()
        _ = controller.confirmImport(promptID: try #require(controller.pendingImport).id, presenterID: presenter)
        await gate.waitForEntry(); controller.cancelActiveRequest()
        #expect(controller.isBusy)
        gate.release(); await controller.waitForCurrentRequest()
        #expect(controller.notice(for: presenter)?.kind == .warning)
        #expect(controller.notice(for: presenter)?.recoveryURLs == [recovery])
    }

    @Test("Notices are presenter-scoped and a delayed dismissal cannot clear a newer notice")
    func scopedNoticesAndStaleDismissal() async throws {
        let operations = ScriptedInterchangeOperations(), controller = KnownPeopleInterchangeController(operations: operations)
        let a = UUID(), b = UUID(), destination = URL(fileURLWithPath: "/private/tmp/output.aagedalpeople")
        operations.exportOutcome = .failed(.init(.exportWriteFailed, detail: "first"))
        _ = controller.beginExport(to: destination, format: .directory, overwrite: false, presenterID: a)
        await controller.waitForCurrentRequest()
        let first = try #require(controller.notice(for: a))
        operations.exportOutcome = .requiresDirectory(.init(.zipRequiresDirectory))
        _ = controller.beginExport(to: destination, format: .zip, overwrite: false, presenterID: a)
        await controller.waitForCurrentRequest()
        let newer = try #require(controller.notice(for: a))
        controller.dismissNotice(id: first.id, presenterID: a)
        controller.dismissNotice(id: newer.id, presenterID: b)
        #expect(controller.notice(for: a)?.id == newer.id && controller.notice(for: b) == nil)
        #expect(newer.kind == .guidance)
        controller.dismissNotice(id: newer.id, presenterID: a)
        #expect(controller.notice(for: a) == nil)
    }

    @Test("Export failures still disclose a nested identity commit and its recovery directory")
    func identityCommitOnExportFailure() async throws {
        let operations = ScriptedInterchangeOperations(), presenter = UUID()
        let recovery = URL(fileURLWithPath: "/private/tmp/identity-backup")
        let identity = KnownPeopleInterchangeCommitEvidence(committed: true, verified: false, wasCancelled: false,
                                                           detail: "Identity readback uncertain", recoveryURLs: [recovery])
        operations.exportOutcome = .failed(.init(.exportPreparationFailed, detail: "No final capture", identityAssignment: identity))
        let controller = KnownPeopleInterchangeController(operations: operations)
        _ = controller.beginExport(to: URL(fileURLWithPath: "/private/tmp/selected.aagedalpeople"), format: .directory,
                                   overwrite: false, presenterID: presenter)
        await controller.waitForCurrentRequest()
        let notice = try #require(controller.notice(for: presenter))
        #expect(notice.kind == .warning && notice.identityAssignment?.committed == true)
        #expect(notice.recoveryURLs == [recovery])
    }

    @Test("Typed availability prevents starting work without inspecting detail strings")
    func availability() {
        let operations = ScriptedInterchangeOperations(), presenter = UUID()
        operations.availability = .unavailable(.routing)
        let controller = KnownPeopleInterchangeController(operations: operations)
        #expect(controller.beginImport(at: URL(fileURLWithPath: "/private/tmp/input"), presenterID: presenter) == nil)
        #expect(!controller.isBusy && operations.preparedCount == 0)
        #expect(controller.notice(for: presenter)?.kind == .guidance)
    }
}

@MainActor
private final class ScriptedInterchangeOperations: KnownPeopleInterchangeOperating {
    var availability: KnownPeopleInterchangeAvailability = .available
    var preparation: KnownPeopleInterchangeImportPreparation = .failed(.init(.admissionFailed))
    var prepareBody: (() async -> KnownPeopleInterchangeImportPreparation)?
    var commitBody: ((KnownPeopleInterchangeImportToken) async -> KnownPeopleInterchangeImportCommitOutcome)?
    var exportOutcome: KnownPeopleInterchangeExportOutcome = .failed(.init(.exportWriteFailed))
    var preparedCount = 0
    var committed: [KnownPeopleInterchangeImportToken] = []
    var discarded: [KnownPeopleInterchangeImportToken] = []
    func prepareImport(at sourceURL: URL) async -> KnownPeopleInterchangeImportPreparation {
        preparedCount += 1
        if let prepareBody { return await prepareBody() }
        return preparation
    }
    func commitImport(_ token: KnownPeopleInterchangeImportToken) async -> KnownPeopleInterchangeImportCommitOutcome {
        committed.append(token)
        if let commitBody { return await commitBody(token) }
        return .committed(.init(committed: true, verified: true, wasCancelled: false, detail: nil, recoveryURLs: []))
    }
    func discardImport(_ token: KnownPeopleInterchangeImportToken) { discarded.append(token) }
    func export(to destinationURL: URL, format: KnownPeopleInterchangeFormat, overwrite: Bool) async -> KnownPeopleInterchangeExportOutcome { exportOutcome }
}

@MainActor
private final class InterchangeTestGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var entryWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
