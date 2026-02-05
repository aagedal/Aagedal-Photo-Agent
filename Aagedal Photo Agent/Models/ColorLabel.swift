import Foundation
import SwiftUI

enum ColorLabel: String, Codable, CaseIterable, Sendable {
    case none = ""
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case cyan = "Cyan"
    case brown = "Brown"
    case trash = "Trash"

    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .cyan: return .cyan
        case .brown: return .brown
        case .trash: return .gray
        }
    }

    var displayName: String {
        self == .none ? "None" : rawValue
    }

    /// XMP label value to write for interoperability.
    var xmpLabelValue: String? {
        switch self {
        case .none:
            return nil
        case .red:
            return "Select"
        case .yellow:
            return "Second"
        case .green:
            return "Approved"
        case .blue:
            return "Review"
        case .purple:
            return "To Do"
        case .cyan:
            return "Cyan"
        case .brown:
            return "Brown"
        case .trash:
            return "Trash"
        }
    }

    /// Index for keyboard shortcuts (Option+0 through Option+8 in menus, Cmd+Option in full screen)
    var shortcutIndex: Int? {
        switch self {
        case .none: return 0
        case .red: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        case .cyan: return 6
        case .brown: return 7
        case .trash: return 8
        }
    }

    static func fromShortcutIndex(_ index: Int) -> ColorLabel? {
        allCases.first { $0.shortcutIndex == index }
    }

    /// Map an XMP label string to a ColorLabel for UI display.
    static func fromMetadataLabel(_ value: String?) -> ColorLabel {
        if let mapped = mappedLabel(from: value) {
            return mapped
        }
        return .none
    }

    /// Normalize a label string to the canonical value we write, preserving unknown labels.
    static func canonicalMetadataLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let mapped = mappedLabel(from: trimmed) {
            return mapped.xmpLabelValue
        }
        return trimmed
    }

    private static func mappedLabel(from value: String?) -> ColorLabel? {
        guard let value else { return nil }
        let normalized = normalizeLabel(value)
        guard !normalized.isEmpty else { return .none }
        return labelAliases[normalized]
    }

    private static func normalizeLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let collapsed = lowered.replacingOccurrences(of: "[\\s\\-_]+", with: "", options: .regularExpression)
        return collapsed
    }

    private static let labelAliases: [String: ColorLabel] = [
        "red": .red,
        "select": .red,
        "yellow": .yellow,
        "second": .yellow,
        "green": .green,
        "approved": .green,
        "blue": .blue,
        "review": .blue,
        "purple": .purple,
        "todo": .purple,
        "orange": .none,
        "cyan": .cyan,
        "aqua": .cyan,
        "teal": .cyan,
        "brown": .brown,
        "trash": .trash,
        "gray": .trash,
        "grey": .trash,
        "darkgray": .trash,
        "darkgrey": .trash,
        "none": .none,
        "nolabel": .none,
        "white": .none,
        "whitelabel": .none
    ]
}
