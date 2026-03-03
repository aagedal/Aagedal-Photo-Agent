import Foundation

enum MultiSelectFieldMode: String, CaseIterable, Sendable {
    case overwrite
    case add

    var displayName: String {
        switch self {
        case .overwrite: return "Overwrite"
        case .add: return "Add"
        }
    }
}
