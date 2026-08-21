import Foundation

/// A validated IPTC/XMP Date Created value which keeps the exact source spelling while exposing
/// the precision and timezone facts needed for lossless editing and container-specific writes.
nonisolated struct EditorialDateCreated: Codable, Sendable, Equatable {
    enum Precision: String, Codable, Sendable, CaseIterable {
        case year
        case month
        case day
        case minute
        case second
        case fractionalSecond
    }

    /// Date-only values have no timezone (`absent`). A timestamp without an offset, including the
    /// RFC 3339 `-00:00` spelling, has an unknown timezone. Only `offsetMinutes` is known.
    enum TimeZoneSemantics: Codable, Sendable, Equatable {
        case absent
        case unknown
        case offsetMinutes(Int)

        var isKnown: Bool {
            if case .offsetMinutes = self { return true }
            return false
        }

        var offsetMinutes: Int? {
            guard case .offsetMinutes(let minutes) = self else { return nil }
            return minutes
        }

        private enum CodingKeys: String, CodingKey {
            case state
            case offsetMinutes
        }

        private enum State: String, Codable {
            case absent
            case unknown
            case offset
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(State.self, forKey: .state) {
            case .absent:
                self = .absent
            case .unknown:
                self = .unknown
            case .offset:
                let minutes = try container.decode(Int.self, forKey: .offsetMinutes)
                guard Self.isValidOffset(minutes) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .offsetMinutes,
                        in: container,
                        debugDescription: "Date Created timezone offset is outside the ISO 8601 range."
                    )
                }
                self = .offsetMinutes(minutes)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .absent:
                try container.encode(State.absent, forKey: .state)
            case .unknown:
                try container.encode(State.unknown, forKey: .state)
            case .offsetMinutes(let minutes):
                guard Self.isValidOffset(minutes) else {
                    throw EncodingError.invalidValue(
                        minutes,
                        EncodingError.Context(
                            codingPath: encoder.codingPath,
                            debugDescription: "Date Created timezone offset is outside the ISO 8601 range."
                        )
                    )
                }
                try container.encode(State.offset, forKey: .state)
                try container.encode(minutes, forKey: .offsetMinutes)
            }
        }

        private static func isValidOffset(_ minutes: Int) -> Bool {
            (-14 * 60 ... 14 * 60).contains(minutes)
        }
    }

    enum ParseError: Error, Sendable, Equatable, LocalizedError {
        case empty
        case unsupportedSyntax
        case invalidCalendarDate
        case invalidTime
        case invalidTimeZoneOffset

        var errorDescription: String? {
            switch self {
            case .empty: "Date Created is empty."
            case .unsupportedSyntax: "Date Created must use supported ISO 8601 syntax."
            case .invalidCalendarDate: "Date Created contains an invalid calendar date."
            case .invalidTime: "Date Created contains an invalid time."
            case .invalidTimeZoneOffset: "Date Created contains an invalid timezone offset."
            }
        }
    }

    let lexicalValue: String
    let canonicalLexicalValue: String
    let precision: Precision
    let timeZone: TimeZoneSemantics
    let year: Int
    let month: Int?
    let day: Int?
    let hour: Int?
    let minute: Int?
    let second: Int?
    /// Digits after the decimal point, retained exactly (including trailing zeroes).
    let fractionalSecondDigits: String?

    var isTimeZoneKnown: Bool { timeZone.isKnown }
    var timeZoneOffsetMinutes: Int? { timeZone.offsetMinutes }

    /// Lossless IIM date projection. Year/month precision cannot be represented by dataset 2:55.
    var iimDateValue: String? {
        guard let month, let day else { return nil }
        return String(
            format: "%04d%02d%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            year, month, day
        )
    }

    /// Lossless IIM time projection. IIM has whole-second precision only, so minute and
    /// fractional-second values stay exclusively in XMP rather than being silently padded/truncated.
    var iimTimeValue: String? {
        guard precision == .second, let hour, let minute, let second else { return nil }
        var result = String(
            format: "%02d%02d%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            hour, minute, second
        )
        if let offset = timeZone.offsetMinutes {
            let sign = offset < 0 ? "-" : "+"
            let magnitude = abs(offset)
            result += String(
                format: "%@%02d%02d",
                locale: Locale(identifier: "en_US_POSIX"),
                sign, magnitude / 60, magnitude % 60
            )
        }
        return result
    }

    /// Builds the exact ISO lexical value representable by the paired legacy IIM datasets.
    static func fromIIM(date: String, time: String?) -> Self? {
        guard date.count == 8, date.allSatisfy(\.isNumber) else { return nil }
        var lexical = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
        if let time, !time.isEmpty {
            let expression = try! NSRegularExpression(pattern: #"^(\d{2})(\d{2})(\d{2})([+-]\d{4})?$"#)
            let range = NSRange(time.startIndex..<time.endIndex, in: time)
            guard let match = expression.firstMatch(in: time, range: range),
                  let hourRange = Range(match.range(at: 1), in: time),
                  let minuteRange = Range(match.range(at: 2), in: time),
                  let secondRange = Range(match.range(at: 3), in: time) else { return nil }
            lexical += "T\(time[hourRange]):\(time[minuteRange]):\(time[secondRange])"
            if match.range(at: 4).location != NSNotFound,
               let zoneRange = Range(match.range(at: 4), in: time) {
                let zone = String(time[zoneRange])
                lexical += "\(zone.prefix(3)):\(zone.suffix(2))"
            }
        }
        return try? Self(parsing: lexical)
    }

    init(parsing lexicalValue: String) throws {
        guard !lexicalValue.isEmpty else { throw ParseError.empty }
        guard lexicalValue == lexicalValue.trimmingCharacters(in: .whitespacesAndNewlines),
              lexicalValue.utf8.count <= 64 else {
            throw ParseError.unsupportedSyntax
        }

        let range = NSRange(lexicalValue.startIndex..<lexicalValue.endIndex, in: lexicalValue)
        guard let match = Self.expression.firstMatch(in: lexicalValue, range: range) else {
            throw ParseError.unsupportedSyntax
        }

        func capture(_ index: Int) -> String? {
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let swiftRange = Range(captureRange, in: lexicalValue) else {
                return nil
            }
            return String(lexicalValue[swiftRange])
        }

        guard let year = capture(1).flatMap(Int.init) else {
            throw ParseError.unsupportedSyntax
        }
        let month = capture(2).flatMap(Int.init)
        let day = capture(3).flatMap(Int.init)
        let hour = capture(4).flatMap(Int.init)
        let minute = capture(5).flatMap(Int.init)
        let second = capture(6).flatMap(Int.init)
        let fraction = capture(7)
        let zone = capture(8)

        try Self.validateCalendarDate(year: year, month: month, day: day)
        try Self.validateTime(hour: hour, minute: minute, second: second)
        let timeZone = try Self.parseTimeZone(zone, hasTime: hour != nil)

        self.lexicalValue = lexicalValue
        self.precision = Self.precision(
            month: month,
            day: day,
            minute: minute,
            second: second,
            fraction: fraction
        )
        self.timeZone = timeZone
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.fractionalSecondDigits = fraction
        self.canonicalLexicalValue = Self.canonicalValue(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            fraction: fraction,
            originalZone: zone,
            timeZone: timeZone
        )
    }

    static func parse(_ lexicalValue: String) throws -> Self {
        try Self(parsing: lexicalValue)
    }

    private enum CodingKeys: String, CodingKey {
        case lexicalValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lexicalValue = try container.decode(String.self, forKey: .lexicalValue)
        do {
            self = try Self(parsing: lexicalValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .lexicalValue,
                in: container,
                debugDescription: "Persisted Date Created value is invalid."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lexicalValue, forKey: .lexicalValue)
    }

    private static let expression = try! NSRegularExpression(
        pattern: #"^(\d{4})(?:-(\d{2})(?:-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|z|[+-]\d{2}:?\d{2})?)?)?)?$"#
    )

    private static func precision(
        month: Int?,
        day: Int?,
        minute: Int?,
        second: Int?,
        fraction: String?
    ) -> Precision {
        if fraction != nil { return .fractionalSecond }
        if second != nil { return .second }
        if minute != nil { return .minute }
        if day != nil { return .day }
        if month != nil { return .month }
        return .year
    }

    private static func validateCalendarDate(year: Int, month: Int?, day: Int?) throws {
        guard (1...9999).contains(year) else { throw ParseError.invalidCalendarDate }
        guard let month else { return }
        guard (1...12).contains(month) else { throw ParseError.invalidCalendarDate }
        guard let day else { return }
        let days = switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
        guard (1...days).contains(day) else { throw ParseError.invalidCalendarDate }
    }

    private static func validateTime(hour: Int?, minute: Int?, second: Int?) throws {
        guard let hour else { return }
        guard (0...23).contains(hour), let minute, (0...59).contains(minute) else {
            throw ParseError.invalidTime
        }
        if let second, !(0...59).contains(second) { throw ParseError.invalidTime }
    }

    private static func parseTimeZone(
        _ value: String?,
        hasTime: Bool
    ) throws -> TimeZoneSemantics {
        guard hasTime else { return .absent }
        guard let value else { return .unknown }
        if value.caseInsensitiveCompare("Z") == .orderedSame { return .offsetMinutes(0) }

        let sign = value.hasPrefix("-") ? -1 : 1
        let digits = value.dropFirst().replacingOccurrences(of: ":", with: "")
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              (0...14).contains(hours),
              (0...59).contains(minutes),
              hours < 14 || minutes == 0 else {
            throw ParseError.invalidTimeZoneOffset
        }
        if sign == -1, hours == 0, minutes == 0 { return .unknown }
        return .offsetMinutes(sign * (hours * 60 + minutes))
    }

    private static func canonicalValue(
        year: Int,
        month: Int?,
        day: Int?,
        hour: Int?,
        minute: Int?,
        second: Int?,
        fraction: String?,
        originalZone: String?,
        timeZone: TimeZoneSemantics
    ) -> String {
        var result = String(format: "%04d", locale: Locale(identifier: "en_US_POSIX"), year)
        guard let month else { return result }
        result += String(format: "-%02d", locale: Locale(identifier: "en_US_POSIX"), month)
        guard let day else { return result }
        result += String(format: "-%02d", locale: Locale(identifier: "en_US_POSIX"), day)
        guard let hour, let minute else { return result }
        result += String(format: "T%02d:%02d", locale: Locale(identifier: "en_US_POSIX"), hour, minute)
        if let second {
            result += String(format: ":%02d", locale: Locale(identifier: "en_US_POSIX"), second)
        }
        if let fraction { result += ".\(fraction)" }

        if originalZone?.hasPrefix("-") == true,
           case .unknown = timeZone {
            result += "-00:00"
        } else if let offset = timeZone.offsetMinutes {
            if originalZone?.caseInsensitiveCompare("Z") == .orderedSame {
                result += "Z"
            } else {
                let sign = offset < 0 ? "-" : "+"
                let magnitude = abs(offset)
                result += String(
                    format: "%@%02d:%02d",
                    locale: Locale(identifier: "en_US_POSIX"),
                    sign,
                    magnitude / 60,
                    magnitude % 60
                )
            }
        }
        return result
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
    }
}
