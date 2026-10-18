import Foundation
import AppKit
import CoreGraphics
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Accessibility and keyboard audit")
@MainActor
struct AccessibilityKeyboardAuditTests {
    @Test("Thumbnail selection follows source identity across insertion, reorder and cell reuse")
    func thumbnailSelectionDuringSnapshotInsertion() {
        let originalURL = URL(fileURLWithPath: "/synthetic-caption/available.png")
        let existingCopyURL = URL(fileURLWithPath: "/synthetic-caption/available copy.png")
        let insertedCopyURL = URL(fileURLWithPath: "/synthetic-caption/available copy 2.png")
        let service = ThumbnailService()

        func configure(_ item: ThumbnailCollectionViewItem, url: URL, selected: Bool) {
            // Pending inputs avoid filesystem probes and asynchronous image decoding.
            let image = ImageFile(url: url, isICloudDownloadPending: true)
            _ = item.view
            item.configure(
                with: ThumbnailCellData(from: image),
                thumbnailService: service,
                showOriginals: true,
                imageFile: image,
                isSelected: selected,
                isActive: selected
            )
        }

        let original = ThumbnailCollectionViewItem()
        let existingCopy = ThumbnailCollectionViewItem()
        configure(original, url: originalURL, selected: true)
        configure(existingCopy, url: existingCopyURL, selected: false)

        // The model has inserted a selected duplicate at index 1, but the displayed
        // index 1 still contains the pre-existing copy from the preceding snapshot.
        ThumbnailCollectionView.refreshSelection(
            in: [original, existingCopy], selectedIDs: [insertedCopyURL], activeURL: insertedCopyURL
        )
        #expect(!original.thumbnailView.isAccessibilitySelected())
        #expect(!existingCopy.thumbnailView.isAccessibilitySelected())
        #expect((existingCopy.thumbnailView.accessibilityValue() as? String)?.hasPrefix("Not selected,") == true)

        let insertedCopy = ThumbnailCollectionViewItem()
        configure(insertedCopy, url: insertedCopyURL, selected: true)
        // Completion must reconcile every visible cell, independent of display order.
        ThumbnailCollectionView.refreshSelection(
            in: [existingCopy, insertedCopy, original],
            selectedIDs: [insertedCopyURL], activeURL: insertedCopyURL
        )
        #expect(insertedCopy.thumbnailView.isAccessibilitySelected())
        #expect(!existingCopy.thumbnailView.isAccessibilitySelected())
        #expect(!original.thumbnailView.isAccessibilitySelected())
        #expect((insertedCopy.thumbnailView.accessibilityValue() as? String)?.hasPrefix("Selected,") == true)

        insertedCopy.prepareForReuse()
        #expect(insertedCopy.currentURL == nil)
        configure(insertedCopy, url: existingCopyURL, selected: false)
        ThumbnailCollectionView.refreshSelection(
            in: [insertedCopy], selectedIDs: [insertedCopyURL], activeURL: insertedCopyURL
        )
        #expect(insertedCopy.currentURL == existingCopyURL)
        #expect(!insertedCopy.thumbnailView.isAccessibilitySelected())
        #expect((insertedCopy.thumbnailView.accessibilityValue() as? String)?.hasPrefix("Not selected,") == true)
    }

    @Test("Thumbnail accessibility selection values stay current without cell reconfiguration")
    func thumbnailSelectionAccessibility() {
        var image = ImageFile(url: URL(fileURLWithPath: "/synthetic-caption/accessibility.png"))
        image.hasPendingMetadataChanges = true
        let view = ThumbnailItemView(frame: .zero)
        view.configure(with: ThumbnailCellData(from: image))
        view.updateSelection(isSelected: false, isActive: false)
        #expect(!view.isAccessibilitySelected())
        #expect(view.accessibilityValue() as? String == "Not selected, Unrated, Pending metadata changes")
        view.updateSelection(isSelected: true, isActive: true)
        #expect(view.isAccessibilitySelected())
        #expect(view.accessibilityValue() as? String == "Selected, Unrated, Pending metadata changes")
        // Duplicate changes model selection while leaving the original's payload unchanged.
        view.updateSelection(isSelected: false, isActive: false)
        #expect(!view.isAccessibilitySelected())
        #expect(view.accessibilityValue() as? String == "Not selected, Unrated, Pending metadata changes")
        view.reset()
        view.configure(with: ThumbnailCellData(from: image))
        #expect(view.accessibilityValue() as? String == "Not selected, Unrated, Pending metadata changes")
    }

    @Test("shared announcements are typed fixed copy with no private interpolation surface")
    func privacySafeAccessibilityAnnouncements() throws {
        let announcements = AppAccessibilityAnnouncement.allFixedCopy
        #expect(!announcements.isEmpty)
        #expect(announcements.contains(.success(.templateSaved)))
        #expect(announcements.contains(.failure(.templateSave)))
        #expect(announcements.contains(.cancellation(.templateEditing)))
        #expect(announcements.contains(.information(.voiceMemoTranscriptPreview)))
        #expect(announcements.contains(.failure(.voiceMemoTranscriptRefused)))
        #expect(announcements.contains(.success(.voiceMemoTranscriptApplied)))
        #expect(announcements.contains(.recovery(.contentCredentialsInspection)))

        for announcement in announcements {
            #expect(!announcement.spokenText.isEmpty)
            #expect(!announcement.spokenText.contains("/"))
            #expect(!announcement.spokenText.contains("\\"))
            #expect(!announcement.spokenText.contains("{"))
            #expect(!announcement.spokenText.contains("}"))
            #expect(!announcement.spokenText.contains("%"))
        }

        let center = try source("Aagedal Photo Agent/Services/AccessibilityAnnouncementCenter.swift")
        #expect(center.contains("NSAccessibility.post"))
        #expect(center.contains(".announcement: announcement.spokenText"))
        #expect(!center.contains("localizedDescription"))

        for path in [
            "Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift",
            "Aagedal Photo Agent/Views/Metadata/VoiceMemoVariablePreviewView.swift",
            "Aagedal Photo Agent/Views/Templates/TemplateEditorView.swift",
            "Aagedal Photo Agent/Views/Templates/DevelopTemplateListView.swift",
            "Aagedal Photo Agent/Views/Browser/C2PADetailSheet.swift",
        ] {
            let view = try source(path)
            #expect(!view.contains("NSAccessibility.post"), "Bypassed shared announcer in \(path)")
        }

        let metadataTemplate = try source("Aagedal Photo Agent/Views/Templates/TemplateEditorView.swift")
        let developTemplate = try source("Aagedal Photo Agent/Views/Templates/DevelopTemplateListView.swift")
        #expect(!metadataTemplate.contains("accessibilityLabel(\"Template save failed. \\("))
        #expect(!developTemplate.contains("accessibilityLabel(\"Template save failed. \\("))
    }

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
        #expect(source.contains("settings.shortcuts.keyboardPreview"))
        #expect(source.contains("registry.reassign(chord, to: command)"))
        #expect(source.contains("registry.remove(chord, from: command)"))
        #expect(source.contains("profileRegistry.resolveConflictsKeepingFirstCommand()"))

        let reservedMenuChords: Set<KeyboardShortcutChord> = [
            .init(key: "w", modifiers: .command),
            .init(key: "x", modifiers: .command),
            .init(key: "q", modifiers: .command),
            .init(key: "z", modifiers: [.command, .shift]),
            .init(key: "return", modifiers: [.command, .option]),
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

    @Test("editor reassignment refuses conflicts without changing persisted state and preserves aliases")
    func editorReassignment() throws {
        let suiteName = "ShortcutEditor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "editor")
        let original = registry.selectedProfile
        let occupied = KeyboardShortcutChord(key: "1")
        #expect(!registry.reassign(occupied, to: .labelRed))
        #expect(registry.selectedPreset == .photoAgent)
        #expect(registry.selectedProfile == original)
        #expect(defaults.data(forKey: "editor") == nil)
        #expect(!registry.reassign(.init(key: "s", modifiers: .command), to: .labelRed))
        #expect(registry.selectedProfile == original)

        #expect(registry.reassign(occupied, to: .labelRed, replacingConflicts: true))
        #expect(registry.selectedProfile.command(for: occupied) == .labelRed)
        #expect(registry.selectedProfile.chord(for: .rateOne) == nil)
        #expect(registry.selectedProfile.command(for: .init(key: "s")) == .labelRed)
        #expect(registry.selectedProfile.command(for: .init(key: "6")) == .labelRed)
        #expect(registry.selectedProfile.conflicts.isEmpty)
        #expect(registry.reassign(occupied, to: .labelRed))
        #expect(registry.selectedProfile.bindings.filter { $0.chord == occupied }.count == 1)
        registry.remove(.init(key: "s"), from: .labelRed)
        let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "editor")
        #expect(reopened.selectedProfile == registry.selectedProfile)
        #expect(reopened.selectedProfile.command(for: .init(key: "s")) == nil)
        #expect(reopened.selectedProfile.command(for: .init(key: "6")) == .labelRed)
        #expect(reopened.selectedProfile.command(for: occupied) == .labelRed)
        reopened.resetCustom()
        #expect(reopened.selectedProfile.bindings == original.bindings)
    }

    @Test("global shortcuts preserve Close Window and avoid bare text-entry keys")
    func staticCommandConflictAudit() throws {
        let source = try source("Aagedal Photo Agent/Aagedal_Photo_AgentApp.swift")
        #expect(!source.contains(#".keyboardShortcut("w", modifiers: .command)"#))
        #expect(!source.contains(#".keyboardShortcut("h", modifiers: [])"#))
        #expect(!source.contains(#".keyboardShortcut("g", modifiers: [])"#))
        #expect(source.contains(".keyboardShortcut(keyboardProfile.menuShortcut(for: .removeOrResetSelectedEditLayer))"))
        #expect(source.contains(".keyboardShortcut(keyboardProfile.menuShortcut(for: .scopeWaveform))"))
        #expect(KeyboardShortcutCommand.removeOrResetSelectedEditLayer.defaultChord == .init(key: "delete", modifiers: [.control, .option]))
        #expect(KeyboardShortcutCommand.scopeWaveform.defaultChord == .init(key: "1", modifiers: [.control, .option]))
        let caption = try self.source("Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift")
        #expect(!caption.contains(#".keyboardShortcut("b", modifiers: .command)"#))
        #expect(caption.contains("case .selectPreviousImage:"))
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
        #expect(metadataPanel.contains("OrderedCreatorsEditor("))
        #expect(metadataPanel.contains("label: \"Creator\""))
        #expect(metadataPanel.contains("metadata.creator.orderedEditor"))
        #expect(metadataPanel.contains("Move creator \\(index + 1) earlier"))
        #expect(metadataPanel.contains("EditorialDateCreatedEditor("))
        #expect(metadataPanel.contains("metadata.dateCreated.validationError"))
        #expect(metadataPanel.contains("Exact ISO 8601 precision and timezone-known state are preserved"))
    }

    @Test("face selection, ingest split cells, scope modes, and metadata copy rows use semantic controls")
    func formerlyGestureOnlyControls() throws {
        let faceCard = try source("Aagedal Photo Agent/Views/Faces/FaceGroupCardView.swift")
        #expect(faceCard.contains("setAccessibilityRole(.button)"))
        #expect(faceCard.contains("override func accessibilityPerformPress() -> Bool"))
        #expect(faceCard.contains("setAccessibilityValue(isSelected ? \"Selected\" : \"Not selected\")"))

        let faceDetail = try source("Aagedal Photo Agent/Views/Faces/FaceGroupDetailView.swift")
        #expect(faceDetail.contains("Button {"))
        #expect(faceDetail.contains("Select this face; hold Command to change a multi-selection"))
        #expect(!faceDetail.contains(".onTapGesture {"))

        let expandedFaces = try source("Aagedal Photo Agent/Views/Faces/ExpandedFaceManagementView.swift")
        #expect(expandedFaces.contains(".accessibilityAction(named: \"Open Full Screen\")"))
        #expect(expandedFaces.contains(".accessibilityValue(isSelected ? \"Selected\" : \"Not selected\")"))

        let splitEditor = try source("Aagedal Photo Agent/Views/Import/ImportSplitEditorView.swift")
        #expect(splitEditor.contains("Button {"))
        #expect(splitEditor.contains("Toggle whether this photo starts a new shoot"))
        #expect(!splitEditor.contains(".onTapGesture"))

        let scopes = try source("Aagedal Photo Agent/Views/Browser/ScopeDisplayView.swift")
        #expect(scopes.contains("scopeViewModel.scopeMode = mode"))
        #expect(scopes.contains("scopeViewModel.scopeMode == mode ? .isSelected : []"))
        #expect(!scopes.contains(".onTapGesture"))

        let technicalMetadata = try source("Aagedal Photo Agent/Views/Browser/TechnicalMetadataView.swift")
        #expect(technicalMetadata.contains("Button(action: copyValue)"))
        #expect(technicalMetadata.contains("Copy this value to the clipboard"))
        #expect(!technicalMetadata.contains(".onTapGesture"))
    }

    @Test("AppKit face thumbnails expose an actionable accessibility press")
    func appKitFaceAccessibilityPress() {
        let faceID = UUID()
        let thumbnail = FaceThumbnailSubview(frame: .zero)
        var pressedFaceID: UUID?
        thumbnail.configure(faceID: faceID, ordinal: 1, image: nil)
        thumbnail.onAccessibilityPress = { pressedFaceID = $0 }

        #expect(thumbnail.accessibilityPerformPress())
        #expect(pressedFaceID == faceID)
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


@Suite("Unified application shortcut profiles")
@MainActor
struct UnifiedKeyboardShortcutTests {
    private func withRegistry(_ body: (KeyboardShortcutProfileRegistry, UserDefaults) throws -> Void) throws {
        let name = "UnifiedKeyboardShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile"), defaults)
    }

    @Test("Every native command default belongs to each built-in profile without conflicts")
    func completeDefaults() {
        for preset in KeyboardShortcutPreset.allCases where preset != .custom {
            let profile = KeyboardShortcutProfiles.profile(for: preset)
            #expect(profile.conflicts.isEmpty)
            for command in KeyboardShortcutCommand.allCases where !command.isCulling {
                #expect(profile.chord(for: command) == command.defaultChord)
                #expect(profile.menuChord(for: command) == command.defaultChord)
                if let chord = command.defaultChord {
                    #expect(KeyboardShortcutProfiles.canAssign(chord, to: command))
                    #expect(chord.swiftUIShortcut != nil)
                }
            }
        }
        for slot in 1...9 {
            let command = KeyboardShortcutCommand.templateCommand(slot: slot)
            #expect(command?.defaultChord == .init(key: String(slot), modifiers: .control))
        }
        #expect(KeyboardShortcutCommand.templateCommand(slot: 0) == nil)
        #expect(KeyboardShortcutCommand.templateCommand(slot: 10) == nil)
    }

    @Test("Moving a key between export and culling needs confirmation and persists atomically")
    func crossCategoryReassignment() throws {
        try withRegistry { registry, defaults in
            let chord = KeyboardShortcutChord(key: "s", modifiers: .command)
            let original = registry.selectedProfile
            #expect(!registry.reassign(chord, to: .rateOne))
            #expect(registry.selectedProfile == original)
            #expect(defaults.data(forKey: "profile") == nil)
            #expect(registry.reassign(chord, to: .rateOne, replacingConflicts: true))
            #expect(registry.selectedProfile.chord(for: .renderSelected) == nil)
            #expect(registry.selectedProfile.command(for: .init(key: "1")) == .rateOne)
            #expect(registry.selectedProfile.menuChord(for: .rating(1)) == chord)
            #expect(registry.selectedProfile.conflicts.isEmpty)
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.selectedProfile == registry.selectedProfile)
            #expect(reopened.reassign(chord, to: .advancedExportSelected, replacingConflicts: true))
            #expect(reopened.selectedProfile.command(for: chord) == .advancedExportSelected)
            #expect(reopened.selectedProfile.command(for: .init(key: "1")) == .rateOne)
            #expect(reopened.selectedProfile.menuChord(for: .rating(1)) == nil)
            #expect(reopened.selectedProfile.conflicts.isEmpty)
        }
    }

    @Test("Native commands have one active shortcut; unassignment never restores their old default")
    func replacementAndUnassignment() throws {
        try withRegistry { registry, defaults in
            let newChord = KeyboardShortcutChord(key: "l", modifiers: [.command, .shift])
            #expect(registry.reassign(newChord, to: .renderSelected))
            #expect(registry.selectedProfile.command(for: .init(key: "s", modifiers: .command)) == nil)
            #expect(registry.selectedProfile.menuChord(for: .renderSelected) == newChord)
            #expect(registry.selectedProfile.bindings.filter { $0.command == .renderSelected }.count == 1)
            registry.remove(newChord, from: .renderSelected)
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.selectedProfile.chord(for: .renderSelected) == nil)
            #expect(reopened.selectedProfile.command(for: .init(key: "s", modifiers: .command)) == nil)
            #expect(reopened.selectedProfile.command(for: newChord) == nil)
            reopened.resetCustom()
            #expect(reopened.selectedProfile.chord(for: .renderSelected) == KeyboardShortcutCommand.renderSelected.defaultChord)
        }
    }

    @Test("Version-one custom culling profiles acquire app defaults without losing custom bindings or clears")
    func legacyMigration() throws {
        try withRegistry { _, defaults in
            struct Legacy: Codable {
                let schemaVersion = 1
                let selectedPreset = KeyboardShortcutPreset.custom
                let customBindings: [KeyboardShortcutBinding]
            }
            let saved = [KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "9"))]
            defaults.set(try JSONEncoder().encode(Legacy(customBindings: saved)), forKey: "profile")
            let migrated = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(migrated.selectedPreset == .custom)
            #expect(migrated.selectedProfile.command(for: .init(key: "9")) == .labelRed)
            #expect(migrated.selectedProfile.chord(for: .rateFour) == nil)
            #expect(migrated.selectedProfile.chord(for: .openFolder) == .init(key: "o", modifiers: .command))
            migrated.unassign(.renderSelected)
            let data = try #require(defaults.data(forKey: "profile"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 2)
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.selectedProfile == migrated.selectedProfile)
            #expect(reopened.selectedProfile.chord(for: .renderSelected) == nil)
        }
    }

    @Test("System and typing keys cannot be reassigned or mutate the active profile")
    func protectedKeys() throws {
        try withRegistry { registry, defaults in
            let original = registry.selectedProfile
            for chord in [
                KeyboardShortcutChord(key: "q", modifiers: .command),
                .init(key: "w", modifiers: .command),
                .init(key: "a", modifiers: .command),
                .init(key: "z", modifiers: [.command, .shift]),
                .init(key: "return", modifiers: [.command, .option]),
                .init(key: "6"),
            ] {
                #expect(!registry.reassign(chord, to: .renderSelected, replacingConflicts: true))
                #expect(registry.selectedProfile == original)
                #expect(defaults.data(forKey: "profile") == nil)
            }
            #expect(!registry.reassign(.init(key: "delete", modifiers: .command), to: .rateOne, replacingConflicts: true))
            #expect(!registry.reassign(.init(key: "h", modifiers: [.control, .option]), to: .rateOne, replacingConflicts: true))
        }
    }

    @Test("Forward Delete compatibility never revives a moved, unassigned, or conflicting layer shortcut")
    func forwardDeleteFallback() throws {
        try withRegistry { registry, _ in
            let forward = KeyboardShortcutChord(key: "forwarddelete", modifiers: [.control, .option])
            #expect(registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            #expect(registry.reassign(forward, to: .renderSelected))
            #expect(!registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            registry.remove(forward, from: .renderSelected)
            #expect(registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            registry.unassign(.removeOrResetSelectedEditLayer)
            #expect(!registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            registry.resetCustom()
            registry.assign(forward, to: .renderSelected)
            registry.assign(forward, to: .renderAll)
            #expect(registry.selectedProfile.command(for: forward) == nil)
            #expect(!registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
        }
    }

    @Test("Core menu chords are not mistaken for culling mutations")
    func routing() {
        let profile = KeyboardShortcutProfiles.profile(for: .photoAgent)
        #expect(KeyboardShortcutRouter.resolve(.init(key: "s", modifiers: .command,
            textEditorOwnsInput: false, imeHasMarkedText: false, isRepeat: false), profile: profile) == nil)
        #expect(profile.command(for: .init(key: "s", modifiers: .command)) == .renderSelected)
        #expect(KeyboardShortcutCommand.duplicateSelected.hasDevelopContextOverride(for: .init(key: "d", modifiers: .command)))
        #expect(!KeyboardShortcutCommand.renderSelected.hasDevelopContextOverride(for: .init(key: "d", modifiers: .command)))
        #expect(!KeyboardShortcutCommand.duplicateSelected.hasDevelopContextOverride(for: .init(key: "d", modifiers: [.command, .shift])))
    }
}
