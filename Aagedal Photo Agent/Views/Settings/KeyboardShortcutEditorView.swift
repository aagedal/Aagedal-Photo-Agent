import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The keyboard shortcut editor: an on-screen keyboard showing what each key does with
/// each modifier combination, a searchable command list with two shortcuts per command,
/// and presets that can be saved, switched, and shared as files.
struct KeyboardShortcutEditorView: View {
    @State private var registry = KeyboardShortcutProfileRegistry.shared
    @State private var captionRegistry = CaptionAdvanceShortcutRegistry.shared
    @StateObject private var recorder = ShortcutRecorder()
    @State private var layout = VirtualKeyboardLayout.current()
    /// Modifier keys clicked on the on-screen keyboard; held modifiers take precedence.
    @State private var clickedModifiers: KeyboardShortcutModifiers = []
    @State private var selectedKeyID: VirtualKey.ID?
    @State private var selectedCommandID: KeyboardShortcutCommand.ID? = KeyboardShortcutCommand.renderSelected.id
    @State private var search = ""
    @State private var category: KeyboardShortcutCategory?
    @State private var filter = AssignmentFilter.all
    @State private var status: Status?
    @State private var pendingReassignment: Assignment?
    @State private var pendingDiscard: PresetAction?
    @State private var namePrompt: NamePrompt?
    @State private var proposedName = ""
    @State private var confirmDelete = false

    private var profile: KeyboardShortcutProfile { registry.selectedProfile }
    private var layer: KeyboardShortcutModifiers { recorder.heldModifiers.isEmpty ? clickedModifiers : recorder.heldModifiers }
    private var selectedKey: VirtualKey? { layout.key(id: selectedKeyID) }
    private var selectedCommand: KeyboardShortcutCommand? {
        get { selectedCommandID.flatMap(KeyboardShortcutCommand.init(rawValue:)) }
        nonmutating set { selectedCommandID = newValue?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetBar
            VirtualKeyboardView(
                layout: layout, commands: profile.commandsByChord, layer: layer,
                selectedKeyID: selectedKeyID, highlightedKeyIDs: highlightedKeyIDs,
                reservedTitle: reservedTitle, summary: keySummary,
                select: { selectedKeyID = $0.id },
                toggleModifier: { clickedModifiers.formSymmetricDifference($0) },
                drop: dropCommand
            )
            .frame(maxWidth: .infinity)
            legend
            HStack(alignment: .top, spacing: 14) {
                commandList
                KeyDetailView(
                    key: selectedKey, profile: profile, layer: layer, selectedCommand: selectedCommand,
                    reservedTitle: reservedTitle, reservedDetail: reservedDetail,
                    assign: { chord in selectedCommand.map { assign(chord, to: $0, slot: nil) } },
                    remove: { chord in remove(chord) },
                    selectCommand: { selectedCommand = $0 }
                )
                .frame(width: 320)
            }
            statusLine
        }
        .padding(20)
        .frame(minWidth: 1020, idealWidth: 1060, minHeight: 800, idealHeight: 840)
        .accessibilityIdentifier("shortcuts.editor")
        .onAppear {
            recorder.install()
            recorder.record = { chord, target in assign(chord, to: target.command, slot: target.slot) }
        }
        .onDisappear { recorder.uninstall() }
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        )) { _ in
            layout = .current()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == KeyboardShortcutUserPreset.fileExtension }) else { return false }
            importPreset(from: url)
            return true
        }
        .confirmationDialog(
            pendingReassignment.map { "\($0.chord.displayName) is assigned to \($0.current.displayName)." } ?? "",
            isPresented: Binding(get: { pendingReassignment != nil }, set: { if !$0 { pendingReassignment = nil } }),
            presenting: pendingReassignment
        ) { pending in
            Button("Reassign to \(pending.command.displayName)") {
                if let error = registry.reassign(pending.chord, to: pending.command, slot: pending.slot) {
                    status = .error(error)
                } else {
                    status = .info("\(pending.chord.displayName) now runs \(pending.command.displayName); \(pending.current.displayName) no longer has it.")
                    selectedKeyID = layout.key(for: pending.chord)?.id ?? selectedKeyID
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Reassigning removes the shortcut from \(pending.current.displayName).")
        }
        .confirmationDialog(
            "Discard the changes to “\(registry.activePresetName)”?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            presenting: pendingDiscard
        ) { action in
            Button("Discard Changes", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your current shortcuts have not been saved to a preset. Use Save As to keep them.")
        }
        .confirmationDialog("Delete the preset “\(registry.activePresetName)”?", isPresented: $confirmDelete) {
            Button("Delete Preset", role: .destructive) {
                let name = registry.activePresetName
                registry.deletePreset(named: name)
                status = .info("Deleted “\(name)”. Your current shortcuts are unchanged.")
            }
        } message: {
            Text("The current shortcuts stay as they are. Exported copies of the preset are not affected.")
        }
        .alert(
            namePrompt?.title ?? "",
            isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } }),
            presenting: namePrompt
        ) { prompt in
            TextField("Preset name", text: $proposedName)
            Button(prompt == .rename ? "Rename" : "Save") { submitName(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt == .rename ? "Enter a new name for this preset." : "Save the current shortcuts as a new preset.")
        }
    }

    // MARK: Presets

    private var presetBar: some View {
        HStack(spacing: 10) {
            Text("Preset").foregroundStyle(.secondary)
            Picker("Preset", selection: Binding(get: { registry.activePresetName }, set: { name in
                guard name != registry.activePresetName else { return }
                confirmingDiscard(.switchTo(name))
            })) {
                ForEach(KeyboardShortcutPreset.allCases) { Text($0.displayName).tag($0.displayName) }
                if !registry.presets.isEmpty { Divider() }
                ForEach(registry.presets) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 240)
            .accessibilityIdentifier("settings.shortcuts.profile")
            if registry.isModified {
                Text("Modified")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .help("The shortcuts differ from the saved preset.")
            }
            Spacer()
            Button("Save") {
                if let error = registry.savePreset(named: registry.activePresetName) { status = .error(error) }
                else { status = .info("Saved “\(registry.activePresetName)”.") }
            }
            .disabled(registry.isBuiltInPresetActive || !registry.isModified)
            .help(registry.isBuiltInPresetActive ? "Built-in presets cannot be changed; use Save As." : "Save the changes to this preset.")
            Button("Save As…") { prompt(.saveAs) }
            Divider().frame(height: 18)
            Button("Import…", action: chooseImport)
                .help("Add a preset from a .\(KeyboardShortcutUserPreset.fileExtension) file. You can also drop the file on this window.")
            Button("Export…", action: export)
                .help("Save the current shortcuts as a .\(KeyboardShortcutUserPreset.fileExtension) file to share.")
            if let data = try? registry.currentPreset.fileData() {
                ShareLink(
                    item: KeyboardShortcutPresetShareItem(name: registry.activePresetName, data: data),
                    preview: SharePreview(registry.activePresetName, image: Image(systemName: "keyboard"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share the current shortcuts as a preset file.")
            }
            Menu {
                Button("Rename…") { prompt(.rename) }.disabled(registry.isBuiltInPresetActive)
                Button("Delete…") { confirmDelete = true }.disabled(registry.isBuiltInPresetActive)
                Divider()
                Button("Revert to Saved Preset") { confirmingDiscard(.switchTo(registry.activePresetName)) }
                    .disabled(!registry.isModified)
                Button("Reset to Photo Agent Defaults") {
                    confirmingDiscard(.switchTo(KeyboardShortcutPreset.photoAgent.displayName))
                }
                .disabled(registry.activePresetName == KeyboardShortcutPreset.photoAgent.displayName && !registry.isModified)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More preset actions")
        }
    }

    private enum PresetAction { case switchTo(String), importPreset(KeyboardShortcutUserPreset) }

    private enum NamePrompt: Equatable {
        case saveAs, rename
        var title: String { self == .saveAs ? "Save Preset As" : "Rename Preset" }
    }

    private func confirmingDiscard(_ action: PresetAction) {
        if registry.isModified { pendingDiscard = action } else { perform(action) }
    }

    private func perform(_ action: PresetAction) {
        switch action {
        case let .switchTo(name):
            let rejected = registry.applyPreset(named: name)
            status = .info("Switched to “\(name)”." + Self.skippedNote(rejected))
        case let .importPreset(preset):
            let result = registry.importPreset(preset)
            status = .info("Imported “\(result.name)”." + Self.skippedNote(result.rejected))
        }
    }

    private static func skippedNote(_ rejected: Int) -> String {
        rejected == 0 ? "" : " \(rejected) shortcut\(rejected == 1 ? " was" : "s were") skipped because they are reserved or duplicated."
    }

    private func prompt(_ prompt: NamePrompt) {
        proposedName = prompt == .rename || !registry.isBuiltInPresetActive ? registry.activePresetName : "My Shortcuts"
        if prompt == .saveAs, registry.presetNames.contains(proposedName) { proposedName += " Copy" }
        namePrompt = prompt
    }

    private func submitName(_ prompt: NamePrompt) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt {
        case .saveAs:
            if name != registry.activePresetName, registry.preset(named: name) != nil {
                status = .error("A preset named “\(name)” already exists. Choose it and use Save, or pick another name.")
            } else if let error = registry.savePreset(named: name) {
                status = .error(error)
            } else {
                status = .info("Saved “\(name)”.")
            }
        case .rename:
            let oldName = registry.activePresetName
            if let error = registry.renamePreset(oldName, to: name) { status = .error(error) }
            else { status = .info("Renamed “\(oldName)” to “\(name)”.") }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Keyboard Preset"
        panel.allowedContentTypes = [.photoAgentKeyboardPreset, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importPreset(from: url)
    }

    private func importPreset(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // A preset lists about a hundred shortcuts; anything far larger is not one.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            status = .error("Could not import \(url.lastPathComponent): the file is too large to be a keyboard preset.")
            return
        }
        do { confirmingDiscard(.importPreset(try KeyboardShortcutUserPreset(fileData: Data(contentsOf: url)))) }
        catch { status = .error("Could not import \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Keyboard Preset"
        panel.nameFieldStringValue = KeyboardShortcutPresetShareItem.fileName(for: registry.activePresetName)
        panel.allowedContentTypes = [.photoAgentKeyboardPreset]
        panel.message = "Anyone with Photo Agent can import this file in the Keyboard Shortcuts window."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try registry.currentPreset.fileData().write(to: url, options: .atomic)
            status = .info("Exported \(url.lastPathComponent).")
        } catch { status = .error("Could not export the preset: \(error.localizedDescription)") }
    }

    // MARK: Keyboard

    /// Keys holding any shortcut of the selected command, in any modifier layer.
    private var highlightedKeyIDs: Set<VirtualKey.ID> {
        guard let selectedCommand else { return [] }
        return Set(profile.chords(for: selectedCommand).compactMap { layout.key(for: $0)?.id })
    }

    /// What owns a chord no command may use: Caption advance, macOS, text entry or a workspace gesture.
    private func reservedTitle(_ chord: KeyboardShortcutChord) -> String? {
        if let caption = CaptionAdvanceShortcutCommand.allCases.first(where: { captionRegistry.chord(for: $0) == chord }) {
            return caption.displayName
        }
        if profile.hasDevelopForwardDeleteFallback(for: chord) { return "Remove Layer" }
        return KeyboardShortcutProfiles.reservedTitle(for: chord)
    }

    private func reservedDetail(_ chord: KeyboardShortcutChord) -> String? {
        if let caption = CaptionAdvanceShortcutCommand.allCases.first(where: { captionRegistry.chord(for: $0) == chord }) {
            return "Caption Workspace: \(caption.displayName) (change in Settings › Shortcuts)"
        }
        if profile.hasDevelopForwardDeleteFallback(for: chord) {
            return "Develop: Remove or Reset Selected Edit Layer (assigning this key overrides it)"
        }
        return KeyboardShortcutProfiles.reservation(for: chord)
    }

    private func keySummary(_ key: VirtualKey) -> String {
        let lines = key.chords.compactMap { entry -> String? in
            if let command = profile.command(for: entry.chord) {
                return "\(entry.chord.displayName)  \(command.displayName)" + developNote(command, entry.chord)
            }
            return nil
        }
        return ([key.name] + (lines.isEmpty ? ["No shortcuts"] : lines)).joined(separator: "\n")
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: 14) {
            FlowLayout(spacing: 12) {
                ForEach(KeyboardShortcutCategory.allCases) { category in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                        Text(category.title)
                    }
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)).frame(width: 10, height: 10)
                    Text("Reserved")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(layer.isEmpty ? "Showing keys without modifiers" : "Showing \(layer.symbols) shortcuts")
                    .foregroundStyle(layer.isEmpty ? Color.secondary : Color.accentColor)
                Text(layout.inputSourceName).foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .font(.caption)
    }

    private func dropCommand(_ command: KeyboardShortcutCommand, on key: VirtualKey) -> Bool {
        guard let chord = key.chord(with: layer) else { return false }
        selectedKeyID = key.id
        selectedCommand = command
        assign(chord, to: command, slot: nil)
        return true
    }

    // MARK: Commands

    private enum AssignmentFilter: String, CaseIterable, Identifiable {
        case all = "All", assigned = "Assigned", unassigned = "Unassigned", changed = "Changed"
        var id: String { rawValue }
    }

    private var filteredCommands: [KeyboardShortcutCommand] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let saved = filter == .changed ? registry.savedProfile(named: registry.activePresetName)?.profile : nil
        let categoryOrder = KeyboardShortcutCategory.allCases
        return KeyboardShortcutCommand.allCases.filter { command in
            let chords = profile.chords(for: command)
            if let category, command.category != category { return false }
            switch filter {
            case .all: break
            case .assigned: if chords.isEmpty { return false }
            case .unassigned: if !chords.isEmpty { return false }
            case .changed: if chords == saved?.chords(for: command) { return false }
            }
            guard !words.isEmpty else { return true }
            let culling = command.isCulling ? "culling" : ""
            let text = ([command.displayName, command.category.title, culling] + chords.map(\.searchText))
                .joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        .sorted {
            let order = (categoryOrder.firstIndex(of: $0.category)!, categoryOrder.firstIndex(of: $1.category)!)
            return order.0 != order.1 ? order.0 < order.1 : (KeyboardShortcutCommand.allCases.firstIndex(of: $0)!) < (KeyboardShortcutCommand.allCases.firstIndex(of: $1)!)
        }
    }

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search", text: $search, prompt: Text("Search commands or shortcuts, such as “render” or “cmd s”"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
                    .accessibilityIdentifier("settings.shortcuts.search")
                Picker("Category", selection: $category) {
                    Text("All Categories").tag(KeyboardShortcutCategory?.none)
                    Divider()
                    ForEach(KeyboardShortcutCategory.allCases) { Text($0.title).tag(KeyboardShortcutCategory?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Show", selection: $filter) {
                    ForEach(AssignmentFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Table(of: KeyboardShortcutCommand.self, selection: $selectedCommandID) {
                TableColumn("Command") { command in
                    HStack(spacing: 6) {
                        Circle().fill(command.category.color).frame(width: 7, height: 7)
                        Text(command.displayName)
                    }
                    .help("\(command.displayName) · \(command.category.title). Drag onto a key to assign it.")
                }
                TableColumn("Shortcut") { command in shortcutField(command, slot: 0) }.width(140)
                TableColumn("Alternate") { command in shortcutField(command, slot: 1) }.width(140)
            } rows: {
                ForEach(filteredCommands) { command in
                    TableRow(command).draggable(command.rawValue)
                }
            }
            .frame(minHeight: 260)
        }
    }

    private func shortcutField(_ command: KeyboardShortcutCommand, slot: Int) -> some View {
        let target = ShortcutRecorder.Target(command: command, slot: slot)
        let chord = profile.chord(for: command, slot: slot)
        // The alternate field waits for the first, since a command's shortcuts stay in order.
        let available = slot < profile.chords(for: command).count + 1
        return ShortcutField(
            chord: chord, isRecording: recorder.target == target, heldModifiers: recorder.heldModifiers,
            isAvailable: available,
            toggle: {
                selectedCommand = command
                recorder.toggle(target)
                if recorder.target != nil {
                    status = .info("Press the new shortcut for \(command.displayName). Click the field again or press Escape to cancel.")
                }
            },
            clear: { chord.map(remove) }
        )
    }

    // MARK: Assigning

    private struct Assignment {
        let chord: KeyboardShortcutChord
        let command: KeyboardShortcutCommand
        let slot: Int
        let current: KeyboardShortcutCommand
    }

    /// Assigns after checking for reserved keys and conflicts. Without a slot, the chord
    /// fills the command's free slot, or replaces its alternate.
    private func assign(_ chord: KeyboardShortcutChord, to command: KeyboardShortcutCommand, slot: Int?) {
        if profile.chords(for: command).contains(chord) {
            status = .info("\(chord.displayName) already runs \(command.displayName).")
            return
        }
        let slot = slot ?? min(profile.chords(for: command).count, KeyboardShortcutProfile.slotCount - 1)
        if KeyboardShortcutProfiles.validationError(chord, for: command) == nil,
           let current = profile.conflict(for: chord, command: command, slot: slot), current != command {
            pendingReassignment = Assignment(chord: chord, command: command, slot: slot, current: current)
            return
        }
        if let error = registry.set(chord, for: command, slot: slot) {
            status = .error("\(chord.displayName): \(error)")
        } else {
            status = .info("\(command.displayName): \(profile.chords(for: command).map(\.displayName).joined(separator: " or ")).")
            selectedKeyID = layout.key(for: chord)?.id ?? selectedKeyID
        }
    }

    private func remove(_ chord: KeyboardShortcutChord) {
        guard let found = profile.assignment(of: chord) else { return }
        registry.remove(chord)
        status = .info("Removed \(chord.displayName) from \(found.command.displayName).")
    }

    // MARK: Status

    private enum Status {
        case info(String), error(String)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch status {
            case let .error(text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(text).foregroundStyle(.red)
            case let .info(text):
                Text(text).foregroundStyle(.secondary)
            case nil:
                Text("Click a shortcut field and press keys to record, or drag a command onto a key. Click or hold ⌘ ⌥ ⌃ ⇧ to see other layers. Each command can have two shortcuts; menus show the first.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("settings.shortcuts.status")
    }
}

/// The note shown beside a chord that Develop also uses for its own gesture.
private func developNote(_ command: KeyboardShortcutCommand, _ chord: KeyboardShortcutChord) -> String {
    guard command.hasDevelopContextOverride(for: chord) else { return "" }
    return command == .duplicateSelected ? " (Develop: hold to mute the selected layer)" : " (Develop: paste with crop)"
}

nonisolated extension KeyboardShortcutCommand: Identifiable {
    var id: String { rawValue }
}

extension KeyboardShortcutCategory {
    var color: Color {
        switch self {
        case .ratingAndLabel: .orange
        case .file: .brown
        case .browser: .teal
        case .image: .blue
        case .metadata: .indigo
        case .templates: .green
        case .develop: .purple
        case .export: .red
        case .view: .pink
        case .scopes: .cyan
        case .upload: .gray
        }
    }
}

/// Records the next key press for a command's shortcut, and tracks held modifiers so
/// the on-screen keyboard can show that layer.
@MainActor
final class ShortcutRecorder: ObservableObject {
    struct Target: Equatable {
        let command: KeyboardShortcutCommand
        let slot: Int
    }

    @Published private(set) var target: Target? {
        didSet { KeyboardShortcutAlternateDispatcher.isSuspended = target != nil }
    }
    @Published private(set) var heldModifiers: KeyboardShortcutModifiers = []
    var record: ((KeyboardShortcutChord, Target) -> Void)?
    private var monitors: [Any] = []
    private weak var window: NSWindow?

    func toggle(_ newTarget: Target) {
        target = target == newTarget ? nil : newTarget
        window = NSApp.keyWindow
    }

    func install() {
        guard monitors.isEmpty else { return }
        // Recording takes every key in the editor's window, including ones menus would
        // otherwise handle, so that reserved chords can be explained rather than run.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let target = self.target, event.window === self.window else { return false }
                if event.isARepeat { return true }
                self.target = nil
                // Escape cancels; it is reserved for every command anyway.
                if event.keyCode != 53, let chord = KeyboardShortcutChord(event: event) { self.record?(chord, target) }
                return true
            }
            return consumed ? nil : event
        }
        let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.heldModifiers = KeyboardShortcutModifiers(event.modifierFlags) }
            return event
        }
        monitors = [keyMonitor, flagsMonitor].compactMap { $0 }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        target = nil
        heldModifiers = []
    }
}

private struct ShortcutField: View {
    let chord: KeyboardShortcutChord?
    let isRecording: Bool
    let heldModifiers: KeyboardShortcutModifiers
    let isAvailable: Bool
    let toggle: () -> Void
    let clear: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: toggle) {
                Text(isRecording ? (heldModifiers.isEmpty ? "Type shortcut…" : heldModifiers.symbols + "…") : chord?.displayName ?? "—")
                    .font(chord == nil || isRecording ? .callout : .callout.monospaced())
                    .foregroundStyle(isRecording ? Color.accentColor : chord == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(
                        isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(hovering ? 0.15 : 0.07)
                    ))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isRecording ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .help(isRecording ? "Press keys to record. Click again or press Escape to cancel." : "Click, then press the shortcut to record it.")
            .accessibilityLabel(chord.map { "Shortcut \($0.displayName). Record new shortcut" } ?? "No shortcut. Record shortcut")
            Button(action: clear) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(chord == nil || isRecording ? 0 : 1)
                .disabled(chord == nil || isRecording)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove shortcut")
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - On-screen keyboard

private struct VirtualKeyboardView: View {
    let layout: VirtualKeyboardLayout
    let commands: [KeyboardShortcutChord: KeyboardShortcutCommand]
    let layer: KeyboardShortcutModifiers
    let selectedKeyID: VirtualKey.ID?
    let highlightedKeyIDs: Set<VirtualKey.ID>
    let reservedTitle: (KeyboardShortcutChord) -> String?
    let summary: (VirtualKey) -> String
    let select: (VirtualKey) -> Void
    let toggleModifier: (KeyboardShortcutModifiers) -> Void
    let drop: (KeyboardShortcutCommand, VirtualKey) -> Bool
    static let unit: CGFloat = 48
    static let gap: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: Self.unit / 2) {
            rows(layout.mainRows)
            rows(layout.navigationRows)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.shortcuts.keyboardPreview")
    }

    private func rows(_ rows: [[VirtualKey]]) -> some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: Self.gap) {
                    ForEach(row) { key in
                        cap(key).frame(width: key.width * Self.unit - Self.gap, height: index == 0 ? 28 : 44)
                    }
                }
            }
        }
    }

    @ViewBuilder private func cap(_ key: VirtualKey) -> some View {
        switch key.role {
        case .spacer:
            Color.clear
        case let .modifier(modifier):
            Button { toggleModifier(modifier) } label: {
                KeyCapView(key: key, command: nil, reserved: nil, otherLayers: [], isSelected: false, isHighlighted: false,
                           isActiveModifier: layer.contains(modifier))
            }
            .buttonStyle(.plain)
            .help("Show shortcuts that use \(key.label)")
            .accessibilityLabel("Show shortcuts that use \(key.label)")
            .accessibilityAddTraits(layer.contains(modifier) ? .isSelected : [])
        case .inert:
            KeyCapView(key: key, command: nil, reserved: nil, otherLayers: [], isSelected: false, isHighlighted: false, isActiveModifier: false)
                .opacity(0.5)
                .accessibilityHidden(true)
        case .key:
            let chord = key.chord(with: layer)
            let command = chord.flatMap { commands[$0] }
            let others = key.chords.filter { $0.chord != chord }.compactMap { commands[$0.chord] }
            Button { select(key) } label: {
                KeyCapView(key: key, command: command, reserved: command == nil ? chord.flatMap(reservedTitle) : nil,
                           otherLayers: others, isSelected: selectedKeyID == key.id,
                           isHighlighted: highlightedKeyIDs.contains(key.id), isActiveModifier: false)
            }
            .buttonStyle(.plain)
            .help(summary(key))
            .accessibilityLabel("\(key.name) key" + (command.map { ", \($0.displayName)" } ?? ""))
            .dropDestination(for: String.self) { items, _ in
                guard let command = items.lazy.compactMap(KeyboardShortcutCommand.init(rawValue:)).first else { return false }
                return drop(command, key)
            }
        }
    }
}

private struct KeyCapView: View {
    let key: VirtualKey
    let command: KeyboardShortcutCommand?
    let reserved: String?
    /// Commands on this key under other modifier combinations.
    let otherLayers: [KeyboardShortcutCommand]
    let isSelected: Bool
    let isHighlighted: Bool
    let isActiveModifier: Bool
    @State private var hovering = false

    private var fill: Color {
        if isActiveModifier { return .accentColor }
        if let command { return command.category.color.opacity(hovering ? 1 : 0.82) }
        if reserved != nil { return Color.secondary.opacity(0.3) }
        return Color(nsColor: .controlBackgroundColor).opacity(hovering ? 0.7 : 1)
    }

    private var textColor: Color { isActiveModifier || command != nil ? .white : .primary }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 1)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    isSelected ? Color.accentColor : isHighlighted ? Color.primary.opacity(0.75) : Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: isSelected ? 2.5 : isHighlighted ? 1.5 : 0.5, dash: isHighlighted && !isSelected ? [3, 2] : [])
                )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 2) {
                    VStack(alignment: .leading, spacing: -1) {
                        if let shifted = key.shiftedLabel { Text(shifted).font(.system(size: 8)).opacity(0.7) }
                        Text(key.label).font(.system(size: key.label.count > 2 ? 9 : 11, weight: .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // One dot per command on this key under other modifiers.
                    HStack(spacing: 2) {
                        ForEach(Array(otherLayers.prefix(key.width > 1 ? 4 : 3).enumerated()), id: \.offset) { _, other in
                            Circle().fill(other.category.color).frame(width: 5, height: 5)
                                .overlay(Circle().strokeBorder(Color.white.opacity(command == nil ? 0 : 0.8), lineWidth: 0.5))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if let title = command?.shortTitle ?? reserved {
                    Text(title)
                        .font(.system(size: 8.5, weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .opacity(command == nil ? 0.7 : 1)
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Key details

/// Everything one key does, under each modifier combination.
private struct KeyDetailView: View {
    let key: VirtualKey?
    let profile: KeyboardShortcutProfile
    let layer: KeyboardShortcutModifiers
    let selectedCommand: KeyboardShortcutCommand?
    let reservedTitle: (KeyboardShortcutChord) -> String?
    let reservedDetail: (KeyboardShortcutChord) -> String?
    let assign: (KeyboardShortcutChord) -> Void
    let remove: (KeyboardShortcutChord) -> Void
    let selectCommand: (KeyboardShortcutCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key, case .key = key.role {
                HStack {
                    Text("\(key.name) Key").font(.headline)
                    Spacer()
                    let used = key.chords.filter { profile.command(for: $0.chord) != nil }.count
                    Text("\(used) of \(key.chords.count) used").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        let current = key.chord(with: layer)
                        ForEach(key.chords.map(\.chord), id: \.self) { chord in row(chord, inLayer: chord == current) }
                    }
                }
                if let selectedCommand, let chord = key.chord(with: layer), profile.assignment(of: chord) == nil,
                   KeyboardShortcutProfiles.validationError(chord, for: selectedCommand) == nil {
                    Button("Assign “\(selectedCommand.displayName)” to \(chord.displayName)") { assign(chord) }
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Key Details").font(.headline)
                Text("Click a key on the keyboard to see what it does with every combination of ⌃ ⌥ ⇧ ⌘.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private func row(_ chord: KeyboardShortcutChord, inLayer: Bool) -> some View {
        let command = profile.command(for: chord)
        return HStack(spacing: 8) {
            Text(chord.displayName)
                .font(.callout.monospaced())
                .frame(width: 84, alignment: .leading)
            if let command {
                Button { selectCommand(command) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(command.category.color).frame(width: 7, height: 7)
                        Text(command.displayName + developNote(command, chord)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(command.displayName) in the command list")
                Button { remove(chord) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove this shortcut")
                    .accessibilityLabel("Remove \(chord.displayName) from \(command.displayName)")
            } else if let reserved = reservedTitle(chord) {
                Text(reserved).foregroundStyle(.secondary).lineLimit(1)
                    .help(reservedDetail(chord) ?? reserved)
                Spacer(minLength: 0)
            } else {
                Text("Unassigned").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let selectedCommand, KeyboardShortcutProfiles.validationError(chord, for: selectedCommand) == nil {
                    Button { assign(chord) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Assign \(selectedCommand.displayName) to \(chord.displayName)")
                        .accessibilityLabel("Assign \(selectedCommand.displayName) to \(chord.displayName)")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(inLayer ? Color.accentColor.opacity(0.12) : .clear))
    }
}
