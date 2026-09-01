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
