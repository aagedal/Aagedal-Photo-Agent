import Foundation

/// The semantic portion of one preflight issue. Localized presentation text and probe error
/// details are deliberately excluded so an immutable delivery plan records decisions without
/// copying arbitrary connection diagnostics or other incidental data into its JSON.
nonisolated struct DeliveryPreflightIssueSnapshot: Codable, Equatable, Sendable {
    let id: String
    let severity: DeadlinePreflightSeverity
    let imageIndex: Int?
    let code: DeadlinePreflightIssueCode
}

nonisolated struct DeliveryPreflightImageResultSnapshot: Codable, Equatable, Sendable {
    let imageIndex: Int
    let issueIDs: [String]
}

/// Exact, locale-independent preflight result frozen into a delivery plan.
nonisolated struct DeliveryPreflightResultSnapshot: Codable, Equatable, Sendable {
    let revision: DeadlinePreflightRevisionToken
    let issues: [DeliveryPreflightIssueSnapshot]
    let imageResults: [DeliveryPreflightImageResultSnapshot]
    let renamePlan: RenamePlan?

    init(publication: DeadlinePreflightPublication) {
        revision = publication.token
        issues = publication.report.issues.map {
            DeliveryPreflightIssueSnapshot(
                id: $0.id,
                severity: $0.severity,
                imageIndex: $0.imageIndex,
                code: $0.code
            )
        }
        imageResults = publication.report.imageReports.map {
            DeliveryPreflightImageResultSnapshot(
                imageIndex: $0.imageIndex,
                issueIDs: $0.issues.map(\.id)
            )
        }
        renamePlan = publication.report.renamePlan
    }

    var blockerCount: Int { issues.count { $0.severity == .blocker } }
    var warningIDs: [String] {
        issues.filter { $0.severity == .warning }.map(\.id)
    }
}

/// Renderer and metadata-writer choices shared by every item in a frozen batch.
nonisolated struct DeliveryRenderWriteSnapshot: Codable, Equatable, Sendable {
    let export: DeadlineExportSnapshot
    let metadataWriteStrategy: DeadlineMetadataWriteStrategy
    let gpsPolicy: DeadlineGPSPolicy
    let verificationFields: [IPTCMetadataVerificationField]
}

/// A destination lookup key plus an already-resolved remote path. No host, user name, password,
/// key material, bookmark, or connection URL is representable in this type.
nonisolated struct DeliveryDestinationSnapshot: Codable, Equatable, Sendable {
    let connectionIdentifier: String
    let resolvedRemotePath: String
}

/// Everything an executor needs to produce one staged output, without consulting mutable UI or
/// profile state. The fingerprint is suitable as a resumability key for a verified staged file.
nonisolated struct DeliveryPlanStageItem: Codable, Equatable, Sendable {
    let itemIndex: Int
    let sourceRevision: SourceImageRevision
    let resolvedMetadata: IPTCMetadata
    let outputFilename: String
    let stagedRelativePath: String
    let isHDR: Bool
    let developSnapshot: DevelopVersionSnapshot?
    let stageInputFingerprint: String
}

/// Immutable contract consumed by later staging, verification, and upload phases.
nonisolated struct DeliveryPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let fingerprint: String
    let profile: DeadlineProfile
    let preflight: DeliveryPreflightResultSnapshot
    let renderAndWrite: DeliveryRenderWriteSnapshot
    let destination: DeliveryDestinationSnapshot
    let acceptedWarningIDs: [String]
    let items: [DeliveryPlanStageItem]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        fingerprint: String,
        profile: DeadlineProfile,
        preflight: DeliveryPreflightResultSnapshot,
        renderAndWrite: DeliveryRenderWriteSnapshot,
        destination: DeliveryDestinationSnapshot,
        acceptedWarningIDs: [String],
        items: [DeliveryPlanStageItem]
    ) {
        self.schemaVersion = schemaVersion
        self.fingerprint = fingerprint
        self.profile = profile
        self.preflight = preflight
        self.renderAndWrite = renderAndWrite
        self.destination = destination
        self.acceptedWarningIDs = acceptedWarningIDs
        self.items = items
    }

    func validateForPersistence() throws {
        try DeliveryPlanningService.validateFrozenPlan(self)
    }
}

/// Mutable facts captured both when preflight ran and immediately before confirmation.
/// Comparing both sides closes the gap between a green preflight and plan creation.
nonisolated struct DeliveryPlanningItemInput: Equatable, Sendable {
    let preflightSourceRevision: SourceImageRevision
    let currentSourceRevision: SourceImageRevision
    let resolvedMetadata: IPTCMetadata
    let preflightDevelopSnapshot: DevelopVersionSnapshot?
    let currentDevelopSnapshot: DevelopVersionSnapshot?

    init(
        sourceRevision: SourceImageRevision,
        resolvedMetadata: IPTCMetadata,
        developSnapshot: DevelopVersionSnapshot? = nil
    ) {
        preflightSourceRevision = sourceRevision
        currentSourceRevision = sourceRevision
        self.resolvedMetadata = resolvedMetadata
        preflightDevelopSnapshot = developSnapshot
        currentDevelopSnapshot = developSnapshot
    }

    init(
        preflightSourceRevision: SourceImageRevision,
        currentSourceRevision: SourceImageRevision,
        resolvedMetadata: IPTCMetadata,
        preflightDevelopSnapshot: DevelopVersionSnapshot?,
        currentDevelopSnapshot: DevelopVersionSnapshot?
    ) {
        self.preflightSourceRevision = preflightSourceRevision
        self.currentSourceRevision = currentSourceRevision
        self.resolvedMetadata = resolvedMetadata
        self.preflightDevelopSnapshot = preflightDevelopSnapshot
        self.currentDevelopSnapshot = currentDevelopSnapshot
    }
}

nonisolated struct DeliveryPlanningRequest: Equatable, Sendable {
    let preflightRequest: DeadlinePreflightRequest
    let publication: DeadlinePreflightPublication
    let currentRevision: DeadlinePreflightRevisionToken
    let currentProfile: DeadlineProfile
    let items: [DeliveryPlanningItemInput]
    let acceptedWarningIDs: Set<String>

    init(
        preflightRequest: DeadlinePreflightRequest,
        publication: DeadlinePreflightPublication,
        currentRevision: DeadlinePreflightRevisionToken,
        currentProfile: DeadlineProfile,
        items: [DeliveryPlanningItemInput],
        acceptedWarningIDs: Set<String> = []
    ) {
        self.preflightRequest = preflightRequest
        self.publication = publication
        self.currentRevision = currentRevision
        self.currentProfile = currentProfile
        self.items = items
        self.acceptedWarningIDs = acceptedWarningIDs
    }
}
