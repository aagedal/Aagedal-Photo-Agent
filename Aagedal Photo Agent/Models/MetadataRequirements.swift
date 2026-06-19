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
/// Persisted as JSON `[FieldKey.rawValue: Level.rawValue]` under `metadataRequirementLevels`; fields
/// absent from the map are `.optional` (so the stored map stays sparse). The first read with no
/// stored map migrates the legacy binary `requiredMetadataFields` set — those fields become
/// `.require` — falling back to `FieldKey.defaultCheckedFields` when nothing was ever configured.
nonisolated enum MetadataRequirements {
    typealias Levels = [IPTCMetadata.FieldKey: MetadataRequirementLevel]

    static func load(from defaults: UserDefaults = .standard) -> Levels {
        if let data = defaults.data(forKey: UserDefaultsKeys.metadataRequirementLevels),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            var levels: Levels = [:]
            for (key, value) in raw {
                guard let field = IPTCMetadata.FieldKey(rawValue: key),
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
        let raw = levels.reduce(into: [String: String]()) { dict, pair in
            if pair.value != .optional { dict[pair.key.rawValue] = pair.value.rawValue }
        }
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: UserDefaultsKeys.metadataRequirementLevels)
        }
    }

    /// The fields marked `.require`. The browser's Complete/Incomplete filter treats only hard
    /// requirements (not warnings) as making an image incomplete.
    static func requireFields(from defaults: UserDefaults = .standard) -> Set<IPTCMetadata.FieldKey> {
        Set(load(from: defaults).filter { $0.value == .require }.keys)
    }

    private static func legacyRequiredSet(from defaults: UserDefaults) -> Set<IPTCMetadata.FieldKey> {
        guard let data = defaults.data(forKey: UserDefaultsKeys.requiredMetadataFields),
              let keys = try? JSONDecoder().decode([IPTCMetadata.FieldKey].self, from: data) else {
            return IPTCMetadata.FieldKey.defaultCheckedFields
        }
        return Set(keys)
    }
}
