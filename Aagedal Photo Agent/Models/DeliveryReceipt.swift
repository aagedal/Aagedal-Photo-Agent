import Foundation

/// Privacy-preserving evidence for one completed delivery batch.
///
/// The receipt deliberately has no fields for credentials or editorial values. Metadata evidence
/// records stable field and issue identifiers only; it never records captions, names, or places.
nonisolated struct DeliveryReceipt: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    let id: UUID
    let batchIdentifier: UUID
    let profileIdentifier: UUID
    let applicationVersion: DeliveryApplicationVersion
    let startedAt: Date
    let completedAt: Date
    let destination: DeliveryReceiptDestination
    /// Complete batch-level warning acceptance from the frozen plan. Per-item lists below contain
    /// only warnings whose preflight evidence is scoped to that image.
    let acceptedWarningIdentifiers: [String]
    let items: [DeliveryReceiptItem]

    init(
        id: UUID = UUID(),
        batchIdentifier: UUID,
        profileIdentifier: UUID,
        applicationVersion: DeliveryApplicationVersion,
        startedAt: Date,
        completedAt: Date,
        destination: DeliveryReceiptDestination,
        acceptedWarningIdentifiers: [String] = [],
        items: [DeliveryReceiptItem]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.batchIdentifier = batchIdentifier
        self.profileIdentifier = profileIdentifier
        self.applicationVersion = applicationVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.destination = destination
        self.acceptedWarningIdentifiers = acceptedWarningIdentifiers
        self.items = items
    }

    var deterministicallyOrdered: Self {
        Self(
            id: id,
            batchIdentifier: batchIdentifier,
            profileIdentifier: profileIdentifier,
            applicationVersion: applicationVersion,
            startedAt: startedAt,
            completedAt: completedAt,
            destination: destination,
            acceptedWarningIdentifiers: sortedUniqueIdentifiers(acceptedWarningIdentifiers),
            items: items.map(\.deterministicallyOrdered).sorted(by: deliveryReceiptItemOrder)
        )
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DeliveryReceiptValidationError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard startedAt <= completedAt else {
            throw DeliveryReceiptValidationError.invalidTimestampOrder
        }
        try applicationVersion.validateForPersistence()
        try destination.validateForPersistence()
        try validateReceiptIdentifiers(acceptedWarningIdentifiers, field: "accepted warning")
        guard !items.isEmpty else {
            throw DeliveryReceiptValidationError.emptyItems
        }

        var deliveredNames = Set<String>()
        for item in items {
            try item.validateForPersistence(startedAt: startedAt, completedAt: completedAt)
            guard Set(item.acceptedWarningIdentifiers).isSubset(
                of: Set(acceptedWarningIdentifiers)
            ) else {
                throw DeliveryReceiptValidationError.invalidIdentifier(
                    field: "item accepted warning"
                )
            }
            let key = item.deliveredFilename.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard deliveredNames.insert(key).inserted else {
                throw DeliveryReceiptValidationError.duplicateDeliveredFilename(
                    item.deliveredFilename
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, batchIdentifier, profileIdentifier, applicationVersion
        case startedAt, completedAt, destination, acceptedWarningIdentifiers, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "delivery receipt",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }

        schemaVersion = Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        batchIdentifier = try container.decode(UUID.self, forKey: .batchIdentifier)
        profileIdentifier = try container.decode(UUID.self, forKey: .profileIdentifier)
        applicationVersion = try container.decode(
            DeliveryApplicationVersion.self,
            forKey: .applicationVersion
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        destination = try container.decode(DeliveryReceiptDestination.self, forKey: .destination)
        let decodedItems = try container.decode([DeliveryReceiptItem].self, forKey: .items)
        acceptedWarningIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .acceptedWarningIdentifiers
        ) ?? sortedUniqueIdentifiers(decodedItems.flatMap(\.acceptedWarningIdentifiers))
        items = decodedItems
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(batchIdentifier, forKey: .batchIdentifier)
        try container.encode(profileIdentifier, forKey: .profileIdentifier)
        try container.encode(applicationVersion, forKey: .applicationVersion)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(destination, forKey: .destination)
        try container.encode(
            sortedUniqueIdentifiers(acceptedWarningIdentifiers),
            forKey: .acceptedWarningIdentifiers
        )
        try container.encode(items.map(\.deterministicallyOrdered).sorted(by: deliveryReceiptItemOrder), forKey: .items)
    }
}

nonisolated struct DeliveryApplicationVersion: Codable, Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String

    init(marketingVersion: String, buildNumber: String) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    fileprivate func validateForPersistence() throws {
        try validateReceiptIdentifier(marketingVersion, field: "application marketing version")
        try validateReceiptIdentifier(buildNumber, field: "application build number")
    }
}

/// A stable connection identifier and resolved delivery path, without connection settings.
nonisolated struct DeliveryReceiptDestination: Codable, Equatable, Sendable {
    let identifier: String
    let path: String

    init(identifier: String, path: String) {
        self.identifier = identifier
        self.path = path
    }

    fileprivate func validateForPersistence() throws {
        guard let uuid = UUID(uuidString: identifier),
              identifier == uuid.uuidString.lowercased() else {
            throw DeliveryReceiptValidationError.invalidDestinationIdentifier
        }
        try validateReceiptText(path, field: "destination path", maximumLength: 4_096)
    }
}

/// Content identity only. Source filenames and filesystem paths are intentionally excluded.
nonisolated struct DeliveryReceiptSourceIdentity: Codable, Equatable, Sendable {
    let sha256: String
    let byteSize: Int64

    init(sha256: String, byteSize: Int64) {
        self.sha256 = sha256
        self.byteSize = byteSize
    }

    fileprivate func validateForPersistence() throws {
        try validateSHA256(sha256, field: "source SHA-256")
        guard byteSize >= 0 else {
            throw DeliveryReceiptValidationError.negativeByteSize(field: "source")
        }
    }
}

nonisolated enum DeliveryMetadataVerificationOutcome: String, Codable, Equatable, Sendable {
    case notPerformed
    case verified
    case verifiedWithWarnings
    case failed
}

/// Verification evidence contains identifiers only, never the corresponding metadata values.
nonisolated struct DeliveryMetadataVerificationResult: Codable, Equatable, Sendable {
    let outcome: DeliveryMetadataVerificationOutcome
    /// The exact verification registry used at read-back. This deliberately uses the broader
    /// verification-field type instead of the editor-only `MetadataFieldID`, so structured
    /// contact/location, GPS, rating, and label evidence cannot be silently discarded.
    let controlledFieldIdentifiers: [IPTCMetadataVerificationField]
    let issueIdentifiers: [String]

    init(
        outcome: DeliveryMetadataVerificationOutcome,
        controlledFieldIdentifiers: [IPTCMetadataVerificationField] = [],
        issueIdentifiers: [String] = []
    ) {
        self.outcome = outcome
        self.controlledFieldIdentifiers = controlledFieldIdentifiers
        self.issueIdentifiers = issueIdentifiers
    }

    fileprivate var deterministicallyOrdered: Self {
        Self(
            outcome: outcome,
            controlledFieldIdentifiers: controlledFieldIdentifiers.sorted {
                $0.rawValue < $1.rawValue
            },
            issueIdentifiers: sortedUniqueIdentifiers(issueIdentifiers)
        )
    }

    fileprivate func validateForPersistence() throws {
        guard Set(controlledFieldIdentifiers.map(\.rawValue)).count
                == controlledFieldIdentifiers.count else {
            throw DeliveryReceiptValidationError.invalidIdentifier(
                field: "controlled metadata field"
            )
        }
        try validateReceiptIdentifiers(issueIdentifiers, field: "metadata verification issue")
    }
}

/// Stable rendering facts needed to reproduce or audit an output, without source metadata.
nonisolated struct DeliveryRenderSettings: Codable, Equatable, Sendable {
    let formatIdentifier: String
    let colorSpaceIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let bitDepth: Int?
    let quality: Int?
    /// The configured per-file encoded-byte ceiling that this delivered artifact satisfied.
    let maximumOutputByteCount: Int64?

    init(
        formatIdentifier: String,
        colorSpaceIdentifier: String,
        pixelWidth: Int,
        pixelHeight: Int,
        bitDepth: Int? = nil,
        quality: Int? = nil,
        maximumOutputByteCount: Int64? = nil
    ) {
        self.formatIdentifier = formatIdentifier
        self.colorSpaceIdentifier = colorSpaceIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bitDepth = bitDepth
        self.quality = quality
        self.maximumOutputByteCount = maximumOutputByteCount
    }

    fileprivate func validateForPersistence() throws {
        try validateReceiptIdentifier(formatIdentifier, field: "render format")
        try validateReceiptIdentifier(colorSpaceIdentifier, field: "render color space")
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw DeliveryReceiptValidationError.invalidPixelDimensions
        }
        if let bitDepth, bitDepth <= 0 {
            throw DeliveryReceiptValidationError.invalidBitDepth
        }
        if let quality, !(0...100).contains(quality) {
            throw DeliveryReceiptValidationError.invalidQuality
        }
        if let maximumOutputByteCount, maximumOutputByteCount <= 0 {
            throw DeliveryReceiptValidationError.invalidMaximumOutputByteCount
        }
    }

    func recordingMaximumOutputByteCount(_ maximum: Int64?) -> Self {
        Self(
            formatIdentifier: formatIdentifier,
            colorSpaceIdentifier: colorSpaceIdentifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            bitDepth: bitDepth,
            quality: quality,
            maximumOutputByteCount: maximum
        )
    }
}

/// Protocol-level upload completion. It does not claim the remote bytes were independently read.
nonisolated struct DeliveryUploadAcknowledgement: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case notAttempted
        case protocolAcknowledged
        case rejected
    }

    let status: Status
    let acknowledgedAt: Date?

    init(status: Status, acknowledgedAt: Date? = nil) {
        self.status = status
        self.acknowledgedAt = acknowledgedAt
    }

    fileprivate func validateForPersistence(startedAt: Date, completedAt: Date) throws {
        switch status {
        case .notAttempted:
            guard acknowledgedAt == nil else {
                throw DeliveryReceiptValidationError.incoherentUploadAcknowledgement
            }
        case .protocolAcknowledged, .rejected:
            guard let acknowledgedAt,
                  (startedAt...completedAt).contains(acknowledgedAt) else {
                throw DeliveryReceiptValidationError.incoherentUploadAcknowledgement
            }
        }
    }
}

/// A separate remote size observation. A size match is not represented as content verification.
nonisolated struct DeliveryRemoteStatAcknowledgement: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable {
        case notRequested
        case unavailable
        case matchesDeliveredByteSize
        case doesNotMatchDeliveredByteSize
    }

    let status: Status
    let checkedAt: Date?
    let observedByteSize: Int64?

    init(status: Status, checkedAt: Date? = nil, observedByteSize: Int64? = nil) {
        self.status = status
        self.checkedAt = checkedAt
        self.observedByteSize = observedByteSize
    }

    fileprivate func validateForPersistence(
        deliveredByteSize: Int64,
        startedAt: Date,
        completedAt: Date
    ) throws {
        switch status {
        case .notRequested:
            guard checkedAt == nil, observedByteSize == nil else {
                throw DeliveryReceiptValidationError.incoherentRemoteStatAcknowledgement
            }
        case .unavailable:
            guard let checkedAt,
                  (startedAt...completedAt).contains(checkedAt),
                  observedByteSize == nil else {
                throw DeliveryReceiptValidationError.incoherentRemoteStatAcknowledgement
            }
        case .matchesDeliveredByteSize:
            guard let checkedAt,
                  (startedAt...completedAt).contains(checkedAt),
                  observedByteSize == deliveredByteSize else {
                throw DeliveryReceiptValidationError.incoherentRemoteStatAcknowledgement
            }
        case .doesNotMatchDeliveredByteSize:
            guard let checkedAt,
                  (startedAt...completedAt).contains(checkedAt),
                  let observedByteSize,
                  observedByteSize >= 0,
                  observedByteSize != deliveredByteSize else {
                throw DeliveryReceiptValidationError.incoherentRemoteStatAcknowledgement
            }
        }
    }
}

nonisolated struct DeliveryReceiptItem: Codable, Equatable, Sendable {
    let sourceIdentity: DeliveryReceiptSourceIdentity
    let deliveredFilename: String
    let deliveredSHA256: String
    let deliveredByteSize: Int64
    let metadataVerification: DeliveryMetadataVerificationResult
    let renderSettings: DeliveryRenderSettings
    let uploadAcknowledgement: DeliveryUploadAcknowledgement
    let remoteStatAcknowledgement: DeliveryRemoteStatAcknowledgement
    let acceptedWarningIdentifiers: [String]

    init(
        sourceIdentity: DeliveryReceiptSourceIdentity,
        deliveredFilename: String,
        deliveredSHA256: String,
        deliveredByteSize: Int64,
        metadataVerification: DeliveryMetadataVerificationResult,
        renderSettings: DeliveryRenderSettings,
        uploadAcknowledgement: DeliveryUploadAcknowledgement,
        remoteStatAcknowledgement: DeliveryRemoteStatAcknowledgement,
        acceptedWarningIdentifiers: [String] = []
    ) {
        self.sourceIdentity = sourceIdentity
        self.deliveredFilename = deliveredFilename
        self.deliveredSHA256 = deliveredSHA256
        self.deliveredByteSize = deliveredByteSize
        self.metadataVerification = metadataVerification
        self.renderSettings = renderSettings
        self.uploadAcknowledgement = uploadAcknowledgement
        self.remoteStatAcknowledgement = remoteStatAcknowledgement
        self.acceptedWarningIdentifiers = acceptedWarningIdentifiers
    }

    fileprivate var deterministicallyOrdered: Self {
        Self(
            sourceIdentity: sourceIdentity,
            deliveredFilename: deliveredFilename,
            deliveredSHA256: deliveredSHA256,
            deliveredByteSize: deliveredByteSize,
            metadataVerification: metadataVerification.deterministicallyOrdered,
            renderSettings: renderSettings,
            uploadAcknowledgement: uploadAcknowledgement,
            remoteStatAcknowledgement: remoteStatAcknowledgement,
            acceptedWarningIdentifiers: sortedUniqueIdentifiers(acceptedWarningIdentifiers)
        )
    }

    fileprivate func validateForPersistence(startedAt: Date, completedAt: Date) throws {
        try sourceIdentity.validateForPersistence()
        try validateDeliveredFilename(deliveredFilename)
        try validateSHA256(deliveredSHA256, field: "delivered SHA-256")
        guard deliveredByteSize >= 0 else {
            throw DeliveryReceiptValidationError.negativeByteSize(field: "delivered")
        }
        try metadataVerification.validateForPersistence()
        try renderSettings.validateForPersistence()
        if let maximum = renderSettings.maximumOutputByteCount,
           deliveredByteSize > maximum {
            throw DeliveryReceiptValidationError.deliveredOutputExceedsMaximum
        }
        try uploadAcknowledgement.validateForPersistence(
            startedAt: startedAt,
            completedAt: completedAt
        )
        try remoteStatAcknowledgement.validateForPersistence(
            deliveredByteSize: deliveredByteSize,
            startedAt: startedAt,
            completedAt: completedAt
        )
        try validateReceiptIdentifiers(acceptedWarningIdentifiers, field: "accepted warning")
    }
}

nonisolated enum DeliveryReceiptValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(found: Int, supported: Int)
    case invalidTimestampOrder
    case emptyItems
    case duplicateDeliveredFilename(String)
    case invalidIdentifier(field: String)
    case invalidDestinationIdentifier
    case invalidText(field: String)
    case invalidSHA256(field: String)
    case negativeByteSize(field: String)
    case invalidDeliveredFilename(String)
    case invalidPixelDimensions
    case invalidBitDepth
    case invalidQuality
    case invalidMaximumOutputByteCount
    case deliveredOutputExceedsMaximum
    case incoherentUploadAcknowledgement
    case incoherentRemoteStatAcknowledgement

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found, supported):
            "Delivery receipt schema \(found) is not supported; this app supports \(supported)."
        case .invalidTimestampOrder:
            "The delivery completion timestamp precedes its start timestamp."
        case .emptyItems:
            "A delivery receipt must contain at least one item."
        case let .duplicateDeliveredFilename(filename):
            "The delivered filename appears more than once: \(filename)"
        case let .invalidIdentifier(field):
            "The \(field) identifier is empty, too long, or contains control characters."
        case .invalidDestinationIdentifier:
            "The destination identifier must be a canonical lowercase UUID."
        case let .invalidText(field):
            "The \(field) is empty, too long, or contains control characters."
        case let .invalidSHA256(field):
            "The \(field) must be a lowercase 64-character SHA-256 digest."
        case let .negativeByteSize(field):
            "The \(field) byte size cannot be negative."
        case let .invalidDeliveredFilename(filename):
            "The delivered filename must be a single filename, not a path: \(filename)"
        case .invalidPixelDimensions:
            "Rendered pixel dimensions must be positive."
        case .invalidBitDepth:
            "Rendered bit depth must be positive."
        case .invalidQuality:
            "Rendered quality must be between 0 and 100."
        case .invalidMaximumOutputByteCount:
            "The recorded maximum output byte count must be greater than zero."
        case .deliveredOutputExceedsMaximum:
            "The delivered output exceeds its recorded maximum byte count."
        case .incoherentUploadAcknowledgement:
            "The upload acknowledgement status and timestamp are inconsistent."
        case .incoherentRemoteStatAcknowledgement:
            "The remote-stat acknowledgement status, timestamp, and byte size are inconsistent."
        }
    }
}

private nonisolated func deliveryReceiptItemOrder(
    _ lhs: DeliveryReceiptItem,
    _ rhs: DeliveryReceiptItem
) -> Bool {
    let leftName = lhs.deliveredFilename.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    let rightName = rhs.deliveredFilename.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
    if leftName != rightName { return leftName < rightName }
    if lhs.deliveredFilename != rhs.deliveredFilename {
        return lhs.deliveredFilename < rhs.deliveredFilename
    }
    return lhs.sourceIdentity.sha256 < rhs.sourceIdentity.sha256
}

private nonisolated func sortedUniqueIdentifiers(_ values: [String]) -> [String] {
    Array(Set(values)).sorted()
}

private nonisolated func validateReceiptIdentifiers(
    _ values: [String],
    field: String
) throws {
    guard Set(values).count == values.count else {
        throw DeliveryReceiptValidationError.invalidIdentifier(field: field)
    }
    for value in values {
        try validateReceiptIdentifier(value, field: field)
    }
}

private nonisolated func validateReceiptIdentifier(_ value: String, field: String) throws {
    let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
    )
    guard !value.isEmpty,
          value.count <= 512,
          value.unicodeScalars.allSatisfy(allowed.contains) else {
        throw DeliveryReceiptValidationError.invalidIdentifier(field: field)
    }
}

private nonisolated func validateReceiptText(
    _ value: String,
    field: String,
    maximumLength: Int
) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.count <= maximumLength,
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw DeliveryReceiptValidationError.invalidText(field: field)
    }
}

private nonisolated func validateSHA256(_ value: String, field: String) throws {
    let lowercaseHexCharacters = Set("0123456789abcdef")
    guard value.count == 64,
          value.allSatisfy(lowercaseHexCharacters.contains) else {
        throw DeliveryReceiptValidationError.invalidSHA256(field: field)
    }
}

private nonisolated func validateDeliveredFilename(_ value: String) throws {
    do {
        try validateReceiptText(value, field: "delivered filename", maximumLength: 1_024)
    } catch {
        throw DeliveryReceiptValidationError.invalidDeliveredFilename(value)
    }
    guard value != ".", value != "..",
          !value.contains("/"), !value.contains("\\") else {
        throw DeliveryReceiptValidationError.invalidDeliveredFilename(value)
    }
}
