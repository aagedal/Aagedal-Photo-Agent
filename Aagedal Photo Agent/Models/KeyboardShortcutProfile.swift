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

    /// All sixteen combinations, fewest modifiers first.
    static let allCombinations = (0..<16).map(Self.init(rawValue:))
        .sorted { ($0.rawValue.nonzeroBitCount, $0.rawValue) < ($1.rawValue.nonzeroBitCount, $1.rawValue) }

    /// In the order macOS menus show them.
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

nonisolated struct KeyboardShortcutChord: Codable, Hashable, Sendable {
    let key: String
    let modifiers: KeyboardShortcutModifiers

    /// Keys known by name rather than by the character they type.
    static let navigationKeys = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
    static let functionKeys = (1...12).map { "f\($0)" }
    static let namedKeys = navigationKeys + functionKeys + ["delete", "forwarddelete", "return", "escape", "space", "tab"]

    /// macOS virtual key codes of the keys that have names rather than characters.
    static let keyCodeNames: [UInt16: String] = [
        51: "delete", 117: "forwarddelete", 36: "return", 76: "return", 53: "escape", 49: "space", 48: "tab",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12",
    ]

    init(key: String, modifiers: KeyboardShortcutModifiers = []) {
        switch key {
        case "\r", "\u{3}": self.key = "return"
        case "\u{7f}", "\u{8}": self.key = "delete"
        case "\u{f728}": self.key = "forwarddelete"
        case "\u{1b}": self.key = "escape"
        case " ": self.key = "space"
        case "\t", "\u{19}": self.key = "tab"
        default: self.key = key.lowercased()
        }
        self.modifiers = modifiers
    }

    @MainActor
    init?(event: NSEvent) {
        // Layout retranslations can turn Forward Delete into backward Delete, and named
        // keys type private-use characters. These fixed hardware identities must survive
        // normalization.
        if let name = Self.keyCodeNames[event.keyCode] {
            self.init(key: name, modifiers: KeyboardShortcutModifiers(event.modifierFlags))
            return
        }
        // Unlike charactersIgnoringModifiers, this also removes Shift and Caps Lock.
        // Keep modifier identity separate from the logical key on the active layout.
        guard let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
              !key.isEmpty else { return nil }
        self.init(key: key, modifiers: KeyboardShortcutModifiers(event.modifierFlags))
    }

    var isFunctionKey: Bool { Self.functionKeys.contains(key) }
    var isNamedKey: Bool { Self.namedKeys.contains(key) }

    /// A single typed character, such as "k", "1", "ø" or ",".
    var isCharacterKey: Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
                && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    /// Menus compare their key equivalent with the character a key types, so Shift with a
    /// digit or punctuation (⇧⌘[ types "{") never matches. Letters have capitals that do.
    var menuCanMatch: Bool {
        !(modifiers.contains(.shift) && isCharacterKey && key.uppercased() == key)
    }

    /// Files and stored data bypass the initializer; normalize as a key press would.
    var normalizedFromStorage: KeyboardShortcutChord {
        KeyboardShortcutChord(key: key, modifiers: modifiers.intersection([.command, .option, .control, .shift]))
    }

    var keyLabel: String {
        [
            "return": "↩", "delete": "⌫", "forwarddelete": "⌦", "escape": "⎋", "space": "Space", "tab": "⇥",
            "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        ][key] ?? key.uppercased()
    }

    var displayName: String { modifiers.symbols + keyLabel }

    /// Words a search for this shortcut may use, such as "cmd shift b".
    var searchText: String {
        let words = [
            modifiers.contains(.control) ? "control ctrl" : "",
            modifiers.contains(.option) ? "option opt alt" : "",
            modifiers.contains(.shift) ? "shift" : "",
            modifiers.contains(.command) ? "command cmd" : "",
        ]
        return (words + [key, displayName]).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
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
    case newBrowserTab
    case showNextBrowserTab
    case showPreviousBrowserTab
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
        case .newBrowserTab: "New Tab"
        case .showNextBrowserTab: "Show Next Tab"
        case .showPreviousBrowserTab: "Show Previous Tab"
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

    var category: KeyboardShortcutCategory {
        switch self {
        case .openFolder: .file
        case .showImport: .file
        case .showWebImport: .file
        case .backupEditedFiles: .file
        case .renderSelected: .export
        case .advancedExportSelected: .export
        case .renderAll: .export
        case .saveAsJPEG: .export
        case .saveAsPNG: .export
        case .renameSelected: .image
        case .duplicateSelected: .image
        case .openInEditor: .image
        case .deleteSelected: .image
        case .moveRejectedToFolder: .image
        case .rotateClockwise: .image
        case .rotateCounterclockwise: .image
        case .addNewMask: .develop
        case .removeOrResetSelectedEditLayer: .develop
        case .resetAllEdits: .develop
        case .removeAllIPTC: .metadata
        case .processVariablesSelected: .metadata
        case .processVariablesAll: .metadata
        case .writeAllPendingMetadata: .metadata
        case .showTemplatePalette: .metadata
        case .showVariableReference: .metadata
        case .showRawMetadata: .metadata
        case .showStructuredKeywords: .metadata
        case .renderAndSignSelected: .export
        case .copyIPTCMetadata: .metadata
        case .pasteIPTCMetadata: .metadata
        case .openCaptionWorkspace: .browser
        case .selectPreviousImage: .browser
        case .selectNextImage: .browser
        case .toggleHDR: .view
        case .scopeWaveform: .scopes
        case .scopeParade: .scopes
        case .scopeVectorscope: .scopes
        case .scopeGamut: .scopes
        case .toggleGamutClipping: .scopes
        case .toggleCleanFeed: .view
        case .uploadSelected: .upload
        case .uploadAll: .upload
        case .newBrowserTab: .browser
        case .showNextBrowserTab: .browser
        case .showPreviousBrowserTab: .browser
        case .templateOne: .templates
        case .templateTwo: .templates
        case .templateThree: .templates
        case .templateFour: .templates
        case .templateFive: .templates
        case .templateSix: .templates
        case .templateSeven: .templates
        case .templateEight: .templates
        case .templateNine: .templates
        default: .ratingAndLabel
        }
    }

    /// A few words that fit on a key of the shortcut editor's keyboard.
    var shortTitle: String {
        switch self {
        case .clearRating: "No Stars"
        case .rateOne: "★"
        case .rateTwo: "★★"
        case .rateThree: "★★★"
        case .rateFour: "★★★★"
        case .rateFive: "★★★★★"
        case .clearLabel: "No Label"
        case .labelRed: "Red"
        case .labelYellow: "Yellow"
        case .labelGreen: "Green"
        case .labelBlue: "Blue"
        case .labelPurple: "Purple"
        case .labelWhite: "White"
        case .labelBlack: "Black"
        case .labelTrash: "Trash Label"
        case .openFolder: "Open"
        case .showImport: "Import"
        case .showWebImport: "Web Import"
        case .backupEditedFiles: "Back Up"
        case .renderSelected: "Render"
        case .advancedExportSelected: "Adv. Export"
        case .renderAll: "Render All"
        case .saveAsJPEG: "JPEG"
        case .saveAsPNG: "PNG"
        case .renameSelected: "Rename"
        case .duplicateSelected: "Duplicate"
        case .openInEditor: "Editor"
        case .deleteSelected: "Trash"
        case .moveRejectedToFolder: "Move Rejects"
        case .rotateClockwise: "Rotate ↻"
        case .rotateCounterclockwise: "Rotate ↺"
        case .addNewMask: "New Mask"
        case .removeOrResetSelectedEditLayer: "Remove Layer"
        case .resetAllEdits: "Reset Edits"
        case .removeAllIPTC: "Strip IPTC"
        case .processVariablesSelected: "Variables"
        case .processVariablesAll: "Variables All"
        case .writeAllPendingMetadata: "Write Pending"
        case .showTemplatePalette: "Templates"
        case .showVariableReference: "Var. Reference"
        case .showRawMetadata: "Raw Metadata"
        case .showStructuredKeywords: "Keywords"
        case .renderAndSignSelected: "Render & Sign"
        case .copyIPTCMetadata: "Copy IPTC"
        case .pasteIPTCMetadata: "Paste IPTC"
        case .openCaptionWorkspace: "Captions"
        case .selectPreviousImage: "Prev Image"
        case .selectNextImage: "Next Image"
        case .toggleHDR: "HDR"
        case .scopeWaveform: "Waveform"
        case .scopeParade: "Parade"
        case .scopeVectorscope: "Vectorscope"
        case .scopeGamut: "Gamut"
        case .toggleGamutClipping: "Gamut Clip"
        case .toggleCleanFeed: "Clean Feed"
        case .uploadSelected: "Upload"
        case .uploadAll: "Upload All"
        case .newBrowserTab: "New Tab"
        case .showNextBrowserTab: "Next Tab"
        case .showPreviousBrowserTab: "Prev Tab"
        case .templateOne: "Template 1"
        case .templateTwo: "Template 2"
        case .templateThree: "Template 3"
        case .templateFour: "Template 4"
        case .templateFive: "Template 5"
        case .templateSix: "Template 6"
        case .templateSeven: "Template 7"
        case .templateEight: "Template 8"
        case .templateNine: "Template 9"
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
        // ⌘T is Apply Template. Tabs mirror Previous/Next Image (⌘B/⌘N) with ⌥: Safari's
        // ⇧⌘[ / ⇧⌘] aren't used because menus match the shifted character ("}") and brackets
        // need ⌥ on many layouts (Norwegian among them).
        case .newBrowserTab: .init(key: "t", modifiers: [.command, .option])
        case .showNextBrowserTab: .init(key: "n", modifiers: [.command, .option])
        case .showPreviousBrowserTab: .init(key: "b", modifiers: [.command, .option])
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

/// Groups commands in the shortcut editor's list and colours them on its keyboard.
nonisolated enum KeyboardShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case ratingAndLabel, file, browser, image, metadata, templates, develop, export, view, scopes, upload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ratingAndLabel: "Rating & Label"
        case .file: "File"
        case .browser: "Browser"
        case .image: "Image"
        case .metadata: "Metadata"
        case .templates: "Templates"
        case .develop: "Develop"
        case .export: "Export"
        case .view: "View"
        case .scopes: "Scopes"
        case .upload: "Upload"
        }
    }
}

nonisolated enum KeyboardCullingAction: Equatable, Sendable {
    case rating(Int)
    case colorLabel(Int)
}

nonisolated struct KeyboardShortcutBinding: Codable, Hashable, Sendable {
    let command: KeyboardShortcutCommand
    let chord: KeyboardShortcutChord
}

nonisolated struct KeyboardShortcutConflict: Equatable, Sendable {
    let chord: KeyboardShortcutChord
    let commands: [KeyboardShortcutCommand]
}

/// Every command's shortcuts, up to two each and in order. The first menu-safe one is the
/// key the menu shows; the focus-aware routers accept any of them. A command's shortcuts stay
/// compact, so clearing the first promotes the second.
nonisolated struct KeyboardShortcutProfile: Codable, Equatable, Sendable {
    static let slotCount = 2

    var name: String
    var bindings: [KeyboardShortcutBinding]

    func command(for chord: KeyboardShortcutChord) -> KeyboardShortcutCommand? {
        let matches = Set(bindings.lazy.filter { $0.chord == chord }.map(\.command))
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    func chord(for command: KeyboardShortcutCommand) -> KeyboardShortcutChord? {
        bindings.first { $0.command == command }?.chord
    }

    func chords(for command: KeyboardShortcutCommand) -> [KeyboardShortcutChord] {
        bindings.filter { $0.command == command }.map(\.chord)
    }

    func chord(for command: KeyboardShortcutCommand, slot: Int) -> KeyboardShortcutChord? {
        let list = chords(for: command)
        return list.indices.contains(slot) ? list[slot] : nil
    }

    /// The command that runs a chord, and which of that command's shortcuts it is.
    func assignment(of chord: KeyboardShortcutChord) -> (command: KeyboardShortcutCommand, slot: Int)? {
        guard let command = bindings.first(where: { $0.chord == chord })?.command,
              let slot = chords(for: command).firstIndex(of: chord) else { return nil }
        return (command, slot)
    }

    /// The command each chord runs, for lookups across a whole keyboard. Like
    /// `command(for:)`, a chord that two commands share runs neither and is left out.
    var commandsByChord: [KeyboardShortcutChord: KeyboardShortcutCommand] {
        var result: [KeyboardShortcutChord: KeyboardShortcutCommand] = [:]
        var shared: Set<KeyboardShortcutChord> = []
        for binding in bindings {
            if let existing = result[binding.chord], existing != binding.command { shared.insert(binding.chord) }
            result[binding.chord] = binding.command
        }
        for chord in shared { result[chord] = nil }
        return result
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

    /// The other command (or this command's other slot) that already uses `chord`.
    func conflict(
        for chord: KeyboardShortcutChord,
        command: KeyboardShortcutCommand,
        slot: Int
    ) -> KeyboardShortcutCommand? {
        guard let found = assignment(of: chord) else { return nil }
        return found.command == command && found.slot == min(slot, chords(for: command).count) ? nil : found.command
    }

    /// Why `chord` cannot be the command's shortcut in `slot`, including conflicts.
    func validationError(
        _ chord: KeyboardShortcutChord,
        for command: KeyboardShortcutCommand,
        slot: Int = 0
    ) -> String? {
        guard (0..<Self.slotCount).contains(slot) else { return "Each command has a shortcut and an alternate." }
        if let error = KeyboardShortcutProfiles.validationError(chord, for: command) { return error }
        if let other = conflict(for: chord, command: command, slot: slot) {
            return other == command ? "Already this command’s other shortcut." : "Already assigned to \(other.displayName)."
        }
        return nil
    }

    /// Sets one shortcut without validation. `nil` clears the slot, and a slot past the
    /// command's last shortcut adds one.
    mutating func set(_ chord: KeyboardShortcutChord?, for command: KeyboardShortcutCommand, slot: Int) {
        var list = chords(for: command)
        if list.indices.contains(slot) {
            if let chord { list[slot] = chord } else { list.remove(at: slot) }
        } else if let chord {
            list.append(chord)
        }
        // Keep a command's bindings together where they were, so profiles stay readable.
        let position = bindings.firstIndex { $0.command == command } ?? bindings.endIndex
        bindings.removeAll { $0.command == command }
        bindings.insert(
            contentsOf: list.prefix(Self.slotCount).map { KeyboardShortcutBinding(command: command, chord: $0) },
            at: min(position, bindings.endIndex)
        )
    }

    /// Removes a shortcut from whichever command has it.
    mutating func unassign(_ chord: KeyboardShortcutChord) {
        guard let found = assignment(of: chord) else { return }
        set(nil, for: found.command, slot: found.slot)
    }

    /// Every command's shortcuts by command name, unbound commands included.
    var savedForm: [String: [KeyboardShortcutChord]] {
        var saved = Dictionary(uniqueKeysWithValues: KeyboardShortcutCommand.allCases.map { ($0.rawValue, [KeyboardShortcutChord]()) })
        for binding in bindings { saved[binding.command.rawValue, default: []].append(binding.chord) }
        return saved
    }

    /// Rebuilds a profile from saved choices. Commands absent from `saved` (such as ones added
    /// since it was written) take their `defaults` unless a saved choice already uses them;
    /// saved shortcuts that are invalid, surplus or already in use are left out and counted.
    static func restoring(
        _ saved: [String: [KeyboardShortcutChord]],
        name: String,
        defaults: KeyboardShortcutProfile
    ) -> (profile: KeyboardShortcutProfile, rejected: Int) {
        var profile = KeyboardShortcutProfile(name: name, bindings: [])
        var rejected = 0
        for command in KeyboardShortcutCommand.allCases {
            for stored in saved[command.rawValue] ?? [] {
                let chord = stored.normalizedFromStorage
                let slot = profile.chords(for: command).count
                if slot < slotCount, profile.validationError(chord, for: command, slot: slot) == nil {
                    profile.set(chord, for: command, slot: slot)
                } else {
                    rejected += 1
                }
            }
        }
        // New or changed defaults must not erase a custom map: a command whose default is
        // already in use stays unbound.
        for command in KeyboardShortcutCommand.allCases where saved[command.rawValue] == nil {
            for chord in defaults.chords(for: command) where profile.assignment(of: chord) == nil {
                profile.set(chord, for: command, slot: profile.chords(for: command).count)
            }
        }
        return (profile, rejected)
    }
}

nonisolated enum KeyboardShortcutPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case photoAgent
    case photoMechanicLike
    case bridgeLike

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photoAgent: "Photo Agent"
        case .photoMechanicLike: "Photo Mechanic-like"
        case .bridgeLike: "Bridge-like"
        }
    }

    static func named(_ name: String) -> Self? { allCases.first { $0.displayName == name } }
}

nonisolated enum KeyboardShortcutProfiles {
    static let applicationBindings: [KeyboardShortcutBinding] = KeyboardShortcutCommand.allCases.compactMap { command in
        guard !command.isCulling, let chord = command.defaultChord else { return nil }
        return KeyboardShortcutBinding(command: command, chord: chord)
    }

    /// Chords the built-in profiles ship with. They stay assignable to their own command
    /// even when they predate the editor's rules (Option-V for Variable Reference).
    private static let builtInBindings: Set<KeyboardShortcutBinding> = Set(
        KeyboardShortcutPreset.allCases.flatMap { profile(for: $0).bindings }
    )

    /// Single-letter gestures that Develop, Full Screen and Comparison handle before any
    /// profile lookup, as (short keycap title, explanation).
    static let workspaceGestures: [String: (title: String, detail: String)] = [
        "c": ("Crop / Compare", "Develop toggles crop; Full Screen opens Comparison"),
        "j": ("Radial Mask", "Develop adds a radial mask"),
        "b": ("Brush", "Develop toggles the brush tool"),
        "z": ("Zoom", "Develop and Full Screen toggle zoom"),
        "m": ("Before / After", "Develop shows the original while held"),
        "d": ("Disable Edits", "Develop hides adjustments while held"),
        "h": ("Hide UI", "Full Screen hides the interface"),
        "f": ("Faces", "Full Screen shows face rectangles"),
        "e": ("Edits", "Full Screen toggles edit rendering"),
    ]

    /// Why no command may use this chord: macOS, text entry, window controls and fixed
    /// workspace gestures keep their keys.
    static func reservation(for chord: KeyboardShortcutChord) -> String? {
        reservationEntry(for: chord)?.detail
    }

    /// A few words naming what owns a reserved chord, for the shortcut editor's keyboard.
    static func reservedTitle(for chord: KeyboardShortcutChord) -> String? {
        reservationEntry(for: chord)?.title
    }

    private static func reservationEntry(for chord: KeyboardShortcutChord) -> (title: String, detail: String)? {
        let modifiers = chord.modifiers
        let key = chord.key
        let withoutShift = modifiers.subtracting(.shift)
        switch key {
        case "return":
            return ("Return", "Reserved for text entry and Caption advance shortcuts")
        case "space":
            return withoutShift.isEmpty
                ? ("Full Screen / Pan", "Reserved for Full Screen and the Develop hand tool")
                : ("Input / Spotlight", "Reserved for macOS input sources and Spotlight")
        case "tab":
            return ("Focus", "Reserved for keyboard focus, app switching and Comparison")
        case "escape":
            return ("Cancel", "Reserved for cancelling and leaving workspaces")
        case _ where KeyboardShortcutChord.navigationKeys.contains(key):
            if withoutShift.isEmpty { return ("Navigate", "Reserved for moving and extending the selection") }
            if withoutShift.contains(.control) && withoutShift.subtracting(.control).isEmpty {
                return ("Spaces", "Reserved for macOS Spaces and Mission Control")
            }
            if !withoutShift.contains(.control) && withoutShift.rawValue.nonzeroBitCount == 1 {
                return ("Text Navigation", "Reserved for moving the insertion point in text")
            }
        case "delete", "forwarddelete":
            if withoutShift.isEmpty || modifiers == .option {
                return ("Delete", "Reserved for deleting text and the focused Comparison photo")
            }
        case "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8":
            if modifiers == .control {
                return ("Keyboard Navigation", "Reserved for macOS keyboard navigation, such as ⌃F2 for the menu bar")
            }
            if key == "f5", modifiers == .command || modifiers == [.command, .option] {
                return ("VoiceOver", "Reserved for VoiceOver and Accessibility Shortcuts")
            }
        case "f11":
            if modifiers.isEmpty { return ("Show Desktop", "Reserved for macOS Show Desktop") }
        default:
            break
        }
        if modifiers.contains(.command) {
            if key == "q" { return ("Quit", "Reserved for Quit and macOS session controls") }
            if modifiers == .command {
                let standard = ["a": "Select All", "c": "Copy", "x": "Cut", "v": "Paste", "z": "Undo",
                                "w": "Close", "h": "Hide", "m": "Minimize", "f": "Full Screen", ",": "Settings", "`": "Next Window"]
                if let title = standard[key] {
                    return (title, "Reserved for text editing, window controls or full screen")
                }
            }
            if modifiers == [.command, .shift] {
                if key == "z" { return ("Redo", "Reserved for Redo") }
                if key == "v" { return ("Paste + Crop", "Reserved for Develop paste with crop") }
                if ["3", "4", "5"].contains(key) { return ("Screenshot", "Reserved for macOS screenshots") }
            }
            // Help is ⌘? on every layout: Shift-/ on U.S. keyboards, Shift-+ on Norwegian ones.
            if key == "?" || (["/", "+"].contains(key) && modifiers == [.command, .shift]) {
                return ("Help", "Reserved for the Help menu")
            }
            if modifiers == [.command, .option] {
                if ["w", "h", "m"].contains(key) { return ("Window", "Reserved for macOS window controls") }
                if key == "d" { return ("Dock", "Reserved for showing and hiding the Dock") }
                if key == "k" { return ("Shortcuts", "Opens the keyboard shortcut editor") }
            }
            if modifiers == [.command, .control] && ["f", "q"].contains(key) {
                return ("System", "Reserved for macOS full screen and Lock Screen")
            }
        }
        if withoutShift == .control, chord.isCharacterKey, key.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
            return ("Text Editing", "Reserved for Control-key text editing, such as ⌃A and ⌃E")
        }
        if withoutShift.isEmpty, let gesture = workspaceGestures[key] {
            return (gesture.title, "Reserved for a workspace gesture: \(gesture.detail)")
        }
        if modifiers == .option {
            if key == "s" { return ("Scaling", "Reserved for Full Screen’s scaling filter") }
            if key == "m" { return ("Embedded / XMP", "Reserved for switching the embedded and XMP reference") }
        }
        return nil
    }

    /// Why `chord` cannot run `command`, apart from conflicts with other commands.
    static func validationError(_ chord: KeyboardShortcutChord, for command: KeyboardShortcutCommand) -> String? {
        if let reservation = reservation(for: chord) { return reservation }
        if builtInBindings.contains(KeyboardShortcutBinding(command: command, chord: chord)) { return nil }
        guard chord.isCharacterKey || chord.isNamedKey else {
            return "Use a letter, digit, punctuation, F1–F12 or a named key."
        }
        if chord.isFunctionKey { return nil }
        // The culling routers match the typed character, so named keys never reach them.
        if command.isCulling, !chord.isCharacterKey {
            return "Ratings and labels use a letter, digit, punctuation or F1–F12 key."
        }
        // Bare culling keys are focus-aware: the routers skip them while text is being typed.
        if command.isCulling, chord.isCharacterKey, chord.modifiers.isSubset(of: .shift) { return nil }
        guard chord.modifiers.contains(.command) || chord.modifiers.contains(.control) else {
            return command.isCulling
                ? "Use a key on its own or with Shift, Command or Control. Option alone types special characters."
                : "Include Command or Control so the shortcut never interrupts typing."
        }
        return nil
    }

    static func canAssign(_ chord: KeyboardShortcutChord, to command: KeyboardShortcutCommand) -> Bool {
        validationError(chord, for: command) == nil
    }

    static func profile(for preset: KeyboardShortcutPreset) -> KeyboardShortcutProfile {
        switch preset {
        case .photoAgent:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoAgentBindings + applicationBindings)
        case .photoMechanicLike:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoMechanicLikeBindings + applicationBindings)
        case .bridgeLike:
            KeyboardShortcutProfile(name: preset.displayName, bindings: bridgeLikeBindings + applicationBindings)
        }
    }

    private static let ratingCommands: [KeyboardShortcutCommand] = [
        .clearRating, .rateOne, .rateTwo, .rateThree, .rateFour, .rateFive,
    ]
    private static let labelCommands: [KeyboardShortcutCommand] = [
        .clearLabel, .labelRed, .labelYellow, .labelGreen, .labelBlue,
        .labelPurple, .labelWhite, .labelBlack, .labelTrash,
    ]

    /// Ratings on bare 0–5, labels on bare 6–9 and X, and every label on Command-0 to 8 in
    /// the menu. Each command has at most two keys, the bare one first.
    private static let photoAgentBindings: [KeyboardShortcutBinding] = {
        var bindings = ratingCommands.enumerated().map {
            KeyboardShortcutBinding(command: $0.element, chord: .init(key: String($0.offset)))
        }
        let bare: [KeyboardShortcutCommand: String] = [
            .labelRed: "6", .labelYellow: "7", .labelGreen: "8", .labelBlue: "9", .labelTrash: "x",
        ]
        for (index, command) in labelCommands.enumerated() {
            if let key = bare[command] {
                bindings.append(KeyboardShortcutBinding(command: command, chord: .init(key: key)))
            }
            bindings.append(KeyboardShortcutBinding(command: command, chord: .init(key: String(index), modifiers: .command)))
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
              input.key.count == 1 || KeyboardShortcutChord.functionKeys.contains(input.key) else { return nil }
        return profile.command(for: KeyboardShortcutChord(
            key: input.key,
            modifiers: input.modifiers
        ))?.action
    }
}

/// The live keymap plus named presets. The built-in presets are read-only; the current
/// shortcuts may differ from the active preset ("Modified") until saved or reverted.
@MainActor
@Observable
final class KeyboardShortcutProfileRegistry {
    static let shared = KeyboardShortcutProfileRegistry()

    private struct Document: Codable {
        var schemaVersion = 3
        var activePresetName: String
        var current: [String: [KeyboardShortcutChord]]
        var presets: [KeyboardShortcutUserPreset]
    }

    /// Schema 1 and 2: one editable "custom" list beside fixed presets.
    private struct LegacyDocument: Codable {
        var schemaVersion: Int
        var selectedPreset: String
        var customBindings: [KeyboardShortcutBinding]
    }

    private static let defaultPresetName = KeyboardShortcutPreset.photoAgent.displayName
    private static let migratedPresetName = "Custom"

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var selectedProfile: KeyboardShortcutProfile
    private(set) var activePresetName: String
    private(set) var presets: [KeyboardShortcutUserPreset]
    /// Saved shortcuts this version could not use (now reserved or duplicated) when the
    /// shortcuts were loaded, so the editor can say they were left out. Loading saves the
    /// shortcuts without them, and the note lasts until the shortcuts next change.
    private(set) var skippedOnLoad = 0
    /// The preset whose saved shortcuts lost `skippedOnLoad`.
    private var skippedOnLoadPreset = ""

    var skippedOnLoadNote: String? {
        guard skippedOnLoad > 0 else { return nil }
        let one = skippedOnLoad == 1
        return "\(skippedOnLoad) shortcut\(one ? "" : "s") saved in “\(skippedOnLoadPreset)” \(one ? "was" : "were") left out because this version reserves or already uses \(one ? "it" : "them")."
    }

    /// Presets resolved once rather than on every `isModified` read; an entry is reused only
    /// while its source preset is unchanged.
    private struct ResolvedPreset {
        let source: KeyboardShortcutUserPreset?
        let profile: KeyboardShortcutProfile
        let rejected: Int
        let savedForm: [String: [KeyboardShortcutChord]]
    }
    @ObservationIgnored private var resolvedPresets: [String: ResolvedPreset] = [:]

    init(
        defaults: UserDefaults = AppDefaults.store,
        storageKey: String = "keyboardShortcutProfile.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        let base = KeyboardShortcutProfiles.profile(for: .photoAgent)
        let data = defaults.data(forKey: storageKey)
        if let data, let document = try? JSONDecoder().decode(Document.self, from: data), document.schemaVersion == 3 {
            var names = Set(KeyboardShortcutPreset.allCases.map(\.displayName))
            presets = document.presets.filter { names.insert($0.name).inserted }
            let active = names.contains(document.activePresetName) ? document.activePresetName : Self.defaultPresetName
            activePresetName = active
            let current = KeyboardShortcutProfile.restoring(document.current, name: active, defaults: base)
            selectedProfile = current.profile
            if current.rejected > 0 {
                persist()
                skippedOnLoad = current.rejected
                skippedOnLoadPreset = active
            }
        } else if let data, let legacy = try? JSONDecoder().decode(LegacyDocument.self, from: data),
                  (1...2).contains(legacy.schemaVersion) {
            let migrated = Self.migratedSavedForm(legacy.customBindings, schemaVersion: legacy.schemaVersion)
            let restored = KeyboardShortcutProfile.restoring(migrated.saved, name: Self.migratedPresetName, defaults: base)
            let custom = restored.profile
            let customPreset = KeyboardShortcutUserPreset(name: Self.migratedPresetName, shortcuts: custom.savedForm)
            if let preset = KeyboardShortcutPreset(rawValue: legacy.selectedPreset) {
                // Keep earlier customisations reachable even while a built-in preset was chosen.
                presets = custom.savedForm == base.savedForm ? [] : [customPreset]
                activePresetName = preset.displayName
                selectedProfile = KeyboardShortcutProfiles.profile(for: preset)
            } else {
                presets = [customPreset]
                activePresetName = Self.migratedPresetName
                selectedProfile = custom
            }
            persist()
            skippedOnLoad = migrated.rejected + restored.rejected
            skippedOnLoadPreset = Self.migratedPresetName
        } else {
            presets = []
            activePresetName = Self.defaultPresetName
            selectedProfile = base
        }
    }

    /// Earlier versions stored a flat list with any number of keys per command. Keep at most
    /// two per command, preferring one menu (Command) chord and one other key, so Red's former
    /// 6 / S / ⌘1 becomes 6 and ⌘1. Version 1 predates app commands, which take defaults.
    /// Keys this version cannot use (reserved, or taken by an earlier command as `restoring`
    /// would find) are dropped and counted before the trim, so a usable third key fills the slot.
    private static func migratedSavedForm(
        _ bindings: [KeyboardShortcutBinding],
        schemaVersion: Int
    ) -> (saved: [String: [KeyboardShortcutChord]], rejected: Int) {
        var saved: [String: [KeyboardShortcutChord]] = [:]
        var used: Set<KeyboardShortcutChord> = []
        var rejected = 0
        for command in KeyboardShortcutCommand.allCases where schemaVersion >= 2 || command.isCulling {
            var chords: [KeyboardShortcutChord] = []
            for chord in bindings.filter({ $0.command == command }).map(\.chord.normalizedFromStorage) where !chords.contains(chord) {
                if used.contains(chord) || KeyboardShortcutProfiles.validationError(chord, for: command) != nil {
                    rejected += 1
                } else {
                    chords.append(chord)
                }
            }
            if chords.count > KeyboardShortcutProfile.slotCount {
                let preferred = [
                    chords.first { $0.modifiers.contains(.command) },
                    chords.first { !$0.modifiers.contains(.command) },
                ].compactMap { $0 }
                // Without one of each, keep the first two.
                chords = preferred.count == KeyboardShortcutProfile.slotCount
                    ? chords.filter(preferred.contains) : Array(chords.prefix(KeyboardShortcutProfile.slotCount))
            }
            used.formUnion(chords)
            saved[command.rawValue] = chords
        }
        return (saved, rejected)
    }

    var isBuiltInPresetActive: Bool { KeyboardShortcutPreset.named(activePresetName) != nil }

    /// Every preset name, built-in first.
    var presetNames: [String] { KeyboardShortcutPreset.allCases.map(\.displayName) + presets.map(\.name) }

    func preset(named name: String) -> KeyboardShortcutUserPreset? { presets.first { $0.name == name } }

    /// The saved shortcuts of a built-in or user preset, and how many of them this version
    /// cannot use.
    func savedProfile(named name: String) -> (profile: KeyboardShortcutProfile, rejected: Int)? {
        resolvedPreset(named: name).map { ($0.profile, $0.rejected) }
    }

    private func resolvedPreset(named name: String) -> ResolvedPreset? {
        let source = preset(named: name)
        if let cached = resolvedPresets[name], cached.source == source { return cached }
        let resolved: (profile: KeyboardShortcutProfile, rejected: Int)
        if let builtIn = KeyboardShortcutPreset.named(name) {
            resolved = (KeyboardShortcutProfiles.profile(for: builtIn), 0)
        } else if let source {
            resolved = source.resolved
        } else {
            return nil
        }
        let entry = ResolvedPreset(source: source, profile: resolved.profile, rejected: resolved.rejected,
                                   savedForm: resolved.profile.savedForm)
        resolvedPresets[name] = entry
        return entry
    }

    var isModified: Bool {
        resolvedPreset(named: activePresetName)?.savedForm != selectedProfile.savedForm
    }

    /// The current shortcuts under the active preset's name, as a shareable file would hold them.
    var currentPreset: KeyboardShortcutUserPreset {
        KeyboardShortcutUserPreset(name: activePresetName, shortcuts: selectedProfile.savedForm)
    }

    // MARK: Editing

    /// Sets one shortcut after checking reserved keys and conflicts; `nil` clears the slot.
    /// Returns why the shortcut was refused.
    @discardableResult
    func set(_ chord: KeyboardShortcutChord?, for command: KeyboardShortcutCommand, slot: Int) -> String? {
        if let chord, let error = selectedProfile.validationError(chord, for: command, slot: slot) { return error }
        selectedProfile.set(chord, for: command, slot: slot)
        persist()
        return nil
    }

    /// Moves a chord from whichever command has it to `command`, once the editor confirmed.
    @discardableResult
    func reassign(_ chord: KeyboardShortcutChord, to command: KeyboardShortcutCommand, slot: Int) -> String? {
        if let error = KeyboardShortcutProfiles.validationError(chord, for: command) { return error }
        var profile = selectedProfile
        let previous = profile.assignment(of: chord)
        profile.unassign(chord)
        // Clearing an earlier slot of the same command shifts the target down by one.
        let target = previous.map { $0.command == command && $0.slot < slot ? slot - 1 : slot } ?? slot
        if let error = profile.validationError(chord, for: command, slot: target) { return error }
        profile.set(chord, for: command, slot: target)
        selectedProfile = profile
        persist()
        return nil
    }

    func remove(_ chord: KeyboardShortcutChord) {
        selectedProfile.unassign(chord)
        persist()
    }

    // MARK: Presets

    /// Replaces the current shortcuts with a saved preset's. Returns how many of the preset's
    /// shortcuts were skipped as reserved or duplicated.
    @discardableResult
    func applyPreset(named name: String) -> Int {
        guard let saved = savedProfile(named: name) else { return 0 }
        activePresetName = name
        selectedProfile = saved.profile
        selectedProfile.name = name
        persist()
        return saved.rejected
    }

    /// Saves the current shortcuts as a user preset, replacing one of the same name.
    @discardableResult
    func savePreset(named rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name for the preset." }
        guard KeyboardShortcutPreset.named(name) == nil else {
            return "“\(name)” is a built-in preset. Choose another name."
        }
        let preset = KeyboardShortcutUserPreset(name: name, shortcuts: selectedProfile.savedForm)
        if let index = presets.firstIndex(where: { $0.name == name }) { presets[index] = preset } else { presets.append(preset) }
        activePresetName = name
        selectedProfile.name = name
        persist()
        return nil
    }

    @discardableResult
    func renamePreset(_ oldName: String, to rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = presets.firstIndex(where: { $0.name == oldName }) else { return "Built-in presets cannot be renamed." }
        guard !name.isEmpty else { return "Enter a name for the preset." }
        guard name == oldName || !presetNames.contains(name) else { return "A preset named “\(name)” already exists." }
        presets[index].name = name
        if activePresetName == oldName {
            activePresetName = name
            selectedProfile.name = name
        }
        persist()
        return nil
    }

    /// Deletes a user preset. The current shortcuts stay as they are, now as changes to the
    /// default preset.
    func deletePreset(named name: String) {
        guard presets.contains(where: { $0.name == name }) else { return }
        presets.removeAll { $0.name == name }
        if activePresetName == name {
            activePresetName = Self.defaultPresetName
            selectedProfile.name = activePresetName
        }
        persist()
    }

    /// Adds an imported preset under a free name and switches to it.
    @discardableResult
    func importPreset(_ imported: KeyboardShortcutUserPreset) -> (name: String, rejected: Int) {
        var name = imported.name
        var counter = 2
        while presetNames.contains(name) {
            name = "\(imported.name) \(counter)"
            counter += 1
        }
        let resolved = imported.resolved
        presets.append(KeyboardShortcutUserPreset(name: name, shortcuts: resolved.profile.savedForm))
        activePresetName = name
        selectedProfile = resolved.profile
        selectedProfile.name = name
        persist()
        return (name, resolved.rejected)
    }

    func resetToDefaults() {
        applyPreset(named: Self.defaultPresetName)
    }

    /// Saves the shortcuts. Every change goes through here, so it also retires the note
    /// about shortcuts left out when they were loaded.
    private func persist() {
        skippedOnLoad = 0
        let document = Document(activePresetName: activePresetName, current: selectedProfile.savedForm, presets: presets)
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
        case "escape": equivalent = .escape
        case "space": equivalent = .space
        case "tab": equivalent = .tab
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "home": equivalent = .home
        case "end": equivalent = .end
        case "pageup": equivalent = .pageUp
        case "pagedown": equivalent = .pageDown
        default:
            if let index = Self.functionKeys.firstIndex(of: key),
               let scalar = Unicode.Scalar(NSF1FunctionKey + index) {
                equivalent = KeyEquivalent(Character(scalar))
            } else {
                guard key.count == 1, let character = key.first else { return nil }
                equivalent = KeyEquivalent(character)
            }
        }
        return KeyboardShortcut(equivalent, modifiers: modifiers.eventModifiers)
    }

    /// The chord a menu item's key equivalent produces, so an alternate shortcut can find
    /// the item whose primary shortcut the menu shows.
    @MainActor
    init?(menuItem: NSMenuItem) {
        let equivalent = menuItem.keyEquivalent
        guard let scalar = equivalent.unicodeScalars.first, equivalent.unicodeScalars.count == 1 else { return nil }
        var modifiers = KeyboardShortcutModifiers(menuItem.keyEquivalentModifierMask)
        let names: [UInt32: String] = [
            UInt32(NSLeftArrowFunctionKey): "left", UInt32(NSRightArrowFunctionKey): "right",
            UInt32(NSUpArrowFunctionKey): "up", UInt32(NSDownArrowFunctionKey): "down",
            UInt32(NSHomeFunctionKey): "home", UInt32(NSEndFunctionKey): "end",
            UInt32(NSPageUpFunctionKey): "pageup", UInt32(NSPageDownFunctionKey): "pagedown",
            UInt32(NSDeleteFunctionKey): "forwarddelete",
        ]
        if let name = names[scalar.value] {
            self.init(key: name, modifiers: modifiers)
        } else if (NSF1FunctionKey...NSF12FunctionKey).contains(Int(scalar.value)) {
            self.init(key: "f\(Int(scalar.value) - NSF1FunctionKey + 1)", modifiers: modifiers)
        } else {
            // AppKit spells Shift-letter equivalents as the capital letter.
            if equivalent != equivalent.lowercased() { modifiers.insert(.shift) }
            self.init(key: equivalent, modifiers: modifiers)
        }
    }

}

extension KeyboardShortcutProfile {
    nonisolated func menuChord(for command: KeyboardShortcutCommand) -> KeyboardShortcutChord? {
        guard !command.isCulling else { return nil }
        return bindings.first { binding in
            binding.command == command && (!binding.chord.modifiers.isEmpty || binding.chord.isFunctionKey)
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
