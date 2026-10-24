import Foundation

/// Reverse-geocode results for `{gps:city}` / `{gps:country}` within one import.
///
/// A card is mostly shot in a few places, so lookups are cached per coordinate rounded to three
/// decimals (about 100 m). Each network lookup is bounded by `timeout`; a failed or timed-out
/// lookup is cached too, so a rate-limited geocoder costs one wait per place rather than one per
/// photo. Unresolved lookups leave the tokens in place (the interpolator's existing behavior),
/// so the user can process variables again later.
actor ImportPlaceLookupCache {
    typealias Geocode = @Sendable (Double, Double) async throws -> GeocodingResult
    struct Place: Sendable, Equatable {
        let city: String
        let country: String
    }

    private let geocode: Geocode
    private let timeout: Duration
    private var cache: [String: Place?] = [:]

    init(
        timeout: Duration = .seconds(10),
        geocode: @escaping Geocode = { latitude, longitude in
            try await GeocodingService().reverseGeocode(latitude: latitude, longitude: longitude)
        }
    ) {
        self.timeout = timeout
        self.geocode = geocode
    }

    func place(latitude: Double, longitude: Double) async -> Place? {
        let key = Self.key(latitude: latitude, longitude: longitude)
        if let cached = cache[key] { return cached }
        let geocode = self.geocode
        let result = await Self.withTimeout(timeout) { () -> Place? in
            guard let location = try? await geocode(latitude, longitude) else { return nil }
            return Place(city: location.city ?? "", country: location.country ?? "")
        }
        cache[key] = .some(result)
        return result
    }

    /// The interpolator hook for this cache.
    nonisolated var lookup: PresetVariableInterpolator.PlaceLookup {
        { latitude, longitude in
            await self.place(latitude: latitude, longitude: longitude).map { ($0.city, $0.country) }
        }
    }

    static func key(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }

    /// Returns `operation`'s value, or nil once `timeout` passes. A lookup that ignores
    /// cancellation keeps running in the background but no longer holds the caller.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let work = Task { gate.resume(with: await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                gate.resume(with: nil)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first.
private nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var resumed = false

    func install(_ continuation: CheckedContinuation<T, Never>) {
        let early: T? = lock.withLock {
            if resumed, let pending {
                self.pending = nil
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(with value: T) {
        let target: CheckedContinuation<T, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            pending = value
            return nil
        }
        target?.resume(returning: value)
    }
}
