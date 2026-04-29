import Foundation

extension ContinuousClock.Instant {
    /// Whole milliseconds elapsed from this instant to now.
    /// Snapshots `.now` once, so the seconds and attoseconds components are consistent.
    nonisolated func elapsedMilliseconds() -> Int {
        let d = duration(to: .now).components
        return Int(d.seconds * 1000) + Int(d.attoseconds / 1_000_000_000_000_000)
    }
}
