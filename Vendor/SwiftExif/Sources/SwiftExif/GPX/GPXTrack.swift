import Foundation

/// A single trackpoint from a GPX file.
public struct GPXTrackpoint: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let elevation: Double?
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, elevation: Double? = nil, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
    }
}

/// A parsed GPX track containing timestamped trackpoints.
public struct GPXTrack: Sendable {
    public let name: String?
    public let trackpoints: [GPXTrackpoint]

    public init(name: String? = nil, trackpoints: [GPXTrackpoint]) {
        self.name = name
        // Sort by timestamp for binary search
        self.trackpoints = trackpoints.sorted { $0.timestamp < $1.timestamp }
    }

    /// The time range covered by this track, or nil if empty.
    public var timeRange: ClosedRange<Date>? {
        guard let first = trackpoints.first, let last = trackpoints.last else { return nil }
        return first.timestamp...last.timestamp
    }
}
