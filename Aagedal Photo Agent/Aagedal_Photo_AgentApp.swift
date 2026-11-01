import AppKit
import SwiftUI

@main
struct Aagedal_Photo_AgentApp: App {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @State private var nativeInvocation = AutomationNativeInvocationController.shared
    @State private var didPresentNativeInvocationUITest = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = SparkleUpdaterService.shared
    @ObservedObject private var imageScaling = ImageScalingController.shared
    @State private var settingsViewModel = SettingsViewModel()
    @State private var commandRouter = AppCommandRouter()
    @State private var keyboardProfiles = KeyboardShortcutProfileRegistry.shared
    @State private var activityHistory: ActivityHistoryStore
    @State private var faceRecognitionViewModel: FaceRecognitionViewModel
    @State private var knownPeopleInterchangeController: KnownPeopleInterchangeController
    @State private var didOpenKnownPeopleUITestWorkflow = false
    private let recentFolders = RecentFoldersStore.shared

    init() {
        let uiTestConfiguration = UITestLaunchConfiguration.current
        if uiTestConfiguration.isEnabled, let root = uiTestConfiguration.knownPeopleRootURL {
            KnownPeopleService.storageOverrideURL = root.standardizedFileURL
        }
        if uiTestConfiguration.isEnabled, let root = uiTestConfiguration.watermarkRootURL {
            WatermarkStore.storageOverrideURL = root.standardizedFileURL
        }
        // Before this run writes folder history, which would make a new install look upgraded.
        if !uiTestConfiguration.isEnabled {
            WhatsNewLaunchState.shared.decide(in: AppDefaults.store)
        }
        let history = ActivityHistoryStore()
        _activityHistory = State(initialValue: history)
        _faceRecognitionViewModel = State(initialValue: FaceRecognitionViewModel(
            readService: SwiftExifReadService(), writeEngine: SwiftExifWriteEngine(), activityHistory: history))
        _knownPeopleInterchangeController = State(initialValue: KnownPeopleInterchangeController(
            operations: KnownPeopleInterchangeProductionOperations()
        ))
        AppStartupSignposts.shared.processStarted()
    }

    /// Radio selection for the View-menu clean-feed display list: the active target
    /// display when on, or `nil` (Off) when disabled. Selecting a display sends the
    /// feed there and enables it; selecting Off disables it.
    private var cleanFeedSelection: Binding<CGDirectDisplayID?> {
        Binding(
            get: { CleanFeedController.shared.activeDisplaySelection },
            set: { newValue in
                if let id = newValue {
                    CleanFeedController.shared.selectDisplay(id: id)
                } else {
                    CleanFeedController.shared.isEnabled = false
                }
            }
        )
    }

    var body: some Scene {
        let keyboardProfile = keyboardProfiles.selectedProfile
        Window("Aagedal Photo Agent", id: "main") {
            ContentView(settingsViewModel: settingsViewModel, commandRouter: commandRouter,
                        faceRecognition: faceRecognitionViewModel, history: activityHistory)
                .environment(commandRouter)
                .environment(knownPeopleInterchangeController)
                .onAppear {
                    AppStartupSignposts.shared.mainContentAppeared()
                    if !didPresentNativeInvocationUITest,
                       UITestLaunchConfiguration.current.isEnabled,
                       ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_TRANSCRIPTION_INVOCATION"] == "1",
                       let service = UITestTranscriptionReviewFixture.currentServiceForModel() {
                        didPresentNativeInvocationUITest = true
                        // Presentation-only fixture: transport authentication is tested
                        // separately. Never touch host roots, models or provider consent.
                        Task {
                            guard let request = try? await service.requests().first,
                                  let id = UUID(uuidString: request.requestID),
                                  let epoch = UUID(uuidString: request.requestEpoch) else { return }
                            nativeInvocation.present(requestID: id, requestEpoch: epoch)
                        }
                    }
                    // UI smoke launches use disposable fixtures and must not start unrelated
                    // migrations, cloud watchers, network refreshes, or backup prompts.
                    if !UITestLaunchConfiguration.current.isEnabled {
                        AppStartupWorkCoordinator.shared.startAfterFirstPaint()
                        nativeInvocation.start()
                    }
                    if UITestNativeInvocationConfiguration.current != nil {
                        nativeInvocation.start()
                    }
                    if UITestLaunchConfiguration.current.isEnabled,
                       UITestLaunchConfiguration.current.workflow == .knownPeopleInterchange,
                       UITestLaunchConfiguration.current.knownPeopleRootURL != nil,
                       !didOpenKnownPeopleUITestWorkflow {
                        didOpenKnownPeopleUITestWorkflow = true
                        Task { @MainActor in
                            await Task.yield()
                            commandRouter.send(.showKnownPeopleDatabase)
                        }
                    }
                }
                .onChange(of: nativeInvocation.pendingReview?.id) { _, id in
                    guard id != nil else { return }
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: nativeInvocation.pendingFaceReview?.id) { _, id in
                    guard id != nil else { return }
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Aagedal Photo Agent") {
                    AboutPanel.show()
                }

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            // No Help book ships with the app; point Help at the 3.0 guides instead.
            CommandGroup(replacing: .help) {
                Button("Photo Agent Feature Guide") {
                    openURL(WhatsNewPresentation.featureGuideURL)
                }
                Button("Known Limitations") {
                    openURL(WhatsNewPresentation.limitationsURL)
                }
                Divider()
                Button("What's New in Photo Agent 3.0") {
                    openWindow(id: "whatsNew")
                }
            }

            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    commandRouter.send(.openFolder)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .openFolder))

                Menu("Open Recent") {
                    ForEach(recentFolders.folders) { recent in
                        Button(recent.name) {
                            commandRouter.send(.openRecentFolder(recent.url))
                        }
                    }

                    if !recentFolders.folders.isEmpty {
                        Divider()
                    }

                    Button("Clear Menu") {
                        recentFolders.clear()
                    }
                    .disabled(recentFolders.folders.isEmpty)
                }

                Button("Import from Web URL…") {
                    commandRouter.send(.showWebImport)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .showWebImport))

                Button("Import Photos...") {
                    commandRouter.send(.showImport)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .showImport))

                Button("Back Up Edited Files...") {
                    commandRouter.send(.backupEditedFiles)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .backupEditedFiles))

                Divider()

                Button("Render Selected") {
                    commandRouter.send(.renderSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .renderSelected))

                Button("Advanced Export Selected...") {
                    commandRouter.send(.advancedExportSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .advancedExportSelected))

                Button("Render All") {
                    commandRouter.send(.renderAll)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .renderAll))

                Divider()

                Button("Save as JPEG") {
                    commandRouter.send(.saveAsJPEG)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .saveAsJPEG))

                Button("Save as PNG") {
                    commandRouter.send(.saveAsPNG)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .saveAsPNG))

                Divider()

                Button("Rename...") {
                    commandRouter.send(.renameSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .renameSelected))

                Button("Duplicate") {
                    commandRouter.send(.duplicateSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .duplicateSelected))
            }

            CommandGroup(replacing: .printItem) { }

            DevelopUndoCommands()

            RatingLabelCommands(commandRouter: commandRouter)

            CommandGroup(after: .newItem) {
                Button("Open in Editor") {
                    let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.defaultEditDestination)
                        ?? DefaultEditDestination.internalEditor.rawValue
                    let destination = DefaultEditDestination(rawValue: raw) ?? .internalEditor
                    if destination == .internalEditor {
                        commandRouter.send(.openInInternalEditor)
                    } else {
                        commandRouter.send(.openInExternalEditor)
                    }
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .openInEditor))
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Move to Trash") {
                    commandRouter.send(.deleteSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .deleteSelected))

                Button("Move Rejected to Folder") {
                    commandRouter.send(.moveRejectedToFolder)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .moveRejectedToFolder))

                Divider()

                Button("Rotate Right") {
                    commandRouter.send(.rotateClockwise)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .rotateClockwise))

                Button("Rotate Left") {
                    commandRouter.send(.rotateCounterclockwise)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .rotateCounterclockwise))

                Button("Add New Mask") {
                    commandRouter.send(.addNewMask)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .addNewMask))

                Button("Remove or Reset Selected Edit Layer") {
                    commandRouter.send(.removeOrResetSelectedEditLayer)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .removeOrResetSelectedEditLayer))

                Divider()

                Button("Reset All Edits") {
                    commandRouter.send(.resetAllEdits)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .resetAllEdits))

                Button("Remove All IPTC Metadata") {
                    commandRouter.send(.removeAllIPTC)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .removeAllIPTC))
            }




            CommandMenu("Metadata") {
                Button("Process Variables") {
                    commandRouter.send(.processVariablesSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .processVariablesSelected))

                Button("Process Variables in All Images") {
                    commandRouter.send(.processVariablesAll)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .processVariablesAll))

                Divider()

                Button("Write All Pending Metadata") {
                    commandRouter.send(.writeAllPendingMetadata)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .writeAllPendingMetadata))

                Divider()

                Button("Apply Template...") {
                    commandRouter.send(.showTemplatePalette)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .showTemplatePalette))

                Divider()

                ForEach(1...9, id: \.self) { slot in
                    Button("Apply Template \(slot)") {
                        commandRouter.send(.applyTemplateShortcut(slot))
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: KeyboardShortcutCommand.templateCommand(slot: slot)))
                }

                Divider()

                Button("Variable Reference") {
                    commandRouter.send(.showVariableReference)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .showVariableReference))

                Button("Show Raw Metadata") {
                    commandRouter.send(.showRawMetadata)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .showRawMetadata))

                Button("Structured Keywords") {
                    commandRouter.send(.showStructuredKeywords)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .showStructuredKeywords))

                Divider()

                Button("Render and Sign Selected") {
                    commandRouter.send(.renderAndSignSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .renderAndSignSelected))

                Divider()

                Button("Copy IPTC Metadata") {
                    commandRouter.send(.copyIPTCMetadata)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .copyIPTCMetadata))

                Button("Paste IPTC Metadata") {
                    commandRouter.send(.pasteIPTCMetadata)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .pasteIPTCMetadata))
            }

            // Grouped to stay within the @CommandsBuilder 10-child limit.
            Group {
            // Merge Scopes + Clean Feed into the system View menu (created by
            // NavigationSplitView's sidebar command) rather than adding extra
            // top-level menus.
            CommandGroup(after: .sidebar) {
                Group {
                    Divider()

                    Button("Caption Workspace") {
                        commandRouter.send(.openCaptionWorkspace)
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .openCaptionWorkspace))

                    Divider()

                    Button("Previous Image") {
                        commandRouter.send(.selectPreviousImage)
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .selectPreviousImage))

                    Button("Next Image") {
                        commandRouter.send(.selectNextImage)
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .selectNextImage))

                    // ⌘W closes the active tab via MainWindowTabCloseKeyMonitor, ahead of the
                    // window's own Close item, so this item carries no key equivalent.
                    Section("Tabs") {
                        Button("New Tab") {
                            commandRouter.send(.browserTab(.newTab))
                        }
                        .keyboardShortcut(keyboardProfile.menuShortcut(for: .newBrowserTab))

                        Button("Close Tab") {
                            commandRouter.send(.browserTab(.closeTab))
                        }

                        Button("Show Next Tab") {
                            commandRouter.send(.browserTab(.showNextTab))
                        }
                        .keyboardShortcut(keyboardProfile.menuShortcut(for: .showNextBrowserTab))

                        Button("Show Previous Tab") {
                            commandRouter.send(.browserTab(.showPreviousTab))
                        }
                        .keyboardShortcut(keyboardProfile.menuShortcut(for: .showPreviousBrowserTab))
                    }

                    Divider()

                    Button("Toggle HDR") {
                        commandRouter.send(.toggleHDR)
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .toggleHDR))

                    Section("Image Scaling") {
                        Toggle("Nearest-Neighbor Scaling", isOn: $imageScaling.useNearestNeighbor)
                    }
                }

                Section("Scopes") {
                    Button("Waveform") {
                        commandRouter.send(.setScopeMode(.waveform))
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .scopeWaveform))

                    Button("Parade") {
                        commandRouter.send(.setScopeMode(.parade))
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .scopeParade))

                    Button("Vectorscope") {
                        commandRouter.send(.setScopeMode(.vectorscope))
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .scopeVectorscope))

                    Button("Gamut") {
                        commandRouter.send(.setScopeMode(.chromaticity))
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .scopeGamut))

                    Divider()

                    Button("Toggle Gamut Clipping") {
                        commandRouter.send(.toggleGamutClipping)
                    }
                    .keyboardShortcut(keyboardProfile.menuShortcut(for: .toggleGamutClipping))
                }

                // The inline Picker's label is itself the section header — wrapping it
                // in a Section too would render "Clean Feed Output" twice.
                Picker("Clean Feed Output", selection: cleanFeedSelection) {
                    Text("Off").tag(CGDirectDisplayID?.none)
                    ForEach(CleanFeedController.shared.feedDisplayOptions) { option in
                        Text(option.name).tag(Optional(option.id))
                    }
                }
                .pickerStyle(.inline)
                .disabled(!CleanFeedController.shared.hasExternalDisplay)

                Picker(
                    "Clean Feed Comparison Layout",
                    selection: Binding(
                        get: { CleanFeedController.shared.comparisonLayout },
                        set: { CleanFeedController.shared.comparisonLayout = $0 }
                    )
                ) {
                    Label("Side by Side", systemImage: "rectangle.split.2x1")
                        .tag(ComparisonLayout.sideBySide)
                    Label("Stacked", systemImage: "rectangle.split.1x2")
                        .tag(ComparisonLayout.stacked)
                    Label("Wipe", systemImage: "rectangle.lefthalf.inset.filled")
                        .tag(ComparisonLayout.wipe)
                }
                .pickerStyle(.inline)
                .disabled(
                    !CleanFeedController.shared.isEnabled
                    || !CleanFeedController.shared.isPresentingComparison
                )

                Divider()

                Button(CleanFeedController.shared.isEnabled
                       ? "Turn Off Clean Feed"
                       : "Turn On Clean Feed") {
                    CleanFeedController.shared.toggleEnabled()
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .toggleCleanFeed))
                .disabled(!CleanFeedController.shared.hasExternalDisplay)
            }

            CommandMenu("Upload") {
                Button("Upload Selected") {
                    commandRouter.send(.uploadSelected)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .uploadSelected))

                Button("Upload All") {
                    commandRouter.send(.uploadAll)
                }
                .keyboardShortcut(keyboardProfile.menuShortcut(for: .uploadAll))
            }
            } // end Group (View additions / Upload)
        }

        Window("What's New", id: "whatsNew") {
            WhatsNewView()
        }
        .windowResizability(.contentSize)

        Window("Structured Keywords", id: "structuredKeywords") {
            StructuredKeywordsWindowContent()
        }
        .defaultSize(width: 420, height: 560)

        Settings {
            SettingsView(settingsViewModel: settingsViewModel)
                .environment(faceRecognitionViewModel)
                .environment(commandRouter)
                .environment(knownPeopleInterchangeController)
        }
    }
}

@MainActor
final class BackgroundOperationMonitor {
    static let shared = BackgroundOperationMonitor()

    var isImporting = false
    var isUploading = false
    var isRenderingForUpload = false
    /// Polled sources for work owned by window models (metadata batch writes, Person Shown
    /// writes, voice memo transcriptions, face scans). Each returns descriptions of what is
    /// running now, such as "a face scan".
    private var sources: [(key: String, activities: @MainActor () -> [String])] = []

    /// Registers (or replaces, by key) a source of running background work.
    func registerSource(_ key: String, activities: @escaping @MainActor () -> [String]) {
        sources.removeAll { $0.key == key }
        sources.append((key, activities))
    }

    var activeOperations: [String] {
        var parts: [String] = []
        if isImporting { parts.append("an import") }
        if isUploading { parts.append("an upload") }
        if isRenderingForUpload { parts.append("upload rendering") }
        for source in sources { parts.append(contentsOf: source.activities()) }
        return parts
    }

    var hasActiveOperation: Bool { !activeOperations.isEmpty }

    var activeOperationSummary: String { Self.summary(of: activeOperations) }

    /// "an import", "an import and a face scan", "an import, an upload and a face scan".
    nonisolated static func summary(of operations: [String]) -> String {
        guard let last = operations.last else { return "" }
        guard operations.count > 1 else { return last }
        return operations.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Alert text for the quit warning: "A face scan is still running. …".
    nonisolated static func quitWarningText(for operations: [String]) -> String {
        let summary = summary(of: operations)
        let subject = summary.isEmpty ? "Background work" : summary.prefix(1).uppercased() + summary.dropFirst()
        let verb = operations.count > 1 ? "are" : "is"
        return "\(subject) \(verb) still running. Quit anyway? Quitting first waits for metadata writes, and offers to stop waiting if they take long; other work stops."
    }

    init() {}
}

/// Whether the "still saving" alert is on screen, so a late flush completion never ends a
/// different modal session.
@MainActor
private final class TerminationModalPresence {
    var isShowing = true
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private let terminationReplyLatch = ApplicationTerminationReplyLatch()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Off-main, and skipped in test processes.
        FFmpegWhisperVerifiedSnapshotCache.sweepStaleSessionsAtLaunch()
    }

    @MainActor
    func applicationWillBecomeActive(_ notification: Notification) {
        AppStartupSignposts.shared.applicationWillBecomeActive()
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        AppStartupSignposts.shared.applicationDidBecomeActive()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        AppStartupWorkCoordinator.shared.cancel()
        AutomationNativeInvocationController.shared.stop()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReplyLatch.isPending { return .terminateLater }

        let monitor = BackgroundOperationMonitor.shared
        let operations = monitor.activeOperations
        if !operations.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Background Work Still Running"
            alert.informativeText = BackgroundOperationMonitor.quitWarningText(for: operations)
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }

        guard terminationReplyLatch.begin() else { return .terminateLater }
        let captionOperation = CaptionWorkspaceTerminationFlushOperation()
        // Writes a cancelled quit left running finish before this quit starts its own, so the
        // same photo is never committed twice concurrently.
        var precedingWork: (@MainActor () async -> Void)?
        if let earlierAttempt = unfinishedTerminationFlush {
            precedingWork = { await earlierAttempt.value }
        }
        let coordinator = ApplicationTerminationFlushCoordinator(
            browserEditorFlush: {
                // Its own stage, ahead of Caption: abandoning one never skips the other.
                try await MetadataEditorTerminationFlush.shared.flush()
            },
            captionFlush: {
                try await captionOperation.flush()
            },
            analysisFlush: {
                try await AnalysisWorkspaceTerminationFlush.shared.flush()
            },
            developFlush: {
                await DevelopVersionFlushCoordinator.shared.flush(.applicationTermination)
            },
            precedingWork: precedingWork,
            waitTimeout: .seconds(4),
            describeActivity: { stage in
                switch stage {
                case .browserEditor: MetadataEditorTerminationFlush.shared.pendingActivityDescription
                default: nil
                }
            },
            canAbandonStage: { stage in
                // Captured Primary Develop edits must never be abandoned from this prompt; the
                // failure prompt forbids it too.
                !(stage == .develop && DevelopPrimaryLifecycleCoordinator.shared.hasPendingWork)
            }
        )
        Task { @MainActor in
            let shouldTerminate = await coordinator.resolve(
                chooseWhileWaiting: { context in terminationWaitChoice(context) },
                chooseFailure: { failure in terminationChoice(for: failure) }
            )
            // Keep Open after a failure leaves nothing running; Cancel Quit may.
            unfinishedTerminationFlush = shouldTerminate ? nil : coordinator.unfinishedAttempt
            guard terminationReplyLatch.finish() else { return }
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    /// The flush a Cancel Quit left running; the next quit waits for it first.
    @MainActor private var unfinishedTerminationFlush: Task<Void, Never>?

    /// Shown when a quit flush is still running after the timeout. AppKit is in its
    /// terminate-later modal loop and further Cmd-Q presses are ignored, so without this prompt a
    /// stalled write (an unplugged card, a hung network volume) would freeze the app for good.
    @MainActor
    private func terminationWaitChoice(
        _ context: ApplicationTerminationWaitContext
    ) -> ApplicationTerminationWaitChoice {
        // Another prompt (a folder switch's discard question the flush is waiting on) is already
        // asking the user; never stack this one on top of it. The timeout re-arms.
        guard NSApp.modalWindow == nil else { return .keepWaiting }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Saving Changes…"
        alert.addButton(withTitle: "Keep Waiting")
        if context.allowsQuitWithoutSaving {
            alert.informativeText = "Still saving \(context.activityDescription). Keep waiting for it to finish, quit without saving this (the remaining changes are still saved first), or cancel quitting and keep working."
            alert.addButton(withTitle: "Quit Without Saving")
            alert.buttons[1].hasDestructiveAction = true
        } else {
            alert.informativeText = "Still saving \(context.activityDescription). Captured Develop edits cannot be abandoned: keep waiting, or cancel quitting and use Retry Develop Writes or Review Develop Conflicts."
        }
        alert.addButton(withTitle: "Cancel Quit")
        let presence = TerminationModalPresence()
        context.whenFlushFinishes {
            guard presence.isShowing else { return }
            presence.isShowing = false
            NSApp.stopModal(withCode: Self.flushFinishedModalResponse)
            // stopModal takes effect when the modal loop next processes an event.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: false)
            }
        }
        let response = alert.runModal()
        presence.isShowing = false
        switch response {
        case .alertSecondButtonReturn: return context.allowsQuitWithoutSaving ? .quitWithoutSaving : .cancelQuit
        case .alertThirdButtonReturn: return .cancelQuit
        default: return .keepWaiting // Keep Waiting, or dismissed because the flush finished
        }
    }

    private static let flushFinishedModalResponse = NSApplication.ModalResponse(rawValue: 9_001)

    @MainActor
    private func terminationChoice(
        for failure: ApplicationTerminationFlushFailure
    ) -> ApplicationTerminationFailureChoice {
        let presentation = ApplicationTerminationFailurePresentation.make(
            for: failure,
            developHasPendingPrimaryWork: DevelopPrimaryLifecycleCoordinator.shared.hasPendingWork
        )
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        guard presentation.offersRetryAndQuit else {
            alert.addButton(withTitle: "Keep App Open")
            alert.runModal()
            return .keepOpen
        }
        alert.addButton(withTitle: "Retry Save")
        alert.addButton(withTitle: "Keep App Open")
        alert.addButton(withTitle: "Quit Without Saving")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertThirdButtonReturn: return .quitWithoutSaving
        default: return .keepOpen
        }
    }
}

extension Notification.Name {
    static let faceMetadataDidChange = Notification.Name("faceMetadataDidChange")
    static let importStarted = Notification.Name("importStarted")
    static let importCompleted = Notification.Name("importCompleted")
    static let knownPeopleDatabaseDidChange = Notification.Name("knownPeopleDatabaseDidChange")
    static let scopeSourceImageDidChange = Notification.Name("scopeSourceImageDidChange")
    static let editSliderDragStateChanged = Notification.Name("editSliderDragStateChanged")
    static let showAllFilesChanged = Notification.Name("showAllFilesChanged")
    /// The RAW decode profile or decoder version changed; caches keyed by URL alone are stale.
    static let rawDecodeSettingsDidChange = Notification.Name("rawDecodeSettingsDidChange")
}


/// Edit ▸ Undo/Redo. In Develop (no text field editing) they drive the Develop history and show
/// its step names ("Undo Exposure"); everywhere else they send the standard responder-chain
/// `undo:`/`redo:`, like the system items they replace. Never disabled: a text field's undo
/// relies on the menu key equivalent even when the Develop history is empty.
private struct DevelopUndoCommands: Commands {
    @State private var router = DevelopUndoMenuRouter.shared

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(router.undoTitle) { router.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button(router.redoTitle) { router.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

/// Observes profile edits directly so native menu key equivalents update with the editor.
private struct RatingLabelCommands: Commands {
    let commandRouter: AppCommandRouter
    @State private var profiles = KeyboardShortcutProfileRegistry.shared

    var body: some Commands {
        let profile = profiles.selectedProfile
        CommandMenu("Rating & Label") {
            Button("No Rating") {
                commandRouter.send(.setRating(.none))
            }
            .keyboardShortcut(shortcut(for: .rating(0), in: profile))

            ForEach(1...5, id: \.self) { value in
                Button("\(value) Star\(value > 1 ? "s" : "")") {
                    guard let rating = StarRating(rawValue: value) else { return }
                    commandRouter.send(.setRating(rating))
                }
                .keyboardShortcut(shortcut(for: .rating(value), in: profile))
            }

            Divider()

            Button("No Label") {
                commandRouter.send(.setLabel(.none))
            }
            .keyboardShortcut(shortcut(for: .colorLabel(0), in: profile))

            ForEach(Array(ColorLabel.allCases.dropFirst().enumerated()), id: \.element) { index, label in
                Button(label.displayName) {
                    commandRouter.send(.setLabel(label))
                }
                .keyboardShortcut(shortcut(for: .colorLabel(index + 1), in: profile))
            }
        }
    }

    private func shortcut(for action: KeyboardCullingAction,
                          in profile: KeyboardShortcutProfile) -> KeyboardShortcut? {
        profile.menuChord(for: action)?.swiftUIShortcut
    }
}
