import SwiftUI

enum ColorLabel: String, Codable, CaseIterable, Sendable {
    case none = ""
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case orange = "Orange"

    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .orange: return .orange
        }
    }

    var displayName: String {
        self == .none ? "None" : rawValue
    }

    /// Index for keyboard shortcuts (CMD+Shift+0 through CMD+Shift+6)
    var shortcutIndex: Int? {
        switch self {
        case .none: return 0
        case .red: return 1
        case .yellow: return 2
        case .green: return 3
        case .blue: return 4
        case .purple: return 5
        case .orange: return 6
        }
    }

    static func fromShortcutIndex(_ index: Int) -> ColorLabel? {
        allCases.first { $0.shortcutIndex == index }
    }
}
