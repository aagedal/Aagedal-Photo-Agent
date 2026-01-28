import Foundation

nonisolated enum FaceCleanupPolicy: String, Codable, CaseIterable {
    case sevenDays = "7days"
    case thirtyDays = "30days"
    case never = "never"

    var displayName: String {
        switch self {
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        case .never: return "Never"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .sevenDays: return 7 * 24 * 60 * 60
        case .thirtyDays: return 30 * 24 * 60 * 60
        case .never: return nil
        }
    }
}
