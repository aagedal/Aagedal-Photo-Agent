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
        for preset in KeyboardShortcutPreset.allCases {
            let profile = KeyboardShortcutProfiles.profile(for: preset)
            #expect(!profile.bindings.isEmpty)
            #expect(profile.conflicts.isEmpty)
            #expect(Set(profile.bindings.map(\.chord)).count == profile.bindings.count)
            for command in KeyboardShortcutCommand.allCases {
                #expect(profile.chords(for: command).count <= KeyboardShortcutProfile.slotCount)
            }
        }
        // Two slots per command: Red keeps the bare 6–9 run and its Command-1 menu key.
        let photoAgent = KeyboardShortcutProfiles.profile(for: .photoAgent)
        #expect(photoAgent.chords(for: .labelRed) == [.init(key: "6"), .init(key: "1", modifiers: .command)])
        #expect(photoAgent.chords(for: .labelTrash) == [.init(key: "x"), .init(key: "8", modifiers: .command)])
        #expect(photoAgent.command(for: .init(key: "s")) == nil)
    }

    @Test("the shortcut editor exposes every command, both slots and reserved chords")
    func completeEditableCommandSurface() throws {
        let source = try source("Aagedal Photo Agent/Views/Settings/KeyboardShortcutEditorView.swift")
        #expect(source.contains("KeyboardShortcutCommand.allCases.filter"))
        #expect(source.contains("settings.shortcuts.keyboardPreview"))
        #expect(source.contains("TableColumn(\"Alternate\")"))
        #expect(source.contains("registry.reassign(pending.chord, to: pending.command, slot: pending.slot)"))
        #expect(source.contains("registry.remove(chord)"))
        let settings = try self.source("Aagedal Photo Agent/Views/Settings/KeyboardShortcutsSettingsView.swift")
        #expect(settings.contains("openWindow(id: KeyboardShortcutEditorWindow.id)"))

        let reservedMenuChords: [KeyboardShortcutChord] = [
            .init(key: "w", modifiers: .command),
            .init(key: "x", modifiers: .command),
            .init(key: "q", modifiers: .command),
            .init(key: "z", modifiers: [.command, .shift]),
            .init(key: "return", modifiers: [.command, .option]),
            .init(key: "k", modifiers: [.command, .option]),
        ]
        for chord in reservedMenuChords {
            #expect(KeyboardShortcutProfiles.validationError(chord, for: .renderSelected) != nil)
            #expect(KeyboardShortcutProfiles.validationError(chord, for: .rateOne) != nil)
        }
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

    @Test("preset selection and modified shortcuts persist")
    func registryPersistence() throws {
        let suiteName = "AccessibilityKeyboardAuditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "shortcut-profile"

        let first = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: key)
        first.applyPreset(named: KeyboardShortcutPreset.bridgeLike.displayName)
        let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: key)
        #expect(reopened.activePresetName == "Bridge-like")
        #expect(reopened.selectedProfile.savedForm == KeyboardShortcutProfiles.profile(for: .bridgeLike).savedForm)
        #expect(!reopened.isModified)

        let chord = KeyboardShortcutChord(key: "r", modifiers: [.control, .option])
        #expect(reopened.set(chord, for: .labelRed, slot: 1) == nil)
        #expect(reopened.isModified)
        let modified = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: key)
        #expect(modified.activePresetName == "Bridge-like")
        #expect(modified.isModified)
        #expect(modified.selectedProfile.command(for: chord) == .labelRed)
    }

    @Test("an occupied chord is refused until the editor confirms the reassignment")
    func conflictRequiresConfirmation() throws {
        let suiteName = "AccessibilityKeyboardAuditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "shortcut-conflict")
        let original = registry.selectedProfile
        let chord = KeyboardShortcutChord(key: "1")

        #expect(registry.set(chord, for: .labelYellow, slot: 1) != nil)
        #expect(registry.selectedProfile == original)
        #expect(defaults.data(forKey: "shortcut-conflict") == nil)

        #expect(registry.reassign(chord, to: .labelYellow, slot: 1) == nil)
        #expect(registry.selectedProfile.command(for: chord) == .labelYellow)
        #expect(registry.selectedProfile.chords(for: .rateOne).isEmpty)
        #expect(registry.selectedProfile.conflicts.isEmpty)

        registry.remove(chord)
        let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "shortcut-conflict")
        #expect(reopened.selectedProfile.command(for: chord) == nil)
        #expect(reopened.selectedProfile.chords(for: .labelYellow) == [.init(key: "7")])
    }

    @Test("editor slots replace, promote and reset in order")
    func editorReassignment() throws {
        let suiteName = "ShortcutEditor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "editor")
        let original = registry.selectedProfile
        let occupied = KeyboardShortcutChord(key: "1")
        #expect(registry.set(.init(key: "s", modifiers: .command), for: .labelRed, slot: 1) != nil)
        #expect(registry.set(.init(key: "n"), for: .labelRed, slot: 2) != nil)
        #expect(registry.selectedProfile == original)

        #expect(registry.reassign(occupied, to: .labelRed, slot: 1) == nil)
        #expect(registry.selectedProfile.chords(for: .labelRed) == [.init(key: "6"), occupied])
        #expect(registry.selectedProfile.chord(for: .rateOne) == nil)
        #expect(registry.selectedProfile.menuChord(for: .colorLabel(1)) == nil)
        #expect(registry.selectedProfile.conflicts.isEmpty)

        // Clearing the first shortcut promotes the alternate.
        #expect(registry.set(nil, for: .labelRed, slot: 0) == nil)
        #expect(registry.selectedProfile.chords(for: .labelRed) == [occupied])
        let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "editor")
        #expect(reopened.selectedProfile == registry.selectedProfile)
        reopened.resetToDefaults()
        #expect(reopened.selectedProfile.bindings == original.bindings)
        #expect(!reopened.isModified)
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
        #expect(metadataPanel.contains("metadata.creator.editor"))
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
        for preset in KeyboardShortcutPreset.allCases {
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
            #expect(registry.set(chord, for: .rateOne, slot: 1) != nil)
            #expect(registry.selectedProfile == original)
            #expect(defaults.data(forKey: "profile") == nil)
            #expect(registry.reassign(chord, to: .rateOne, slot: 1) == nil)
            #expect(registry.selectedProfile.chord(for: .renderSelected) == nil)
            #expect(registry.selectedProfile.command(for: .init(key: "1")) == .rateOne)
            #expect(registry.selectedProfile.menuChord(for: .rating(1)) == chord)
            #expect(registry.selectedProfile.conflicts.isEmpty)
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.selectedProfile == registry.selectedProfile)
            #expect(reopened.reassign(chord, to: .advancedExportSelected, slot: 0) == nil)
            #expect(reopened.selectedProfile.command(for: chord) == .advancedExportSelected)
            #expect(reopened.selectedProfile.command(for: .init(key: "1")) == .rateOne)
            #expect(reopened.selectedProfile.menuChord(for: .rating(1)) == nil)
            #expect(reopened.selectedProfile.conflicts.isEmpty)
        }
    }

    @Test("Native commands keep two shortcuts; the menu shows the first and unassignment never restores a default")
    func replacementAndUnassignment() throws {
        try withRegistry { registry, defaults in
            let newChord = KeyboardShortcutChord(key: "l", modifiers: [.command, .shift])
            let alternate = KeyboardShortcutChord(key: "f5")
            #expect(registry.set(newChord, for: .renderSelected, slot: 0) == nil)
            #expect(registry.selectedProfile.command(for: .init(key: "s", modifiers: .command)) == nil)
            #expect(registry.set(alternate, for: .renderSelected, slot: 1) == nil)
            #expect(registry.selectedProfile.menuChord(for: .renderSelected) == newChord)
            #expect(registry.selectedProfile.chords(for: .renderSelected) == [newChord, alternate])
            registry.remove(newChord)
            #expect(registry.selectedProfile.menuChord(for: .renderSelected) == alternate)
            registry.remove(alternate)
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.selectedProfile.chord(for: .renderSelected) == nil)
            #expect(reopened.selectedProfile.command(for: .init(key: "s", modifiers: .command)) == nil)
            #expect(reopened.selectedProfile.command(for: newChord) == nil)
            reopened.resetToDefaults()
            #expect(reopened.selectedProfile.chord(for: .renderSelected) == KeyboardShortcutCommand.renderSelected.defaultChord)
        }
    }

    @Test("Version-one custom culling profiles become a Custom preset with app defaults and kept clears")
    func legacyMigration() throws {
        try withRegistry { _, defaults in
            struct Legacy: Codable {
                let schemaVersion = 1
                let selectedPreset = "custom"
                let customBindings: [KeyboardShortcutBinding]
            }
            let saved = [KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "9"))]
            defaults.set(try JSONEncoder().encode(Legacy(customBindings: saved)), forKey: "profile")
            let migrated = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(migrated.activePresetName == "Custom")
            #expect(migrated.preset(named: "Custom") != nil)
            #expect(!migrated.isModified)
            #expect(migrated.selectedProfile.command(for: .init(key: "9")) == .labelRed)
            #expect(migrated.selectedProfile.chord(for: .rateFour) == nil)
            #expect(migrated.selectedProfile.chord(for: .openFolder) == .init(key: "o", modifiers: .command))
            migrated.set(nil, for: .renderSelected, slot: 0)
            let data = try #require(defaults.data(forKey: "profile"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 3)
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.selectedProfile == migrated.selectedProfile)
            #expect(reopened.selectedProfile.chord(for: .renderSelected) == nil)
            #expect(reopened.isModified)
        }
    }

    @Test("Version-two profiles keep at most two keys per command, preferring the menu chord")
    func legacyThreeKeyMigration() throws {
        try withRegistry { _, defaults in
            struct Legacy: Codable {
                let schemaVersion = 2
                let selectedPreset: String
                let customBindings: [KeyboardShortcutBinding]
            }
            var bindings = KeyboardShortcutProfiles.profile(for: .photoAgent).bindings
            bindings.removeAll { $0.command == .labelRed }
            bindings += [
                KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "6")),
                KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "s")),
                KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "1", modifiers: .command)),
            ]
            defaults.set(try JSONEncoder().encode(Legacy(selectedPreset: "custom", customBindings: bindings)), forKey: "profile")
            let migrated = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(migrated.selectedProfile.chords(for: .labelRed) == [.init(key: "6"), .init(key: "1", modifiers: .command)])
            #expect(migrated.selectedProfile.command(for: .init(key: "s")) == nil)

            // An earlier custom list survives as a preset even while a built-in one was chosen.
            defaults.set(try JSONEncoder().encode(Legacy(selectedPreset: "bridgeLike", customBindings: [
                KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "r", modifiers: [.control, .option])),
            ])), forKey: "profile")
            let builtIn = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(builtIn.activePresetName == "Bridge-like")
            #expect(builtIn.preset(named: "Custom") != nil)
            #expect(!builtIn.isModified)
        }
    }

    @Test("Version-two migration keeps two keys when none of a command's keys uses Command")
    func legacyMigrationWithoutMenuChord() throws {
        try withRegistry { _, defaults in
            struct Legacy: Codable {
                let schemaVersion = 2
                let selectedPreset = "custom"
                let customBindings: [KeyboardShortcutBinding]
            }
            var bindings = KeyboardShortcutProfiles.profile(for: .photoAgent).bindings
            bindings.removeAll { $0.command == .rateOne || $0.chord == .init(key: "q") }
            bindings += [
                KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "1")),
                KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "q")),
                KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "1", modifiers: .shift)),
            ]
            defaults.set(try JSONEncoder().encode(Legacy(customBindings: bindings)), forKey: "profile")
            let migrated = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(migrated.selectedProfile.chords(for: .rateOne) == [.init(key: "1"), .init(key: "q")])
        }
    }

    @Test("Migration drops keys this version cannot use before keeping two, so a usable key fills the slot")
    func legacyMigrationDropsUnusableKeysBeforeTrimming() throws {
        try withRegistry { _, defaults in
            struct Legacy: Codable {
                let schemaVersion = 2
                let selectedPreset = "custom"
                let customBindings: [KeyboardShortcutBinding]
            }
            var bindings = KeyboardShortcutProfiles.profile(for: .photoAgent).bindings
            bindings.removeAll { $0.command == .rateOne || $0.chord == .init(key: "q") }
            bindings += [
                // Now reserved for macOS keyboard navigation.
                KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "f2", modifiers: .control)),
                KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "1")),
                KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "q")),
            ]
            defaults.set(try JSONEncoder().encode(Legacy(customBindings: bindings)), forKey: "profile")
            let migrated = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(migrated.selectedProfile.chords(for: .rateOne) == [.init(key: "1"), .init(key: "q")])
            #expect(migrated.skippedOnLoad == 1)
            #expect(migrated.skippedOnLoadNote?.contains("“Custom”") == true)
        }
    }

    @Test("Saved shortcuts that are now reserved are counted when loading")
    func skippedOnLoad() throws {
        try withRegistry { registry, defaults in
            #expect(registry.skippedOnLoadNote == nil)
            struct Document: Codable {
                var schemaVersion = 3
                var activePresetName = "Photo Agent"
                var current: [String: [KeyboardShortcutChord]]
                var presets: [KeyboardShortcutUserPreset] = []
            }
            var current = registry.selectedProfile.savedForm
            current[KeyboardShortcutCommand.renderSelected.rawValue] = [.init(key: "f", modifiers: [.command, .control])]
            defaults.set(try JSONEncoder().encode(Document(current: current)), forKey: "profile")
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.skippedOnLoad == 1)
            #expect(reopened.skippedOnLoadNote != nil)
            #expect(reopened.selectedProfile.chords(for: .renderSelected).isEmpty)

            // Loading saved the shortcuts without it, so the note shows once.
            let again = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(again.skippedOnLoadNote == nil)
            // Any change retires the note.
            reopened.resetToDefaults()
            #expect(reopened.skippedOnLoadNote == nil)
        }
    }

    @Test("A chord two commands share runs neither, on the keyboard as when pressed")
    func sharedChordRunsNeither() {
        let profile = KeyboardShortcutProfile(name: "Test", bindings: [
            KeyboardShortcutBinding(command: .rateOne, chord: .init(key: "z")),
            KeyboardShortcutBinding(command: .rateTwo, chord: .init(key: "z")),
            KeyboardShortcutBinding(command: .rateThree, chord: .init(key: "y")),
        ])
        #expect(profile.command(for: .init(key: "z")) == nil)
        #expect(profile.commandsByChord[.init(key: "z")] == nil)
        #expect(profile.commandsByChord[.init(key: "y")] == .rateThree)
    }

    @Test("System, text-entry and workspace keys cannot be assigned or mutate the active profile")
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
                .init(key: "a", modifiers: .control),
                .init(key: "left", modifiers: .command),
                .init(key: "space", modifiers: .command),
                .init(key: "k", modifiers: [.command, .option]),
            ] {
                #expect(registry.set(chord, for: .renderSelected, slot: 0) != nil)
                #expect(registry.reassign(chord, to: .renderSelected, slot: 0) != nil)
                #expect(registry.selectedProfile == original)
                #expect(defaults.data(forKey: "profile") == nil)
            }
            #expect(registry.set(.init(key: "delete", modifiers: .command), for: .rateOne, slot: 1) != nil)
            #expect(registry.set(.init(key: "c"), for: .rateOne, slot: 1) != nil)
            #expect(registry.set(.init(key: "h", modifiers: .option), for: .rateOne, slot: 1) != nil)
            #expect(KeyboardShortcutProfiles.reservedTitle(for: .init(key: "c")) == "Crop / Compare")
            #expect(KeyboardShortcutProfiles.reservedTitle(for: .init(key: "q", modifiers: .command)) == "Quit")
            // Wider keys are available where they cannot interrupt typing.
            #expect(KeyboardShortcutProfiles.canAssign(.init(key: "left", modifiers: [.command, .option]), to: .selectNextImage))
            #expect(KeyboardShortcutProfiles.canAssign(.init(key: "f6"), to: .rateTwo))
            #expect(KeyboardShortcutProfiles.canAssign(.init(key: "ø", modifiers: .command), to: .renderAll))
            #expect(KeyboardShortcutProfiles.canAssign(.init(key: "g"), to: .labelGreen))
        }
    }

    @Test("Forward Delete compatibility never revives a moved or unassigned layer shortcut")
    func forwardDeleteFallback() throws {
        try withRegistry { registry, _ in
            let forward = KeyboardShortcutChord(key: "forwarddelete", modifiers: [.control, .option])
            #expect(registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            #expect(registry.set(forward, for: .renderSelected, slot: 1) == nil)
            #expect(!registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            registry.remove(forward)
            #expect(registry.selectedProfile.hasDevelopForwardDeleteFallback(for: forward))
            registry.set(nil, for: .removeOrResetSelectedEditLayer, slot: 0)
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

@Suite("Keyboard shortcut editor presets and keys")
@MainActor
struct KeyboardShortcutEditorModelTests {
    private func withRegistry(_ body: (KeyboardShortcutProfileRegistry, UserDefaults) throws -> Void) throws {
        let name = "KeyboardShortcutEditorModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile"), defaults)
    }

    @Test("User presets save, switch, rename, delete and persist; built-in presets stay read-only")
    func presetLifecycle() throws {
        try withRegistry { registry, defaults in
            let chord = KeyboardShortcutChord(key: "f7")
            #expect(registry.set(chord, for: .toggleHDR, slot: 1) == nil)
            #expect(registry.isModified)
            #expect(registry.savePreset(named: "Photo Agent") != nil)
            #expect(registry.savePreset(named: "  ") != nil)
            #expect(registry.savePreset(named: "Sports Desk") == nil)
            #expect(registry.activePresetName == "Sports Desk")
            #expect(!registry.isBuiltInPresetActive)
            #expect(!registry.isModified)

            registry.applyPreset(named: "Photo Agent")
            #expect(registry.selectedProfile.command(for: chord) == nil)
            registry.applyPreset(named: "Sports Desk")
            #expect(registry.selectedProfile.command(for: chord) == .toggleHDR)

            #expect(registry.renamePreset("Sports Desk", to: "Bridge-like") != nil)
            #expect(registry.renamePreset("Sports Desk", to: "Match Day") == nil)
            #expect(registry.activePresetName == "Match Day")
            let reopened = KeyboardShortcutProfileRegistry(defaults: defaults, storageKey: "profile")
            #expect(reopened.presetNames.contains("Match Day"))
            #expect(reopened.activePresetName == "Match Day")
            #expect(reopened.selectedProfile.command(for: chord) == .toggleHDR)

            reopened.deletePreset(named: "Match Day")
            #expect(reopened.presets.isEmpty)
            #expect(reopened.activePresetName == "Photo Agent")
            // Deleting keeps the current shortcuts, now as changes to the default preset.
            #expect(reopened.selectedProfile.command(for: chord) == .toggleHDR)
            #expect(reopened.isModified)
        }
    }

    @Test("Preset files round-trip, refuse other JSON and report skipped shortcuts on import")
    func presetFiles() throws {
        try withRegistry { registry, _ in
            let current = registry.currentPreset
            let decoded = try KeyboardShortcutUserPreset(fileData: current.fileData())
            #expect(decoded == current)

            #expect(throws: KeyboardShortcutPresetError.self) {
                try KeyboardShortcutUserPreset(fileData: Data(#"{"name":"x"}"#.utf8))
            }
            let newer = Data(#"{"format":"com.aagedal.photoagent.keyboard-preset","version":99,"name":"x","shortcuts":{}}"#.utf8)
            #expect(throws: KeyboardShortcutPresetError.self) { try KeyboardShortcutUserPreset(fileData: newer) }

            // Reserved and duplicate entries are skipped; absent commands take their defaults.
            let imported = KeyboardShortcutUserPreset(name: "Photo Agent", shortcuts: [
                KeyboardShortcutCommand.rateOne.rawValue: [.init(key: "q", modifiers: .command), .init(key: "1")],
                KeyboardShortcutCommand.rateTwo.rawValue: [.init(key: "1")],
                "commandFromTheFuture": [.init(key: "j", modifiers: .command)],
            ])
            let result = registry.importPreset(imported)
            #expect(result.name == "Photo Agent 2")
            #expect(result.rejected == 2)
            #expect(registry.activePresetName == "Photo Agent 2")
            #expect(registry.selectedProfile.chords(for: .rateOne) == [.init(key: "1")])
            #expect(registry.selectedProfile.chords(for: .rateTwo).isEmpty)
            #expect(registry.selectedProfile.chord(for: .openFolder) == KeyboardShortcutCommand.openFolder.defaultChord)
            #expect(!registry.isModified)
        }
    }

    @Test("Key events normalize named keys to the names the editor records")
    func eventNormalization() throws {
        func chord(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> KeyboardShortcutChord? {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            return KeyboardShortcutChord(event: event)
        }
        #expect(try chord(96, "\u{F708}") == .init(key: "f5"))
        #expect(try chord(123, "\u{F702}", [.command, .option]) == .init(key: "left", modifiers: [.command, .option]))
        #expect(try chord(117, "\u{F728}", [.control]) == .init(key: "forwarddelete", modifiers: .control))
        #expect(try chord(49, " ") == .init(key: "space"))
        #expect(try chord(53, "\u{1b}") == .init(key: "escape"))
        #expect(KeyboardShortcutChord(key: "f5").displayName == "F5")
        #expect(KeyboardShortcutChord(key: "left", modifiers: [.command, .option]).displayName == "⌥⌘←")
        #expect(KeyboardShortcutChord(key: "f5").swiftUIShortcut != nil)
        #expect(KeyboardShortcutChord(key: "pagedown", modifiers: .command).swiftUIShortcut != nil)
        let search = KeyboardShortcutChord(key: "b", modifiers: [.command, .shift]).searchText
        #expect(["cmd", "command", "shift", "b", "⇧⌘b"].allSatisfy(search.contains))
    }

    @Test("Menu key equivalents map back to chords, including Shift capitals and function keys")
    func menuItemChords() {
        let shifted = NSMenuItem(title: "Render All", action: nil, keyEquivalent: "S")
        shifted.keyEquivalentModifierMask = [.command]
        #expect(KeyboardShortcutChord(menuItem: shifted) == .init(key: "s", modifiers: [.command, .shift]))
        let function = NSMenuItem(title: "HDR", action: nil, keyEquivalent: String(Character(Unicode.Scalar(NSF5FunctionKey)!)))
        function.keyEquivalentModifierMask = []
        #expect(KeyboardShortcutChord(menuItem: function) == .init(key: "f5"))
        let arrow = NSMenuItem(title: "Next", action: nil, keyEquivalent: String(Character(Unicode.Scalar(NSRightArrowFunctionKey)!)))
        arrow.keyEquivalentModifierMask = [.command, .option]
        #expect(KeyboardShortcutChord(menuItem: arrow) == .init(key: "right", modifiers: [.command, .option]))
        #expect(KeyboardShortcutChord(menuItem: NSMenuItem(title: "None", action: nil, keyEquivalent: "")) == nil)
    }

    @Test("An alternate shortcut runs the enabled menu item that shows the primary one")
    func alternateDispatch() throws {
        final class Target: NSObject {
            var count = 0
            @objc func run(_ sender: Any?) { count += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "Render Selected", action: #selector(Target.run(_:)), keyEquivalent: "s")
        item.keyEquivalentModifierMask = .command
        item.target = target
        submenu.addItem(item)
        let parent = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)

        var profile = KeyboardShortcutProfiles.profile(for: .photoAgent)
        profile.set(.init(key: "f6"), for: .renderSelected, slot: 1)
        func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            ))
            return KeyboardShortcutAlternateDispatcher.perform(event, profile: profile, menu: menu)
        }
        #expect(try press(97, "\u{F709}", []))
        #expect(target.count == 1)
        // The primary chord is the menu's own key equivalent; AppKit handles it natively.
        #expect(try !press(1, "s", .command))
        #expect(target.count == 1)

        submenu.autoenablesItems = false
        item.isEnabled = false
        #expect(try !press(97, "\u{F709}", []))
        #expect(target.count == 1)

        KeyboardShortcutAlternateDispatcher.isSuspended = true
        defer { KeyboardShortcutAlternateDispatcher.isSuspended = false }
        item.isEnabled = true
        #expect(try !press(97, "\u{F709}", []))
        #expect(target.count == 1)
    }

    @Test("Develop's ⌘D gesture blocks Duplicate's alternate only while a Develop workspace claims the key")
    func developGestureOwnership() throws {
        final class Target: NSObject {
            var count = 0
            @objc func run(_ sender: Any?) { count += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Duplicate", action: #selector(Target.run(_:)), keyEquivalent: "x")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = target
        menu.addItem(item)

        var profile = KeyboardShortcutProfiles.profile(for: .photoAgent)
        profile.set(.init(key: "x", modifiers: [.command, .option]), for: .duplicateSelected, slot: 0)
        profile.set(.init(key: "d", modifiers: .command), for: .duplicateSelected, slot: 1)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ))
        #expect(KeyboardShortcutAlternateDispatcher.perform(event, profile: profile, menu: menu))
        #expect(target.count == 1)

        let owner = UUID()
        KeyboardShortcutAlternateDispatcher.registerDevelopGestureOwner(owner) { _, _ in true }
        defer { KeyboardShortcutAlternateDispatcher.unregisterDevelopGestureOwner(owner) }
        #expect(!KeyboardShortcutAlternateDispatcher.perform(event, profile: profile, menu: menu))
        #expect(target.count == 1)
    }

    @Test("Alternates run the command's own item when a system item shows the same chord first")
    func alternateDispatchPrefersCommandTitle() throws {
        final class Target: NSObject {
            var count = 0
            @objc func run(_ sender: Any?) { count += 1 }
        }
        let system = Target(), tab = Target()
        let menu = NSMenu()
        for (title, target) in [("Show Toolbar", system), ("New Tab", tab)] {
            let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: "t")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = target
            menu.addItem(item)
        }
        var profile = KeyboardShortcutProfiles.profile(for: .photoAgent)
        profile.set(.init(key: "f6"), for: .newBrowserTab, slot: 1)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F709}", charactersIgnoringModifiers: "\u{F709}", isARepeat: false, keyCode: 97
        ))
        #expect(KeyboardShortcutAlternateDispatcher.perform(event, profile: profile, menu: menu))
        #expect(tab.count == 1)
        #expect(system.count == 0)

        // When no item's title names the command, neither item runs.
        menu.items[1].title = "Open Tab"
        #expect(!KeyboardShortcutAlternateDispatcher.perform(event, profile: profile, menu: menu))
        #expect(tab.count == 1)
        #expect(system.count == 0)
        #expect(KeyboardShortcutCommand.openFolder.isMenuTitle("Open Folder..."))
        #expect(KeyboardShortcutCommand.showWebImport.isMenuTitle("Import from Web URL…"))
        #expect(KeyboardShortcutCommand.toggleCleanFeed.isMenuTitle("Turn Off Clean Feed"))
        #expect(!KeyboardShortcutCommand.newBrowserTab.isMenuTitle("Show Toolbar"))
    }

    @Test("A Shift-punctuation primary, which menus cannot match, runs through the dispatcher")
    func shiftedPunctuationPrimary() throws {
        final class Target: NSObject {
            var count = 0
            @objc func run(_ sender: Any?) { count += 1 }
        }
        #expect(!KeyboardShortcutChord(key: "[", modifiers: [.command, .shift]).menuCanMatch)
        #expect(KeyboardShortcutChord(key: "b", modifiers: [.command, .shift]).menuCanMatch)
        #expect(KeyboardShortcutChord(key: "[", modifiers: [.command, .option]).menuCanMatch)
        // The comma key types punctuation on common layouts; read it as this layout does.
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43
        ))
        let chord = try #require(KeyboardShortcutChord(event: event))
        guard !chord.menuCanMatch else { return }
        let target = Target()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Show Previous Tab", action: #selector(Target.run(_:)), keyEquivalent: chord.key)
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = target
        menu.addItem(item)
        var profile = KeyboardShortcutProfiles.profile(for: .photoAgent)
        profile.set(chord, for: .showPreviousBrowserTab, slot: 0)
        #expect(KeyboardShortcutAlternateDispatcher.perform(event, profile: profile, menu: menu))
        #expect(target.count == 1)
    }

    @Test("macOS-owned function-key chords are reserved")
    func reservedFunctionKeys() {
        for chord in [
            KeyboardShortcutChord(key: "f2", modifiers: .control),
            KeyboardShortcutChord(key: "f8", modifiers: .control),
            KeyboardShortcutChord(key: "f5", modifiers: .command),
            KeyboardShortcutChord(key: "f11"),
        ] {
            #expect(!KeyboardShortcutProfiles.canAssign(chord, to: .renderSelected))
        }
        #expect(KeyboardShortcutProfiles.canAssign(.init(key: "f9", modifiers: .control), to: .renderSelected))
        #expect(KeyboardShortcutProfiles.canAssign(.init(key: "f2", modifiers: [.control, .shift]), to: .renderSelected))
    }

    @Test("The on-screen keyboard finds named keys on any layout and lists every modifier layer")
    func virtualKeyboard() throws {
        let layout = VirtualKeyboardLayout.current()
        #expect(layout.key(for: .init(key: "f5"))?.keyCode == 96)
        #expect(layout.key(for: .init(key: "left", modifiers: [.command, .option]))?.keyCode == 123)
        #expect(layout.key(for: .init(key: "forwarddelete"))?.keyCode == 117)
        let space = try #require(layout.key(for: .init(key: "space")))
        #expect(space.chords.count == 16)
        #expect(space.chords.first?.modifiers == [])
        #expect(Set(space.chords.map(\.chord)).count == 16)
        let letterKeys = layout.keys.filter { if case let .key(key) = $0.role { return key.count == 1 } else { return false } }
        #expect(letterKeys.count >= 47)
    }
}

@Suite("Keyboard preset file normalization")
@MainActor
struct KeyboardPresetFileNormalizationTests {
    @Test("Hand-edited preset chords are normalized to what a key press produces")
    func normalizesStoredChords() throws {
        let json = #"{"format":"com.aagedal.photoagent.keyboard-preset","version":1,"name":"Edited","shortcuts":{"renderAll":[{"key":"L","modifiers":1025}]}}"#
        let preset = try KeyboardShortcutUserPreset(fileData: Data(json.utf8))
        let resolved = preset.resolved
        #expect(resolved.rejected == 0)
        #expect(resolved.profile.chords(for: .renderAll) == [.init(key: "l", modifiers: .command)])
        #expect(KeyboardShortcutProfiles.reservedTitle(for: .init(key: "+", modifiers: [.command, .shift])) == "Help")
    }
}
