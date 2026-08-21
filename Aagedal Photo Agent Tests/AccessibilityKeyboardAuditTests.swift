import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Accessibility and keyboard audit")
@MainActor
struct AccessibilityKeyboardAuditTests {
    @Test("built-in culling profiles are deterministic, conflict-free, and use unique chords")
    func builtInProfiles() {
        for preset in [
            KeyboardShortcutPreset.photoAgent,
            .photoMechanicLike,
            .bridgeLike,
        ] {
            let profile = KeyboardShortcutProfiles.profile(for: preset)
            #expect(!profile.bindings.isEmpty)
            #expect(profile.conflicts.isEmpty)
            #expect(Set(profile.bindings.map(\.chord)).count == profile.bindings.count)
        }
    }

    @Test("the settings editor exposes every culling command and an unassigned state")
    func completeEditableCommandSurface() throws {
        let source = try source("Aagedal Photo Agent/Views/Settings/KeyboardShortcutsSettingsView.swift")
        #expect(source.contains("ForEach(KeyboardShortcutCommand.allCases"))
        #expect(source.contains("Text(\"Unassigned\").tag(nil as KeyboardShortcutChord?)"))
        #expect(source.contains("profileRegistry.assign(chord, to: command)"))
        #expect(source.contains("profileRegistry.unassign(command)"))
        #expect(source.contains("profileRegistry.resolveConflictsKeepingFirstCommand()"))

        let reservedMenuChords: Set<KeyboardShortcutChord> = [
            KeyboardShortcutChord(key: "w", modifiers: .command),
            KeyboardShortcutChord(key: "s", modifiers: .command),
            KeyboardShortcutChord(key: "x", modifiers: .command),
            KeyboardShortcutChord(key: "1", modifiers: [.control, .option]),
            KeyboardShortcutChord(key: "2", modifiers: [.control, .option]),
            KeyboardShortcutChord(key: "3", modifiers: [.control, .option]),
            KeyboardShortcutChord(key: "4", modifiers: [.control, .option]),
            KeyboardShortcutChord(key: "g", modifiers: [.control, .option]),
            KeyboardShortcutChord(key: "h", modifiers: [.control, .option]),
        ]
        #expect(reservedMenuChords.isDisjoint(with: KeyboardShortcutProfiles.editableChordChoices))
    }

    @Test("conflicts are grouped and sorted deterministically")
    func deterministicConflicts() {
        let chord = KeyboardShortcutChord(key: "1")
        let profile = KeyboardShortcutProfile(name: "Conflict", bindings: [
            KeyboardShortcutBinding(command: .rateTwo, chord: chord),
            KeyboardShortcutBinding(command: .rateOne, chord: chord),
            KeyboardShortcutBinding(command: .rateTwo, chord: chord),
        ])

        #expect(profile.command(for: chord) == nil)
        #expect(profile.conflicts == [KeyboardShortcutConflict(
            chord: chord,
            commands: [.rateOne, .rateTwo]
        )])
    }

    @Test("the router suppresses culling keys for text editors, IME composition, and repeats")
    func textAndIMERoutingBoundary() {
        let profile = KeyboardShortcutProfiles.profile(for: .photoAgent)
        let base = KeyboardShortcutRouteInput(
            key: "3",
            modifiers: [],
            textEditorOwnsInput: false,
            imeHasMarkedText: false,
            isRepeat: false
        )
        #expect(KeyboardShortcutRouter.resolve(base, profile: profile) == .rating(3))
        #expect(KeyboardShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: base.key,
            modifiers: base.modifiers,
            textEditorOwnsInput: true,
            imeHasMarkedText: false,
            isRepeat: false
        ), profile: profile) == nil)
        #expect(KeyboardShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: base.key,
            modifiers: base.modifiers,
            textEditorOwnsInput: false,
            imeHasMarkedText: true,
            isRepeat: false
        ), profile: profile) == nil)
        #expect(KeyboardShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: base.key,
            modifiers: base.modifiers,
            textEditorOwnsInput: false,
            imeHasMarkedText: false,
            isRepeat: true
        ), profile: profile) == nil)
    }

    @Test("preset selection and custom assignments persist")
    func registryPersistence() throws {
        let suiteName = "AccessibilityKeyboardAuditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "shortcut-profile"

        let first = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: key)
        first.select(.bridgeLike)
        let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: key)
        #expect(reopened.selectedPreset == .bridgeLike)
        #expect(reopened.selectedProfile == KeyboardShortcutProfiles.profile(for: .bridgeLike))

        reopened.assign(
            KeyboardShortcutChord(key: "r", modifiers: [.control, .option]),
            to: .labelRed
        )
        let custom = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: key)
        #expect(custom.selectedPreset == .custom)
        #expect(custom.selectedProfile.command(for: KeyboardShortcutChord(
            key: "r",
            modifiers: [.control, .option]
        )) == .labelRed)
    }

    @Test("custom assignments can be unassigned and ambiguous chords are disabled until remediated")
    func customConflictRemediation() throws {
        let suiteName = "AccessibilityKeyboardAuditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = KeyboardShortcutProfileRegistry(
            defaults: defaults,
            storageKey: "shortcut-conflict"
        )
        let chord = KeyboardShortcutChord(key: "1")

        registry.assign(chord, to: .labelYellow)
        #expect(registry.selectedPreset == .custom)
        #expect(registry.selectedProfile.command(for: chord) == nil)
        #expect(registry.selectedProfile.conflicts.count == 1)
        #expect(KeyboardShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: "1",
            modifiers: [],
            textEditorOwnsInput: false,
            imeHasMarkedText: false,
            isRepeat: false
        ), profile: registry.selectedProfile) == nil)

        registry.resolveConflictsKeepingFirstCommand()
        #expect(registry.selectedProfile.conflicts.isEmpty)
        #expect(registry.selectedProfile.command(for: chord) != nil)

        registry.unassign(.labelYellow)
        #expect(registry.selectedProfile.chord(for: .labelYellow) == nil)
        let reopened = KeyboardShortcutProfileRegistry(
            defaults: defaults,
            storageKey: "shortcut-conflict"
        )
        #expect(reopened.selectedProfile.chord(for: .labelYellow) == nil)
    }

    @Test("global shortcuts preserve Close Window and avoid bare text-entry keys")
    func staticCommandConflictAudit() throws {
        let source = try source("Aagedal Photo Agent/Aagedal_Photo_AgentApp.swift")
        #expect(!source.contains(#".keyboardShortcut("w", modifiers: .command)"#))
        #expect(!source.contains(#".keyboardShortcut("h", modifiers: [])"#))
        #expect(!source.contains(#".keyboardShortcut("g", modifiers: [])"#))
        #expect(source.contains(#".keyboardShortcut(.delete, modifiers: [.control, .option])"#))
        #expect(source.contains(#".keyboardShortcut("1", modifiers: [.control, .option])"#))
    }

    @Test("primary workspaces expose stable automation identifiers")
    func workspaceIdentifiers() throws {
        let expectations: [(String, String)] = [
            ("Aagedal Photo Agent/Views/Browser/BrowserView.swift", "browser.workspace"),
            ("Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift", "caption.workspace"),
            ("Aagedal Photo Agent/Views/Browser/BatchRenameSheet.swift", "batchRename.workspace"),
            ("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift", "metadata.panel"),
            ("Aagedal Photo Agent/Views/Browser/ComparisonWorkspaceView.swift", "comparison.workspace"),
            ("Aagedal Photo Agent/Views/CleanFeed/CleanFeedView.swift", "cleanFeed.preview"),
            ("Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift", "develop.workspace"),
            ("Aagedal Photo Agent/Views/Analysis/AnalysisWorkspaceView.swift", "analysis.workspace"),
            ("Aagedal Photo Agent/Views/Browser/DeadlineWorkspaceView.swift", "deadline.workspace"),
            ("Aagedal Photo Agent/Views/Activity/ActivityHistoryView.swift", "activity.history"),
        ]
        for (path, identifier) in expectations {
            #expect(try source(path).contains(identifier), "Missing \(identifier) in \(path)")
        }
    }

    @Test("caption and activity layouts retain adaptive sizing anchors")
    func adaptiveLayoutAudit() throws {
        let caption = try source("Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift")
        #expect(caption.contains(".frame(minHeight: 44)"))
        #expect(caption.contains(".frame(minHeight: 50)"))
        #expect(!caption.contains(".frame(height: 44)"))
        #expect(!caption.contains(".frame(height: 50)"))

        let activity = try source("Aagedal Photo Agent/Views/Activity/ActivityHistoryView.swift")
        #expect(activity.contains(".frame(minWidth: 420, idealWidth: 680, maxWidth: 900)"))
        #expect(activity.contains(".accessibilityLabel(\"Activity filter\")"))
    }

    @Test("accessibility extended description is named distinctly from the editorial caption")
    func accessibilityExtendedDescriptionLabel() throws {
        let metadataPanel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        #expect(metadataPanel.contains("Extended Description (Accessibility)"))
        #expect(metadataPanel.contains("distinct from the editorial caption"))
        #expect(metadataPanel.contains("Describe the visual content for accessibility"))
    }

    @Test("structured contact and created/shown location editors remain distinct and repeatable")
    func structuredEditorialMetadataEditorAudit() throws {
        let metadataPanel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        let editor = try source("Aagedal Photo Agent/Views/Metadata/StructuredEditorialMetadataEditor.swift")

        #expect(metadataPanel.contains("StructuredEditorialMetadataEditor("))
        #expect(metadataPanel.contains("Creator contact and structured locations can be edited one image at a time."))
        #expect(editor.contains("Creator Contact Information"))
        #expect(editor.contains("Location Created"))
        #expect(editor.contains("Location Shown"))
        #expect(editor.contains("RepeatableStructuredTextEditor(title: \"Email\""))
        #expect(editor.contains("RepeatableStructuredTextEditor(title: \"Phone\""))
        #expect(editor.contains("RepeatableStructuredTextEditor(title: \"Web URL\""))
        #expect(editor.contains("RepeatableStructuredTextEditor(title: \"Identifier\""))
        #expect(editor.contains("Latitude"))
        #expect(editor.contains("Longitude"))
    }

    @Test("ordered Creator and typed Date Created expose semantic accessible editors")
    func orderedCreatorAndDateEditorAudit() throws {
        let metadataPanel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        #expect(metadataPanel.contains("Creators (ordered)"))
        #expect(metadataPanel.contains("metadata.creator.orderedEditor"))
        #expect(metadataPanel.contains("Move creator \\(index + 1) earlier"))
        #expect(metadataPanel.contains("EditorialDateCreatedEditor("))
        #expect(metadataPanel.contains("metadata.dateCreated.validationError"))
        #expect(metadataPanel.contains("Exact ISO 8601 precision and timezone-known state are preserved"))
    }

    private func source(_ relativePath: String) throws -> String {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: workspace.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
