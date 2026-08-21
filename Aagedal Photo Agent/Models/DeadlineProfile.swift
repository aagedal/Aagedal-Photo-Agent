import Foundation

/// A portable, secret-free description of the work that must happen before delivery.
///
/// Connections are represented only by stable identifiers. Authentication material remains in
/// the application's connection store and must never be serialized into this document.
nonisolated struct DeadlineProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var validationProfile: DeadlineValidationProfileSource?
    var captionFields: DeadlineCaptionFieldConfiguration
    var metadataTemplate: DeadlineMetadataTemplateConfiguration?
    /// Controlled-vocabulary, approved-values, or other newsroom list dependencies.
    var requiredLists: [DeadlineResourceReference]
    var rename: DeadlineRenameConfiguration?
    var export: DeadlineExportConfigurationSource?
    var destination: DeadlineDestinationConfiguration?
    var gpsPolicy: DeadlineGPSPolicy
    var metadataWriteStrategy: DeadlineMetadataWriteStrategy

    init(
        id: UUID = UUID(),
        name: String,
        validationProfile: DeadlineValidationProfileSource? = nil,
        captionFields: DeadlineCaptionFieldConfiguration = .default,
        metadataTemplate: DeadlineMetadataTemplateConfiguration? = nil,
        requiredLists: [DeadlineResourceReference] = [],
        rename: DeadlineRenameConfiguration? = nil,
        export: DeadlineExportConfigurationSource? = nil,
        destination: DeadlineDestinationConfiguration? = nil,
        gpsPolicy: DeadlineGPSPolicy = .retain,
        metadataWriteStrategy: DeadlineMetadataWriteStrategy = .stagedCopies
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.validationProfile = validationProfile
        self.captionFields = captionFields
        self.metadataTemplate = metadataTemplate
        self.requiredLists = requiredLists
        self.rename = rename
        self.export = export
        self.destination = destination
        self.gpsPolicy = gpsPolicy
        self.metadataWriteStrategy = metadataWriteStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, validationProfile, captionFields, metadataTemplate, requiredLists
        case rename, export, destination, gpsPolicy, metadataWriteStrategy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "deadline profile",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }

        schemaVersion = Self.currentSchemaVersion
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Deadline"
        validationProfile = try container.decodeIfPresent(
            DeadlineValidationProfileSource.self,
            forKey: .validationProfile
        )
        captionFields = try container.decodeIfPresent(
            DeadlineCaptionFieldConfiguration.self,
            forKey: .captionFields
        ) ?? .default
        metadataTemplate = try container.decodeIfPresent(
            DeadlineMetadataTemplateConfiguration.self,
            forKey: .metadataTemplate
        )
        requiredLists = try container.decodeIfPresent(
            [DeadlineResourceReference].self,
            forKey: .requiredLists
        ) ?? []
        rename = try container.decodeIfPresent(DeadlineRenameConfiguration.self, forKey: .rename)
        export = try container.decodeIfPresent(
            DeadlineExportConfigurationSource.self,
            forKey: .export
        )
        destination = try container.decodeIfPresent(
            DeadlineDestinationConfiguration.self,
            forKey: .destination
        )
        gpsPolicy = try container.decodeIfPresent(DeadlineGPSPolicy.self, forKey: .gpsPolicy)
            ?? .retain
        metadataWriteStrategy = try container.decodeIfPresent(
            DeadlineMetadataWriteStrategy.self,
            forKey: .metadataWriteStrategy
        ) ?? .xmpSidecars
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(validationProfile, forKey: .validationProfile)
        try container.encode(captionFields, forKey: .captionFields)
        try container.encodeIfPresent(metadataTemplate, forKey: .metadataTemplate)
        try container.encode(requiredLists, forKey: .requiredLists)
        try container.encodeIfPresent(rename, forKey: .rename)
        try container.encodeIfPresent(export, forKey: .export)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encode(gpsPolicy, forKey: .gpsPolicy)
        try container.encode(metadataWriteStrategy, forKey: .metadataWriteStrategy)
    }
}

nonisolated struct DeadlineResourceReference: Codable, Equatable, Sendable {
    var identifier: String
    var displayName: String?

    init(identifier: String, displayName: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName
    }

    init(id: UUID, displayName: String? = nil) {
        self.init(identifier: id.uuidString.lowercased(), displayName: displayName)
    }
}

nonisolated enum DeadlineValidationProfileSource: Codable, Equatable, Sendable {
    case reference(DeadlineResourceReference)
    case snapshot(MetadataValidationProfile)
}

nonisolated struct DeadlineCaptionFieldConfiguration: Codable, Equatable, Sendable {
    /// Stable editor order, including fields currently hidden from the deadline workspace.
    var orderedFieldIDs: [MetadataFieldID]
    /// A list rather than a set keeps serialized output deterministic.
    var visibleFieldIDs: [MetadataFieldID]

    init(orderedFieldIDs: [MetadataFieldID], visibleFieldIDs: [MetadataFieldID]) {
        self.orderedFieldIDs = orderedFieldIDs
        self.visibleFieldIDs = visibleFieldIDs
    }

    static let `default` = Self(
        orderedFieldIDs: MetadataFieldID.editorFields,
        visibleFieldIDs: MetadataFieldID.editorFields
    )
}

nonisolated enum DeadlineTemplateVariablePolicy: String, Codable, Equatable, Sendable {
    case preservePlaceholders
    case processWhenApplied
    case processAtDeadline
}

/// A self-contained metadata template shape. It intentionally excludes shortcut/UI state.
nonisolated struct DeadlineMetadataTemplateSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var templateType: TemplateType
    var fields: [DeadlineMetadataTemplateField]

    init(
        id: UUID,
        name: String,
        templateType: TemplateType,
        fields: [DeadlineMetadataTemplateField]
    ) {
        self.id = id
        self.name = name
        self.templateType = templateType
        self.fields = fields
    }

    init(validating template: MetadataTemplate) throws {
        let convertedFields = try template.fields.map { field in
            guard let converted = DeadlineMetadataTemplateField(field) else {
                throw DeadlineProfileSnapshotError.unsupportedMetadataTemplateFieldKey(field.fieldKey)
            }
            return converted
        }
        self.init(
            id: template.id,
            name: template.name,
            templateType: TemplateType(rawValue: template.templateType.rawValue) ?? .full,
            fields: convertedFields
        )
    }

    nonisolated enum TemplateType: String, Codable, Equatable, Sendable {
        case full = "Full"
        case perField = "Per Field"
    }
}

nonisolated struct DeadlineMetadataTemplateField: Codable, Equatable, Sendable {
    var fieldID: MetadataFieldID
    var templateValue: String

    init(fieldID: MetadataFieldID, templateValue: String) {
        self.fieldID = fieldID
        self.templateValue = templateValue
    }

    init?(_ field: TemplateField) {
        guard let fieldID = MetadataFieldID(rawValue: field.fieldKey) else { return nil }
        self.init(fieldID: fieldID, templateValue: field.templateValue)
    }
}

nonisolated enum DeadlineMetadataTemplateSource: Codable, Equatable, Sendable {
    case reference(DeadlineResourceReference)
    case snapshot(DeadlineMetadataTemplateSnapshot)
}

nonisolated struct DeadlineMetadataTemplateConfiguration: Codable, Equatable, Sendable {
    var source: DeadlineMetadataTemplateSource
    var variablePolicy: DeadlineTemplateVariablePolicy

    init(
        source: DeadlineMetadataTemplateSource,
        variablePolicy: DeadlineTemplateVariablePolicy
    ) {
        self.source = source
        self.variablePolicy = variablePolicy
    }
}

nonisolated enum DeadlineRenameRecipeSource: Codable, Equatable, Sendable {
    case reference(DeadlineResourceReference)
    case snapshot(BatchRenameRecipe)
}

nonisolated struct DeadlineRenameConfiguration: Codable, Equatable, Sendable {
    var recipe: DeadlineRenameRecipeSource
    var collisionPolicy: RenameCollisionPolicy

    init(recipe: DeadlineRenameRecipeSource, collisionPolicy: RenameCollisionPolicy) {
        self.recipe = recipe
        self.collisionPolicy = collisionPolicy
    }
}

nonisolated enum DeadlineExportConfigurationSource: Codable, Equatable, Sendable {
    case reference(DeadlineResourceReference)
    case snapshot(DeadlineExportSnapshot)
}

/// Codable equivalents of the renderer's stable choices. The snapshot deliberately stores no
/// local security-scoped URL; deadline destinations are resolved separately.
nonisolated struct DeadlineExportSnapshot: Codable, Equatable, Sendable {
    var sdrFormat: SDRFormat
    var sdrQuality: Double
    var sdrGamut: ColorGamut
    var hdrFormat: HDRFormat
    var hdrQuality: Double
    var hdrGamut: ColorGamut
    var tiffCompression: TIFFCompressionMode
    var resolutionLimit: ResolutionLimit
    /// Optional newsroom hard limit for each final encoded delivery artifact. This is checked
    /// exactly after staged metadata verification; preflight estimates are advisory evidence.
    var maximumOutputByteCount: Int64?

    init(
        sdrFormat: SDRFormat,
        sdrQuality: Double,
        sdrGamut: ColorGamut,
        hdrFormat: HDRFormat,
        hdrQuality: Double,
        hdrGamut: ColorGamut,
        tiffCompression: TIFFCompressionMode,
        resolutionLimit: ResolutionLimit,
        maximumOutputByteCount: Int64? = nil
    ) {
        self.sdrFormat = sdrFormat
        self.sdrQuality = sdrQuality
        self.sdrGamut = sdrGamut
        self.hdrFormat = hdrFormat
        self.hdrQuality = hdrQuality
        self.hdrGamut = hdrGamut
        self.tiffCompression = tiffCompression
        self.resolutionLimit = resolutionLimit
        self.maximumOutputByteCount = maximumOutputByteCount
    }

    init(_ configuration: AdvancedExportConfiguration) {
        self.init(
            sdrFormat: SDRFormat(rawValue: configuration.sdrFormat.rawValue) ?? .jpeg,
            sdrQuality: configuration.sdrQuality,
            sdrGamut: ColorGamut(rawValue: configuration.sdrGamut.rawValue) ?? .sRGB,
            hdrFormat: HDRFormat(rawValue: configuration.hdrFormat.rawValue) ?? .jpegGainMap,
            hdrQuality: configuration.hdrQuality,
            hdrGamut: ColorGamut(rawValue: configuration.hdrGamut.rawValue) ?? .displayP3,
            tiffCompression: TIFFCompressionMode(rawValue: configuration.tiffCompression.rawValue) ?? .lzw,
            resolutionLimit: ResolutionLimit(rawValue: configuration.resolutionLimit.rawValue) ?? .original,
            maximumOutputByteCount: nil
        )
    }

    nonisolated enum SDRFormat: String, Codable, Equatable, Sendable {
        case jpeg, png, tiff, heic, avif, avifFFmpeg, jxl
    }

    nonisolated enum HDRFormat: String, Codable, Equatable, Sendable {
        case jpegGainMap, heic10bit, avif10bit, avifFFmpeg10bit, jxl, tiff16bit, png16bit
    }

    nonisolated enum ColorGamut: String, Codable, Equatable, Sendable {
        case sRGB, displayP3, rec2020, adobeRGB
    }

    nonisolated enum TIFFCompressionMode: String, Codable, Equatable, Sendable {
        case none, lzw, zip
    }

    nonisolated enum ResolutionLimit: String, Codable, Equatable, Sendable {
        case original, pixels6000, pixels4000, pixels3000, pixels2048, pixels1600
    }
}

nonisolated struct DeadlineDestinationConfiguration: Codable, Equatable, Sendable {
    /// Stable lookup key for a separately stored connection. Never a URL containing credentials.
    var connectionIdentifier: String
    var remotePathTemplate: String

    init(connectionIdentifier: String, remotePathTemplate: String) {
        self.connectionIdentifier = connectionIdentifier
        self.remotePathTemplate = remotePathTemplate
    }
}

nonisolated enum DeadlineGPSPolicy: String, Codable, Equatable, Sendable {
    case retain
    case remove
}

nonisolated enum DeadlineMetadataWriteStrategy: String, Codable, Equatable, Sendable {
    case originals
    case xmpSidecars
    case stagedCopies
}

nonisolated enum DeadlineProfileSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedMetadataTemplateFieldKey(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedMetadataTemplateFieldKey(key):
            "The metadata template field key “\(key)” is not supported by deadline profiles."
        }
    }
}
