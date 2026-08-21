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
        self.key = ["\r", "\u{3}"].contains(key) ? "return" : key.lowercased()
        self.modifiers = modifiers
    }

    var displayName: String {
        let prefix = [
            modifiers.contains(.control) ? "⌃" : "",
            modifiers.contains(.option) ? "⌥" : "",
            modifiers.contains(.shift) ? "⇧" : "",
            modifiers.contains(.command) ? "⌘" : "",
        ].joined()
        return prefix + (key == "return" ? "↩" : key.uppercased())
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
        }
    }

    var action: KeyboardCullingAction {
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
        }
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
    static let editableChordChoices: [KeyboardShortcutChord] = {
        let numbers = (0...9).map(String.init)
        // Keep the editor's finite choices away from standard editing/menu chords such
        // as Command-S/Command-X and the app's Control-Option scope commands.
        return (numbers + ["s", "x"]).map { KeyboardShortcutChord(key: $0) }
            + numbers.map { KeyboardShortcutChord(key: $0, modifiers: .command) }
            + numbers.map { KeyboardShortcutChord(key: $0, modifiers: [.command, .option]) }
    }()

    static func profile(for preset: KeyboardShortcutPreset) -> KeyboardShortcutProfile {
        switch preset {
        case .photoAgent:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoAgentBindings)
        case .photoMechanicLike:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoMechanicLikeBindings)
        case .bridgeLike:
            KeyboardShortcutProfile(name: preset.displayName, bindings: bridgeLikeBindings)
        case .custom:
            KeyboardShortcutProfile(name: preset.displayName, bindings: photoAgentBindings)
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
        var schemaVersion = 1
        var selectedPreset: KeyboardShortcutPreset
        var customBindings: [KeyboardShortcutBinding]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var selectedPreset: KeyboardShortcutPreset
    private(set) var customBindings: [KeyboardShortcutBinding]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "keyboardShortcutProfile.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let document = try? JSONDecoder().decode(Document.self, from: data),
           document.schemaVersion == 1 {
            selectedPreset = document.selectedPreset
            customBindings = document.customBindings
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
        defaults: UserDefaults = .standard,
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
