import Foundation

nonisolated struct DeadlineProfileReferenceCatalog: Equatable, Sendable {
    var validationProfileIdentifiers: Set<String>
    var metadataTemplateIdentifiers: Set<String>
    var listIdentifiers: Set<String>
    var renameRecipeIdentifiers: Set<String>
    var exportConfigurationIdentifiers: Set<String>
    var connectionIdentifiers: Set<String>

    init(
        validationProfileIdentifiers: Set<String> = [],
        metadataTemplateIdentifiers: Set<String> = [],
        listIdentifiers: Set<String> = [],
        renameRecipeIdentifiers: Set<String> = [],
        exportConfigurationIdentifiers: Set<String> = [],
        connectionIdentifiers: Set<String> = []
    ) {
        self.validationProfileIdentifiers = validationProfileIdentifiers
        self.metadataTemplateIdentifiers = metadataTemplateIdentifiers
        self.listIdentifiers = listIdentifiers
        self.renameRecipeIdentifiers = renameRecipeIdentifiers
        self.exportConfigurationIdentifiers = exportConfigurationIdentifiers
        self.connectionIdentifiers = connectionIdentifiers
    }
}

nonisolated enum DeadlineProfileDiagnostic: Equatable, Sendable {
    case missingValidationProfile(identifier: String)
    case missingMetadataTemplate(identifier: String)
    case missingList(identifier: String)
    case missingRenameRecipe(identifier: String)
    case missingExportConfiguration(identifier: String)
    case missingDestinationConnection(identifier: String)
}

/// Pure JSON boundary plus structural/reference validation for deadline profiles.
nonisolated struct DeadlineProfileIO: Sendable {
    static let maximumFileSize = 4 * 1_048_576

    func encode(_ profile: DeadlineProfile) throws -> Data {
        try validate(profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(profile)
        data.append(0x0A)
        return data
    }

    func decode(_ data: Data) throws -> DeadlineProfile {
        guard data.count <= Self.maximumFileSize else {
            throw DeadlineProfileIOError.fileTooLarge(found: data.count, limit: Self.maximumFileSize)
        }
        try EditorialJSONSchema.requireWritableVersion(
            in: data,
            supportedVersion: DeadlineProfile.currentSchemaVersion,
            documentName: "deadline profile",
            unversionedLegacyVersion: 1
        )
        let profile = try JSONDecoder().decode(DeadlineProfile.self, from: data)
        try validate(profile)
        return profile
    }

    func export(_ profile: DeadlineProfile, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try Data(contentsOf: destination, options: .mappedIfSafe)
            try EditorialJSONSchema.requireWritableVersion(
                in: existing,
                supportedVersion: DeadlineProfile.currentSchemaVersion,
                documentName: "deadline profile",
                unversionedLegacyVersion: 1
            )
        }
        try encode(profile).write(to: destination, options: .atomic)
    }

    func importProfile(from source: URL) throws -> DeadlineProfile {
        let resourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        if let size = resourceValues.fileSize, size > Self.maximumFileSize {
            throw DeadlineProfileIOError.fileTooLarge(found: size, limit: Self.maximumFileSize)
        }
        return try decode(Data(contentsOf: source, options: .mappedIfSafe))
    }

    func validate(_ profile: DeadlineProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeadlineProfileIOError.emptyProfileName
        }

        let order = profile.captionFields.orderedFieldIDs
        guard Set(order).count == order.count else {
            throw DeadlineProfileIOError.duplicateCaptionField
        }
        let visible = profile.captionFields.visibleFieldIDs
        guard Set(visible).count == visible.count else {
            throw DeadlineProfileIOError.duplicateVisibleCaptionField
        }
        guard Set(visible).isSubset(of: Set(order)) else {
            throw DeadlineProfileIOError.visibleCaptionFieldMissingFromOrder
        }

        try validateReference(profile.validationProfile.flatMap(reference))
        if let template = profile.metadataTemplate {
            try validateReference(reference(template.source))
            if case let .snapshot(snapshot) = template.source {
                let fieldIDs = snapshot.fields.map(\.fieldID)
                guard Set(fieldIDs).count == fieldIDs.count else {
                    throw DeadlineProfileIOError.duplicateMetadataTemplateField
                }
            }
        }
        var listIdentifiers = Set<String>()
        for list in profile.requiredLists {
            try validateReference(list)
            guard listIdentifiers.insert(list.identifier).inserted else {
                throw DeadlineProfileIOError.duplicateRequiredListIdentifier(list.identifier)
            }
        }
        if let rename = profile.rename {
            try validateReference(reference(rename.recipe))
        }
        if let export = profile.export {
            try validateReference(reference(export))
            if case let .snapshot(snapshot) = export {
                guard (0...1).contains(snapshot.sdrQuality),
                      (0...1).contains(snapshot.hdrQuality) else {
                    throw DeadlineProfileIOError.invalidExportQuality
                }
                if let maximum = snapshot.maximumOutputByteCount, maximum <= 0 {
                    throw DeadlineProfileIOError.invalidMaximumOutputByteCount
                }
            }
        }
        if let destination = profile.destination {
            let identifier = destination.connectionIdentifier
            guard let parsedIdentifier = UUID(uuidString: identifier),
                  parsedIdentifier.uuidString.lowercased() == identifier
            else {
                throw DeadlineProfileIOError.invalidDestinationConnectionIdentifier(identifier)
            }
            guard !destination.remotePathTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeadlineProfileIOError.emptyRemotePathTemplate
            }
        }
    }

    func diagnostics(
        for profile: DeadlineProfile,
        catalog: DeadlineProfileReferenceCatalog
    ) -> [DeadlineProfileDiagnostic] {
        var result: [DeadlineProfileDiagnostic] = []
        if let reference = profile.validationProfile.flatMap(reference),
           !catalog.validationProfileIdentifiers.contains(reference.identifier) {
            result.append(.missingValidationProfile(identifier: reference.identifier))
        }
        if let template = profile.metadataTemplate,
           let reference = reference(template.source),
           !catalog.metadataTemplateIdentifiers.contains(reference.identifier) {
            result.append(.missingMetadataTemplate(identifier: reference.identifier))
        }
        for list in profile.requiredLists where !catalog.listIdentifiers.contains(list.identifier) {
            result.append(.missingList(identifier: list.identifier))
        }
        if let rename = profile.rename,
           let reference = reference(rename.recipe),
           !catalog.renameRecipeIdentifiers.contains(reference.identifier) {
            result.append(.missingRenameRecipe(identifier: reference.identifier))
        }
        if let export = profile.export,
           let reference = reference(export),
           !catalog.exportConfigurationIdentifiers.contains(reference.identifier) {
            result.append(.missingExportConfiguration(identifier: reference.identifier))
        }
        if let destination = profile.destination,
           !catalog.connectionIdentifiers.contains(destination.connectionIdentifier) {
            result.append(.missingDestinationConnection(identifier: destination.connectionIdentifier))
        }
        return result
    }

    private func validateReference(_ reference: DeadlineResourceReference?) throws {
        guard let reference else { return }
        guard !reference.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeadlineProfileIOError.emptyResourceIdentifier
        }
    }

    private func reference(_ source: DeadlineValidationProfileSource) -> DeadlineResourceReference? {
        guard case let .reference(reference) = source else { return nil }
        return reference
    }

    private func reference(_ source: DeadlineMetadataTemplateSource) -> DeadlineResourceReference? {
        guard case let .reference(reference) = source else { return nil }
        return reference
    }

    private func reference(_ source: DeadlineRenameRecipeSource) -> DeadlineResourceReference? {
        guard case let .reference(reference) = source else { return nil }
        return reference
    }

    private func reference(_ source: DeadlineExportConfigurationSource) -> DeadlineResourceReference? {
        guard case let .reference(reference) = source else { return nil }
        return reference
    }
}

nonisolated enum DeadlineProfileIOError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(found: Int, limit: Int)
    case emptyProfileName
    case duplicateCaptionField
    case duplicateVisibleCaptionField
    case visibleCaptionFieldMissingFromOrder
    case duplicateMetadataTemplateField
    case duplicateRequiredListIdentifier(String)
    case emptyResourceIdentifier
    case invalidExportQuality
    case invalidMaximumOutputByteCount
    case invalidDestinationConnectionIdentifier(String)
    case emptyRemotePathTemplate

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(found, limit):
            "The deadline profile is \(found) bytes; the maximum supported size is \(limit) bytes."
        case .emptyProfileName: "The deadline profile must have a name."
        case .duplicateCaptionField: "The caption field order contains a duplicate field."
        case .duplicateVisibleCaptionField: "The visible caption fields contain a duplicate field."
        case .visibleCaptionFieldMissingFromOrder:
            "Every visible caption field must also appear in the ordered field list."
        case .duplicateMetadataTemplateField:
            "The metadata template snapshot contains the same field more than once."
        case let .duplicateRequiredListIdentifier(identifier):
            "The deadline profile references list “\(identifier)” more than once."
        case .emptyResourceIdentifier: "A referenced deadline resource has no stable identifier."
        case .invalidExportQuality: "Export quality must be between zero and one."
        case .invalidMaximumOutputByteCount:
            "The maximum encoded output size must be greater than zero bytes."
        case let .invalidDestinationConnectionIdentifier(identifier):
            "The deadline destination connection identifier must be a canonical UUID, not “\(identifier)”."
        case .emptyRemotePathTemplate: "The deadline destination must provide a remote path template."
        }
    }
}
