import Foundation

/// Shared schema checks for user-authored editorial JSON documents.
///
/// These documents predate the repository's atomic JSON store and use both `version`
/// and unversioned legacy shapes. Keeping the lightweight check here lets their existing
/// storage services reject data from a newer build before decoding or overwriting it.
nonisolated enum EditorialJSONSchema {
    static func version(
        in data: Data,
        currentKey: String = "schemaVersion",
        legacyKey: String? = nil,
        unversionedLegacyVersion: Int? = nil
    ) throws -> Int {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw EditorialJSONSchemaError.invalidTopLevelJSON
        }

        if let version = object[currentKey] as? Int, version > 0 {
            return version
        }
        if object[currentKey] != nil {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        if let legacyKey, let version = object[legacyKey] as? Int, version > 0 {
            return version
        }
        if let legacyKey, object[legacyKey] != nil {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        if let unversionedLegacyVersion {
            return unversionedLegacyVersion
        }
        throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
    }

    static func requireWritableVersion(
        in data: Data,
        supportedVersion: Int,
        documentName: String,
        legacyKey: String? = nil,
        unversionedLegacyVersion: Int? = nil
    ) throws {
        let found = try version(
            in: data,
            legacyKey: legacyKey,
            unversionedLegacyVersion: unversionedLegacyVersion
        )
        guard found <= supportedVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: documentName,
                found: found,
                supported: supportedVersion
            )
        }
    }
}

nonisolated enum EditorialJSONSchemaError: Error, Equatable, LocalizedError, Sendable {
    case invalidTopLevelJSON
    case missingOrInvalidSchemaVersion
    case unsupportedOlderSchema(document: String, found: Int, supported: Int)
    case newerSchemaRequiresReadOnly(document: String, found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTopLevelJSON:
            "The JSON document must contain a top-level object."
        case .missingOrInvalidSchemaVersion:
            "The JSON document has no valid schema version."
        case .unsupportedOlderSchema(let document, let found, let supported):
            "The \(document) uses schema version \(found), which cannot be migrated to version \(supported)."
        case .newerSchemaRequiresReadOnly(let document, let found, let supported):
            "The \(document) uses schema version \(found), newer than supported version \(supported), and cannot be changed by this build."
        }
    }
}
