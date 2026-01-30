import Foundation

/// Defines the algorithm used for face recognition and clustering.
nonisolated enum FaceRecognitionMode: String, Codable, CaseIterable, Sendable {
    /// Apple Vision VNFeaturePrint (current default behavior)
    case visionFeaturePrint = "vision"
    /// Combined face and torso/clothing features for red carpet scenarios
    case faceAndClothing = "faceClothing"

    var displayName: String {
        switch self {
        case .visionFeaturePrint:
            return "Vision"
        case .faceAndClothing:
            return "Face + Clothing"
        }
    }

    var description: String {
        switch self {
        case .visionFeaturePrint:
            return "Apple Vision feature prints. Fast, built-in, good general accuracy."
        case .faceAndClothing:
            return "Combines face and torso features. Best for events where clothing helps identify people."
        }
    }
}
