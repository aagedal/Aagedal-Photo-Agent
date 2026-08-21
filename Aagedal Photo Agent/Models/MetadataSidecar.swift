import Foundation

/// How much of a changed metadata value is retained in editing history.
///
/// Exact values can be replayed. Summarized and redacted entries deliberately cannot: silently
/// reconstructing only part of a value would be more dangerous than declining the restore.
nonisolated enum MetadataHistoryValueStorage: String, Codable, Sendable {
    case exact
    case summarized
    case redacted
}

nonisolated struct MetadataHistoryEntry: Codable, Sendable, Identifiable {
    /// Existing sidecars did not persist an ID. Include the field identity in the fallback so
    /// simultaneous edits do not collide in SwiftUI lists as they did when `Date` was the ID.
    var id: String { "\(timestamp.timeIntervalSinceReferenceDate)-\(fieldID?.rawValue ?? fieldName)" }

    let timestamp: Date
    /// Stable identity for normal editor fields. `fieldName` remains for old sidecars and audit
    /// events which do not correspond to an editable metadata field.
    let fieldID: MetadataFieldID?
    let fieldName: String
    /// Canonical values used for lossless replay. They are omitted for summarized/redacted entries.
    let oldValue: String?
    let newValue: String?
    private let oldValueSummary: String?
    private let newValueSummary: String?
    let valueStorage: MetadataHistoryValueStorage

    var displayName: String { fieldID?.displayName ?? (fieldName == "Title" ? "Headline" : fieldName) }
    var displayOldValue: String? {
        oldValueSummary ?? Self.displayValue(oldValue, for: fieldID, fieldName: fieldName)
    }
    var displayNewValue: String? {
        newValueSummary ?? Self.displayValue(newValue, for: fieldID, fieldName: fieldName)
    }
    var isRestorable: Bool { valueStorage == .exact }

    /// Source-compatible initializer for older call sites and non-field audit events.
    init(timestamp: Date, fieldName: String, oldValue: String?, newValue: String?) {
        self.timestamp = timestamp
        self.fieldID = MetadataFieldID(legacyHistoryName: fieldName)
        self.fieldName = fieldName
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldValueSummary = nil
        self.newValueSummary = nil
        self.valueStorage = .exact
    }

    init(
        timestamp: Date,
        fieldID: MetadataFieldID,
        oldValue: String?,
        newValue: String?
    ) {
        self.timestamp = timestamp
        self.fieldID = fieldID
        self.fieldName = fieldID.displayName

        let storage = Self.storage(for: fieldID, oldValue: oldValue, newValue: newValue)
        self.valueStorage = storage
        switch storage {
        case .exact:
            self.oldValue = oldValue
            self.newValue = newValue
            self.oldValueSummary = nil
            self.newValueSummary = nil
        case .summarized:
            self.oldValue = nil
            self.newValue = nil
            self.oldValueSummary = Self.summary(of: oldValue, for: fieldID)
            self.newValueSummary = Self.summary(of: newValue, for: fieldID)
        case .redacted:
            self.oldValue = nil
            self.newValue = nil
            self.oldValueSummary = Self.redactedSummary(of: oldValue)
            self.newValueSummary = Self.redactedSummary(of: newValue)
        }
    }

    /// Creates a count-only/redacted entry for structured or location-bearing metadata which must
    /// not be copied into an audit trail merely to make history readable.
    init(
        timestamp: Date,
        fieldName: String,
        oldSummary: String?,
        newSummary: String?,
        valueStorage: MetadataHistoryValueStorage
    ) {
        precondition(valueStorage != .exact)
        self.timestamp = timestamp
        self.fieldID = nil
        self.fieldName = fieldName
        self.oldValue = nil
        self.newValue = nil
        self.oldValueSummary = oldSummary
        self.newValueSummary = newSummary
        self.valueStorage = valueStorage
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, fieldID, fieldName, oldValue, newValue
        case oldValueSummary, newValueSummary, valueStorage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        fieldName = try container.decode(String.self, forKey: .fieldName)
        fieldID = try container.decodeIfPresent(MetadataFieldID.self, forKey: .fieldID)
            ?? MetadataFieldID(legacyHistoryName: fieldName)
        oldValueSummary = try container.decodeIfPresent(String.self, forKey: .oldValueSummary)
        newValueSummary = try container.decodeIfPresent(String.self, forKey: .newValueSummary)
        // Absence means the legacy exact-value format. This is the compatibility boundary which
        // keeps existing histories replayable after migration.
        valueStorage = try container.decodeIfPresent(
            MetadataHistoryValueStorage.self,
            forKey: .valueStorage
        ) ?? .exact
        if valueStorage == .exact {
            oldValue = try container.decodeIfPresent(String.self, forKey: .oldValue)
            newValue = try container.decodeIfPresent(String.self, forKey: .newValue)
        } else {
            // Treat storage policy as authoritative even for hand-edited or malformed input. This
            // prevents a supposedly hidden value from leaking back out on the next sidecar save.
            oldValue = nil
            newValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(fieldID, forKey: .fieldID)
        try container.encode(fieldName, forKey: .fieldName)
        try container.encodeIfPresent(oldValue, forKey: .oldValue)
        try container.encodeIfPresent(newValue, forKey: .newValue)
        try container.encodeIfPresent(oldValueSummary, forKey: .oldValueSummary)
        try container.encodeIfPresent(newValueSummary, forKey: .newValueSummary)
        try container.encode(valueStorage, forKey: .valueStorage)
    }

    /// Replays an exact entry. Returns `false` instead of partially applying an entry whose value
    /// was intentionally not retained.
    @discardableResult
    func apply(to metadata: inout IPTCMetadata) -> Bool {
        guard isRestorable else { return false }
        if let fieldID {
            fieldID.setHistoryValue(newValue, in: &metadata)
            return true
        }

        // Compatibility for historical entries which predate MetadataFieldID or live outside
        // the editor-field registry.
        switch fieldName {
        case "GPS", "GPS Coordinates":
            let parts = newValue?.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? []
            guard parts.isEmpty || (parts.count == 2 && Double(parts[0]) != nil && Double(parts[1]) != nil) else {
                return false
            }
            metadata.latitude = parts.count == 2 ? Double(parts[0]) : nil
            metadata.longitude = parts.count == 2 ? Double(parts[1]) : nil
        case "Rating":
            metadata.rating = newValue.flatMap(Int.init)
        case "Label":
            metadata.label = newValue
        case "Capture Date":
            metadata.captureDate = newValue
        case "Orientation":
            metadata.exifOrientation = newValue.flatMap(Int.init)
        case "Variables processed":
            // This historical audit event describes a bulk action rather than a metadata value.
            return true
        default:
            // Unknown legacy events cannot safely claim to have restored anything.
            return false
        }
        return true
    }

    /// Builds entries for every descriptive field currently represented by `IPTCMetadata`, plus
    /// rating/label and the structured editorial fields not represented by MetadataFieldID.
    static func changes(
        from previous: IPTCMetadata,
        to edited: IPTCMetadata,
        timestamp: Date
    ) -> [Self] {
        var changes: [Self] = MetadataFieldID.allCases.compactMap { field in
            let oldValue = field.historyValue(in: previous)
            let newValue = field.historyValue(in: edited)
            guard oldValue != newValue else { return nil }
            return Self(timestamp: timestamp, fieldID: field, oldValue: oldValue, newValue: newValue)
        }

        func recordExact(_ name: String, _ oldValue: String?, _ newValue: String?) {
            guard oldValue != newValue else { return }
            changes.append(Self(timestamp: timestamp, fieldName: name, oldValue: oldValue, newValue: newValue))
        }
        func recordRedacted(_ name: String, changed: Bool, oldPresent: Bool, newPresent: Bool) {
            guard changed else { return }
            changes.append(Self(
                timestamp: timestamp,
                fieldName: name,
                oldSummary: oldPresent ? "Present (value hidden)" : nil,
                newSummary: newPresent ? "Present (value hidden)" : nil,
                valueStorage: .redacted
            ))
        }

        recordExact("Capture Date", previous.captureDate, edited.captureDate)
        recordExact("Rating", previous.rating.map(String.init), edited.rating.map(String.init))
        recordExact("Label", previous.label, edited.label)
        recordRedacted(
            "Creator Contact Information",
            changed: previous.creatorContactInfo != edited.creatorContactInfo,
            oldPresent: !(previous.creatorContactInfo?.isEmpty ?? true),
            newPresent: !(edited.creatorContactInfo?.isEmpty ?? true)
        )
        recordRedacted(
            "Location Created",
            changed: previous.locationsCreated != edited.locationsCreated,
            oldPresent: previous.locationsCreated.contains { !$0.isEmpty },
            newPresent: edited.locationsCreated.contains { !$0.isEmpty }
        )
        recordRedacted(
            "Location Shown",
            changed: previous.locationsShown != edited.locationsShown,
            oldPresent: previous.locationsShown.contains { !$0.isEmpty },
            newPresent: edited.locationsShown.contains { !$0.isEmpty }
        )
        recordRedacted(
            "GPS Coordinates",
            changed: previous.latitude != edited.latitude || previous.longitude != edited.longitude,
            oldPresent: previous.latitude != nil || previous.longitude != nil,
            newPresent: edited.latitude != nil || edited.longitude != nil
        )
        return changes
    }

    private static func storage(
        for field: MetadataFieldID,
        oldValue: String?,
        newValue: String?
    ) -> MetadataHistoryValueStorage {
        switch field {
        case .digitalImageGUID, .imageSupplierImageID, .imageSupplier, .jobId:
            return .redacted
        case .description, .extendedDescription, .rightsUsageTerms, .instructions:
            return .summarized
        default:
            let longest = max(oldValue?.count ?? 0, newValue?.count ?? 0)
            return longest > 160 ? .summarized : .exact
        }
    }

    private static func summary(of value: String?, for field: MetadataFieldID) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch field {
        case .keywords, .personShown, .organisationShownName, .organisationShownCode, .sceneCode,
                .subjectCode, .mediaTopic, .genre:
            let count = repeatableValues(from: value)?.count
                ?? value.split(separator: ",", omittingEmptySubsequences: true).count
            return "\(count) value\(count == 1 ? "" : "s")"
        default:
            break
        }
        return "\(value.count) characters"
    }

    private static func redactedSummary(of value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return "Present (value hidden)"
    }

    private static func displayValue(
        _ value: String?,
        for field: MetadataFieldID?,
        fieldName: String
    ) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let repeatableValues = field.flatMap { $0.isRepeatable ? Self.repeatableValues(from: value) : nil }
        switch field {
        case .digitalSourceType:
            return DigitalSourceType(metadataValue: value)?.displayName ?? value
        case .sceneCode:
            return (repeatableValues ?? value.components(separatedBy: ", ")).map {
                IPTCSceneCode.entry(for: $0)?.displayValue ?? $0
            }.joined(separator: ", ")
        case .urgency:
            if value == "1" { return "1 — Most urgent" }
            if value == "8" { return "8 — Least urgent" }
            return value
        case .countryCode:
            guard let country = ISO3166Country.all.first(where: { $0.alpha3 == value }) else {
                return value
            }
            return "\(country.alpha3) — \(country.localizedName())"
        default:
            if let repeatableValues {
                return repeatableValues.joined(separator: ", ")
            }
            if fieldName == "Rating", let rating = Int(value), (1...5).contains(rating) {
                return "\(String(repeating: "★", count: rating)) (\(rating))"
            }
            if fieldName == "Label" {
                let label = ColorLabel.fromMetadataLabel(value)
                return label == .none ? value : label.displayName
            }
            return value
        }
    }

    private static func repeatableValues(from value: String) -> [String]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

nonisolated struct MetadataSidecar: Codable, Sendable {
    static let currentSchemaVersion = 1
    /// Source compatibility for call sites that used the original name.
    static let currentVersion = currentSchemaVersion
    static let historyLimit = 20

    var schemaVersion: Int
    /// Source compatibility for code that still refers to the legacy JSON key.
    var version: Int { schemaVersion }
    var sourceFile: String
    var lastModified: Date
    var pendingChanges: Bool
    var metadata: IPTCMetadata
    var imageMetadataSnapshot: IPTCMetadata?
    var history: [MetadataHistoryEntry]

    init(
        sourceFile: String,
        lastModified: Date = Date(),
        pendingChanges: Bool = false,
        metadata: IPTCMetadata = IPTCMetadata(),
        imageMetadataSnapshot: IPTCMetadata? = nil,
        history: [MetadataHistoryEntry] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sourceFile = sourceFile
        self.lastModified = lastModified
        self.pendingChanges = pendingChanges
        self.metadata = metadata
        self.imageMetadataSnapshot = imageMetadataSnapshot
        self.history = history
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, version
        case sourceFile, lastModified, pendingChanges, metadata, imageMetadataSnapshot, history
    }

    static let persistedJSONFieldNames = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .version)
            ?? 1
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "metadata sidecar",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard decodedVersion == 1 else {
            throw EditorialJSONSchemaError.unsupportedOlderSchema(
                document: "metadata sidecar",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }

        schemaVersion = Self.currentSchemaVersion
        sourceFile = try container.decode(String.self, forKey: .sourceFile)
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? .distantPast
        pendingChanges = try container.decodeIfPresent(Bool.self, forKey: .pendingChanges) ?? false
        metadata = try container.decodeIfPresent(IPTCMetadata.self, forKey: .metadata) ?? IPTCMetadata()
        imageMetadataSnapshot = try container.decodeIfPresent(
            IPTCMetadata.self,
            forKey: .imageMetadataSnapshot
        )
        history = try container.decodeIfPresent([MetadataHistoryEntry].self, forKey: .history) ?? []
        history.trimToHistoryLimit()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(sourceFile, forKey: .sourceFile)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(pendingChanges, forKey: .pendingChanges)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(imageMetadataSnapshot, forKey: .imageMetadataSnapshot)
        try container.encode(history, forKey: .history)
    }
}

extension Array where Element == MetadataHistoryEntry {
    nonisolated mutating func trimToHistoryLimit() {
        let limit = MetadataSidecar.historyLimit
        guard count > limit else { return }
        removeFirst(count - limit)
    }
}
