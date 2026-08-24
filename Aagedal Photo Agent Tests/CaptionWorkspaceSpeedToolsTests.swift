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

    @Test("non-Deadline layout and keyboard path preserve global customization order")
    func customizedGlobalFieldLayout() {
        let configuration = DeadlineCaptionFieldConfiguration(
            orderedFieldIDs: [.countryCode, .headline, .urgency, .description],
            visibleFieldIDs: [.countryCode, .headline, .urgency, .description]
        )
        let layout = CaptionWorkspaceFieldLayout.make(
            configuration: configuration,
            groupsSecondaryFields: false
        )

        #expect(layout.priority == [.countryCode, .headline, .urgency, .description])
        #expect(layout.secondary.isEmpty)
        #expect(CaptionKeyboardOrder(priorityFields: layout.priority).surfaces.prefix(4) == [
            .priorityField(.countryCode),
            .priorityField(.headline),
            .priorityField(.urgency),
            .priorityField(.description),
        ])
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

    @Test("compact checklist keeps shared readiness and next-issue ordering")
    func compactChecklistSummary() {
        let imageURL = URL(fileURLWithPath: "/caption/a.jpg")
        let warning = MetadataValidationIssue(
            id: "description.warning",
            imageURL: imageURL,
            field: .description,
            severity: .warning,
            message: "Description needs attention.",
            technicalDetail: nil
        )
        let firstBlocker = MetadataValidationIssue(
            id: "headline.blocker",
            imageURL: imageURL,
            field: .headline,
            severity: .blocker,
            message: "Headline is required.",
            technicalDetail: nil
        )
        let laterBlocker = MetadataValidationIssue(
            id: "creator.blocker",
            imageURL: imageURL,
            field: .creator,
            severity: .blocker,
            message: "Creator is required.",
            technicalDetail: nil
        )

        let blocked = CaptionWorkspaceChecklistSummary.make(report: MetadataValidationReport(
            issues: [warning, firstBlocker, laterBlocker]
        ))
        #expect(blocked.readiness == .blocked)
        #expect(blocked.blockerCount == 2)
        #expect(blocked.warningCount == 1)
        #expect(blocked.informationCount == 0)
        #expect(blocked.nextIssue == firstBlocker)

        let visibleOnly = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [firstBlocker, warning]),
            actionableFields: [.description]
        )
        #expect(visibleOnly.readiness == .blocked)
        #expect(visibleOnly.blockerCount == 1)
        #expect(visibleOnly.nextIssue == warning)

        let noVisibleIssue = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [firstBlocker]),
            actionableFields: []
        )
        #expect(noVisibleIssue.readiness == .blocked)
        #expect(noVisibleIssue.blockerCount == 1)
        #expect(noVisibleIssue.nextIssue == nil)

        let warnings = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [warning])
        )
        #expect(warnings.readiness == .warnings)
        #expect(warnings.nextIssue == warning)

        let ready = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [])
        )
        #expect(ready.readiness == .ready)
        #expect(ready.nextIssue == nil)
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
            "Fix Next", "Full Screen", "Faces", "Metadata checks", "All metadata fields",
            "Secondary & Technical",
        ] {
            #expect(caption.contains(label), "Missing \(label)")
        }
        #expect(caption.contains("@State private var showsAllFields = false"))
        #expect(caption.contains("actionableFields: Set(layout.priority + layout.secondary)"))
        #expect(caption.contains("settingsViewModel.orderedIPTCMetadataFields"))
        #expect(caption.contains("settingsViewModel.visibleIPTCMetadataFieldsInOrder"))
        #expect(caption.contains("caption.metadataChecklist.nextIssue"))
        #expect(caption.contains("caption.metadataChecklist.noActionableIssue"))
        #expect(caption.contains("caption.metadataChecklist.ready"))
        #expect(caption.contains("caption.metadataChecklist.disclosure"))
        #expect(caption.contains("Additional IPTC fields can be enabled in Settings → Metadata."))
        #expect(caption.contains("Button(\"Metadata Settings…\")"))
        #expect(caption.contains("settingsViewModel.requestedDestination = .metadata"))
        #expect(caption.contains("openSettings()"))
        #expect(caption.contains("caption.metadataSettings"))
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

        let settings = try source("Aagedal Photo Agent/Views/Settings/SettingsView.swift")
        #expect(settings.contains(".onChange(of: settingsViewModel.requestedDestination)"))
        #expect(settings.contains("case .metadata: selection = .metadata"))
        #expect(settings.contains("settingsViewModel.requestedDestination = nil"))
        #expect(settings.contains("RequiredMetadataFieldsSection(settingsViewModel: settingsViewModel)"))

        let customization = try source("Aagedal Photo Agent/Views/Settings/RequiredMetadataFieldsSection.swift")
        #expect(customization.contains("settingsViewModel.orderedIPTCMetadataFields"))
        #expect(customization.contains(".draggable(field.rawValue)"))
        #expect(customization.contains(".dropDestination(for: String.self)"))
        #expect(customization.contains("Validation for \\(field.displayName)"))
        #expect(customization.contains("Move \\(field.displayName) up"))
        #expect(customization.contains("Move \\(field.displayName) down"))
        #expect(customization.contains("Warn and Require continue to validate hidden fields"))

        #expect(panel.contains("settingsViewModel.visibleIPTCMetadataFieldsInOrder"))
        #expect(panel.contains("editablePrimaryMetadataField(field)"))
        #expect(panel.contains("editableAdditionalMetadataField(field)"))
    }

    @Test("every stable IPTC field has concise localized guidance")
    func metadataFieldGuidanceCoverage() {
        #expect(MetadataFieldID.allCases.count == 33)
        for field in MetadataFieldID.allCases {
            let guidance = field.guidance
            #expect(!guidance.commonUse.isEmpty, "Missing common use for \(field)")
            #expect(!guidance.example.isEmpty, "Missing example for \(field)")
            #expect(guidance.commonUse.count <= 100, "Common use is not concise for \(field)")
            #expect(guidance.example.count <= 90, "Example is not concise for \(field)")
            #expect(guidance.helpText.contains(guidance.commonUse))
            #expect(guidance.helpText.contains(guidance.example))
        }
    }

    @Test("Metadata panel shares field guidance across hover and accessibility")
    func metadataPanelGuidanceAudit() throws {
        let model = try source("Aagedal Photo Agent/Models/MetadataFieldID.swift")
        let panel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        let supplier = try source("Aagedal Photo Agent/Views/Metadata/ImageSupplierMetadataEditor.swift")

        #expect(model.contains("String(localized:"))
        #expect(panel.contains("private struct MetadataFieldGuidanceModifier"))
        #expect(panel.contains(".help(helpText)"))
        #expect(panel.contains(".accessibilityElement(children: .contain)"))
        #expect(panel.contains(".accessibilityHint(helpText)"))
        #expect(panel.contains(".metadataField(field)"))

        let directlyComposedFields = [
            "headline", "description", "extendedDescription", "keywords", "personShown",
            "organisationShownName", "organisationShownCode", "copyright", "creator",
            "rightsUsageTerms", "webStatementOfRights", "digitalImageGUID",
            "imageSupplierImageID", "jobId", "dateCreated", "digitalSourceType", "urgency",
            "sceneCode", "subjectCode", "mediaTopic", "genre", "credit", "city", "country",
            "countryCode", "event",
        ]
        for field in directlyComposedFields {
            #expect(panel.contains(".metadataField(.\(field))"), "Missing panel guidance for \(field)")
        }

        for field in [
            "creatorJobTitle", "descriptionWriter", "source", "sublocation", "provinceState",
            "instructions",
        ] {
            let inlineCall = "simpleAdditionalField(.\(field)"
            let multilineArgument = ".\(field),"
            #expect(
                panel.contains(inlineCall) || panel.contains(multilineArgument),
                "Missing simple editor for \(field)"
            )
        }
        #expect(supplier.contains(".metadataField(.imageSupplier)"))
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
