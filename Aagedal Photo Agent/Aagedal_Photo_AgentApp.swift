import AppKit
import SwiftUI

@main
struct Aagedal_Photo_AgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = SparkleUpdaterService.shared
    @ObservedObject private var imageScaling = ImageScalingController.shared
    @State private var settingsViewModel = SettingsViewModel()
    @State private var commandRouter = AppCommandRouter()
    private let recentFolders = RecentFoldersStore.shared

    init() {
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
        Window("Aagedal Photo Agent", id: "main") {
            ContentView(settingsViewModel: settingsViewModel, commandRouter: commandRouter)
                .environment(commandRouter)
                .onAppear {
                    AppStartupSignposts.shared.mainContentAppeared()
                    // UI smoke launches use disposable fixtures and must not start unrelated
                    // migrations, cloud watchers, network refreshes, or backup prompts.
                    if !UITestLaunchConfiguration.current.isEnabled {
                        AppStartupWorkCoordinator.shared.startAfterFirstPaint()
                    }
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

            CommandGroup(after: .newItem) {
                Button("Open Folder...") {
                    commandRouter.send(.openFolder)
                }
                .keyboardShortcut("o", modifiers: .command)

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

                Button("Import Photos...") {
                    commandRouter.send(.showImport)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Back Up Edited Files...") {
                    commandRouter.send(.backupEditedFiles)
                }

                Divider()

                Button("Render Selected") {
                    commandRouter.send(.renderSelected)
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Advanced Export Selected...") {
                    commandRouter.send(.advancedExportSelected)
                }

                Button("Render All") {
                    commandRouter.send(.renderAll)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Save as JPEG") {
                    commandRouter.send(.saveAsJPEG)
                }

                Button("Save as PNG") {
                    commandRouter.send(.saveAsPNG)
                }

                Divider()

                Button("Rename...") {
                    commandRouter.send(.renameSelected)
                }

                Button("Duplicate") {
                    commandRouter.send(.duplicateSelected)
                }
                .keyboardShortcut("d", modifiers: .command)
            }

            CommandGroup(replacing: .printItem) { }

            CommandMenu("Rating & Label") {
                // Ratings carry no menu key equivalents: the bare 1–5 keys are
                // handled in the grid / full-screen views (focus-aware, so they
                // don't fire while a metadata field is being edited). CMD+digits
                // are reserved for the color labels below.
                Button("No Rating") {
                    commandRouter.send(.setRating(.none))
                }

                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) Star\(rating > 1 ? "s" : "")") {
                        guard let rating = StarRating(rawValue: rating) else { return }
                        commandRouter.send(.setRating(rating))
                    }
                }

                Divider()

                Button("No Label") {
                    commandRouter.send(.setLabel(.none))
                }
                .keyboardShortcut("0", modifiers: .command)

                ForEach(Array(ColorLabel.allCases.dropFirst().enumerated()), id: \.element) { index, label in
                    Button(label.displayName) {
                        commandRouter.send(.setLabel(label))
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))),
                        modifiers: .command
                    )
                }
            }

            CommandGroup(after: .newItem) {
                Button("Open in Editor") {
                    let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultEditDestination)
                        ?? DefaultEditDestination.internalEditor.rawValue
                    let destination = DefaultEditDestination(rawValue: raw) ?? .internalEditor
                    if destination == .internalEditor {
                        commandRouter.send(.openInInternalEditor)
                    } else {
                        commandRouter.send(.openInExternalEditor)
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Move to Trash") {
                    commandRouter.send(.deleteSelected)
                }
                .keyboardShortcut(.delete, modifiers: .command)

                Button("Move Rejected to Folder…") {
                    commandRouter.send(.moveRejectedToFolder)
                }

                Divider()

                Button("Rotate Right") {
                    commandRouter.send(.rotateClockwise)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Rotate Left") {
                    commandRouter.send(.rotateCounterclockwise)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Add New Mask") {
                    commandRouter.send(.addNewMask)
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("Remove or Reset Selected Edit Layer") {
                    commandRouter.send(.removeOrResetSelectedEditLayer)
                }
                .keyboardShortcut(.delete, modifiers: [.control, .option])

                Divider()

                Button("Reset All Edits") {
                    commandRouter.send(.resetAllEdits)
                }

                Button("Remove All IPTC Metadata") {
                    commandRouter.send(.removeAllIPTC)
                }
            }




            CommandMenu("Metadata") {
                Button("Process Variables") {
                    commandRouter.send(.processVariablesSelected)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Process Variables in All Images") {
                    commandRouter.send(.processVariablesAll)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Write All Pending Metadata") {
                    commandRouter.send(.writeAllPendingMetadata)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button("Apply Template...") {
                    commandRouter.send(.showTemplatePalette)
                }
                .keyboardShortcut("t", modifiers: .command)

                Divider()

                ForEach(1...9, id: \.self) { slot in
                    Button("Apply Template \(slot)") {
                        commandRouter.send(.applyTemplateShortcut(slot))
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(slot))), modifiers: .control)
                }

                Divider()

                Button("Variable Reference") {
                    commandRouter.send(.showVariableReference)
                }
                .keyboardShortcut("v", modifiers: .option)

                Button("Show Raw Metadata") {
                    commandRouter.send(.showRawMetadata)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Structured Keywords") {
                    commandRouter.send(.showStructuredKeywords)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                Button("Render and Sign Selected") {
                    commandRouter.send(.renderAndSignSelected)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button("Copy IPTC Metadata") {
                    commandRouter.send(.copyIPTCMetadata)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Paste IPTC Metadata") {
                    commandRouter.send(.pasteIPTCMetadata)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
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
                    .keyboardShortcut("m", modifiers: [.command, .shift])

                    Divider()

                    Button("Previous Image") {
                        commandRouter.send(.selectPreviousImage)
                    }
                    .keyboardShortcut("b", modifiers: .command)

                    Button("Next Image") {
                        commandRouter.send(.selectNextImage)
                    }
                    .keyboardShortcut("n", modifiers: .command)

                    Divider()

                    Button("Toggle HDR") {
                        commandRouter.send(.toggleHDR)
                    }
                    .keyboardShortcut("h", modifiers: [.control, .option])

                    Section("Image Scaling") {
                        Toggle("Nearest-Neighbor Scaling", isOn: $imageScaling.useNearestNeighbor)
                    }
                }

                Section("Scopes") {
                    Button("Waveform") {
                        commandRouter.send(.setScopeMode(.waveform))
                    }
                    .keyboardShortcut("1", modifiers: [.control, .option])

                    Button("Parade") {
                        commandRouter.send(.setScopeMode(.parade))
                    }
                    .keyboardShortcut("2", modifiers: [.control, .option])

                    Button("Vectorscope") {
                        commandRouter.send(.setScopeMode(.vectorscope))
                    }
                    .keyboardShortcut("3", modifiers: [.control, .option])

                    Button("Gamut") {
                        commandRouter.send(.setScopeMode(.chromaticity))
                    }
                    .keyboardShortcut("4", modifiers: [.control, .option])

                    Divider()

                    Button("Toggle Gamut Clipping") {
                        commandRouter.send(.toggleGamutClipping)
                    }
                    .keyboardShortcut("g", modifiers: [.control, .option])
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
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!CleanFeedController.shared.hasExternalDisplay)
            }

            CommandMenu("Upload") {
                Button("Upload Selected") {
                    commandRouter.send(.uploadSelected)
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("Upload All") {
                    commandRouter.send(.uploadAll)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            } // end Group (View additions / Upload)
        }

        Window("Structured Keywords", id: "structuredKeywords") {
            StructuredKeywordsWindowContent()
        }
        .defaultSize(width: 420, height: 560)

        Settings {
            SettingsView(settingsViewModel: settingsViewModel)
                .environment(commandRouter)
        }
    }
}

@MainActor
final class BackgroundOperationMonitor {
    static let shared = BackgroundOperationMonitor()

    var isImporting = false
    var isUploading = false
    var isRenderingForUpload = false

    var hasActiveOperation: Bool {
        isImporting || isUploading || isRenderingForUpload
    }

    var activeOperationSummary: String {
        var parts: [String] = []
        if isImporting { parts.append("an import") }
        if isUploading { parts.append("an upload") }
        if isRenderingForUpload { parts.append("upload rendering") }
        return parts.joined(separator: " and ")
    }

    private init() {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private let terminationReplyLatch = ApplicationTerminationReplyLatch()

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
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReplyLatch.isPending { return .terminateLater }

        let monitor = BackgroundOperationMonitor.shared
        if monitor.hasActiveOperation {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Import or upload still in progress"
            let summary = monitor.activeOperationSummary.isEmpty ? "background work" : monitor.activeOperationSummary
            alert.informativeText = "Quitting now will stop \(summary). Wait for it to finish, or quit anyway?"
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }

        guard terminationReplyLatch.begin() else { return .terminateLater }
        let captionOperation = CaptionWorkspaceTerminationFlushOperation()
        let coordinator = ApplicationTerminationFlushCoordinator(
            captionFlush: { try await captionOperation.flush() },
            developFlush: {
                await DevelopVersionFlushCoordinator.shared.flush(.applicationTermination)
            }
        )
        Task { @MainActor in
            let shouldTerminate = await coordinator.resolve { failure in
                terminationChoice(for: failure)
            }
            guard terminationReplyLatch.finish() else { return }
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    @MainActor
    private func terminationChoice(
        for failure: ApplicationTerminationFlushFailure
    ) -> ApplicationTerminationFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch failure.stage {
        case .caption:
            alert.messageText = "Caption Save Failed"
            alert.informativeText = "Caption sidecar changes could not be saved: \(failure.message)\n\nRetry the retained drafts, keep the app open, or explicitly quit without saving them."
        case .develop:
            alert.messageText = "Named Version Save Failed"
            alert.informativeText = "The active Develop version could not be saved: \(failure.message)\n\nRetry saving, keep the app open, or explicitly quit without saving these changes."
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
}
