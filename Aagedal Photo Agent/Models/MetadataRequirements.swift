import Foundation

/// How strictly an IPTC field is enforced when judging whether an image is "complete".
nonisolated enum MetadataRequirementLevel: String, Codable, CaseIterable, Sendable {
    /// Never flagged when empty.
    case optional
    /// Flagged as a soft warning (amber) when empty — does not mark the image incomplete in the
    /// browser filter and never blocks upload.
    case warnOnEmpty
    /// Flagged as a hard requirement (red) when empty — marks the image incomplete in the browser's
    /// Required Metadata filter and blocks FTP upload.
    case require
}

/// Per-field metadata requirement levels, configured in Settings → Library & Metadata. One global
/// config drives both the browser's "Required metadata" filter and the FTP upload checks.
///
/// Persisted as JSON `[MetadataFieldID.rawValue: Level.rawValue]` under
/// `metadataRequirementLevels`; fields
/// absent from the map are `.optional` (so the stored map stays sparse). The first read with no
/// stored map migrates the legacy binary `requiredMetadataFields` set — those fields become
/// `.require` — falling back to `MetadataFieldID.defaultCheckedFields` when nothing was configured.
nonisolated enum MetadataRequirements {
    typealias Levels = [MetadataFieldID: MetadataRequirementLevel]
    typealias MinimumLengths = [MetadataFieldID: Int]

    static let defaultMinimumLengths: MinimumLengths = [.headline: 10, .description: 30]

    static func load(from defaults: UserDefaults = .standard) -> Levels {
        if let data = defaults.data(forKey: UserDefaultsKeys.metadataRequirementLevels),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            var levels: Levels = [:]
            for (key, value) in raw {
                guard let field = MetadataFieldID(rawValue: key),
                      let level = MetadataRequirementLevel(rawValue: value),
                      level != .optional else { continue }
                levels[field] = level
            }
            return levels
        }
        // Migrate the legacy binary required set (or its default): each required field → .require.
        return Dictionary(uniqueKeysWithValues: legacyRequiredSet(from: defaults).map { ($0, .require) })
    }

    static func save(_ levels: Levels, to defaults: UserDefaults = .standard) {
        // Preserve entries this build cannot interpret. Preference maps predate an enclosing
        // schema marker, so dropping unknown future field/level values during an unrelated edit
        // would be an irreversible downgrade.
        let existing = defaults.data(forKey: UserDefaultsKeys.metadataRequirementLevels)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        var raw = existing.filter { key, value in
            MetadataFieldID(rawValue: key) == nil
                || MetadataRequirementLevel(rawValue: value) == nil
        }
        levels.forEach { pair in
            if pair.value != .optional { raw[pair.key.rawValue] = pair.value.rawValue }
        }
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: UserDefaultsKeys.metadataRequirementLevels)
        }
    }

    /// The fields marked `.require`. The browser's Complete/Incomplete filter treats only hard
    /// requirements (not warnings) as making an image incomplete.
    static func requireFields(from defaults: UserDefaults = .standard) -> Set<MetadataFieldID> {
        Set(load(from: defaults).filter { $0.value == .require }.keys)
    }

    static func loadMinimumLengths(from defaults: UserDefaults = .standard) -> MinimumLengths {
        guard let data = defaults.data(forKey: UserDefaultsKeys.metadataMinimumLengths),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return defaultMinimumLengths
        }
        return raw.reduce(into: MinimumLengths()) { result, pair in
            if let field = MetadataFieldID(rawValue: pair.key), pair.value > 0 {
                result[field] = pair.value
            }
        }
    }

    static func saveMinimumLengths(_ lengths: MinimumLengths, to defaults: UserDefaults = .standard) {
        let existing = defaults.data(forKey: UserDefaultsKeys.metadataMinimumLengths)
            .flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        var raw = existing.filter { key, value in
            MetadataFieldID(rawValue: key) == nil || value <= 0
        }
        for pair in lengths where pair.value > 0 {
            raw[pair.key.rawValue] = pair.value
        }
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: UserDefaultsKeys.metadataMinimumLengths)
        }
    }

    static func fieldFails(_ field: MetadataFieldID, in metadata: IPTCMetadata,
                           levels: Levels, minimumLengths: MinimumLengths) -> Bool {
        let profile = MetadataValidationProfile.currentRequirements(
            levels: levels.filter { $0.key == field },
            minimumLengths: minimumLengths.filter { $0.key == field }
        )
        return MetadataValidationEngine().validate(
            metadata,
            imageURL: URL(fileURLWithPath: "/validation/field"),
            profile: profile
        ).issues.contains { $0.field == field }
    }

    private static func legacyRequiredSet(from defaults: UserDefaults) -> Set<MetadataFieldID> {
        guard let data = defaults.data(forKey: UserDefaultsKeys.requiredMetadataFields),
              let keys = try? JSONDecoder().decode([MetadataFieldID].self, from: data) else {
            return MetadataFieldID.defaultCheckedFields
        }
        return Set(keys)
    }
}
