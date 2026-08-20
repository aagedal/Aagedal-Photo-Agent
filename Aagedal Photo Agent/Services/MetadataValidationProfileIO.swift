import Foundation

/// File boundary for portable newsroom validation profiles.
///
/// The model owns schema migration while this service owns semantic validation and safe file I/O.
/// Keeping those concerns outside the UI lets future assignment packages reuse the exact same
/// import rules.
nonisolated struct MetadataValidationProfileIO: Sendable {
    static let maximumFileSize = 1_048_576

    func encode(_ profile: MetadataValidationProfile) throws -> Data {
        try validate(profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(profile)
        data.append(0x0A)
        return data
    }

    func decode(_ data: Data) throws -> MetadataValidationProfile {
        guard data.count <= Self.maximumFileSize else {
            throw MetadataValidationProfileIOError.fileTooLarge(
                found: data.count,
                limit: Self.maximumFileSize
            )
        }
        try EditorialJSONSchema.requireWritableVersion(
            in: data,
            supportedVersion: MetadataValidationProfile.currentSchemaVersion,
            documentName: "metadata validation profile"
        )
        let profile = try JSONDecoder().decode(MetadataValidationProfile.self, from: data)
        try validate(profile)
        return profile
    }

    func export(_ profile: MetadataValidationProfile, to destination: URL) throws {
        try encode(profile).write(to: destination, options: .atomic)
    }

    func importProfile(from source: URL) throws -> MetadataValidationProfile {
        let resourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize, fileSize > Self.maximumFileSize {
            throw MetadataValidationProfileIOError.fileTooLarge(
                found: fileSize,
                limit: Self.maximumFileSize
            )
        }
        return try decode(Data(contentsOf: source, options: .mappedIfSafe))
    }

    func validate(_ profile: MetadataValidationProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MetadataValidationProfileIOError.emptyProfileName
        }

        var ruleIDs = Set<String>()
        for (index, rule) in profile.rules.enumerated() {
            let ruleID = rule.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ruleID.isEmpty else {
                throw MetadataValidationProfileIOError.emptyRuleID(index: index)
            }
            guard ruleIDs.insert(ruleID).inserted else {
                throw MetadataValidationProfileIOError.duplicateRuleID(ruleID)
            }

            switch rule.requirement {
            case .required, .forbidsPlaceholder:
                break
            case let .minimumLength(_, count):
                guard count > 0 else {
                    throw MetadataValidationProfileIOError.invalidMinimumLength(
                        ruleID: ruleID,
                        count: count
                    )
                }
            case let .maximumLength(_, count), let .maximumUTF8Bytes(_, count):
                guard count >= 0 else {
                    throw MetadataValidationProfileIOError.invalidMaximumLength(
                        ruleID: ruleID,
                        count: count
                    )
                }
            case let .pattern(_, expression):
                do {
                    _ = try NSRegularExpression(pattern: expression)
                } catch {
                    throw MetadataValidationProfileIOError.invalidPattern(
                        ruleID: ruleID,
                        detail: error.localizedDescription
                    )
                }
            case let .allowedValues(_, values):
                guard !values.isEmpty else {
                    throw MetadataValidationProfileIOError.emptyAllowedValues(ruleID: ruleID)
                }
                guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw MetadataValidationProfileIOError.emptyAllowedValue(ruleID: ruleID)
                }
            case let .requires(field, whenPresent):
                guard field != whenPresent else {
                    throw MetadataValidationProfileIOError.selfDependency(
                        ruleID: ruleID,
                        field: field
                    )
                }
            }
        }
    }
}

nonisolated enum MetadataValidationProfileIOError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(found: Int, limit: Int)
    case emptyProfileName
    case emptyRuleID(index: Int)
    case duplicateRuleID(String)
    case invalidMinimumLength(ruleID: String, count: Int)
    case invalidMaximumLength(ruleID: String, count: Int)
    case invalidPattern(ruleID: String, detail: String)
    case emptyAllowedValues(ruleID: String)
    case emptyAllowedValue(ruleID: String)
    case selfDependency(ruleID: String, field: MetadataFieldID)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(found, limit):
            "The validation profile is \(found) bytes; the maximum supported size is \(limit) bytes."
        case .emptyProfileName:
            "The validation profile must have a name."
        case let .emptyRuleID(index):
            "Validation rule \(index + 1) must have a stable identifier."
        case let .duplicateRuleID(id):
            "The validation profile contains the rule identifier “\(id)” more than once."
        case let .invalidMinimumLength(ruleID, count):
            "Rule “\(ruleID)” has invalid minimum length \(count); it must be greater than zero."
        case let .invalidMaximumLength(ruleID, count):
            "Rule “\(ruleID)” has invalid maximum length \(count); it cannot be negative."
        case let .invalidPattern(ruleID, detail):
            "Rule “\(ruleID)” has an invalid pattern: \(detail)"
        case let .emptyAllowedValues(ruleID):
            "Rule “\(ruleID)” must contain at least one allowed value."
        case let .emptyAllowedValue(ruleID):
            "Rule “\(ruleID)” contains an empty allowed value."
        case let .selfDependency(ruleID, field):
            "Rule “\(ruleID)” cannot require \(field.displayName) when that same field is present."
        }
    }
}
