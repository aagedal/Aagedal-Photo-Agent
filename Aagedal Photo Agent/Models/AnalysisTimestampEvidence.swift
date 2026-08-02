import Foundation

nonisolated enum AnalysisTimestampSource: String, Codable, CaseIterable, Sendable {
    case embeddedMetadata
    case gpsMetadata
    case fileSystem
    case sidecar
    case userEntered

    var displayName: String {
        switch self {
        case .embeddedMetadata: "Embedded metadata"
        case .gpsMetadata: "GPS metadata"
        case .fileSystem: "File system"
        case .sidecar: "XMP sidecar"
        case .userEntered: "User observation"
        }
    }
}

nonisolated enum AnalysisTimestampKind: String, Codable, CaseIterable, Sendable {
    case capture
    case gps
    case fileCreation
    case fileModification
    case sidecarModification
    case observation

    var displayName: String {
        switch self {
        case .capture: "Capture time"
        case .gps: "GPS time"
        case .fileCreation: "File created"
        case .fileModification: "File modified"
        case .sidecarModification: "Sidecar modified"
        case .observation: "Observed time"
        }
    }
}

nonisolated enum AnalysisTimestampPrecision: String, Codable, CaseIterable, Sendable {
    case day
    case minute
    case second
    case subsecond

    var displayName: String {
        switch self {
        case .day: "Day"
        case .minute: "Minute"
        case .second: "Second"
        case .subsecond: "Subsecond"
        }
    }

    fileprivate var comparisonTolerance: TimeInterval {
        switch self {
        case .day: 86_400
        case .minute: 60
        case .second: 1
        case .subsecond: 0.001
        }
    }
}

/// A wall-clock timestamp whose timezone may deliberately be unknown.
///
/// Storing components instead of coercing timezone-less EXIF values into `Date` prevents a local
/// camera time from being misrepresented as an absolute instant. `resolvedInstant` is available
/// only when the evidence actually provides an offset.
nonisolated struct AnalysisTimestampValue: Codable, Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var nanosecond: Int
    var precision: AnalysisTimestampPrecision
    var utcOffsetMinutes: Int?

    var timezoneKnown: Bool { utcOffsetMinutes != nil }

    init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0,
        nanosecond: Int = 0,
        precision: AnalysisTimestampPrecision,
        utcOffsetMinutes: Int?
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
        self.precision = precision
        self.utcOffsetMinutes = utcOffsetMinutes
    }

    init(
        date: Date,
        precision: AnalysisTimestampPrecision,
        timeZone: TimeZone
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        self.init(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            nanosecond: components.nanosecond ?? 0,
            precision: precision,
            utcOffsetMinutes: timeZone.secondsFromGMT(for: date) / 60
        )
    }

    var resolvedInstant: Date? {
        guard let utcOffsetMinutes,
              let timeZone = TimeZone(secondsFromGMT: utcOffsetMinutes * 60) else { return nil }
        return date(in: timeZone)
    }

    /// A sorting-only wall-clock value. It must never be described as an absolute instant when
    /// `timezoneKnown` is false.
    var wallClockSortDate: Date? {
        date(in: TimeZone(secondsFromGMT: 0)!)
    }

    var formatted: String {
        let datePart = String(format: "%04d-%02d-%02d", year, month, day)
        guard precision != .day else { return datePart }
        var value = datePart + String(format: " %02d:%02d", hour, minute)
        if precision == .second || precision == .subsecond {
            value += String(format: ":%02d", second)
        }
        if precision == .subsecond, nanosecond > 0 {
            let fractional = String(format: "%09d", nanosecond)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            value += "." + fractional
        }
        if let utcOffsetMinutes {
            if utcOffsetMinutes == 0 {
                value += " UTC"
            } else {
                let sign = utcOffsetMinutes < 0 ? "−" : "+"
                let magnitude = abs(utcOffsetMinutes)
                value += String(format: " UTC%@%02d:%02d", sign, magnitude / 60, magnitude % 60)
            }
        }
        return value
    }

    func validate() -> Bool {
        guard (-14 * 60...14 * 60).contains(utcOffsetMinutes ?? 0),
              (0..<1_000_000_000).contains(nanosecond),
              precision == .subsecond || nanosecond == 0,
              precision != .day || (hour == 0 && minute == 0 && second == 0),
              precision != .minute || second == 0 else { return false }
        let timeZone = TimeZone(secondsFromGMT: (utcOffsetMinutes ?? 0) * 60)!
        guard let date = date(in: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return roundTrip.year == year
            && roundTrip.month == month
            && roundTrip.day == day
            && roundTrip.hour == hour
            && roundTrip.minute == minute
            && roundTrip.second == second
    }

    private func date(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return calendar.date(from: components)
    }
}

nonisolated struct AnalysisTimestampEvidence: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: AnalysisTimestampKind
    var title: String
    var value: AnalysisTimestampValue
    var source: AnalysisTimestampSource
    var sourceDetail: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: AnalysisTimestampKind,
        title: String? = nil,
        value: AnalysisTimestampValue,
        source: AnalysisTimestampSource,
        sourceDetail: String,
        now: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.displayName
        self.value = value
        self.source = source
        self.sourceDetail = sourceDetail
        createdAt = now
        updatedAt = now
    }

    mutating func markUpdated(now: Date = Date()) {
        updatedAt = max(now, createdAt)
    }

    func validate() -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.validate()
            && updatedAt >= createdAt
    }
}

nonisolated struct AnalysisTimestampConflict: Identifiable, Equatable, Sendable {
    let id: String
    let evidenceIDs: Set<UUID>
    let explanation: String
}

nonisolated enum AnalysisTimelineResolver {
    static func sourceEvidence(
        from facts: AnalysisSourceFacts,
        rawMetadata: [AnalysisRawMetadataEntry] = []
    ) -> [AnalysisTimestampEvidence] {
        var evidence: [AnalysisTimestampEvidence] = []
        if let captureDate = facts.captureDate,
           let value = parseMetadataTimestamp(captureDate, timezoneKnown: facts.captureTimezoneKnown) {
            evidence.append(AnalysisTimestampEvidence(
                id: stableID("capture"),
                kind: .capture,
                value: value,
                source: .embeddedMetadata,
                sourceDetail: "EXIF/XMP capture timestamp"
            ))
        }
        if let value = gpsTimestampValue(facts: facts, rawMetadata: rawMetadata) {
            evidence.append(AnalysisTimestampEvidence(
                id: stableID("gps"),
                kind: .gps,
                value: value,
                source: .gpsMetadata,
                sourceDetail: "GPS date/time metadata"
            ))
        }
        if let date = facts.fileCreationDate {
            evidence.append(fileEvidence(
                id: "file-creation",
                kind: .fileCreation,
                date: date,
                detail: "Source file creation date"
            ))
        }
        if let date = facts.fileModificationDate {
            evidence.append(fileEvidence(
                id: "file-modification",
                kind: .fileModification,
                date: date,
                detail: "Source file modification date"
            ))
        }
        if let date = facts.sidecarModificationDate {
            evidence.append(AnalysisTimestampEvidence(
                id: stableID("sidecar-modification"),
                kind: .sidecarModification,
                value: AnalysisTimestampValue(
                    date: date,
                    precision: .subsecond,
                    timeZone: TimeZone(secondsFromGMT: 0)!
                ),
                source: .sidecar,
                sourceDetail: "XMP sidecar modification date"
            ))
        }
        return evidence
    }

    static func sorted(_ evidence: [AnalysisTimestampEvidence]) -> [AnalysisTimestampEvidence] {
        evidence.sorted {
            let lhs = $0.value.resolvedInstant ?? $0.value.wallClockSortDate ?? .distantPast
            let rhs = $1.value.resolvedInstant ?? $1.value.wallClockSortDate ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func conflicts(in evidence: [AnalysisTimestampEvidence]) -> [AnalysisTimestampConflict] {
        var conflicts: [AnalysisTimestampConflict] = []
        let acquisition = evidence.filter { $0.kind == .capture || $0.kind == .gps }
        for leftIndex in acquisition.indices {
            for rightIndex in acquisition.indices where rightIndex > leftIndex {
                let left = acquisition[leftIndex]
                let right = acquisition[rightIndex]
                guard let first = left.value.resolvedInstant,
                      let second = right.value.resolvedInstant else { continue }
                let tolerance = max(
                    left.value.precision.comparisonTolerance,
                    right.value.precision.comparisonTolerance
                )
                guard abs(first.timeIntervalSince(second)) > tolerance else { continue }
                conflicts.append(AnalysisTimestampConflict(
                    id: "acquisition-\(left.id)-\(right.id)",
                    evidenceIDs: [left.id, right.id],
                    explanation: "Capture and GPS timestamps identify different absolute times."
                ))
            }
        }

        let captures = evidence.filter { $0.kind == .capture || $0.kind == .gps }
        let modifications = evidence.filter { $0.kind == .fileModification }
        for capture in captures {
            for modification in modifications {
                guard let captureDate = capture.value.resolvedInstant,
                      let modificationDate = modification.value.resolvedInstant,
                      captureDate > modificationDate else { continue }
                conflicts.append(AnalysisTimestampConflict(
                    id: "chronology-\(capture.id)-\(modification.id)",
                    evidenceIDs: [capture.id, modification.id],
                    explanation: "A capture timestamp occurs after the source file modification time."
                ))
            }
        }
        return conflicts
    }

    private static func fileEvidence(
        id: String,
        kind: AnalysisTimestampKind,
        date: Date,
        detail: String
    ) -> AnalysisTimestampEvidence {
        AnalysisTimestampEvidence(
            id: stableID(id),
            kind: kind,
            value: AnalysisTimestampValue(
                date: date,
                precision: .subsecond,
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            source: .fileSystem,
            sourceDetail: detail
        )
    }

    private static func gpsTimestampValue(
        facts: AnalysisSourceFacts,
        rawMetadata: [AnalysisRawMetadataEntry]
    ) -> AnalysisTimestampValue? {
        let gpsDate = rawMetadata.first {
            $0.key.lowercased().contains("gpsdatestamp")
        }?.value
        let gpsTime = rawMetadata.first {
            $0.key.lowercased().contains("gpstimestamp")
        }?.value
        if let gpsDate, let gpsTime,
           let combined = parseMetadataTimestamp(
            gpsDate + " " + gpsTime,
            timezoneKnown: true,
            defaultOffsetMinutes: 0
           ) {
            return combined
        }
        if let gpsTimestamp = facts.gpsTimestamp,
           let complete = parseMetadataTimestamp(
            gpsTimestamp,
            timezoneKnown: true,
            defaultOffsetMinutes: 0
           ) {
            return complete
        }
        guard let gpsDate else { return nil }
        return parseMetadataDate(gpsDate, utcOffsetMinutes: 0)
    }

    private static func parseMetadataTimestamp(
        _ input: String,
        timezoneKnown: Bool,
        defaultOffsetMinutes: Int? = nil
    ) -> AnalysisTimestampValue? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{4})[:-](\d{2})[:-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(?:\s*(Z|[+-]\d{2}:?\d{2}))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ) else { return nil }

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: trimmed) else {
                return nil
            }
            return String(trimmed[swiftRange])
        }

        guard let year = group(1).flatMap(Int.init),
              let month = group(2).flatMap(Int.init),
              let day = group(3).flatMap(Int.init),
              let hour = group(4).flatMap(Int.init),
              let minute = group(5).flatMap(Int.init),
              let second = group(6).flatMap(Int.init) else { return nil }
        let fraction = group(7) ?? ""
        let nanosecond = Int(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0
        let parsedOffset = group(8).flatMap(parseOffset)
        let value = AnalysisTimestampValue(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: nanosecond,
            precision: fraction.isEmpty ? .second : .subsecond,
            utcOffsetMinutes: timezoneKnown ? (parsedOffset ?? defaultOffsetMinutes) : nil
        )
        return value.validate() ? value : nil
    }

    private static func parseMetadataDate(
        _ input: String,
        utcOffsetMinutes: Int?
    ) -> AnalysisTimestampValue? {
        let parts = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        let value = AnalysisTimestampValue(
            year: year,
            month: month,
            day: day,
            precision: .day,
            utcOffsetMinutes: utcOffsetMinutes
        )
        return value.validate() ? value : nil
    }

    private static func parseOffset(_ value: String) -> Int? {
        if value == "Z" { return 0 }
        let compact = value.replacingOccurrences(of: ":", with: "")
        guard compact.count == 5,
              let hours = Int(compact.dropFirst().prefix(2)),
              let minutes = Int(compact.suffix(2)),
              hours <= 14,
              minutes < 60 else { return nil }
        return (compact.first == "-" ? -1 : 1) * (hours * 60 + minutes)
    }

    private static func stableID(_ value: String) -> UUID {
        // Reserved namespace for deterministic source-fact rows. These values are constants so
        // regenerated analyzer output does not churn SwiftUI identity or report references.
        switch value {
        case "capture": UUID(uuidString: "A2300000-0000-4000-8000-000000000001")!
        case "gps": UUID(uuidString: "A2300000-0000-4000-8000-000000000002")!
        case "file-creation": UUID(uuidString: "A2300000-0000-4000-8000-000000000003")!
        case "file-modification": UUID(uuidString: "A2300000-0000-4000-8000-000000000004")!
        case "sidecar-modification": UUID(uuidString: "A2300000-0000-4000-8000-000000000005")!
        default: preconditionFailure("Unknown source timestamp identifier")
        }
    }
}
