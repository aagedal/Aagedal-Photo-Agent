import Foundation

enum StarRating: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var displayString: String {
        if self == .none { return "" }
        return String(repeating: "\u{2605}", count: rawValue)
    }
}
