import Foundation

nonisolated enum ExifToolSource: String, CaseIterable {
    case bundled
    case homebrew
    case custom

    var displayName: String {
        switch self {
        case .bundled: return "Bundled"
        case .homebrew: return "Homebrew"
        case .custom: return "Custom"
        }
    }
}
