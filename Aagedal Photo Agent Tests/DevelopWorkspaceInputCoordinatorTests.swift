import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop workspace input coordinator")
@MainActor
struct DevelopWorkspaceInputCoordinatorTests {
    private final class Token {
        let name: String

        init(_ name: String) {
            self.name = name
        }
    }

    @Test("inactive monitor installation is removed immediately")
    func inactiveInstallation() {
        let coordinator = DevelopWorkspaceInputCoordinator()
        let token = Token("inactive")
        var removed: [String] = []

        coordinator.installKeyMonitor(token) { removed.append(($0 as! Token).name) }

        #expect(removed == ["inactive"])
        #expect(!coordinator.hasKeyMonitor)
    }

    @Test("replacing one monitor removes only the previous registration")
    func replacement() {
        let coordinator = DevelopWorkspaceInputCoordinator()
        var removed: [String] = []
        coordinator.beginWorkspace()

        coordinator.installScrollMonitor(Token("first")) {
            removed.append(($0 as! Token).name)
        }
        coordinator.installScrollMonitor(Token("second")) {
            removed.append(($0 as! Token).name)
        }

        #expect(removed == ["first"])
        #expect(coordinator.hasScrollMonitor)
        #expect(!coordinator.hasKeyMonitor)
        coordinator.removeScrollMonitor()
        #expect(removed == ["first", "second"])
        #expect(!coordinator.hasScrollMonitor)
    }

    @Test("workspace teardown removes every monitor and transient input value")
    func workspaceTeardown() {
        let coordinator = DevelopWorkspaceInputCoordinator()
        var removed: [String] = []
        let remover: DevelopWorkspaceInputCoordinator.MonitorRemoval = {
            removed.append(($0 as! Token).name)
        }
        let hovered = URL(fileURLWithPath: "/tmp/develop-input-hovered.raw")
        let target = URL(fileURLWithPath: "/tmp/develop-input-target.raw")

        coordinator.beginWorkspace()
        coordinator.installScrollMonitor(Token("scroll"), remove: remover)
        coordinator.installKeyMonitor(Token("key"), remove: remover)
        coordinator.installMiddleMouseMonitor(Token("middle"), remove: remover)
        coordinator.isCursorOverPreview = true
        coordinator.hoveredFilmstripURL = hovered
        coordinator.isSpaceHandToolActive = true
        coordinator.filmstripKeyboardScrollTarget = target

        coordinator.endWorkspace()

        #expect(Set(removed) == ["scroll", "key", "middle"])
        #expect(!coordinator.isWorkspaceActive)
        #expect(!coordinator.hasScrollMonitor)
        #expect(!coordinator.hasKeyMonitor)
        #expect(!coordinator.hasMiddleMouseMonitor)
        #expect(!coordinator.isCursorOverPreview)
        #expect(coordinator.hoveredFilmstripURL == nil)
        #expect(!coordinator.isSpaceHandToolActive)
        #expect(coordinator.filmstripKeyboardScrollTarget == nil)
    }

    @Test("repeated begin cleans interrupted presentation registrations")
    func repeatedBegin() {
        let coordinator = DevelopWorkspaceInputCoordinator()
        var removalCount = 0

        coordinator.beginWorkspace()
        coordinator.installKeyMonitor(Token("key")) { _ in removalCount += 1 }
        coordinator.isSpaceHandToolActive = true
        coordinator.beginWorkspace()

        #expect(removalCount == 1)
        #expect(coordinator.isWorkspaceActive)
        #expect(!coordinator.hasKeyMonitor)
        #expect(!coordinator.isSpaceHandToolActive)
    }

    @Test("edit workspace delegates monitor and transient input ownership")
    func sourceContract() throws {
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
            "@State private var workspaceInput = DevelopWorkspaceInputCoordinator()"
        ))
        #expect(source.contains("workspaceInput.beginWorkspace()"))
        #expect(source.contains("workspaceInput.endWorkspace()"))
        #expect(source.contains("workspaceInput.installScrollMonitor("))
        #expect(source.contains("workspaceInput.installKeyMonitor("))
        #expect(source.contains("workspaceInput.installMiddleMouseMonitor("))
        #expect(!source.contains("@State private var scrollEventMonitor"))
        #expect(!source.contains("@State private var keyEventMonitor"))
        #expect(!source.contains("@State private var middleMouseEventMonitor"))
        #expect(!source.contains("@State private var isSpaceHandToolActive"))
        #expect(!source.contains("@State private var hoveredFilmstripURL"))
    }
}

@Suite("Develop workspace session coordinator")
@MainActor
struct DevelopWorkspaceSessionCoordinatorTests {
    @Test("workspace lifetime owns the external named-version flush registration")
    func flushRegistrationLifetime() async {
        let flushCoordinator = DevelopVersionFlushCoordinator()
        let coordinator = DevelopWorkspaceSessionCoordinator()
        var reasons: [DevelopVersionFlushReason] = []

        coordinator.beginWorkspace(flushCoordinator: flushCoordinator) { reason in
            reasons.append(reason)
            return .succeeded
        }

        #expect(coordinator.isWorkspaceActive)
        #expect(flushCoordinator.hasRegisteredHandler)
        #expect(await flushCoordinator.flush(.applicationTermination) == .succeeded)
        #expect(reasons == [.applicationTermination])

        coordinator.endWorkspace()

        #expect(!coordinator.isWorkspaceActive)
        #expect(!flushCoordinator.hasRegisteredHandler)
        #expect(await flushCoordinator.flush(.workspaceExit) == .succeeded)
        #expect(reasons == [.applicationTermination])
    }

    @Test("a replacement notice cannot be cleared by the superseded timer")
    func replacementNoticeOwnsTimer() async throws {
        let coordinator = DevelopWorkspaceSessionCoordinator(
            noticeDuration: .milliseconds(60)
        )
        coordinator.beginWorkspace(
            flushCoordinator: DevelopVersionFlushCoordinator()
        ) { _ in .succeeded }

        coordinator.showNotice("Copied")
        try await Task.sleep(for: .milliseconds(35))
        coordinator.showNotice("Pasted")
        try await Task.sleep(for: .milliseconds(35))

        #expect(coordinator.notice == "Pasted")

        try await Task.sleep(for: .milliseconds(40))
        #expect(coordinator.notice == nil)
    }

    @Test("workspace teardown clears a notice and rejects its late timer")
    func teardownRejectsLateNoticeTimer() async throws {
        let coordinator = DevelopWorkspaceSessionCoordinator(
            noticeDuration: .milliseconds(30)
        )
        coordinator.beginWorkspace(
            flushCoordinator: DevelopVersionFlushCoordinator()
        ) { _ in .succeeded }
        coordinator.showNotice("Copied")

        coordinator.endWorkspace()
        try await Task.sleep(for: .milliseconds(50))

        #expect(coordinator.notice == nil)
        #expect(!coordinator.isWorkspaceActive)
    }

    @Test("repeated appearance replaces the complete workspace session")
    func repeatedBeginReplacesSession() async {
        let firstFlushCoordinator = DevelopVersionFlushCoordinator()
        let secondFlushCoordinator = DevelopVersionFlushCoordinator()
        let coordinator = DevelopWorkspaceSessionCoordinator()
        var firstCalls = 0
        var secondCalls = 0

        coordinator.beginWorkspace(flushCoordinator: firstFlushCoordinator) { _ in
            firstCalls += 1
            return .succeeded
        }
        coordinator.showNotice("Old")
        coordinator.beginWorkspace(flushCoordinator: secondFlushCoordinator) { _ in
            secondCalls += 1
            return .succeeded
        }

        #expect(!firstFlushCoordinator.hasRegisteredHandler)
        #expect(secondFlushCoordinator.hasRegisteredHandler)
        #expect(coordinator.notice == nil)
        #expect(await firstFlushCoordinator.flush(.applicationTermination) == .succeeded)
        #expect(await secondFlushCoordinator.flush(.applicationTermination) == .succeeded)
        #expect(firstCalls == 0)
        #expect(secondCalls == 1)
    }

    @Test("edit workspace delegates session notices and flush registration")
    func sourceContract() throws {
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
            "@State private var workspaceSession = DevelopWorkspaceSessionCoordinator()"
        ))
        #expect(source.contains("workspaceSession.beginWorkspace("))
        #expect(source.contains("workspaceSession.endWorkspace()"))
        #expect(source.contains("workspaceSession.showNotice(message)"))
        #expect(!source.contains("@State private var copyPasteFeedback"))
        #expect(!source.contains("@State private var developVersionFlushRegistrationID"))
    }
}
