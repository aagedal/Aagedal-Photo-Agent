import Foundation

/// Severity level for validation issues.
public enum ValidationSeverity: String, Sendable, CustomStringConvertible {
    case error
    case warning

    public var description: String { rawValue }
}

/// A single validation issue found during metadata validation.
public struct ValidationIssue: Sendable, CustomStringConvertible {
    public let field: String
    public let message: String
    public let severity: ValidationSeverity

    public var description: String {
        "[\(severity)] \(field): \(message)"
    }
}

/// The result of validating metadata against a profile.
public struct ValidationResult: Sendable {
    public let issues: [ValidationIssue]

    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    public var errors: [ValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    public var warnings: [ValidationIssue] {
        issues.filter { $0.severity == .warning }
    }
}

/// Validates image metadata against configurable journalism profiles.
/// Checks required fields, recommended fields, and data format correctness.
public struct MetadataValidator: Sendable {
    /// Fields that must be present for the metadata to pass validation.
    public let requiredFields: Set<String>

    /// Fields that should be present (generates warnings, not errors).
    public let recommendedFields: Set<String>

    /// Whether to enforce IPTC data format rules (date, urgency, country code).
    public let enforceFormats: Bool

    /// Minimum number of keywords required (0 = no minimum).
    public let minimumKeywords: Int

    /// Minimum xmp:Rating required (nil = no minimum). Editorial desks use this to gate submissions.
    public let minimumRating: Double?

    public init(
        requiredFields: Set<String> = [],
        recommendedFields: Set<String> = [],
        enforceFormats: Bool = true,
        minimumKeywords: Int = 0,
        minimumRating: Double? = nil
    ) {
        self.requiredFields = requiredFields
        self.recommendedFields = recommendedFields
        self.enforceFormats = enforceFormats
        self.minimumKeywords = minimumKeywords
        self.minimumRating = minimumRating
    }

    /// Validate metadata and return all issues found.
    public func validate(_ metadata: ImageMetadata) -> ValidationResult {
        var issues: [ValidationIssue] = []
        let dict = MetadataExporter.buildDictionary(metadata)

        // Check required fields
        for field in requiredFields.sorted() {
            if field == "IPTC:Keywords" {
                let keywords = metadata.iptc.keywords
                if keywords.isEmpty {
                    issues.append(ValidationIssue(
                        field: field, message: "Required field is missing", severity: .error))
                }
            } else if dict[field] == nil {
                issues.append(ValidationIssue(
                    field: field, message: "Required field is missing", severity: .error))
            }
        }

        // Check recommended fields
        for field in recommendedFields.sorted() {
            if field == "IPTC:Keywords" {
                if metadata.iptc.keywords.isEmpty {
                    issues.append(ValidationIssue(
                        field: field, message: "Recommended field is missing", severity: .warning))
                }
            } else if dict[field] == nil {
                issues.append(ValidationIssue(
                    field: field, message: "Recommended field is missing", severity: .warning))
            }
        }

        // Check minimum keywords
        if minimumKeywords > 0 {
            let count = metadata.iptc.keywords.count
            if count < minimumKeywords {
                issues.append(ValidationIssue(
                    field: "IPTC:Keywords",
                    message: "Requires at least \(minimumKeywords) keywords, found \(count)",
                    severity: .error))
            }
        }

        // Check minimum rating
        if let minimum = minimumRating {
            let actual = metadata.xmp?.rating ?? 0
            if actual < minimum {
                issues.append(ValidationIssue(
                    field: "XMP-xmp:Rating",
                    message: "Requires at least \(Self.formatRating(minimum)) stars, found \(Self.formatRating(actual))",
                    severity: .error))
            }
        }

        // Format validation
        if enforceFormats {
            issues.append(contentsOf: validateFormats(metadata))
        }

        return ValidationResult(issues: issues)
    }

    // MARK: - Format Validation

    private func validateFormats(_ metadata: ImageMetadata) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // Urgency: must be 1-8
        if let urgencyStr = metadata.iptc.value(for: .urgency) {
            if let urgency = Int(urgencyStr) {
                if urgency < 1 || urgency > 8 {
                    issues.append(ValidationIssue(
                        field: "IPTC:Urgency",
                        message: "Must be 1-8, got \(urgency)",
                        severity: .error))
                }
            } else {
                issues.append(ValidationIssue(
                    field: "IPTC:Urgency",
                    message: "Must be a digit 1-8, got '\(urgencyStr)'",
                    severity: .error))
            }
        }

        // DateCreated: must be YYYYMMDD (8 digits)
        if let date = metadata.iptc.dateCreated {
            if !isValidIPTCDate(date) {
                issues.append(ValidationIssue(
                    field: "IPTC:DateCreated",
                    message: "Must be YYYYMMDD format, got '\(date)'",
                    severity: .error))
            }
        }

        // TimeCreated: must be HHMMSS±HHMM (11 chars) or HHMMSS (6 chars)
        if let time = metadata.iptc.timeCreated {
            if !isValidIPTCTime(time) {
                issues.append(ValidationIssue(
                    field: "IPTC:TimeCreated",
                    message: "Must be HHMMSS±HHMM format, got '\(time)'",
                    severity: .error))
            }
        }

        // CountryCode: must be 3 uppercase letters (ISO 3166-1 alpha-3)
        if let code = metadata.iptc.countryCode {
            if !isValidCountryCode(code) {
                issues.append(ValidationIssue(
                    field: "IPTC:Country-PrimaryLocationCode",
                    message: "Must be 3 uppercase letters (ISO 3166-1 alpha-3), got '\(code)'",
                    severity: .error))
            }
        }

        // ObjectCycle: must be "a" (morning), "p" (evening), or "b" (both)
        if let cycle = metadata.iptc.value(for: .objectCycle) {
            if cycle != "a" && cycle != "p" && cycle != "b" {
                issues.append(ValidationIssue(
                    field: "IPTC:ObjectCycle",
                    message: "Must be 'a', 'p', or 'b', got '\(cycle)'",
                    severity: .error))
            }
        }

        // DigitalSourceType: should be from IPTC controlled vocabulary
        if let xmp = metadata.xmp, let dst = xmp.digitalSourceType {
            if !dst.hasPrefix("http://cv.iptc.org/newscodes/digitalsourcetype/") {
                issues.append(ValidationIssue(
                    field: "XMP-Iptc4xmpExt:DigitalSourceType",
                    message: "Should use an IPTC controlled vocabulary URI (http://cv.iptc.org/newscodes/digitalsourcetype/...)",
                    severity: .warning))
            }
        }

        return issues
    }

    private func isValidIPTCDate(_ date: String) -> Bool {
        guard date.count == 8, date.allSatisfy(\.isNumber) else { return false }
        let month = Int(date[date.index(date.startIndex, offsetBy: 4)..<date.index(date.startIndex, offsetBy: 6)]) ?? 0
        let day = Int(date[date.index(date.startIndex, offsetBy: 6)...]) ?? 0
        return month >= 1 && month <= 12 && day >= 1 && day <= 31
    }

    private func isValidIPTCTime(_ time: String) -> Bool {
        // Accept HHMMSS (6), HHMMSS±HH (9), or HHMMSS±HHMM (11)
        guard time.count == 6 || time.count == 9 || time.count == 11 else { return false }
        let hhmmss = time.prefix(6)
        guard hhmmss.allSatisfy(\.isNumber) else { return false }
        let hh = Int(hhmmss.prefix(2)) ?? 99
        let mm = Int(hhmmss.dropFirst(2).prefix(2)) ?? 99
        let ss = Int(hhmmss.dropFirst(4).prefix(2)) ?? 99
        guard hh <= 23, mm <= 59, ss <= 59 else { return false }
        if time.count > 6 {
            let sign = time[time.index(time.startIndex, offsetBy: 6)]
            guard sign == "+" || sign == "-" else { return false }
            let offset = time[time.index(time.startIndex, offsetBy: 7)...]
            guard offset.allSatisfy(\.isNumber) else { return false }
        }
        return true
    }

    private func isValidCountryCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isUppercase && $0.isLetter }
    }

    private static func formatRating(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - Built-in Profiles

    /// News wire submission profile (AP/Reuters/AFP standards).
    /// Requires: headline, caption, byline, credit, city, country, date, copyright, keywords.
    public static let newsWire = MetadataValidator(
        requiredFields: [
            "IPTC:Headline",
            "IPTC:Caption-Abstract",
            "IPTC:By-line",
            "IPTC:Credit",
            "IPTC:City",
            "IPTC:Country-PrimaryLocationName",
            "IPTC:DateCreated",
            "IPTC:CopyrightNotice",
            "IPTC:Keywords",
        ],
        recommendedFields: [
            "IPTC:Source",
            "IPTC:Province-State",
            "IPTC:Country-PrimaryLocationCode",
            "IPTC:SpecialInstructions",
            "IPTC:OriginalTransmissionReference",
        ],
        enforceFormats: true,
        minimumKeywords: 1
    )

    /// Stock photography profile.
    /// Requires: headline, caption, keywords (≥3), copyright, byline.
    public static let stockPhoto = MetadataValidator(
        requiredFields: [
            "IPTC:Headline",
            "IPTC:Caption-Abstract",
            "IPTC:By-line",
            "IPTC:CopyrightNotice",
            "IPTC:Keywords",
        ],
        recommendedFields: [
            "IPTC:City",
            "IPTC:Country-PrimaryLocationName",
            "IPTC:Source",
            "XMP-Iptc4xmpExt:DigitalSourceType",
        ],
        enforceFormats: true,
        minimumKeywords: 3
    )

    /// Editorial-desk quality review. Gates submissions on xmp:Rating in addition to the
    /// core set required by the news/editorial profiles.
    public static let qualityReview = MetadataValidator(
        requiredFields: [
            "IPTC:Headline",
            "IPTC:Caption-Abstract",
            "IPTC:By-line",
            "IPTC:Credit",
        ],
        recommendedFields: [
            "IPTC:CopyrightNotice",
            "IPTC:Keywords",
        ],
        enforceFormats: true,
        minimumKeywords: 0,
        minimumRating: 3.0
    )

    /// Editorial/feature profile.
    /// Requires: headline, caption, byline, credit.
    public static let editorial = MetadataValidator(
        requiredFields: [
            "IPTC:Headline",
            "IPTC:Caption-Abstract",
            "IPTC:By-line",
            "IPTC:Credit",
        ],
        recommendedFields: [
            "IPTC:CopyrightNotice",
            "IPTC:Keywords",
            "IPTC:City",
            "IPTC:DateCreated",
        ],
        enforceFormats: true,
        minimumKeywords: 0
    )
}
