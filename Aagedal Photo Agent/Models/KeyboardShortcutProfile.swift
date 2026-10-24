import AppKit
import Foundation
import SwiftUI

nonisolated struct KeyboardShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: Self = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.shift) { value.insert(.shift) }
        self = value
    }

    init(_ modifiers: EventModifiers) {
        var value: Self = []
        if modifiers.contains(.command) { value.insert(.command) }
        if modifiers.contains(.option) { value.insert(.option) }
        if modifiers.contains(.control) { value.insert(.control) }
        if modifiers.contains(.shift) { value.insert(.shift) }
        self = value
    }

    var eventModifiers: EventModifiers {
        var value: EventModifiers = []
        if contains(.command) { value.insert(.command) }
        if contains(.option) { value.insert(.option) }
        if contains(.control) { value.insert(.control) }
        if contains(.shift) { value.insert(.shift) }
        return value
    }
}

nonisolated struct KeyboardShortcutChord: Codable, Hashable, Sendable {
    let key: String
    let modifiers: KeyboardShortcutModifiers

    init(key: String, modifiers: KeyboardShortcutModifiers = []) {
        switch key {
        case "\r", "\u{3}": self.key = "return"
        case "\u{7f}", "\u{8}": self.key = "delete"
        case "\u{f728}": self.key = "forwarddelete"
        default: self.key = key.lowercased()
        }
        self.modifiers = modifiers
    }

    @MainActor
    init?(event: NSEvent) {
        // Layout retranslations can turn Forward Delete into backward Delete.
        // These fixed hardware identities must survive normalization.
        switch event.keyCode {
        case 51: self.init(key: "delete", modifiers: KeyboardShortcutModifiers(event.modifierFlags)); return
        case 117: self.init(key: "forwarddelete", modifiers: KeyboardShortcutModifiers(event.modifierFlags)); return
        case 36, 76: self.init(key: "return", modifiers: KeyboardShortcutModifiers(event.modifierFlags)); return
        default: break
        }
        // Unlike charactersIgnoringModifiers, this also removes Shift and Caps Lock.
        // Keep modifier identity separate from the logical key on the active layout.
        guard let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
              !key.isEmpty else { return nil }
        self.init(key: key, modifiers: KeyboardShortcutModifiers(event.modifierFlags))
    }

    var displayName: String {
        let prefix = [
            modifiers.contains(.control) ? "⌃" : "",
            modifiers.contains(.option) ? "⌥" : "",
            modifiers.contains(.shift) ? "⇧" : "",
            modifiers.contains(.command) ? "⌘" : "",
        ].joined()
        return prefix + (key == "return" ? "↩" : key == "delete" ? "⌫" : key == "forwarddelete" ? "⌦" : key.uppercased())
    }
}

nonisolated enum KeyboardShortcutCommand: String, CaseIterable, Codable, Sendable {
    case clearRating
    case rateOne
    case rateTwo
    case rateThree
    case rateFour
    case rateFive
    case clearLabel
    case labelRed
    case labelYellow
    case labelGreen
    case labelBlue
    case labelPurple
    case labelWhite
    case labelBlack
    case labelTrash

    case openFolder
    case showImport
    case showWebImport
    case backupEditedFiles
    case renderSelected
    case advancedExportSelected
    case renderAll
    case saveAsJPEG
    case saveAsPNG
    case renameSelected
    case duplicateSelected
    case openInEditor
    case deleteSelected
    case moveRejectedToFolder
    case rotateClockwise
    case rotateCounterclockwise
    case addNewMask
    case removeOrResetSelectedEditLayer
    case resetAllEdits
    case removeAllIPTC
    case processVariablesSelected
    case processVariablesAll
    case writeAllPendingMetadata
    case showTemplatePalette
    case showVariableReference
    case showRawMetadata
    case showStructuredKeywords
    case renderAndSignSelected
    case copyIPTCMetadata
    case pasteIPTCMetadata
    case openCaptionWorkspace
    case selectPreviousImage
    case selectNextImage
    case toggleHDR
    case scopeWaveform
    case scopeParade
    case scopeVectorscope
    case scopeGamut
    case toggleGamutClipping
    case toggleCleanFeed
    case uploadSelected
    case uploadAll
    case templateOne
    case templateTwo
    case templateThree
    case templateFour
    case templateFive
    case templateSix
    case templateSeven
    case templateEight
    case templateNine

    var displayName: String {
        switch self {
        case .clearRating: "Clear rating"
        case .rateOne: "Rate 1 star"
        case .rateTwo: "Rate 2 stars"
        case .rateThree: "Rate 3 stars"
        case .rateFour: "Rate 4 stars"
        case .rateFive: "Rate 5 stars"
        case .clearLabel: "Clear color label"
        case .labelRed: "Set red label"
        case .labelYellow: "Set yellow label"
        case .labelGreen: "Set green label"
        case .labelBlue: "Set blue label"
        case .labelPurple: "Set purple label"
        case .labelWhite: "Set white label"
        case .labelBlack: "Set black label"
        case .labelTrash: "Set trash label"
        case .openFolder: "Open Folder"
        case .showImport: "Import Photos"
        case .showWebImport: "Import from Web URL"
        case .backupEditedFiles: "Back Up Edited Files"
        case .renderSelected: "Render Selected"
        case .advancedExportSelected: "Advanced Export Selected"
        case .renderAll: "Render All"
        case .saveAsJPEG: "Save as JPEG"
        case .saveAsPNG: "Save as PNG"
        case .renameSelected: "Rename"
        case .duplicateSelected: "Duplicate"
        case .openInEditor: "Open in Editor"
        case .deleteSelected: "Move to Trash"
        case .moveRejectedToFolder: "Move Rejected to Folder"
        case .rotateClockwise: "Rotate Right"
        case .rotateCounterclockwise: "Rotate Left"
        case .addNewMask: "Add New Mask"
        case .removeOrResetSelectedEditLayer: "Remove or Reset Selected Edit Layer"
        case .resetAllEdits: "Reset All Edits"
        case .removeAllIPTC: "Remove All IPTC Metadata"
        case .processVariablesSelected: "Process Variables"
        case .processVariablesAll: "Process Variables in All Images"
        case .writeAllPendingMetadata: "Write All Pending Metadata"
        case .showTemplatePalette: "Apply Template"
        case .showVariableReference: "Variable Reference"
        case .showRawMetadata: "Show Raw Metadata"
        case .showStructuredKeywords: "Structured Keywords"
        case .renderAndSignSelected: "Render and Sign Selected"
        case .copyIPTCMetadata: "Copy IPTC Metadata"
        case .pasteIPTCMetadata: "Paste IPTC Metadata"
        case .openCaptionWorkspace: "Caption Workspace"
        case .selectPreviousImage: "Previous Image"
        case .selectNextImage: "Next Image"
        case .toggleHDR: "Toggle HDR"
        case .scopeWaveform: "Waveform"
        case .scopeParade: "Parade"
        case .scopeVectorscope: "Vectorscope"
        case .scopeGamut: "Gamut"
        case .toggleGamutClipping: "Toggle Gamut Clipping"
        case .toggleCleanFeed: "Toggle Clean Feed"
        case .uploadSelected: "Upload Selected"
        case .uploadAll: "Upload All"
        case .templateOne: "Apply Template 1"
        case .templateTwo: "Apply Template 2"
        case .templateThree: "Apply Template 3"
        case .templateFour: "Apply Template 4"
        case .templateFive: "Apply Template 5"
        case .templateSix: "Apply Template 6"
        case .templateSeven: "Apply Template 7"
        case .templateEight: "Apply Template 8"
        case .templateNine: "Apply Template 9"
        }
    }

    var action: KeyboardCullingAction? {
        switch self {
        case .clearRating: .rating(0)
        case .rateOne: .rating(1)
        case .rateTwo: .rating(2)
        case .rateThree: .rating(3)
        case .rateFour: .rating(4)
        case .rateFive: .rating(5)
        case .clearLabel: .colorLabel(0)
        case .labelRed: .colorLabel(1)
        case .labelYellow: .colorLabel(2)
        case .labelGreen: .colorLabel(3)
        case .labelBlue: .colorLabel(4)
        case .labelPurple: .colorLabel(5)
        case .labelWhite: .colorLabel(6)
        case .labelBlack: .colorLabel(7)
        case .labelTrash: .colorLabel(8)
        default: nil
        }
    }

    var isCulling: Bool { action != nil }

    var category: String {
        switch self {
        case .openFolder: "File"
        case .showImport: "File"
        case .showWebImport: "File"
        case .backupEditedFiles: "File"
        case .renderSelected: "Export"
        case .advancedExportSelected: "Export"
        case .renderAll: "Export"
        case .saveAsJPEG: "Export"
        case .saveAsPNG: "Export"
        case .renameSelected: "Image"
        case .duplicateSelected: "Image"
        case .openInEditor: "Image"
        case .deleteSelected: "Image"
        case .moveRejectedToFolder: "Image"
        case .rotateClockwise: "Image"
        case .rotateCounterclockwise: "Image"
        case .addNewMask: "Develop"
        case .removeOrResetSelectedEditLayer: "Develop"
        case .resetAllEdits: "Develop"
        case .removeAllIPTC: "Metadata"
        case .processVariablesSelected: "Metadata"
        case .processVariablesAll: "Metadata"
        case .writeAllPendingMetadata: "Metadata"
        case .showTemplatePalette: "Metadata"
        case .showVariableReference: "Metadata"
        case .showRawMetadata: "Metadata"
        case .showStructuredKeywords: "Metadata"
        case .renderAndSignSelected: "Export"
        case .copyIPTCMetadata: "Metadata"
        case .pasteIPTCMetadata: "Metadata"
        case .openCaptionWorkspace: "Browser"
        case .selectPreviousImage: "Browser"
        case .selectNextImage: "Browser"
        case .toggleHDR: "View"
        case .scopeWaveform: "Scopes"
        case .scopeParade: "Scopes"
        case .scopeVectorscope: "Scopes"
        case .scopeGamut: "Scopes"
        case .toggleGamutClipping: "Scopes"
        case .toggleCleanFeed: "View"
        case .uploadSelected: "Upload"
        case .uploadAll: "Upload"
        case .templateOne: "Templates"
        case .templateTwo: "Templates"
        case .templateThree: "Templates"
        case .templateFour: "Templates"
        case .templateFive: "Templates"
        case .templateSix: "Templates"
        case .templateSeven: "Templates"
        case .templateEight: "Templates"
        case .templateNine: "Templates"
        default: "Rating & Label"
        }
    }

    var defaultChord: KeyboardShortcutChord? {
        switch self {
        case .openFolder: .init(key: "o", modifiers: .command)
        case .showImport: .init(key: "i", modifiers: [.command, .shift])
        case .renderSelected: .init(key: "s", modifiers: .command)
        case .renderAll: .init(key: "s", modifiers: [.command, .shift])
        case .duplicateSelected: .init(key: "d", modifiers: .command)
        case .openInEditor: .init(key: "e", modifiers: .command)
        case .deleteSelected: .init(key: "delete", modifiers: .command)
        case .rotateClockwise: .init(key: "r", modifiers: .command)
        case .rotateCounterclockwise: .init(key: "r", modifiers: [.command, .shift])
        case .addNewMask: .init(key: "j", modifiers: .command)
        case .removeOrResetSelectedEditLayer: .init(key: "delete", modifiers: [.control, .option])
        case .processVariablesSelected: .init(key: "p", modifiers: .command)
        case .processVariablesAll: .init(key: "p", modifiers: [.command, .shift])
        case .writeAllPendingMetadata: .init(key: "w", modifiers: [.command, .shift])
        case .showTemplatePalette: .init(key: "t", modifiers: .command)
        case .showVariableReference: .init(key: "v", modifiers: .option)
        case .showRawMetadata: .init(key: "i", modifiers: .command)
        case .showStructuredKeywords: .init(key: "k", modifiers: [.command, .shift])
        case .renderAndSignSelected: .init(key: "s", modifiers: [.command, .option])
        case .copyIPTCMetadata: .init(key: "c", modifiers: [.command, .option])
        case .pasteIPTCMetadata: .init(key: "v", modifiers: [.command, .option])
        case .openCaptionWorkspace: .init(key: "m", modifiers: [.command, .shift])
        case .selectPreviousImage: .init(key: "b", modifiers: .command)
        case .selectNextImage: .init(key: "n", modifiers: .command)
        case .toggleHDR: .init(key: "h", modifiers: [.control, .option])
        case .scopeWaveform: .init(key: "1", modifiers: [.control, .option])
        case .scopeParade: .init(key: "2", modifiers: [.control, .option])
        case .scopeVectorscope: .init(key: "3", modifiers: [.control, .option])
        case .scopeGamut: .init(key: "4", modifiers: [.control, .option])
        case .toggleGamutClipping: .init(key: "g", modifiers: [.control, .option])
        case .toggleCleanFeed: .init(key: "f", modifiers: [.command, .shift])
        case .uploadSelected: .init(key: "u", modifiers: .command)
        case .uploadAll: .init(key: "u", modifiers: [.command, .shift])
        case .templateOne: .init(key: "1", modifiers: .control)
        case .templateTwo: .init(key: "2", modifiers: .control)
        case .templateThree: .init(key: "3", modifiers: .control)
        case .templateFour: .init(key: "4", modifiers: .control)
        case .templateFive: .init(key: "5", modifiers: .control)
        case .templateSix: .init(key: "6", modifiers: .control)
        case .templateSeven: .init(key: "7", modifiers: .control)
        case .templateEight: .init(key: "8", modifiers: .control)
        case .templateNine: .init(key: "9", modifiers: .control)
        default: nil
        }
    }

    static func templateCommand(slot: Int) -> Self? {
        let commands: [Self] = [.templateOne, .templateTwo, .templateThree, .templateFour, .templateFive, .templateSix, .templateSeven, .templateEight, .templateNine]
        return (1...commands.count).contains(slot) ? commands[slot - 1] : nil
    }

    /// Preserve the existing Develop hold/paste behavior only at its original chord.
    func hasDevelopContextOverride(for chord: KeyboardShortcutChord) -> Bool {
        (self == .duplicateSelected && chord == .init(key: "d", modifiers: .command))
            || (self == .showVariableReference && chord == .init(key: "v", modifiers: .option))
    }
}

nonisolated enum KeyboardCullingAction: Equatable, Sendable {
    case rating(Int)
    case colorLabel(Int)
}

nonisolated struct KeyboardShortcutBinding: Codable, Equatable, Sendable {
    let command: KeyboardShortcutCommand
    let chord: KeyboardShortcutChord
}

nonisolated struct KeyboardShortcutConflict: Equatable, Sendable {
    let chord: KeyboardShortcutChord
    let commands: [KeyboardShortcutCommand]
}

nonisolated struct KeyboardShortcutProfile: Codable, Equatable, Sendable {
    let name: String
    var bindings: [KeyboardShortcutBinding]

    func command(for chord: KeyboardShortcutChord) -> KeyboardShortcutCommand? {
        let matches = Set(bindings.lazy.filter { $0.chord == chord }.map(\.command))
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    func chord(for command: KeyboardShortcutCommand) -> KeyboardShortcutChord? {
        bindings.first { $0.command == command }?.chord
    }

    var conflicts: [KeyboardShortcutConflict] {
        Dictionary(grouping: bindings, by: \.chord)
            .compactMap { chord, bindings in
                let commands = Array(Set(bindings.map(\.command))).sorted { $0.rawValue < $1.rawValue }
                guard commands.count > 1 else { return nil }
                return KeyboardShortcutConflict(chord: chord, commands: commands)
            }
            .sorted { lhs, rhs in
                if lhs.chord.displayName != rhs.chord.displayName {
                    return lhs.chord.displayName < rhs.chord.displayName
                }
                return lhs.commands.map(\.rawValue).joined() < rhs.commands.map(\.rawValue).joined()
            }
    }
}

nonisolated enum KeyboardShortcutPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case photoAgent
    case photoMechanicLike
    case bridgeLike
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photoAgent: "Photo Agent"
        case .photoMechanicLike: "Photo Mechanic-like"
        case .bridgeLike: "Bridge-like"
        case .custom: "Custom"
        }
    }
}

nonisolated enum KeyboardShortcutProfiles {
    static let applicationBindings: [KeyboardShortcutBinding] = KeyboardShortcutCommand.allCases.compactMap { command in
        guard !command.isCulling, let chord = command.defaultChord else { return nil }
        return KeyboardShortcutBinding(command: command, chord: chord)
    }

    static let editableChordChoices: [KeyboardShortcutChord] = {
        let bare = ((0...9).map(String.init) + ["s", "x"]).map { KeyboardShortcutChord(key: $0) }
        let keys = Array("abcdefghijklmnopqrstuvwxyz0123456789").map(String.init) + ["delete", "forwarddelete"]
        let commandChords = (0..<16).map(KeyboardShortcutModifiers.init(rawValue:))
            .filter { $0.contains(.command) }
            .flatMap { modifiers in keys.map { KeyboardShortcutChord(key: $0, modifiers: modifiers) } }
            .filter { reservation(for: $0) == nil }
        let legacy = applicationBindings.map(\.chord)
        let controlOption = keys.map { KeyboardShortcutChord(key: $0, modifiers: [.control, .option]) }
        return Array(Set(bare + commandChords + controlOption + legacy)).sorted { $0.displayName < $1.displayName }
    }()

    /// System text editing, window controls and fixed workspace navigation keep their keys.
    static func reservation(for chord: KeyboardShortcutChord) -> String? {
        let modifiers = chord.modifiers
        if chord.key == "return" { return "Reserved for text entry and Caption advance shortcuts" }
        if modifiers.contains(.command) {
            if chord.key == "q" { return "Reserved for Quit and macOS session controls" }
            if modifiers == .command && ["a", "c", "x", "v", "z", "w", "h", "m", "f"].contains(chord.key) {
                return "Reserved for text editing, window controls or full screen"
            }
            if modifiers == [.command, .shift] && ["z", "v"].contains(chord.key) {
                return "Reserved for Redo and Develop paste with crop"
            }
            if modifiers == [.command, .option] && ["w", "h", "m"].contains(chord.key) {
                return "Reserved for macOS window controls"
            }
        }
        return nil
    }

    static func canAssign(_ chord: KeyboardShortcutChord, to command: KeyboardShortcutCommand) -> Bool {
        guard editableChordChoices.contains(chord) else { return false }
        // Menu commands must not consume ordinary typing. Culling's bare-key input is focus-aware.
        if command.isCulling {
            return chord.key.count == 1 && (chord.modifiers.isEmpty || chord.modifiers.contains(.command))
        }
        return !chord.modifiers.isEmpty
    }

    static func profile(for preset: KeyboardShortcutPreset) -> KeyboardShortcutProfile {
        switch preset {
        case .photoAgent:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoAgentBindings + applicationBindings)
        case .photoMechanicLike:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoMechanicLikeBindings + applicationBindings)
        case .bridgeLike:
            KeyboardShortcutProfile(name: preset.displayName, bindings: bridgeLikeBindings + applicationBindings)
        case .custom:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoAgentBindings + applicationBindings)
        }
    }

    private static let ratingCommands: [KeyboardShortcutCommand] = [
        .clearRating, .rateOne, .rateTwo, .rateThree, .rateFour, .rateFive,
    ]
    private static let labelCommands: [KeyboardShortcutCommand] = [
        .clearLabel, .labelRed, .labelYellow, .labelGreen, .labelBlue,
        .labelPurple, .labelWhite, .labelBlack, .labelTrash,
    ]

    private static let photoAgentBindings: [KeyboardShortcutBinding] = {
        var bindings = ratingCommands.enumerated().map {
            KeyboardShortcutBinding(command: $0.element, chord: .init(key: String($0.offset)))
        }
        bindings += [
            KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "6")),
            KeyboardShortcutBinding(command: .labelYellow, chord: .init(key: "7")),
            KeyboardShortcutBinding(command: .labelGreen, chord: .init(key: "8")),
            KeyboardShortcutBinding(command: .labelBlue, chord: .init(key: "9")),
            KeyboardShortcutBinding(command: .labelRed, chord: .init(key: "s")),
            KeyboardShortcutBinding(command: .labelTrash, chord: .init(key: "x")),
        ]
        bindings += labelCommands.enumerated().map {
            KeyboardShortcutBinding(command: $0.element,
                chord: .init(key: String($0.offset), modifiers: .command))
        }
        return bindings
    }()

    private static let photoMechanicLikeBindings: [KeyboardShortcutBinding] = {
        var bindings = ratingCommands.enumerated().map {
            KeyboardShortcutBinding(command: $0.element, chord: .init(key: String($0.offset)))
        }
        bindings += labelCommands.enumerated().map {
            KeyboardShortcutBinding(
                command: $0.element,
                chord: .init(key: String($0.offset), modifiers: .command)
            )
        }
        return bindings
    }()

    private static let bridgeLikeBindings: [KeyboardShortcutBinding] = {
        var bindings = ratingCommands.enumerated().map {
            KeyboardShortcutBinding(
                command: $0.element,
                chord: .init(key: String($0.offset), modifiers: .command)
            )
        }
        bindings += labelCommands.enumerated().map {
            KeyboardShortcutBinding(
                command: $0.element,
                chord: .init(key: String($0.offset), modifiers: [.command, .option])
            )
        }
        return bindings
    }()
}

nonisolated struct KeyboardShortcutRouteInput: Equatable, Sendable {
    let key: String
    let modifiers: KeyboardShortcutModifiers
    let textEditorOwnsInput: Bool
    let imeHasMarkedText: Bool
    let isRepeat: Bool
}

nonisolated enum KeyboardShortcutRouter {
    static func resolve(
        _ input: KeyboardShortcutRouteInput,
        profile: KeyboardShortcutProfile
    ) -> KeyboardCullingAction? {
        guard !input.textEditorOwnsInput,
              !input.imeHasMarkedText,
              !input.isRepeat,
              input.key.count == 1 else { return nil }
        return profile.command(for: KeyboardShortcutChord(
            key: input.key,
            modifiers: input.modifiers
        ))?.action
    }
}

@MainActor
@Observable
final class KeyboardShortcutProfileRegistry {
    static let shared = KeyboardShortcutProfileRegistry()

    private struct Document: Codable {
        var schemaVersion = 2
        var selectedPreset: KeyboardShortcutPreset
        var customBindings: [KeyboardShortcutBinding]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var selectedPreset: KeyboardShortcutPreset
    private(set) var customBindings: [KeyboardShortcutBinding]

    init(
        defaults: UserDefaults = AppDefaults.store,
        storageKey: String = "keyboardShortcutProfile.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let document = try? JSONDecoder().decode(Document.self, from: data),
           (1...2).contains(document.schemaVersion) {
            selectedPreset = document.selectedPreset
            customBindings = document.customBindings
            if document.schemaVersion == 1 {
                let occupied = Set(customBindings.map(\.chord))
                customBindings += KeyboardShortcutProfiles.applicationBindings.filter { !occupied.contains($0.chord) }
            }
        } else {
            selectedPreset = .photoAgent
            customBindings = KeyboardShortcutProfiles.profile(for: .photoAgent).bindings
        }
    }

    var selectedProfile: KeyboardShortcutProfile {
        if selectedPreset == .custom {
            return KeyboardShortcutProfile(name: KeyboardShortcutPreset.custom.displayName, bindings: customBindings)
        }
        return KeyboardShortcutProfiles.profile(for: selectedPreset)
    }

    func select(_ preset: KeyboardShortcutPreset) {
        selectedPreset = preset
        persist()
    }

    func assign(_ chord: KeyboardShortcutChord, to command: KeyboardShortcutCommand) {
        if selectedPreset != .custom {
            customBindings = selectedProfile.bindings
            selectedPreset = .custom
        }
        customBindings.removeAll { $0.command == command }
        customBindings.append(KeyboardShortcutBinding(command: command, chord: chord))
        customBindings.sort { $0.command.rawValue < $1.command.rawValue }
        persist()
    }

    /// Refuse occupied chords until the editor explicitly confirms reassignment.
    /// Existing aliases remain available when adding another shortcut.
    @discardableResult
    func reassign(
        _ chord: KeyboardShortcutChord,
        to command: KeyboardShortcutCommand,
        replacingConflicts: Bool = false
    ) -> Bool {
        guard KeyboardShortcutProfiles.canAssign(chord, to: command) else { return false }
        let occupied = selectedProfile.bindings.contains { $0.chord == chord && $0.command != command }
        guard !occupied || replacingConflicts else { return false }
        if selectedPreset != .custom {
            customBindings = selectedProfile.bindings
            selectedPreset = .custom
        }
        // App menus have one key equivalent per command. Culling retains alternate keys,
        // routed by the focus-aware workspaces as well as the native menu.
        customBindings.removeAll { $0.chord == chord || (!command.isCulling && $0.command == command) }
        customBindings.append(KeyboardShortcutBinding(command: command, chord: chord))
        persist()
        return true
    }

    func remove(_ chord: KeyboardShortcutChord, from command: KeyboardShortcutCommand) {
        if selectedPreset != .custom {
            customBindings = selectedProfile.bindings
            selectedPreset = .custom
        }
        customBindings.removeAll { $0.command == command && $0.chord == chord }
        persist()
    }

    func unassign(_ command: KeyboardShortcutCommand) {
        if selectedPreset != .custom {
            customBindings = selectedProfile.bindings
            selectedPreset = .custom
        }
        customBindings.removeAll { $0.command == command }
        persist()
    }

    func resolveConflictsKeepingFirstCommand() {
        if selectedPreset != .custom {
            customBindings = selectedProfile.bindings
            selectedPreset = .custom
        }
        let conflictingChords = Set(selectedProfile.conflicts.map(\.chord))
        for chord in conflictingChords {
            let commands = customBindings
                .filter { $0.chord == chord }
                .map(\.command)
                .sorted { $0.rawValue < $1.rawValue }
            for command in commands.dropFirst() {
                customBindings.removeAll { $0.command == command && $0.chord == chord }
            }
        }
        persist()
    }

    func resetCustom() {
        customBindings = KeyboardShortcutProfiles.profile(for: .photoAgent).bindings
        selectedPreset = .custom
        persist()
    }

    private func persist() {
        let document = Document(
            selectedPreset: selectedPreset,
            customBindings: customBindings
        )
        if let data = try? JSONEncoder().encode(document) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

nonisolated enum CaptionAdvanceShortcutCommand: String, CaseIterable, Codable, Sendable {
    case saveAndNext
    case writeAndNext

    var displayName: String {
        switch self {
        case .saveAndNext: "Save & Next"
        case .writeAndNext: "Write & Next"
        }
    }
}

nonisolated enum CaptionAdvanceShortcutRouter {
    static func resolve(
        _ input: KeyboardShortcutRouteInput,
        bindings: [CaptionAdvanceShortcutCommand: KeyboardShortcutChord]
    ) -> CaptionAdvanceShortcutCommand? {
        guard !input.imeHasMarkedText, !input.isRepeat else { return nil }
        let chord = KeyboardShortcutChord(key: input.key, modifiers: input.modifiers)
        let matches = bindings.filter { $0.value == chord }.map(\.key)
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Caption advance commands are stored separately from culling profiles because they remain
/// active while a text field owns focus. Assignment is conflict-preventing: giving one command a
/// chord atomically unassigns that chord from the other command.
@MainActor
@Observable
final class CaptionAdvanceShortcutRegistry {
    static let shared = CaptionAdvanceShortcutRegistry()

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var bindings: [CaptionAdvanceShortcutCommand: KeyboardShortcutChord]

    static let editableChordChoices: [KeyboardShortcutChord] = [
        KeyboardShortcutChord(key: "return", modifiers: .control),
        KeyboardShortcutChord(key: "return", modifiers: [.control, .option]),
        KeyboardShortcutChord(key: "return", modifiers: [.command, .option]),
        KeyboardShortcutChord(key: "return", modifiers: [.command, .shift]),
    ]

    init(
        defaults: UserDefaults = AppDefaults.store,
        storageKey: String = "captionAdvanceShortcuts.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               [CaptionAdvanceShortcutCommand: KeyboardShortcutChord].self,
               from: data
           ) {
            bindings = Self.sanitized(decoded)
        } else {
            bindings = [
                .saveAndNext: KeyboardShortcutChord(key: "return", modifiers: .control),
                .writeAndNext: KeyboardShortcutChord(
                    key: "return",
                    modifiers: [.control, .option]
                ),
            ]
        }
    }

    func chord(for command: CaptionAdvanceShortcutCommand) -> KeyboardShortcutChord? {
        bindings[command]
    }

    func assign(_ chord: KeyboardShortcutChord, to command: CaptionAdvanceShortcutCommand) {
        for other in CaptionAdvanceShortcutCommand.allCases where other != command {
            if bindings[other] == chord { bindings[other] = nil }
        }
        bindings[command] = chord
        persist()
    }

    func unassign(_ command: CaptionAdvanceShortcutCommand) {
        bindings[command] = nil
        persist()
    }

    private static func sanitized(
        _ decoded: [CaptionAdvanceShortcutCommand: KeyboardShortcutChord]
    ) -> [CaptionAdvanceShortcutCommand: KeyboardShortcutChord] {
        var seen = Set<KeyboardShortcutChord>()
        var result: [CaptionAdvanceShortcutCommand: KeyboardShortcutChord] = [:]
        for command in CaptionAdvanceShortcutCommand.allCases {
            guard let chord = decoded[command], seen.insert(chord).inserted else { continue }
            result[command] = chord
        }
        return result
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

@MainActor
func keyboardTextInputState(in window: NSWindow?) -> (
    textEditorOwnsInput: Bool,
    imeHasMarkedText: Bool
) {
    guard let responder = window?.firstResponder else { return (false, false) }
    let client = responder as? NSTextInputClient
    return (
        responder is NSText || responder is NSTextView || client != nil,
        client?.hasMarkedText() ?? false
    )
}


extension KeyboardShortcutProfile {
    /// Menu equivalents must remain safe during text entry. Bare culling keys stay
    /// with the focus-aware browser router; only unambiguous Command chords reach menus.
    nonisolated func menuChord(for action: KeyboardCullingAction) -> KeyboardShortcutChord? {
        bindings.first { binding in
            binding.command.action == action && binding.chord.modifiers.contains(.command)
                && binding.chord.key.count == 1 && command(for: binding.chord) == binding.command
        }?.chord
    }
}


extension KeyboardShortcutChord {
    nonisolated var swiftUIShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "delete": equivalent = .delete
        case "forwarddelete": equivalent = .deleteForward
        case "return": equivalent = .return
        default:
            guard key.count == 1, let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        return KeyboardShortcut(equivalent, modifiers: modifiers.eventModifiers)
    }

}

extension KeyboardShortcutProfile {
    nonisolated func menuChord(for command: KeyboardShortcutCommand) -> KeyboardShortcutChord? {
        guard !command.isCulling else { return nil }
        return bindings.first { binding in
            binding.command == command && !binding.chord.modifiers.isEmpty
                && self.command(for: binding.chord) == command
        }?.chord
    }
}


extension KeyboardShortcutProfile {
    /// This is a Develop-only compatibility gesture, superseded by any explicit binding.
    nonisolated func hasDevelopForwardDeleteFallback(for chord: KeyboardShortcutChord) -> Bool {
        chord.key == "forwarddelete" && !bindings.contains { $0.chord == chord }
            && command(for: .init(key: "delete", modifiers: chord.modifiers)) == .removeOrResetSelectedEditLayer
    }
}


extension KeyboardShortcutProfile {
    nonisolated func menuShortcut(for command: KeyboardShortcutCommand?) -> KeyboardShortcut? {
        command.flatMap { menuChord(for: $0)?.swiftUIShortcut }
    }
}

extension KeyboardShortcutProfileRegistry {
    /// A template slot's chord in the active profile; users can rebind the default ⌃1–⌃9.
    func templateShortcutDisplayName(slot: Int) -> String {
        KeyboardShortcutCommand.templateCommand(slot: slot)
            .flatMap { selectedProfile.menuChord(for: $0) }?.displayName ?? "Slot \(slot) (no shortcut)"
    }
}
