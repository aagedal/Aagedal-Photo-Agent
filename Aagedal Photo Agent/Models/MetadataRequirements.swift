import Foundation

/// The set of IPTC fields the user marks as mandatory, configured in Settings → Metadata and used
/// by the browser's "Required metadata" filter. Persisted as a JSON-encoded `[FieldKey]` under
/// `UserDefaultsKeys.requiredMetadataFields`.
///
/// A missing key means "never configured" → fall back to `FieldKey.defaultCheckedFields` (Headline,
/// Description, Creator, Copyright), the same set the FTP pre-upload check defaults to, so the two
/// completeness checks stay consistent. A stored empty array is honored as "nothing required".
nonisolated enum MetadataRequirements {
    static func load(from defaults: UserDefaults = .standard) -> Set<IPTCMetadata.FieldKey> {
        guard let data = defaults.data(forKey: UserDefaultsKeys.requiredMetadataFields),
              let keys = try? JSONDecoder().decode([IPTCMetadata.FieldKey].self, from: data) else {
            return IPTCMetadata.FieldKey.defaultCheckedFields
        }
        return Set(keys)
    }

    static func save(_ fields: Set<IPTCMetadata.FieldKey>, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(Array(fields)) {
            defaults.set(data, forKey: UserDefaultsKeys.requiredMetadataFields)
        }
    }
}
