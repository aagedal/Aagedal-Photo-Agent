import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Caption Workspace speed tools")
@MainActor
struct CaptionWorkspaceSpeedToolsTests {
    @Test("confirmed people require named groups and valid geometry, then sort left to right")
    func confirmedPersonOrdering() {
        let imageURL = URL(fileURLWithPath: "/caption/a.jpg")
        let otherURL = URL(fileURLWithPath: "/caption/b.jpg")
        let leftGroup = FaceGroup(
            id: UUID(), name: "Left Person", representativeFaceID: UUID(), faceIDs: []
        )
        let rightGroup = FaceGroup(
            id: UUID(), name: "Right Person", representativeFaceID: UUID(), faceIDs: []
        )
        let unnamedGroup = FaceGroup(
            id: UUID(), name: nil, representativeFaceID: UUID(), faceIDs: []
        )
        let faces = [
            face(imageURL, CGRect(x: 0.65, y: 0.25, width: 0.2, height: 0.3), rightGroup.id),
            face(imageURL, CGRect(x: 0.10, y: 0.30, width: 0.2, height: 0.3), leftGroup.id),
            face(imageURL, CGRect(x: 0.40, y: 0.30, width: 0.2, height: 0.3), unnamedGroup.id),
            face(imageURL, CGRect(x: -0.1, y: 0.30, width: 0.2, height: 0.3), leftGroup.id),
            face(otherURL, CGRect(x: 0.05, y: 0.20, width: 0.2, height: 0.3), leftGroup.id),
        ]
        let data = FolderFaceData(
            folderURL: imageURL.deletingLastPathComponent(),
            faces: faces,
            groups: [rightGroup, unnamedGroup, leftGroup],
            lastScanDate: .distantPast,
            scanComplete: true
        )

        let people = CaptionConfirmedPersonOrdering.people(for: imageURL, in: data)
        #expect(people.map(\.name) == ["Left Person", "Right Person"])
    }

    @Test("priority fields preserve profile order and separate technical fields")
    func fieldLayout() {
        let configuration = DeadlineCaptionFieldConfiguration(
            orderedFieldIDs: [.countryCode, .description, .headline, .personShown, .urgency],
            visibleFieldIDs: [.countryCode, .description, .headline, .personShown, .urgency]
        )
        let layout = CaptionWorkspaceFieldLayout.make(configuration: configuration)
        #expect(layout.priority == [.description, .headline, .personShown])
        #expect(layout.secondary == [.countryCode, .urgency])
    }

    @Test("headline and caption counts use the narrowest optional profile limit")
    func fieldCountsAndLimits() {
        let profile = MetadataValidationProfile(name: "Caption", rules: [
            MetadataValidationRule(
                id: "headline-max-80",
                severity: .warning,
                requirement: .maximumLength(field: .headline, count: 80)
            ),
            MetadataValidationRule(
                id: "headline-max-64",
                severity: .blocker,
                requirement: .maximumLength(field: .headline, count: 64)
            ),
        ])
        var metadata = IPTCMetadata()
        metadata.title = "Four"
        #expect(CaptionWorkspaceValidationSummary.characterCount(
            for: .headline,
            metadata: metadata
        ) == 4)
        #expect(CaptionWorkspaceValidationSummary.maximumCharacterCount(
            for: .headline,
            profile: profile
        ) == 64)
    }

    @Test("face rectangles convert from Vision bottom-left to preview top-left coordinates")
    func previewGeometry() {
        let fitted = CaptionPreviewGeometry.fittedImageRect(
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 300, height: 300)
        )
        #expect(fitted == CGRect(x: 0, y: 75, width: 300, height: 150))
        let face = CaptionPreviewGeometry.displayRect(
            forVisionRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            in: fitted
        )
        #expect(face == CGRect(x: 75, y: 112.5, width: 150, height: 75))
    }

    @Test("write and next advances only after success for the unchanged image")
    func writeAndNextGate() {
        let current = URL(fileURLWithPath: "/caption/a.jpg")
        #expect(CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: current,
            currentURL: current,
            writeSucceeded: true
        ))
        #expect(!CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: current,
            currentURL: URL(fileURLWithPath: "/caption/b.jpg"),
            writeSucceeded: true
        ))
        #expect(!CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: current,
            currentURL: current,
            writeSucceeded: false
        ))
    }

    @Test("caption advance shortcuts persist and cannot remain ambiguous")
    func captionShortcutRegistry() throws {
        let suiteName = "CaptionWorkspaceSpeedToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = CaptionAdvanceShortcutRegistry(defaults: defaults, storageKey: "advance")
        let chord = KeyboardShortcutChord(key: "return", modifiers: [.command, .option])

        registry.assign(chord, to: .saveAndNext)
        registry.assign(chord, to: .writeAndNext)
        #expect(registry.chord(for: .saveAndNext) == nil)
        #expect(registry.chord(for: .writeAndNext) == chord)

        let reopened = CaptionAdvanceShortcutRegistry(defaults: defaults, storageKey: "advance")
        #expect(reopened.bindings == registry.bindings)
        #expect(CaptionAdvanceShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: "\r",
            modifiers: [.command, .option],
            textEditorOwnsInput: true,
            imeHasMarkedText: false,
            isRepeat: false
        ), bindings: reopened.bindings) == .writeAndNext)
        #expect(CaptionAdvanceShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: "\r",
            modifiers: [.command, .option],
            textEditorOwnsInput: true,
            imeHasMarkedText: true,
            isRepeat: false
        ), bindings: reopened.bindings) == nil)
    }

    @Test("Tab order is deterministic across priority fields and actions in both directions")
    func keyboardTraversalOrder() {
        let order = CaptionKeyboardOrder(priorityFields: [.description, .headline])
        #expect(order.surfaces.prefix(3) == [
            .priorityField(.description),
            .priorityField(.headline),
            .action(.previous),
        ])
        #expect(order.adjacent(to: .priorityField(.description), reverse: false)
            == .priorityField(.headline))
        #expect(order.adjacent(to: .priorityField(.description), reverse: true)
            == .action(.close))
        #expect(order.adjacent(to: .action(.close), reverse: false)
            == .priorityField(.description))
        #expect(CaptionKeyboardOrder(priorityFields: []).adjacent(
            to: nil,
            reverse: false
        ) == .action(.previous))
    }

    @Test("completion announcements are fixed and contain no editorial or path placeholders")
    func privacySafeAnnouncements() {
        #expect(CaptionAccessibilityAnnouncement.savedAndAdvanced.rawValue
            == "Saved and moved to the next photo.")
        #expect(CaptionAccessibilityAnnouncement.wroteAndAdvanced.rawValue
            == "Wrote metadata and moved to the next photo.")
        for announcement in [
            CaptionAccessibilityAnnouncement.savedAndAdvanced,
            .wroteAndAdvanced,
        ] {
            #expect(!announcement.rawValue.contains("/"))
            #expect(!announcement.rawValue.contains("{"))
            #expect(!announcement.rawValue.contains("%"))
        }
    }

    @Test("Caption Workspace exposes the sticky speed tools and prose-only spelling boundary")
    func staticViewAudit() throws {
        let caption = try source("Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift")
        for label in [
            "Previous", "Save & Next", "Write & Next", "Apply Template", "Copy Previous",
            "Fix Next", "Full Screen", "Faces", "Secondary & Technical",
        ] {
            #expect(caption.contains(label), "Missing \(label)")
        }
        #expect(caption.contains("CaptionWorkspaceFlushCoordinator.shared.flush()"))
        #expect(caption.contains("preservingEditorFocus"))
        #expect(caption.contains("CaptionAdvanceShortcutRouter.resolve"))
        #expect(caption.contains("imeHasMarkedText: inputState.imeHasMarkedText"))
        #expect(caption.contains("event.keyCode == 48"))
        #expect(caption.contains("moveCaptionFocus(reverse:"))
        #expect(caption.contains("moveCaptionFocus(from: field, reverse: reverse)"))
        #expect(caption.contains("NSAccessibility.post"))
        #expect(caption.contains("postAccessibilityAnnouncement(.savedAndAdvanced)"))
        #expect(caption.contains("postAccessibilityAnnouncement(.wroteAndAdvanced)"))
        #expect(caption.contains("onDismiss: restoreLastEditorFocus"))
        #expect(caption.contains(".labelsHidden()"))
        #expect(caption.contains(".frame(height: 92)"))

        let panel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        #expect(panel.contains("let proseFields: Set<MetadataFieldID> = [.headline, .description, .extendedDescription]"))
        #expect(panel.contains("editor.isContinuousSpellCheckingEnabled = enabled"))
        #expect(panel.contains("editor.isGrammarCheckingEnabled = enabled"))
        #expect(panel.contains("restoreCaptionAutocompleteFocus()"))
        #expect(panel.contains(".restoreCaptionEditorFocus"))
        #expect(panel.contains(".onKeyPress(.tab)"))
        #expect(panel.contains("handleTab(reverse: true)"))
        #expect(panel.contains("!editor.hasMarkedText()"))

        let autocomplete = try source("Aagedal Photo Agent/Views/Metadata/CaptionAutocompletePopover.swift")
        let codeReplacement = try source("Aagedal Photo Agent/Views/Metadata/CodeReplacementSettingsView.swift")
        let template = try source("Aagedal Photo Agent/Views/Templates/TemplatePaletteView.swift")
        #expect(autocomplete.contains(".onKeyPress(.escape)"))
        #expect(codeReplacement.components(separatedBy: ".onKeyPress(.escape)").count >= 3)
        #expect(template.contains(".onKeyPress(.escape)"))
    }

    private func face(
        _ imageURL: URL,
        _ rect: CGRect,
        _ groupID: UUID?
    ) -> DetectedFace {
        DetectedFace(
            id: UUID(),
            imageURL: imageURL,
            faceRect: rect,
            featurePrintData: Data(),
            groupID: groupID,
            detectedAt: .distantPast
        )
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
