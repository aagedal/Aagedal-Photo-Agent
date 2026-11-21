import AppKit
import Carbon.HIToolbox

/// One key of the shortcut editor's on-screen keyboard.
struct VirtualKey: Identifiable, Hashable {
    enum Role: Hashable {
        /// A key that shortcuts can use, by the name or unshifted character the routers see for it.
        case key(String)
        case modifier(KeyboardShortcutModifiers)
        case inert
        case spacer
    }

    let id: String
    let keyCode: UInt16?
    let role: Role
    /// In key units; a letter key is one unit wide.
    let width: CGFloat
    let label: String
    /// The legend above the main one, such as ! over 1.
    let shiftedLabel: String?

    /// The chord this key produces with the given modifiers held, matching
    /// `KeyboardShortcutChord(event:)` for the same press.
    func chord(with modifiers: KeyboardShortcutModifiers) -> KeyboardShortcutChord? {
        guard case let .key(key) = role else { return nil }
        return KeyboardShortcutChord(key: key, modifiers: modifiers)
    }

    /// Every chord this key can produce, fewest modifiers first.
    var chords: [(modifiers: KeyboardShortcutModifiers, chord: KeyboardShortcutChord)] {
        KeyboardShortcutModifiers.allCombinations.compactMap { modifiers in
            chord(with: modifiers).map { (modifiers, $0) }
        }
    }

    /// A name for lists and accessibility, such as "J" or "Left Arrow".
    var name: String {
        guard case let .key(key) = role else { return label }
        let names = [
            "left": "Left Arrow", "right": "Right Arrow", "up": "Up Arrow", "down": "Down Arrow",
            "delete": "Delete", "forwarddelete": "Forward Delete", "return": "Return", "escape": "Escape",
            "space": "Space", "tab": "Tab", "home": "Home", "end": "End", "pageup": "Page Up", "pagedown": "Page Down",
        ]
        return names[key] ?? key.uppercased()
    }
}

/// The physical keyboard drawn by the shortcut editor, labelled from the current input
/// source so that each key shows the character it types (Ø on a Norwegian layout, for example).
struct VirtualKeyboardLayout: Equatable {
    var mainRows: [[VirtualKey]]
    var navigationRows: [[VirtualKey]]
    var isISO: Bool
    var inputSourceName: String

    var keys: [VirtualKey] { (mainRows + navigationRows).flatMap { $0 } }
    func key(id: VirtualKey.ID?) -> VirtualKey? { keys.first { $0.id == id } }

    /// The key that produces a chord on this layout, if any does.
    func key(for chord: KeyboardShortcutChord) -> VirtualKey? {
        keys.first { $0.chord(with: chord.modifiers) == chord }
    }

    private enum Spec {
        case code(UInt16, CGFloat = 1)
        case modifier(KeyboardShortcutModifiers, String, CGFloat)
        case inert(String, CGFloat)
        case spacer(CGFloat)
    }

    static func current() -> VirtualKeyboardLayout {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        let layoutData = source.flatMap { source in
            TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
                .map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }
        }
        let sourceName = source.flatMap { source in
            TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        } ?? "U.S."
        let isISO = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
        let functionRow: [Spec] = [.code(53, 1.5)]
            + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].map { .code($0, 1.125) }
        let letters2: [Spec] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30].map { .code($0) }
        let letters3: [Spec] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39].map { .code($0) }
        let letters4: [Spec] = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44].map { .code($0) }
        let digits: [Spec] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24].map { .code($0) }
        let bottom: [Spec] = [
            .inert("fn", 1), .modifier(.control, "⌃ control", 1.25), .modifier(.option, "⌥ option", 1.25),
            .modifier(.command, "⌘ command", 1.5), .code(49, 5.5), .modifier(.command, "⌘ command", 1.5),
            .modifier(.option, "⌥ option", 1.25), .modifier(.control, "⌃ control", 1.75),
        ]
        // ISO keyboards have a key left of 1 (code 10), one beside left Shift (code 50) and a tall Return.
        let main: [[Spec]] = isISO ? [
            functionRow,
            [.code(10)] + digits + [.code(51, 2)],
            [.code(48, 1.5)] + letters2 + [.code(36, 1.5)],
            [.inert("⇪", 1.75)] + letters3 + [.code(42), .code(36, 1.25)],
            [.modifier(.shift, "⇧ shift", 1.25), .code(50)] + letters4 + [.modifier(.shift, "⇧ shift", 2.75)],
            bottom,
        ] : [
            functionRow,
            [.code(50)] + digits + [.code(51, 2)],
            [.code(48, 1.5)] + letters2 + [.code(42, 1.5)],
            [.inert("⇪", 1.75)] + letters3 + [.code(36, 2.25)],
            [.modifier(.shift, "⇧ shift", 2.25)] + letters4 + [.modifier(.shift, "⇧ shift", 2.75)],
            bottom,
        ]
        let navigation: [[Spec]] = [
            [.spacer(3)],
            [.inert("fn", 1), .code(115), .code(116)],
            [.code(117), .code(119), .code(121)],
            [.spacer(3)],
            [.spacer(1), .code(126), .spacer(1)],
            [.code(123), .code(125), .code(124)],
        ]
        func keys(_ rows: [[Spec]], prefix: String) -> [[VirtualKey]] {
            var drawn: Set<UInt16> = []
            return rows.enumerated().map { row, specs in
                specs.enumerated().map { column, spec in
                    let id = "\(prefix)\(row).\(column)"
                    switch spec {
                    case let .code(code, width):
                        let key = key(code: code, width: width, id: id, layoutData: layoutData)
                        // The lower half of the ISO Return key carries no second legend.
                        guard drawn.insert(code).inserted else {
                            return VirtualKey(id: id, keyCode: code, role: key.role, width: width, label: "", shiftedLabel: nil)
                        }
                        return key
                    case let .modifier(modifier, label, width):
                        return VirtualKey(id: id, keyCode: nil, role: .modifier(modifier), width: width, label: label, shiftedLabel: nil)
                    case let .inert(label, width):
                        return VirtualKey(id: id, keyCode: nil, role: .inert, width: width, label: label, shiftedLabel: nil)
                    case let .spacer(width):
                        return VirtualKey(id: id, keyCode: nil, role: .spacer, width: width, label: "", shiftedLabel: nil)
                    }
                }
            }
        }
        return VirtualKeyboardLayout(
            mainRows: keys(main, prefix: "m"), navigationRows: keys(navigation, prefix: "n"),
            isISO: isISO, inputSourceName: sourceName
        )
    }

    private static func key(code: UInt16, width: CGFloat, id: String, layoutData: Data?) -> VirtualKey {
        if let name = KeyboardShortcutChord.keyCodeNames[code] {
            let labels = [
                "escape": "esc", "delete": "⌫ delete", "forwarddelete": "⌦", "tab": "⇥ tab", "return": "↩ return",
                "space": "", "home": "home", "end": "end", "pageup": "pg up", "pagedown": "pg dn",
            ]
            return VirtualKey(
                id: id, keyCode: code, role: .key(name), width: width,
                label: labels[name] ?? KeyboardShortcutChord(key: name).keyLabel, shiftedLabel: nil
            )
        }
        let (base, shifted) = characters(for: code, layoutData: layoutData) ?? usCharacters[code] ?? ("?", "?")
        // Letters show one legend; keys whose Shift character differs show both, as printed caps do.
        let showsShifted = shifted.lowercased() != base.lowercased() && !shifted.isEmpty
        // Some lowercase letters, such as ß, have no single-letter capital.
        let capital = base.uppercased()
        return VirtualKey(
            id: id, keyCode: code, role: .key(base.lowercased()), width: width,
            label: capital.count == base.count ? capital : base, shiftedLabel: showsShifted ? shifted : nil
        )
    }

    /// The characters the input source types for a key, unshifted and with Shift.
    private static func characters(for keyCode: UInt16, layoutData: Data?) -> (String, String)? {
        guard let layoutData else { return nil }
        return layoutData.withUnsafeBytes { raw -> (String, String)? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            func translate(_ modifierState: UInt32) -> String? {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDown), modifierState, UInt32(LMGetKbdType()),
                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
                )
                guard status == noErr, length > 0 else { return nil }
                let string = String(utf16CodeUnits: characters, count: length)
                return string.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } ? string : nil
            }
            guard let base = translate(0) else { return nil }
            return (base, translate(UInt32(shiftKey >> 8) & 0xFF) ?? base)
        }
    }

    private static let usCharacters: [UInt16: (String, String)] = [
        50: ("`", "~"), 10: ("§", "±"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 23: ("5", "%"),
        22: ("6", "^"), 26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("), 29: ("0", ")"), 27: ("-", "_"), 24: ("=", "+"),
        12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 17: ("t", "T"), 16: ("y", "Y"), 32: ("u", "U"),
        34: ("i", "I"), 31: ("o", "O"), 35: ("p", "P"), 33: ("[", "{"), 30: ("]", "}"), 42: ("\\", "|"), 0: ("a", "A"),
        1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 5: ("g", "G"), 4: ("h", "H"), 38: ("j", "J"), 40: ("k", "K"),
        37: ("l", "L"), 41: (";", ":"), 39: ("'", "\""), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
        11: ("b", "B"), 45: ("n", "N"), 46: ("m", "M"), 43: (",", "<"), 47: (".", ">"), 44: ("/", "?"),
    ]
}
