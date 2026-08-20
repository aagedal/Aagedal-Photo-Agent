import Foundation

/// Severity shared by metadata editing, review, filtering, and delivery preflight.
nonisolated enum MetadataValidationSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case warning
    case blocker

    fileprivate var sortRank: Int {
        switch self {
        case .blocker: return 0
        case .warning: return 1
        case .information: return 2
        }
    }
}

/// One testable metadata requirement. Rules deliberately reference stable field IDs rather than
/// labels or container-specific XMP/IIM tags.
nonisolated enum MetadataValidationRequirement: Codable, Equatable, Sendable {
    case required(field: MetadataFieldID)
    case minimumLength(field: MetadataFieldID, count: Int)
    case maximumLength(field: MetadataFieldID, count: Int)
    case pattern(field: MetadataFieldID, expression: String)
    case allowedValues(field: MetadataFieldID, values: [String])
    case requires(field: MetadataFieldID, whenPresent: MetadataFieldID)
    case forbidsPlaceholder(field: MetadataFieldID)

    var field: MetadataFieldID {
        switch self {
        case let .required(field), let .minimumLength(field, _),
             let .maximumLength(field, _), let .pattern(field, _),
             let .allowedValues(field, _), let .requires(field, _),
             let .forbidsPlaceholder(field):
            return field
        }
    }
}

/// A stable rule definition. `id` is persisted and becomes part of issue identity so callers can
/// reconcile results across refreshes without depending on localized messages.
nonisolated struct MetadataValidationRule: Codable, Equatable, Sendable {
    let id: String
    let severity: MetadataValidationSeverity
    let requirement: MetadataValidationRequirement
    let message: String?

    init(
        id: String,
        severity: MetadataValidationSeverity,
        requirement: MetadataValidationRequirement,
        message: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.requirement = requirement
        self.message = message
    }
}

/// Versioned, portable configuration for the shared validation engine.
nonisolated struct MetadataValidationProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var rules: [MetadataValidationRule]

    init(id: UUID = UUID(), name: String, rules: [MetadataValidationRule]) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "metadata validation profile",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }
        schemaVersion = Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rules = try container.decode([MetadataValidationRule].self, forKey: .rules)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(rules, forKey: .rules)
    }
}

/// A single failure suitable for both compact badges and detailed remediation UI.
nonisolated struct MetadataValidationIssue: Equatable, Sendable, Identifiable {
    let id: String
    let imageURL: URL
    let field: MetadataFieldID
    let severity: MetadataValidationSeverity
    let message: String
    let technicalDetail: String?
}

/// Stable aggregate used by batch and deadline surfaces.
nonisolated struct MetadataValidationReport: Equatable, Sendable {
    let issues: [MetadataValidationIssue]

    var blockerCount: Int { issues.count { $0.severity == .blocker } }
    var warningCount: Int { issues.count { $0.severity == .warning } }
    var informationCount: Int { issues.count { $0.severity == .information } }
    var isBlocked: Bool { blockerCount > 0 }

    /// Rules retain profile order within a severity, making “Fix Next Issue” deterministic.
    var nextBlockingIssue: MetadataValidationIssue? {
        issues.first { $0.severity == .blocker }
    }
}

nonisolated struct MetadataValidationEngine: Sendable {
    func validate(
        _ metadata: IPTCMetadata,
        imageURL: URL,
        profile: MetadataValidationProfile
    ) -> MetadataValidationReport {
        let indexedIssues = profile.rules.enumerated().compactMap { index, rule in
            issue(for: rule, metadata: metadata, imageURL: imageURL).map { (index, $0) }
        }
        .sorted {
            if $0.1.severity.sortRank != $1.1.severity.sortRank {
                return $0.1.severity.sortRank < $1.1.severity.sortRank
            }
            return $0.0 < $1.0
        }
        return MetadataValidationReport(issues: indexedIssues.map(\.1))
    }

    private func issue(
        for rule: MetadataValidationRule,
        metadata: IPTCMetadata,
        imageURL: URL
    ) -> MetadataValidationIssue? {
        let field = rule.requirement.field
        let value = field.textValue(in: metadata)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = validationValues(for: field, in: metadata)
        let detail: String?
        let defaultMessage: String

        switch rule.requirement {
        case .required:
            guard field.isEmpty(in: metadata) else { return nil }
            defaultMessage = "\(field.displayName) is required."
            detail = nil

        case let .minimumLength(_, count):
            guard count > 0, let value, !value.isEmpty, value.count < count else { return nil }
            defaultMessage = "\(field.displayName) must contain at least \(count) characters."
            detail = "Current length: \(value.count)."

        case let .maximumLength(_, count):
            guard count >= 0, let value, value.count > count else { return nil }
            defaultMessage = "\(field.displayName) must contain no more than \(count) characters."
            detail = "Current length: \(value.count)."

        case let .pattern(_, expression):
            guard let value, !value.isEmpty else { return nil }
            guard let regex = try? NSRegularExpression(pattern: expression) else {
                defaultMessage = "\(field.displayName) could not be validated."
                detail = "Invalid validation expression in rule \(rule.id)."
                return makeIssue(rule, field: field, imageURL: imageURL, message: defaultMessage, detail: detail)
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard regex.firstMatch(in: value, range: range)?.range == range else {
                return makeIssue(
                    rule,
                    field: field,
                    imageURL: imageURL,
                    message: rule.message ?? "\(field.displayName) has an invalid format.",
                    detail: "Value does not match the configured expression."
                )
            }
            return nil

        case let .allowedValues(_, allowedValues):
            func normalized(_ candidate: String) -> String {
                if field == .digitalSourceType {
                    return canonicalVocabularyValue(candidate)
                }
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let allowed = Set(allowedValues.map(normalized))
            let rejected = values.filter { !allowed.contains(normalized($0)) }
            guard !rejected.isEmpty else { return nil }
            defaultMessage = "\(field.displayName) contains a value outside the approved vocabulary."
            detail = "Rejected canonical value count: \(rejected.count)."

        case let .requires(_, whenPresent):
            guard !whenPresent.isEmpty(in: metadata), field.isEmpty(in: metadata) else { return nil }
            defaultMessage = "\(field.displayName) is required when \(whenPresent.displayName) is present."
            detail = nil

        case .forbidsPlaceholder:
            guard values.contains(where: MetadataTemplatePlaceholderDetector.containsPlaceholder) else {
                return nil
            }
            defaultMessage = "\(field.displayName) contains an unresolved template variable."
            detail = "Resolve template variables before delivery."
        }

        return makeIssue(
            rule,
            field: field,
            imageURL: imageURL,
            message: rule.message ?? defaultMessage,
            detail: detail
        )
    }

    private func makeIssue(
        _ rule: MetadataValidationRule,
        field: MetadataFieldID,
        imageURL: URL,
        message: String,
        detail: String?
    ) -> MetadataValidationIssue {
        MetadataValidationIssue(
            id: "\(imageURL.standardizedFileURL.path)|\(rule.id)|\(field.rawValue)",
            imageURL: imageURL,
            field: field,
            severity: rule.severity,
            message: message,
            technicalDetail: detail
        )
    }

    private func validationValues(for field: MetadataFieldID, in metadata: IPTCMetadata) -> [String] {
        switch field {
        case .keywords: return metadata.keywords
        case .personShown: return metadata.personShown
        default: return field.textValue(in: metadata).map { [$0] } ?? []
        }
    }

    /// Vocabulary aliases are normalized before comparison. Unknown schemes remain unchanged so
    /// the caller can report them rather than silently accepting a display label.
    private func canonicalVocabularyValue(_ value: String) -> String {
        DigitalSourceType(metadataValue: value)?.newsCodeURI
            ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum MetadataTemplatePlaceholderDetector {
    private static let expression = try! NSRegularExpression(
        pattern: #"\{(?:date(?::[^{}]+)?|dateCreated(?::[^{}]+)?|dateCaptured(?::[^{}]+)?|filename|initials|persons|keywords|gps(?::(?:city|country))?|latitude|longitude|seq(?::\d+)?|field:[^{}]+)\}"#
    )

    static func containsPlaceholder(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }
}

extension MetadataValidationProfile {
    /// Bridges the shipped Settings model into the generalized rule engine. Sparse optional fields
    /// remain absent, preserving current browser and upload behavior.
    nonisolated static func currentRequirements(
        levels: MetadataRequirements.Levels,
        minimumLengths: MetadataRequirements.MinimumLengths
    ) -> Self {
        var rules: [MetadataValidationRule] = []
        for field in MetadataFieldID.allCases {
            let level = levels[field] ?? .optional
            guard level != .optional else { continue }
            let severity: MetadataValidationSeverity = level == .require ? .blocker : .warning
            rules.append(MetadataValidationRule(
                id: "legacy.required.\(field.rawValue)",
                severity: severity,
                requirement: .required(field: field)
            ))
            if let minimum = minimumLengths[field], minimum > 0 {
                rules.append(MetadataValidationRule(
                    id: "legacy.minimumLength.\(field.rawValue)",
                    severity: severity,
                    requirement: .minimumLength(field: field, count: minimum)
                ))
            }
        }
        return MetadataValidationProfile(
            id: UUID(uuidString: "605C608F-D256-4A31-A986-51EB878FA699")!,
            name: "Photo Agent Default",
            rules: rules
        )
    }
}
