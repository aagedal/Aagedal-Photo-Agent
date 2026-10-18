import SwiftUI
import Testing
import AppKit
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("Full-screen culling shortcuts")
struct FullScreenShortcutTests {
    private static let numberKeyCodes = [
        29, // 0
        18, // 1
        19, // 2
        20, // 3
        21, // 4
        23, // 5
        22, // 6
        26, // 7
        28, // 8
        25, // 9
    ]

    @Test("Bare digits map 0–5 to ratings and 6–9 to color labels")
    func bareDigitMappings() {
        for (number, keyCode) in Self.numberKeyCodes.enumerated() {
            let expected: FullScreenNumberShortcut = number <= 5
                ? .rating(number)
                : .colorLabel(number - 5)

            #expect(
                FullScreenNumberShortcut.resolve(
                    keyCode: keyCode,
                    command: false,
                    option: false
                ) == expected
            )
        }
    }

    @Test("Command digit mappings retain the menu shortcuts")
    func modifiedDigitMappings() {
        for (number, keyCode) in Self.numberKeyCodes.enumerated() {
            let rating = FullScreenNumberShortcut.resolve(
                keyCode: keyCode,
                command: true,
                option: false
            )
            #expect(rating == (number <= 5 ? .rating(number) : nil))

            let label = FullScreenNumberShortcut.resolve(
                keyCode: keyCode,
                command: true,
                option: true
            )
            #expect(label == (number <= 8 ? .colorLabel(number) : nil))
        }
    }

    @Test("Option-only digits are not intercepted")
    func optionOnlyDigitsAreIgnored() {
        for keyCode in Self.numberKeyCodes {
            #expect(
                FullScreenNumberShortcut.resolve(
                    keyCode: keyCode,
                    command: false,
                    option: true
                ) == nil
            )
        }
    }

    @Test("Rating stars and color-label choices remain semantic buttons")
    func accessibleRatingAndLabelControls() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/FullScreenImageView.swift"
            ),
            encoding: .utf8
        )

        let ratingOverlay = try #require(source.slice(
            from: "private func starRatingOverlay",
            through: "// MARK: - Presenter"
        ))
        #expect(ratingOverlay.contains("ForEach(1...5"))
        #expect(ratingOverlay.contains("Button {"))
        #expect(!ratingOverlay.contains(".onTapGesture"))
        #expect(ratingOverlay.contains(".accessibilityLabel(\"\\(star) star rating\")"))
        #expect(ratingOverlay.contains(".accessibilityValue("))
        #expect(ratingOverlay.contains(".accessibilityIdentifier(\"fullScreen.rating.\\(star)\")"))

        let labelOverlay = try #require(source.slice(
            from: "private func colorLabelOverlay",
            through: "private func starRatingOverlay"
        ))
        #expect(labelOverlay.contains("ForEach(ColorLabel.allCases"))
        #expect(labelOverlay.contains("Button {"))
        #expect(labelOverlay.contains(".accessibilityLabel(\"\\(label.displayName) color label\")"))
        #expect(labelOverlay.contains(".accessibilityValue("))
        #expect(labelOverlay.contains(".accessibilityIdentifier(\"fullScreen.colorLabel.\\(label.rawValue)\")"))
        #expect(labelOverlay.contains("picker \\(showLabelPicker ? \"expanded\" : \"collapsed\")"))
    }
}

private extension String {
    func slice(from startMarker: String, through endMarker: String) -> String? {
        guard let start = range(of: startMarker),
              let end = range(of: endMarker, range: start.upperBound..<endIndex) else {
            return nil
        }
        return String(self[start.lowerBound..<end.lowerBound])
    }
}

@Suite("Full-screen loading recovery")
struct FullScreenLoadingRecoveryTests {
    @Test("High-resolution speed guidance appears only for edited previews")
    func editedPreviewGuidance() {
        #expect(
            FullScreenLoadingGuidance.message(
                isRenderingEdits: true,
                hasEdits: true
            ) == "Edited previews can take longer. Press E to turn off edits when faster high-resolution loading matters."
        )
        #expect(
            FullScreenLoadingGuidance.message(
                isRenderingEdits: false,
                hasEdits: true
            ) == nil
        )
        #expect(
            FullScreenLoadingGuidance.message(
                isRenderingEdits: true,
                hasEdits: false
            ) == nil
        )
    }

    @Test("Failure details identify the file, path, and preview mode")
    func failureDetails() {
        let url = URL(fileURLWithPath: "/Volumes/Archive/News Photos/frame 001.tiff")

        let editedFailure = FullScreenLoadFailure(url: url, isRenderingEdits: true)
        #expect(editedFailure.message == "Unable to load this image at high resolution.")
        #expect(editedFailure.details.contains("File: frame 001.tiff"))
        #expect(editedFailure.details.contains("Path: /Volumes/Archive/News Photos/frame 001.tiff"))
        #expect(editedFailure.details.contains("Preview mode: Edited"))

        let originalFailure = FullScreenLoadFailure(url: url, isRenderingEdits: false)
        #expect(originalFailure.details.contains("Preview mode: Original"))
    }
}

@Suite("Profile-derived rating and label menu shortcuts")
struct ProfileMenuShortcutTests {
    @Test("Built-in menus follow profile Command chords and leave bare typing to the browser")
    func builtInMenus() {
        let photoAgent = KeyboardShortcutProfiles.profile(for: .photoAgent)
        #expect(photoAgent.menuChord(for: .rating(1)) == nil)
        #expect(photoAgent.menuChord(for: .colorLabel(1)) == .init(key: "1", modifiers: .command))
        #expect(photoAgent.menuChord(for: .colorLabel(0)) == .init(key: "0", modifiers: .command))
        #expect(photoAgent.command(for: .init(key: "s")) == .labelRed)

        let bridge = KeyboardShortcutProfiles.profile(for: .bridgeLike)
        #expect(bridge.menuChord(for: .rating(1)) == .init(key: "1", modifiers: .command))
        #expect(bridge.menuChord(for: .colorLabel(1)) == .init(key: "1", modifiers: [.command, .option]))
        let photoMechanic = KeyboardShortcutProfiles.profile(for: .photoMechanicLike)
        #expect(photoMechanic.menuChord(for: .rating(1)) == nil)
        #expect(photoMechanic.menuChord(for: .colorLabel(1)) == .init(key: "1", modifiers: .command))
    }

    @Test("Ambiguous, bare and non-Command chords cannot become native menu equivalents")
    func unsafeMenuChords() {
        let commandOne = KeyboardShortcutChord(key: "1", modifiers: .command)
        let profile = KeyboardShortcutProfile(name: "Conflict", bindings: [
            .init(command: .rateOne, chord: .init(key: "1")),
            .init(command: .labelRed, chord: .init(key: "r", modifiers: .option)),
            .init(command: .rateOne, chord: commandOne),
            .init(command: .labelRed, chord: commandOne),
        ])
        #expect(profile.menuChord(for: .rating(1)) == nil)
        #expect(profile.menuChord(for: .colorLabel(1)) == nil)
    }

    @MainActor
    @Test("Menus reflect edited, removed and switched profile bindings without fixed defaults")
    func editedMenuChords() throws {
        let suite = "ProfileMenuShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = KeyboardShortcutProfileRegistry(defaults: defaults)
        let commandOne = KeyboardShortcutChord(key: "1", modifiers: .command)
        #expect(registry.selectedProfile.menuChord(for: .colorLabel(1)) == commandOne)
        #expect(registry.reassign(commandOne, to: .rateOne, replacingConflicts: true))
        #expect(registry.selectedProfile.menuChord(for: .rating(1)) == commandOne)
        #expect(registry.selectedProfile.menuChord(for: .colorLabel(1)) == nil)
        registry.remove(commandOne, from: .rateOne)
        #expect(registry.selectedProfile.menuChord(for: .rating(1)) == nil)
        registry.select(.bridgeLike)
        #expect(registry.selectedProfile.menuChord(for: .rating(1)) == commandOne)
        #expect(registry.selectedProfile.menuChord(for: .colorLabel(1)) == .init(
            key: "1", modifiers: [.command, .option]))
    }
}


@Suite("Develop keyboard window ownership")
@MainActor
struct DevelopKeyboardWindowOwnershipTests {
    @Test("Only the retained owning key window may drive Develop shortcuts")
    func keyWindowOwnership() {
        let reference = DevelopKeyboardWindowReference()
        let owner = KeyboardOwnershipWindow(contentRect: .zero, styleMask: .borderless,
                                             backing: .buffered, defer: true)
        let settings = KeyboardOwnershipWindow(contentRect: .zero, styleMask: .borderless,
                                                backing: .buffered, defer: true)
        #expect(!reference.ownsKeyEvent(in: nil))
        #expect(!reference.ownsKeyEvent(in: owner))
        reference.window = owner
        #expect(reference.ownsKeyEvent(in: owner))
        #expect(!reference.ownsKeyEvent(in: settings))
        #expect(!reference.ownsKeyEvent(in: nil))
        owner.simulatedKeyWindow = false
        #expect(!reference.ownsKeyEvent(in: owner))
    }


}

@MainActor
private final class KeyboardOwnershipWindow: NSWindow {
    var simulatedKeyWindow = true
    override var isKeyWindow: Bool { simulatedKeyWindow }
}

@Suite("Native shortcut event normalization")
@MainActor
struct NativeShortcutEventNormalizationTests {
    @Test("Shifted numeric events retain their logical key and separate modifiers")
    func shiftedNumber() throws {
        let seed = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 25))
        let base = try #require(seed.characters(byApplyingModifiers: []))
        let shifted = try #require(seed.characters(byApplyingModifiers: .shift))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: shifted, charactersIgnoringModifiers: shifted, isARepeat: false, keyCode: 25))
        let chord = try #require(KeyboardShortcutChord(event: event))
        #expect(chord == .init(key: base, modifiers: [.command, .shift]))
    }

    @Test("Forward and backward Delete retain distinct native menu equivalents")
    func forwardDelete() {
        let forward = KeyboardShortcutChord(key: "\u{f728}", modifiers: [.control, .option])
        let backward = KeyboardShortcutChord(key: "\u{7f}", modifiers: [.control, .option])
        #expect(forward != backward)
        #expect(forward.key == "forwarddelete")
        #expect(backward.key == "delete")
        #expect(forward.swiftUIShortcut?.key == .deleteForward)
        #expect(backward.swiftUIShortcut?.key == .delete)
    }
}

@Suite("Isolated native menu shortcut matching")
@MainActor
struct NativeMenuShortcutMatchingTests {
    @Test("Command-letter profile equivalents invoke their isolated menu action")
    func commandLetter() throws {
        try assertSingleMenuInvocation(chord: .init(key: "l", modifiers: .command),
                                       keyCode: 37)
    }

    @Test("Shift-Command-letter equivalents retain native menu behavior")
    func shiftedLetter() throws {
        try assertSingleMenuInvocation(chord: .init(key: "l", modifiers: [.command, .shift]),
                                       keyCode: 37)
    }

    @Test("Logical Shift-Command-number equivalents match shifted event characters")
    func shiftedNumberMenuEquivalent() throws {
        // Retranslation uses the current input source: Shift-9 is '(' on US,
        // but ')' on Norwegian. Do not construct an impossible mixed-layout event.
        let seed = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 25))
        let base = try #require(seed.characters(byApplyingModifiers: []))
        try assertSingleMenuInvocation(chord: .init(key: base, modifiers: [.command, .shift]),
                                       keyCode: 25)
    }

    @Test("Forward Delete profile equivalents invoke a distinct native menu action")
    func forwardDeleteMenuEquivalent() throws {
        try assertSingleMenuInvocation(chord: .init(key: "forwarddelete", modifiers: [.control, .option]),
                                       keyCode: 117)
    }

    private func assertSingleMenuInvocation(chord: KeyboardShortcutChord,
                                            keyCode: UInt16) throws {
        let shortcut = try #require(chord.swiftUIShortcut)
        let target = IsolatedShortcutMenuTarget()
        let menu = NSHostingMenu(rootView: Button("Count invocation") {
            target.invoke(nil)
        }.keyboardShortcut(shortcut))
        menu.update()
        #expect(menu.items.count == 1)
        // CGEvent-backed NSEvents populate both character fields as macOS does.
        // With Command+Shift, characters can be lowercase/base while
        // charactersIgnoringModifiers retains Shift. No input is posted.
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        cgEvent.flags = flags
        let event = try #require(NSEvent(cgEvent: cgEvent))
        #expect(KeyboardShortcutChord(event: event) == chord)

        #expect(target.invocationCount == 0)
        #expect(menu.performKeyEquivalent(with: event))
        #expect(target.invocationCount == 1)
    }
}

@MainActor
private final class IsolatedShortcutMenuTarget: NSObject {
    private(set) var invocationCount = 0

    @objc func invoke(_ sender: Any?) {
        invocationCount += 1
    }
}

@Suite("Workspace event window ownership")
@MainActor
struct WorkspaceEventWindowOwnershipTests {
    @Test("Workspace owns only its current key window, excluding Settings and unrelated workspaces")
    func windowOwnership() {
        let reference = WorkspaceEventWindowReference()
        let owner = makeWindow()
        let settings = makeWindow()
        let unrelated = makeWindow()
        #expect(!reference.ownsEvent(in: nil, modalWindow: nil))
        #expect(!reference.ownsEvent(in: owner, modalWindow: nil))
        reference.window = owner
        #expect(reference.ownsEvent(in: owner, modalWindow: nil))
        #expect(!reference.ownsEvent(in: settings, modalWindow: nil))
        #expect(!reference.ownsEvent(in: unrelated, modalWindow: nil))
        owner.simulatedKeyWindow = false
        #expect(!reference.ownsEvent(in: owner, modalWindow: nil))
    }

    @Test("Modal panels, attached sheets and sheet-owned workspaces retain their key events")
    func sheetAndModalOwnership() {
        let reference = WorkspaceEventWindowReference()
        let owner = makeWindow()
        let sheet = makeWindow()
        reference.window = owner
        #expect(reference.ownsEvent(in: owner, modalWindow: nil))
        #expect(!reference.ownsEvent(in: owner, modalWindow: sheet))
        owner.simulatedAttachedSheet = sheet
        #expect(!reference.ownsEvent(in: owner, modalWindow: nil))
        #expect(!reference.ownsEvent(in: sheet, modalWindow: nil))
        owner.simulatedAttachedSheet = nil
        owner.simulatedSheetParent = sheet
        #expect(!reference.ownsEvent(in: owner, modalWindow: nil))
        owner.simulatedSheetParent = nil
        #expect(reference.ownsEvent(in: owner, modalWindow: nil))
    }

    private func makeWindow() -> CaptionOwnershipTestWindow {
        CaptionOwnershipTestWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
    }
}

@MainActor
private final class CaptionOwnershipTestWindow: NSWindow {
    var simulatedKeyWindow = true
    var simulatedAttachedSheet: NSWindow?
    var simulatedSheetParent: NSWindow?
    override var isKeyWindow: Bool { simulatedKeyWindow }
    override var attachedSheet: NSWindow? { simulatedAttachedSheet }
    override var sheetParent: NSWindow? { simulatedSheetParent }
}
