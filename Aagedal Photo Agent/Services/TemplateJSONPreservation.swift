import Foundation
import CoreFoundation

/// Storage-only compatibility handling. Never infer ownership of a key from the new
/// draft: omitted known keys represent clears, whereas extensions belong to the file.
nonisolated enum TemplateJSONPreservation {
    private static let metadataKeys: Set<String> = [
        "schemaVersion", "id", "name", "templateType", "presetType", "fields",
        "shortcutSlot", "processInstantly"
    ]
    private static let fieldKeys: Set<String> = ["id", "fieldKey", "templateValue"]
    private static let developKeys: Set<String> = [
        "schemaVersion", "id", "name", "settings", "shortcutSlot", "includesCrop"
    ]

    static func metadata(replacement: Data, existing: Data) throws -> Data {
        let old = try object(existing)
        var new = try object(replacement)
        try preserveExtensions(from: old, in: &new, owned: metadataKeys)
        let oldFields = old["fields"] as? [[String: Any]] ?? []
        var fieldsByID: [UUID: [String: Any]] = [:]
        for field in oldFields {
            guard let rawID = field["id"] as? String, let id = UUID(uuidString: rawID),
                  fieldsByID.updateValue(field, forKey: id) == nil else {
                throw PreservationError.ambiguousFieldIdentity
            }
        }
        var seen = Set<UUID>()
        var fields = new["fields"] as? [[String: Any]] ?? []
        for index in fields.indices {
            guard let rawID = fields[index]["id"] as? String, let id = UUID(uuidString: rawID),
                  seen.insert(id).inserted else {
                throw PreservationError.ambiguousFieldIdentity
            }
            if let oldField = fieldsByID[id] {
                try preserveExtensions(from: oldField, in: &fields[index], owned: fieldKeys)
            }
        }
        // Removing a field intentionally removes its whole record. Extensions follow
        // retained field UUIDs through reorder; they never migrate to another field.
        new["fields"] = fields
        return try JSONSerialization.data(withJSONObject: new, options: [.sortedKeys])
    }

    static func develop(replacement: Data, existing: Data, decodedExisting: Data) throws -> Data {
        let old = try object(existing)
        let roundTrip = try object(decodedExisting)
        // Settings contain optional objects, enum payloads and ordered arrays without
        // universal identity. Refuse any lossy decode before allowing their replacement.
        // This also conservatively refuses explicit nulls or sanitized decoder state
        // omitted by the model, rather than guessing whether those members are owned.
        guard let oldSettings = old["settings"], let decodedSettings = roundTrip["settings"],
              retainsMembers(original: oldSettings, decoded: decodedSettings) else {
            throw PreservationError.unsupportedDevelopSettings
        }
        var new = try object(replacement)
        try preserveExtensions(from: old, in: &new, owned: developKeys)
        return try JSONSerialization.data(withJSONObject: new, options: [.sortedKeys])
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        do {
            try KnownPeoplePackageManifest.validateJSONStructure(data)
        } catch {
            throw PreservationError.ambiguousJSON
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditorialJSONSchemaError.invalidTopLevelJSON
        }
        return value
    }

    private static func preserveExtensions(
        from old: [String: Any], in new: inout [String: Any], owned: Set<String>
    ) throws {
        for (key, value) in old where !owned.contains(key) {
            guard preservesExactly(value) else { throw PreservationError.numericExtension }
            new[key] = value
        }
    }

    // Foundation may round arbitrary-precision JSON numbers while parsing. Refuse
    // numeric extensions rather than silently changing values owned by another writer.
    // Booleans are NSNumber too, but their exact representation is unambiguous.
    private static func preservesExactly(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        if let object = value as? [String: Any] { return object.values.allSatisfy(preservesExactly) }
        if let array = value as? [Any] { return array.allSatisfy(preservesExactly) }
        return true
    }

    private static func retainsMembers(original: Any, decoded: Any) -> Bool {
        if let object = original as? [String: Any] {
            guard let counterpart = decoded as? [String: Any] else { return false }
            return object.allSatisfy { key, value in
                guard let retained = counterpart[key] else { return false }
                return retainsMembers(original: value, decoded: retained)
            }
        }
        if let array = original as? [Any] {
            guard let counterpart = decoded as? [Any], array.count == counterpart.count else { return false }
            return zip(array, counterpart).allSatisfy { retainsMembers(original: $0, decoded: $1) }
        }
        return (original as? NSObject)?.isEqual(decoded) == true
    }

    enum PreservationError: LocalizedError {
        case mismatchedIdentity
        case ambiguousJSON
        case numericExtension
        case ambiguousFieldIdentity
        case unsupportedDevelopSettings

        var errorDescription: String? {
            switch self {
            case .mismatchedIdentity:
                "The existing template file belongs to a different template identity. The original file was preserved. Save as New to keep an independent copy."
            case .ambiguousJSON:
                "The template has ambiguous or unsupported JSON structure. The original file was preserved."
            case .numericExtension:
                "The template contains extension numbers this version cannot safely preserve. The original file was preserved. Save as New to keep an independent copy of the supported fields."
            case .ambiguousFieldIdentity:
                "The template contains duplicate field identities. The original file was preserved. Save as New to keep an independent copy."
            case .unsupportedDevelopSettings:
                "The Develop template contains settings this version cannot safely preserve. The original file was preserved. Save as New to keep an independent copy of the supported settings."
            }
        }
    }
}
