import Foundation

/// Defines the algorithm used for grouping similar faces into clusters.
enum FaceClusteringAlgorithm: String, Codable, CaseIterable, Sendable {
    /// Hierarchical agglomerative clustering with average linkage (current default, backward compatible)
    case hierarchicalAverage = "hierarchicalAverage"
    /// Hierarchical agglomerative clustering with median linkage (Apple Photos style)
    case hierarchicalMedian = "hierarchicalMedian"
    /// Graph-based Chinese Whispers clustering (Facebook/dlib style)
    case chineseWhispers = "chineseWhispers"
    /// Quality-gated two-pass: cluster high-quality faces first, then assign low-quality
    case qualityGatedTwoPass = "qualityGated"

    var displayName: String {
        switch self {
        case .hierarchicalAverage:
            return "Average Linkage"
        case .hierarchicalMedian:
            return "Median Linkage"
        case .chineseWhispers:
            return "Chinese Whispers"
        case .qualityGatedTwoPass:
            return "Quality-Gated"
        }
    }

    var description: String {
        switch self {
        case .hierarchicalAverage:
            return "Original algorithm. Uses average distance between all face pairs. Sensitive to outliers."
        case .hierarchicalMedian:
            return "Apple Photos style. Uses median distance, more robust to outliers and low-quality faces."
        case .chineseWhispers:
            return "Graph-based algorithm used by Facebook. Order-independent with natural outlier isolation."
        case .qualityGatedTwoPass:
            return "Clusters high-quality faces first, then assigns low-quality faces. Best for mixed-quality photos."
        }
    }
}
