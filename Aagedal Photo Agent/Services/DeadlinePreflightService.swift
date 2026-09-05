import Foundation

/// Delivery-preflight severity is intentionally independent from any one validator or planner.
nonisolated enum DeadlinePreflightSeverity: String, Codable, Equatable, Sendable {
    case blocker
    case warning
    case information

    fileprivate var sortRank: Int {
        switch self {
        case .blocker: return 0
        case .warning: return 1
        case .information: return 2
        }
    }
}

nonisolated enum DeadlinePreflightIssueCode: Codable, Equatable, Sendable {
    case missingValidationProfile(reference: String)
    case missingMetadataTemplate(reference: String)
    case missingRequiredList(reference: String)
    case metadataValidation(ruleID: String, field: MetadataFieldID)
    case unresolvedVariable(field: MetadataFieldID)
    case unresolvedStructuredVariable(field: DeadlineStructuredMetadataField)
    case sidecarPending
    case sidecarFailed
    case missingRenameRecipe(reference: String)
    case renameEnvironmentUnavailable
    case rename(RenamePlanIssue.Kind)
    case sourceUnavailable
    case sourceUnreadable
    case sourceWritabilityUnknown
    case sourceNotWritable
    case unsupportedSourceFormat
    case sourceCannotDecode
    case staleDescriptiveMetadataConflict
    case c2pa(DeadlineC2PAConsequence)
    case missingExportConfiguration(reference: String)
    case exportCapabilitiesUnknown
    case unavailableSDRExportFormat(DeadlineExportSnapshot.SDRFormat)
    case unavailableHDRExportFormat(DeadlineExportSnapshot.HDRFormat)
    case unavailableSDRExportGamut(DeadlineExportSnapshot.ColorGamut)
    case unavailableHDRExportGamut(DeadlineExportSnapshot.ColorGamut)
    case invalidExportQuality
    case invalidMaximumOutputByteCount
    case invalidSourceDimensions
    case exportWillDownscale(maximumDimension: Int)
    case outputSizeEstimateUnknown(maximumBytes: Int64)
    case estimatedOutputExceedsMaximum(estimatedBytes: Int64, maximumBytes: Int64)
    case deliverySizeUnknown
    case destinationSpaceUnknown
    case insufficientDestinationSpace(requiredBytes: Int64, availableBytes: Int64)
    case stagingUnavailable
    case stagingInsufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case unsupportedDeliveryWriteStrategy(DeadlineMetadataWriteStrategy)
    case connectionNotConfigured(identifier: String)
    case connectionReachabilityUnknown(identifier: String)
    case connectionUnreachable(identifier: String)
    case remotePathInvalid
    case remotePathHasUnresolvedVariables([String])
}

nonisolated enum DeadlineCreatorContactField: String, Codable, Equatable, Sendable {
    case addressLine
    case city
    case region
    case postalCode
    case country
    case email
    case phoneNumber
    case webURL
}

nonisolated enum DeadlineEditorialLocationField: String, Codable, Equatable, Sendable {
    case identifier
    case name
    case sublocation
    case city
    case provinceState
    case countryName
    case countryCode
    case worldRegion
}

/// Typed paths keep structured placeholder fixes addressable without flattening IPTC Extension
/// structures into display strings.
nonisolated enum DeadlineStructuredMetadataField: Codable, Equatable, Sendable {
    case creatorContact(field: DeadlineCreatorContactField, valueIndex: Int? = nil)
    case locationCreated(
        locationIndex: Int,
        field: DeadlineEditorialLocationField,
        valueIndex: Int? = nil
    )
    case locationShown(
        locationIndex: Int,
        field: DeadlineEditorialLocationField,
        valueIndex: Int? = nil
    )
}

/// Immutable output suitable for both a compact badge and a future Fix Next workflow.
nonisolated struct DeadlinePreflightIssue: Equatable, Sendable, Identifiable {
    let id: String
    let severity: DeadlinePreflightSeverity
    let imageIndex: Int?
    let imageURL: URL?
    let code: DeadlinePreflightIssueCode
    let message: String
    let technicalDetail: String?

    fileprivate let checkRank: Int
    fileprivate let occurrence: Int
}

nonisolated struct DeadlinePreflightImageReport: Equatable, Sendable {
    let imageIndex: Int
    let imageURL: URL
    let issues: [DeadlinePreflightIssue]
}

nonisolated struct DeadlinePreflightReport: Equatable, Sendable {
    let issues: [DeadlinePreflightIssue]
    let imageReports: [DeadlinePreflightImageReport]
    let renamePlan: RenamePlan?

    var blockerCount: Int { issues.count { $0.severity == .blocker } }
    var warningCount: Int { issues.count { $0.severity == .warning } }
    var informationCount: Int { issues.count { $0.severity == .information } }
    var isBlocked: Bool { blockerCount > 0 }

    /// Severity, pipeline check order, input image order, then stable identity determine this value.
    var nextIssue: DeadlinePreflightIssue? { issues.first }
}

/// Immutable partial results emitted at deterministic pipeline boundaries while preflight runs.
/// A snapshot contains only images that have completed per-image checks; later stages republish
/// those rows with rename and batch issues included. It is never accepted as a sendable final
/// report by the delivery model.
nonisolated struct DeadlinePreflightProgress: Equatable, Sendable {
    nonisolated enum Stage: String, Equatable, Sendable {
        case resolvingDependencies
        case checkingImages
        case planningRename
        case checkingDelivery
    }

    let stage: Stage
    let completedImageCount: Int
    let totalImageCount: Int
    let reportSnapshot: DeadlinePreflightReport
}

nonisolated enum DeadlineSidecarStateSnapshot: Equatable, Sendable {
    case clean
    case pending
    case failed(message: String)
}

nonisolated enum DeadlineDescriptiveMetadataConflictSnapshot: Equatable, Sendable {
    case none
    case staleXMPSidecarDiffersFromEmbedded(detail: String? = nil)
}

/// The caller decides the expected authenticity effect after inspecting the actual source and
/// configured delivery pipeline. Preflight presents it separately from metadata-write failures.
nonisolated enum DeadlineC2PAConsequence: String, Codable, Equatable, Sendable {
    case none
    case preserved
    case originalWriteInvalidatesManifest
    case derivedOutputDropsManifest
    case requiresResigning
    case unsupportedProtectedSource
}

/// Filesystem-derived facts captured by a caller before entering the pure preflight layer.
nonisolated struct DeadlineSourceSnapshot: Equatable, Sendable {
    var isAvailable: Bool
    var isReadable: Bool
    var isWritable: Bool
    var isWritabilityKnown: Bool
    var isSupportedFormat: Bool
    var canDecode: Bool
    var byteCount: Int64?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var isHDR: Bool

    init(
        isAvailable: Bool = true,
        isReadable: Bool = true,
        isWritable: Bool = true,
        isWritabilityKnown: Bool = true,
        isSupportedFormat: Bool = true,
        canDecode: Bool = true,
        byteCount: Int64? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        isHDR: Bool = false
    ) {
        self.isAvailable = isAvailable
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.isWritabilityKnown = isWritabilityKnown
        self.isSupportedFormat = isSupportedFormat
        self.canDecode = canDecode
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isHDR = isHDR
    }
}

nonisolated struct DeadlinePreflightItemSnapshot: Equatable, Sendable {
    let sourceURL: URL
    var metadata: IPTCMetadata
    var renameContext: BatchRenameContext
    var sidecarState: DeadlineSidecarStateSnapshot
    var source: DeadlineSourceSnapshot
    var descriptiveConflict: DeadlineDescriptiveMetadataConflictSnapshot
    var c2paConsequence: DeadlineC2PAConsequence
    /// A renderer-aware per-item estimate. Source byte size is not an output estimate.
    var estimatedOutputByteCount: Int64?

    init(
        sourceURL: URL,
        metadata: IPTCMetadata = IPTCMetadata(),
        renameContext: BatchRenameContext? = nil,
        sidecarState: DeadlineSidecarStateSnapshot = .clean,
        source: DeadlineSourceSnapshot = DeadlineSourceSnapshot(),
        descriptiveConflict: DeadlineDescriptiveMetadataConflictSnapshot = .none,
        c2paConsequence: DeadlineC2PAConsequence = .none,
        estimatedOutputByteCount: Int64? = nil
    ) {
        self.sourceURL = sourceURL
        self.metadata = metadata
        self.renameContext = renameContext
            ?? BatchRenameContext(originalFilename: sourceURL.lastPathComponent)
        self.sidecarState = sidecarState
        self.source = source
        self.descriptiveConflict = descriptiveConflict
        self.c2paConsequence = c2paConsequence
        self.estimatedOutputByteCount = estimatedOutputByteCount
    }
}

/// Resolved library resources. Absent entries remain visible as blocking reference failures.
nonisolated struct DeadlinePreflightResourceSnapshot: Equatable, Sendable {
    var validationProfiles: [String: MetadataValidationProfile]
    var metadataTemplateIdentifiers: Set<String>
    var listIdentifiers: Set<String>
    var renameRecipes: [String: BatchRenameRecipe]
    var exportConfigurations: [String: DeadlineExportSnapshot]

    init(
        validationProfiles: [String: MetadataValidationProfile] = [:],
        metadataTemplateIdentifiers: Set<String> = [],
        listIdentifiers: Set<String> = [],
        renameRecipes: [String: BatchRenameRecipe] = [:],
        exportConfigurations: [String: DeadlineExportSnapshot] = [:]
    ) {
        self.validationProfiles = validationProfiles
        self.metadataTemplateIdentifiers = metadataTemplateIdentifiers
        self.listIdentifiers = listIdentifiers
        self.renameRecipes = renameRecipes
        self.exportConfigurations = exportConfigurations
    }
}

nonisolated struct DeadlineExportCapabilitySnapshot: Equatable, Sendable {
    var isKnown: Bool
    var availableSDRFormats: [DeadlineExportSnapshot.SDRFormat]
    var availableHDRFormats: [DeadlineExportSnapshot.HDRFormat]
    var availableSDRGamuts: [DeadlineExportSnapshot.ColorGamut]
    var availableHDRGamuts: [DeadlineExportSnapshot.ColorGamut]

    init(
        isKnown: Bool = true,
        availableSDRFormats: [DeadlineExportSnapshot.SDRFormat] = [
            .jpeg, .png, .tiff, .heic, .avif, .avifFFmpeg, .jxl,
        ],
        availableHDRFormats: [DeadlineExportSnapshot.HDRFormat] = [
            .jpegGainMap, .heic10bit, .avif10bit, .avifFFmpeg10bit, .jxl, .tiff16bit, .png16bit,
        ],
        availableSDRGamuts: [DeadlineExportSnapshot.ColorGamut] = [
            .sRGB, .displayP3, .rec2020, .adobeRGB,
        ],
        availableHDRGamuts: [DeadlineExportSnapshot.ColorGamut] = [
            .sRGB, .displayP3, .rec2020, .adobeRGB,
        ]
    ) {
        self.isKnown = isKnown
        self.availableSDRFormats = availableSDRFormats
        self.availableHDRFormats = availableHDRFormats
        self.availableSDRGamuts = availableSDRGamuts
        self.availableHDRGamuts = availableHDRGamuts
    }
}

nonisolated enum DeadlineStagingStateSnapshot: Equatable, Sendable {
    case notRequired
    case ready
    case unavailable(reason: String)
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
}

nonisolated enum DeadlineConnectionStateSnapshot: Equatable, Sendable {
    case notConfigured
    case configuredReachabilityUnknown
    case reachable
    case unreachable(reason: String)
}

nonisolated enum DeadlineRemotePathStateSnapshot: Equatable, Sendable {
    case valid(resolvedPath: String)
    case invalid(reason: String)
    case unresolvedVariables([String])
}

/// Destination/network facts are observations only; gathering them is outside this service.
nonisolated struct DeadlineBatchDeliverySnapshot: Equatable, Sendable {
    var destinationAvailableBytes: Int64?
    var estimatedRequiredBytes: Int64?
    var stagingState: DeadlineStagingStateSnapshot
    var connections: [String: DeadlineConnectionStateSnapshot]
    var remotePathState: DeadlineRemotePathStateSnapshot?
    /// Auditable local staging facts. They do not describe remote destination capacity.
    var stagingRootURL: URL?
    var stagingAvailableBytes: Int64?
    var supportedMetadataWriteStrategies: [DeadlineMetadataWriteStrategy]

    init(
        destinationAvailableBytes: Int64? = nil,
        estimatedRequiredBytes: Int64? = nil,
        stagingState: DeadlineStagingStateSnapshot = .notRequired,
        connections: [String: DeadlineConnectionStateSnapshot] = [:],
        remotePathState: DeadlineRemotePathStateSnapshot? = nil,
        stagingRootURL: URL? = nil,
        stagingAvailableBytes: Int64? = nil,
        supportedMetadataWriteStrategies: [DeadlineMetadataWriteStrategy] = [
            .originals, .xmpSidecars, .stagedCopies,
        ]
    ) {
        self.destinationAvailableBytes = destinationAvailableBytes
        self.estimatedRequiredBytes = estimatedRequiredBytes
        self.stagingState = stagingState
        self.connections = connections
        self.remotePathState = remotePathState
        self.stagingRootURL = stagingRootURL
        self.stagingAvailableBytes = stagingAvailableBytes
        self.supportedMetadataWriteStrategies = supportedMetadataWriteStrategies
    }
}

nonisolated struct DeadlinePreflightRequest: Equatable, Sendable {
    let profile: DeadlineProfile
    var items: [DeadlinePreflightItemSnapshot]
    var resources: DeadlinePreflightResourceSnapshot
    var renameEnvironment: RenamePlanningEnvironment
    var artifactRegistry: RenameArtifactRegistry
    var exportCapabilities: DeadlineExportCapabilitySnapshot
    var delivery: DeadlineBatchDeliverySnapshot

    init(
        profile: DeadlineProfile,
        items: [DeadlinePreflightItemSnapshot],
        resources: DeadlinePreflightResourceSnapshot = DeadlinePreflightResourceSnapshot(),
        renameEnvironment: RenamePlanningEnvironment = RenamePlanningEnvironment(
            caseSensitivity: .caseInsensitive
        ),
        artifactRegistry: RenameArtifactRegistry = .standard,
        exportCapabilities: DeadlineExportCapabilitySnapshot = DeadlineExportCapabilitySnapshot(),
        delivery: DeadlineBatchDeliverySnapshot = DeadlineBatchDeliverySnapshot()
    ) {
        self.profile = profile
        self.items = items
        self.resources = resources
        self.renameEnvironment = renameEnvironment
        self.artifactRegistry = artifactRegistry
        self.exportCapabilities = exportCapabilities
        self.delivery = delivery
    }
}

/// A pure, cancellable coordinator over immutable snapshots. It deliberately performs no reads,
/// writes, network probes, or caching; callers own snapshot freshness and cancellation lifetime.
nonisolated struct DeadlinePreflightService: Sendable {
    typealias ProgressHandler = @Sendable (DeadlinePreflightProgress) async -> Void

    private let metadataValidator: MetadataValidationEngine
    private let renamePlanner: RenamePlanningService

    init(
        metadataValidator: MetadataValidationEngine = MetadataValidationEngine(),
        renamePlanner: RenamePlanningService = RenamePlanningService()
    ) {
        self.metadataValidator = metadataValidator
        self.renamePlanner = renamePlanner
    }

    func evaluate(
        _ request: DeadlinePreflightRequest,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> DeadlinePreflightReport {
        await Task.yield()
        try Task.checkCancellation()

        var issues: [DeadlinePreflightIssue] = []
        var occurrence = 0
        let validationResolution = resolveValidationProfile(request)
        let exportResolution = resolveExportConfiguration(request)

        if case let .missing(reference) = validationResolution {
            append(
                &issues,
                occurrence: &occurrence,
                severity: .blocker,
                checkRank: 0,
                code: .missingValidationProfile(reference: reference),
                message: "The deadline validation profile is unavailable.",
                technicalDetail: reference
            )
        }
        appendMissingProfileDependencies(request, to: &issues, occurrence: &occurrence)
        try await publishProgress(
            stage: .resolvingDependencies,
            completedImageCount: 0,
            request: request,
            issues: issues,
            renamePlan: nil,
            onProgress: onProgress
        )

        for (imageIndex, item) in request.items.enumerated() {
            await Task.yield()
            try Task.checkCancellation()

            if case let .value(profile) = validationResolution {
                let report = metadataValidator.validate(
                    item.metadata,
                    imageURL: item.sourceURL,
                    profile: profile
                )
                for validationIssue in report.issues {
                    append(
                        &issues,
                        occurrence: &occurrence,
                        severity: validationIssue.severity.preflightSeverity,
                        checkRank: 0,
                        imageIndex: imageIndex,
                        imageURL: item.sourceURL,
                        code: .metadataValidation(
                            ruleID: validationIssue.id,
                            field: validationIssue.field
                        ),
                        message: validationIssue.message,
                        technicalDetail: validationIssue.technicalDetail
                    )
                }
            }

            for field in MetadataFieldID.allCases where containsPlaceholder(field, in: item.metadata) {
                append(
                    &issues,
                    occurrence: &occurrence,
                    severity: .blocker,
                    checkRank: 1,
                    imageIndex: imageIndex,
                    imageURL: item.sourceURL,
                    code: .unresolvedVariable(field: field),
                    message: "\(field.displayName) contains an unresolved template variable.",
                    technicalDetail: nil
                )
            }
            for structuredField in structuredPlaceholderFields(in: item.metadata) {
                append(
                    &issues,
                    occurrence: &occurrence,
                    severity: .blocker,
                    checkRank: 1,
                    imageIndex: imageIndex,
                    imageURL: item.sourceURL,
                    code: .unresolvedStructuredVariable(field: structuredField),
                    message: "Structured metadata contains an unresolved template variable.",
                    technicalDetail: structuredField.technicalPath
                )
            }

            switch item.sidecarState {
            case .clean:
                break
            case .pending:
                append(
                    &issues,
                    occurrence: &occurrence,
                    severity: .blocker,
                    checkRank: 2,
                    imageIndex: imageIndex,
                    imageURL: item.sourceURL,
                    code: .sidecarPending,
                    message: "Metadata changes are still pending sidecar persistence.",
                    technicalDetail: nil
                )
            case let .failed(message):
                append(
                    &issues,
                    occurrence: &occurrence,
                    severity: .blocker,
                    checkRank: 2,
                    imageIndex: imageIndex,
                    imageURL: item.sourceURL,
                    code: .sidecarFailed,
                    message: "The latest sidecar write failed.",
                    technicalDetail: message
                )
            }

            appendSourceIssues(
                for: item,
                imageIndex: imageIndex,
                strategy: request.profile.metadataWriteStrategy,
                to: &issues,
                occurrence: &occurrence
            )

            if case let .staleXMPSidecarDiffersFromEmbedded(detail) = item.descriptiveConflict {
                append(
                    &issues,
                    occurrence: &occurrence,
                    severity: .blocker,
                    checkRank: 5,
                    imageIndex: imageIndex,
                    imageURL: item.sourceURL,
                    code: .staleDescriptiveMetadataConflict,
                    message: "The XMP sidecar and embedded descriptive metadata conflict.",
                    technicalDetail: detail
                )
            }

            appendC2PAIssue(
                item.c2paConsequence,
                imageIndex: imageIndex,
                imageURL: item.sourceURL,
                to: &issues,
                occurrence: &occurrence
            )

            if case let .value(export) = exportResolution {
                appendExportIssues(
                    export,
                    capabilities: request.exportCapabilities,
                    item: item,
                    imageIndex: imageIndex,
                    to: &issues,
                    occurrence: &occurrence
                )
            }

            let completedImageCount = imageIndex + 1
            let progressStride = max(1, request.items.count / 100)
            if completedImageCount.isMultiple(of: progressStride)
                || completedImageCount == request.items.count {
                try await publishProgress(
                    stage: .checkingImages,
                    completedImageCount: completedImageCount,
                    request: request,
                    issues: issues,
                    renamePlan: nil,
                    onProgress: onProgress
                )
            }
        }

        if case let .missing(reference) = exportResolution {
            append(
                &issues,
                occurrence: &occurrence,
                severity: .blocker,
                checkRank: 7,
                code: .missingExportConfiguration(reference: reference),
                message: "The deadline export configuration is unavailable.",
                technicalDetail: reference
            )
        }


        try await publishProgress(
            stage: .planningRename,
            completedImageCount: request.items.count,
            request: request,
            issues: issues,
            renamePlan: nil,
            onProgress: onProgress
        )

        let renamePlan = try await makeRenamePlan(
            request,
            issues: &issues,
            occurrence: &occurrence
        )
        try Task.checkCancellation()

        appendBatchDeliveryIssues(request, to: &issues, occurrence: &occurrence)
        try await publishProgress(
            stage: .checkingDelivery,
            completedImageCount: request.items.count,
            request: request,
            issues: issues,
            renamePlan: renamePlan,
            onProgress: onProgress
        )
        return makeReport(
            request: request,
            issues: issues,
            completedImageCount: request.items.count,
            renamePlan: renamePlan
        )
    }

    private func publishProgress(
        stage: DeadlinePreflightProgress.Stage,
        completedImageCount: Int,
        request: DeadlinePreflightRequest,
        issues: [DeadlinePreflightIssue],
        renamePlan: RenamePlan?,
        onProgress: ProgressHandler
    ) async throws {
        try Task.checkCancellation()
        let snapshot = makeReport(
            request: request,
            issues: issues,
            completedImageCount: completedImageCount,
            renamePlan: renamePlan
        )
        await onProgress(DeadlinePreflightProgress(
            stage: stage,
            completedImageCount: completedImageCount,
            totalImageCount: request.items.count,
            reportSnapshot: snapshot
        ))
        try Task.checkCancellation()
    }

    private func makeReport(
        request: DeadlinePreflightRequest,
        issues: [DeadlinePreflightIssue],
        completedImageCount: Int,
        renamePlan: RenamePlan?
    ) -> DeadlinePreflightReport {
        let sorted = issues.sorted(by: issuePrecedes)
        let issuesByImageIndex = Dictionary(grouping: sorted.compactMap { issue in
            issue.imageIndex.map { ($0, issue) }
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1)
        }
        let completedCount = min(max(0, completedImageCount), request.items.count)
        let imageReports = request.items.prefix(completedCount).enumerated().map { index, item in
            DeadlinePreflightImageReport(
                imageIndex: index,
                imageURL: item.sourceURL,
                issues: issuesByImageIndex[index] ?? []
            )
        }
        return DeadlinePreflightReport(
            issues: sorted,
            imageReports: imageReports,
            renamePlan: renamePlan
        )
    }

    private func makeRenamePlan(
        _ request: DeadlinePreflightRequest,
        issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) async throws -> RenamePlan? {
        guard let rename = request.profile.rename else { return nil }
        let recipe: BatchRenameRecipe
        switch rename.recipe {
        case let .snapshot(snapshot):
            recipe = snapshot
        case let .reference(reference):
            guard let resolved = request.resources.renameRecipes[reference.identifier] else {
                append(
                    &issues,
                    occurrence: &occurrence,
                    severity: .blocker,
                    checkRank: 3,
                    code: .missingRenameRecipe(reference: reference.identifier),
                    message: "The deadline rename recipe is unavailable.",
                    technicalDetail: reference.identifier
                )
                return nil
            }
            recipe = resolved
        }

        await Task.yield()
        try Task.checkCancellation()
        let plan = renamePlanner.makePlan(
            items: request.items.map {
                RenamePlanningItem(sourceImageURL: $0.sourceURL, context: $0.renameContext)
            },
            recipe: recipe,
            collisionPolicy: rename.collisionPolicy,
            artifactRegistry: request.artifactRegistry,
            environment: request.renameEnvironment
        )
        if !request.renameEnvironment.isComplete {
            append(
                &issues,
                occurrence: &occurrence,
                severity: .blocker,
                checkRank: 3,
                code: .renameEnvironmentUnavailable,
                message: "The rename preview has not been checked against the destination's existing files.",
                technicalDetail: nil
            )
        }
        for planIssue in plan.issues {
            let item = request.items[planIssue.itemIndex]
            append(
                &issues,
                occurrence: &occurrence,
                severity: planIssue.severity == .blocking ? .blocker : .warning,
                checkRank: 3,
                imageIndex: planIssue.itemIndex,
                imageURL: item.sourceURL,
                code: .rename(planIssue.kind),
                message: renameMessage(for: planIssue.kind),
                technicalDetail: planIssue.url?.path
            )
        }
        return plan
    }

    private func appendSourceIssues(
        for item: DeadlinePreflightItemSnapshot,
        imageIndex: Int,
        strategy: DeadlineMetadataWriteStrategy,
        to issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) {
        let source = item.source
        if !source.isAvailable {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 4,
                   imageIndex: imageIndex, imageURL: item.sourceURL, code: .sourceUnavailable,
                   message: "The source image is unavailable.", technicalDetail: nil)
        }
        if source.isAvailable, !source.isReadable {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 4,
                   imageIndex: imageIndex, imageURL: item.sourceURL, code: .sourceUnreadable,
                   message: "The source image cannot be read with the current permissions.", technicalDetail: nil)
        }
        if strategy == .originals, source.isAvailable {
            if !source.isWritabilityKnown {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 4,
                       imageIndex: imageIndex, imageURL: item.sourceURL, code: .sourceWritabilityUnknown,
                       message: "Source writability has not been verified for original-file metadata updates.",
                       technicalDetail: nil)
            } else if !source.isWritable {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 4,
                       imageIndex: imageIndex, imageURL: item.sourceURL, code: .sourceNotWritable,
                       message: "The source image cannot be updated with the current permissions.", technicalDetail: nil)
            }
        }
        if !source.isSupportedFormat {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 4,
                   imageIndex: imageIndex, imageURL: item.sourceURL, code: .unsupportedSourceFormat,
                   message: "The source image format is not supported.", technicalDetail: item.sourceURL.pathExtension)
        }
        if source.isSupportedFormat, !source.canDecode {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 4,
                   imageIndex: imageIndex, imageURL: item.sourceURL, code: .sourceCannotDecode,
                   message: "The source image cannot be decoded for export.", technicalDetail: nil)
        }
    }

    private func appendC2PAIssue(
        _ consequence: DeadlineC2PAConsequence,
        imageIndex: Int,
        imageURL: URL,
        to issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) {
        let severity: DeadlinePreflightSeverity
        let message: String
        switch consequence {
        case .none:
            return
        case .preserved:
            severity = .information
            message = "The C2PA manifest will be preserved."
        case .originalWriteInvalidatesManifest:
            severity = .blocker
            message = "Writing the original would invalidate its C2PA manifest."
        case .derivedOutputDropsManifest:
            severity = .warning
            message = "The derived output will not retain the source C2PA manifest."
        case .requiresResigning:
            severity = .warning
            message = "The delivered output must be signed with a new C2PA manifest."
        case .unsupportedProtectedSource:
            severity = .blocker
            message = "The configured pipeline cannot safely process this C2PA-protected source."
        }
        append(&issues, occurrence: &occurrence, severity: severity, checkRank: 6,
               imageIndex: imageIndex, imageURL: imageURL, code: .c2pa(consequence),
               message: message, technicalDetail: nil)
    }

    private func appendExportIssues(
        _ export: DeadlineExportSnapshot,
        capabilities: DeadlineExportCapabilitySnapshot,
        item: DeadlinePreflightItemSnapshot,
        imageIndex: Int,
        to issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) {
        if !(0...1).contains(export.sdrQuality) || !(0...1).contains(export.hdrQuality) {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                   imageIndex: imageIndex, imageURL: item.sourceURL, code: .invalidExportQuality,
                   message: "The configured export quality is outside the supported range.", technicalDetail: nil)
        }
        if let maximum = export.maximumOutputByteCount, maximum <= 0 {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                   imageIndex: imageIndex, imageURL: item.sourceURL,
                   code: .invalidMaximumOutputByteCount,
                   message: "The configured maximum encoded output size is invalid.",
                   technicalDetail: "Maximum: \(maximum) bytes.")
        }
        appendOutputSizeEstimateIssue(
            export,
            item: item,
            imageIndex: imageIndex,
            to: &issues,
            occurrence: &occurrence
        )
        if !capabilities.isKnown {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                   imageIndex: imageIndex, imageURL: item.sourceURL, code: .exportCapabilitiesUnknown,
                   message: "Export format and gamut capabilities have not been captured.", technicalDetail: nil)
            return
        }
        if item.source.isHDR {
            if !capabilities.availableHDRFormats.contains(export.hdrFormat) {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL,
                       code: .unavailableHDRExportFormat(export.hdrFormat),
                       message: "The configured HDR export format is unavailable.", technicalDetail: export.hdrFormat.rawValue)
            }
            if !capabilities.availableHDRGamuts.contains(export.hdrGamut) {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL,
                       code: .unavailableHDRExportGamut(export.hdrGamut),
                       message: "The configured HDR export gamut is unavailable.", technicalDetail: export.hdrGamut.rawValue)
            }
        } else {
            if !capabilities.availableSDRFormats.contains(export.sdrFormat) {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL,
                       code: .unavailableSDRExportFormat(export.sdrFormat),
                       message: "The configured SDR export format is unavailable.", technicalDetail: export.sdrFormat.rawValue)
            }
            if !capabilities.availableSDRGamuts.contains(export.sdrGamut) {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL,
                       code: .unavailableSDRExportGamut(export.sdrGamut),
                       message: "The configured SDR export gamut is unavailable.", technicalDetail: export.sdrGamut.rawValue)
            }
        }

        if let width = item.source.pixelWidth, let height = item.source.pixelHeight {
            guard width > 0, height > 0 else {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL, code: .invalidSourceDimensions,
                       message: "The source image dimensions are invalid.", technicalDetail: "\(width) × \(height)")
                return
            }
            if let limit = maximumDimension(for: export.resolutionLimit), max(width, height) > limit {
                append(&issues, occurrence: &occurrence, severity: .information, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL,
                       code: .exportWillDownscale(maximumDimension: limit),
                       message: "Export will downscale the image to a maximum dimension of \(limit) pixels.",
                       technicalDetail: "Source: \(width) × \(height)")
            }
        }

    }

    private func appendOutputSizeEstimateIssue(
        _ export: DeadlineExportSnapshot,
        item: DeadlinePreflightItemSnapshot,
        imageIndex: Int,
        to issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) {
        guard let maximum = export.maximumOutputByteCount, maximum > 0 else { return }
        if let estimate = item.estimatedOutputByteCount, estimate >= 0 {
            if estimate > maximum {
                append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 7,
                       imageIndex: imageIndex, imageURL: item.sourceURL,
                       code: .estimatedOutputExceedsMaximum(
                           estimatedBytes: estimate,
                           maximumBytes: maximum
                       ),
                       message: "The estimated encoded output exceeds the configured per-file limit.",
                       technicalDetail: "Estimated: \(estimate) bytes; maximum: \(maximum) bytes.")
            }
        } else {
            append(&issues, occurrence: &occurrence, severity: .warning, checkRank: 7,
                   imageIndex: imageIndex, imageURL: item.sourceURL,
                   code: .outputSizeEstimateUnknown(maximumBytes: maximum),
                   message: "The encoded output size cannot be predicted reliably before rendering.",
                   technicalDetail: "The final staged file will be refused above \(maximum) bytes.")
        }
    }

    private func appendBatchDeliveryIssues(
        _ request: DeadlinePreflightRequest,
        to issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) {
        let delivery = request.delivery
        if !delivery.supportedMetadataWriteStrategies.contains(request.profile.metadataWriteStrategy) {
            append(
                &issues,
                occurrence: &occurrence,
                severity: .blocker,
                checkRank: 8,
                code: .unsupportedDeliveryWriteStrategy(request.profile.metadataWriteStrategy),
                message: "The live delivery adapter does not support this metadata write strategy.",
                technicalDetail: request.profile.metadataWriteStrategy.rawValue
            )
        }
        if let required = delivery.estimatedRequiredBytes {
            if let available = delivery.destinationAvailableBytes {
                if required > available {
                    append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 8,
                           code: .insufficientDestinationSpace(requiredBytes: required, availableBytes: available),
                           message: "The destination does not have enough free space.",
                           technicalDetail: "Required: \(required) bytes; available: \(available) bytes.")
                }
            } else {
                append(&issues, occurrence: &occurrence, severity: .warning, checkRank: 8,
                       code: .destinationSpaceUnknown,
                       message: "Destination free space has not been measured.", technicalDetail: nil)
            }
        } else if request.profile.export != nil || request.profile.metadataWriteStrategy == .stagedCopies {
            append(&issues, occurrence: &occurrence, severity: .warning, checkRank: 8,
                   code: .deliverySizeUnknown,
                   message: "The required delivery size has not been estimated.", technicalDetail: nil)
        }

        switch delivery.stagingState {
        case .notRequired where request.profile.metadataWriteStrategy == .stagedCopies:
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 8,
                   code: .stagingUnavailable,
                   message: "The staged-copy workflow has no validated staging location.",
                   technicalDetail: nil)
        case .notRequired, .ready:
            break
        case let .unavailable(reason):
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 8,
                   code: .stagingUnavailable, message: "The staging location is unavailable.",
                   technicalDetail: reason)
        case let .insufficientSpace(required, available):
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 8,
                   code: .stagingInsufficientSpace(requiredBytes: required, availableBytes: available),
                   message: "The staging location does not have enough free space.",
                   technicalDetail: "Required: \(required) bytes; available: \(available) bytes.")
        }

        guard let destination = request.profile.destination else { return }
        let identifier = destination.connectionIdentifier
        switch delivery.connections[identifier] ?? .notConfigured {
        case .notConfigured:
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 9,
                   code: .connectionNotConfigured(identifier: identifier),
                   message: "The deadline destination connection is not configured.", technicalDetail: identifier)
        case .configuredReachabilityUnknown:
            append(&issues, occurrence: &occurrence, severity: .warning, checkRank: 9,
                   code: .connectionReachabilityUnknown(identifier: identifier),
                   message: "The deadline destination has not been reachability-checked.", technicalDetail: identifier)
        case .reachable:
            break
        case let .unreachable(reason):
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 9,
                   code: .connectionUnreachable(identifier: identifier),
                   message: "The deadline destination is not reachable.", technicalDetail: reason)
        }

        switch delivery.remotePathState {
        case nil:
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 10,
                   code: .remotePathInvalid, message: "The remote delivery path has not been validated.",
                   technicalDetail: destination.remotePathTemplate)
        case .valid:
            break
        case let .invalid(reason):
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 10,
                   code: .remotePathInvalid, message: "The remote delivery path is invalid.", technicalDetail: reason)
        case let .unresolvedVariables(variables):
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 10,
                   code: .remotePathHasUnresolvedVariables(variables),
                   message: "The remote delivery path contains unresolved variables.",
                   technicalDetail: variables.joined(separator: ", "))
        }
    }

    private func appendMissingProfileDependencies(
        _ request: DeadlinePreflightRequest,
        to issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int
    ) {
        if let template = request.profile.metadataTemplate,
           case let .reference(reference) = template.source,
           !request.resources.metadataTemplateIdentifiers.contains(reference.identifier) {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 0,
                   code: .missingMetadataTemplate(reference: reference.identifier),
                   message: "The deadline metadata template is unavailable.",
                   technicalDetail: reference.identifier)
        }
        for list in request.profile.requiredLists
            where !request.resources.listIdentifiers.contains(list.identifier) {
            append(&issues, occurrence: &occurrence, severity: .blocker, checkRank: 0,
                   code: .missingRequiredList(reference: list.identifier),
                   message: "A required deadline list is unavailable.", technicalDetail: list.identifier)
        }
    }

    private enum Resolution<Value> {
        case none
        case value(Value)
        case missing(String)
    }

    private func resolveValidationProfile(
        _ request: DeadlinePreflightRequest
    ) -> Resolution<MetadataValidationProfile> {
        switch request.profile.validationProfile {
        case nil: return .none
        case let .snapshot(profile): return .value(profile)
        case let .reference(reference):
            return request.resources.validationProfiles[reference.identifier]
                .map(Resolution.value) ?? .missing(reference.identifier)
        }
    }

    private func resolveExportConfiguration(
        _ request: DeadlinePreflightRequest
    ) -> Resolution<DeadlineExportSnapshot> {
        switch request.profile.export {
        case nil: return .none
        case let .snapshot(export): return .value(export)
        case let .reference(reference):
            return request.resources.exportConfigurations[reference.identifier]
                .map(Resolution.value) ?? .missing(reference.identifier)
        }
    }

    private func containsPlaceholder(_ field: MetadataFieldID, in metadata: IPTCMetadata) -> Bool {
        let values: [String]
        switch field {
        case .keywords: values = metadata.keywords
        case .personShown: values = metadata.personShown
        case .organisationShownName: values = metadata.organisationsShownNames
        case .organisationShownCode: values = metadata.organisationsShownCodes
        case .sceneCode: values = metadata.sceneCodes
        default: values = field.textValue(in: metadata).map { [$0] } ?? []
        }
        return values.contains(where: MetadataTemplatePlaceholderDetector.containsPlaceholder)
    }

    private func structuredPlaceholderFields(
        in metadata: IPTCMetadata
    ) -> [DeadlineStructuredMetadataField] {
        var fields: [DeadlineStructuredMetadataField] = []
        func hasPlaceholder(_ value: String?) -> Bool {
            value.map(MetadataTemplatePlaceholderDetector.containsPlaceholder) ?? false
        }

        if let contact = metadata.creatorContactInfo {
            for (index, value) in contact.addressLines.enumerated() where hasPlaceholder(value) {
                fields.append(.creatorContact(field: .addressLine, valueIndex: index))
            }
            for (field, value) in [
                (DeadlineCreatorContactField.city, contact.city),
                (.region, contact.region),
                (.postalCode, contact.postalCode),
                (.country, contact.country),
            ] where hasPlaceholder(value) {
                fields.append(.creatorContact(field: field))
            }
            for (field, values) in [
                (DeadlineCreatorContactField.email, contact.emails),
                (.phoneNumber, contact.phoneNumbers),
                (.webURL, contact.webURLs),
            ] {
                for (index, value) in values.enumerated() where hasPlaceholder(value) {
                    fields.append(.creatorContact(field: field, valueIndex: index))
                }
            }
        }

        func appendLocations(_ locations: [EditorialLocation], shown: Bool) {
            for (locationIndex, location) in locations.enumerated() {
                for (valueIndex, value) in location.identifiers.enumerated() where hasPlaceholder(value) {
                    fields.append(shown
                        ? .locationShown(locationIndex: locationIndex, field: .identifier, valueIndex: valueIndex)
                        : .locationCreated(locationIndex: locationIndex, field: .identifier, valueIndex: valueIndex))
                }
                for (field, value) in [
                    (DeadlineEditorialLocationField.name, location.name),
                    (.sublocation, location.sublocation),
                    (.city, location.city),
                    (.provinceState, location.provinceState),
                    (.countryName, location.countryName),
                    (.countryCode, location.countryCode),
                    (.worldRegion, location.worldRegion),
                ] where hasPlaceholder(value) {
                    fields.append(shown
                        ? .locationShown(locationIndex: locationIndex, field: field)
                        : .locationCreated(locationIndex: locationIndex, field: field))
                }
            }
        }
        appendLocations(metadata.locationsCreated, shown: false)
        appendLocations(metadata.locationsShown, shown: true)
        return fields
    }

    private func maximumDimension(for limit: DeadlineExportSnapshot.ResolutionLimit) -> Int? {
        switch limit {
        case .original: return nil
        case .pixels6000: return 6_000
        case .pixels4000: return 4_000
        case .pixels3000: return 3_000
        case .pixels2048: return 2_048
        case .pixels1600: return 1_600
        }
    }

    private func renameMessage(for kind: RenamePlanIssue.Kind) -> String {
        switch kind {
        case .missingValue: return "The rename recipe is missing a required value."
        case .recipeProblem: return "The rename recipe could not be evaluated."
        case .invalidFilename: return "The rename recipe produced an invalid filename."
        case .duplicateTarget: return "Multiple planned artifacts have the same destination."
        case .existingDestination: return "A planned rename destination already exists."
        case .caseInsensitiveCollision: return "A planned rename conflicts on a case-insensitive filesystem."
        case .unrecognizedImageExtension:
            return "The rename removes the recognized image extension. The file will no longer appear in image views."
        case .caseOnlyRename: return "The rename changes only filename capitalization."
        case .deterministicSuffixApplied: return "A deterministic suffix will resolve a rename conflict."
        case .deterministicSuffixExhausted: return "No available deterministic rename suffix was found."
        case .originalFilenameXMPSidecarMissing:
            return "Original-filename preservation requires an existing XMP sidecar for this RAW file."
        }
    }

    private func append(
        _ issues: inout [DeadlinePreflightIssue],
        occurrence: inout Int,
        severity: DeadlinePreflightSeverity,
        checkRank: Int,
        imageIndex: Int? = nil,
        imageURL: URL? = nil,
        code: DeadlinePreflightIssueCode,
        message: String,
        technicalDetail: String?
    ) {
        let scope = imageURL?.standardizedFileURL.path ?? "batch"
        let id = "\(scope)|\(checkRank)|\(occurrence)"
        issues.append(DeadlinePreflightIssue(
            id: id,
            severity: severity,
            imageIndex: imageIndex,
            imageURL: imageURL,
            code: code,
            message: message,
            technicalDetail: technicalDetail,
            checkRank: checkRank,
            occurrence: occurrence
        ))
        occurrence += 1
    }

    private func issuePrecedes(_ lhs: DeadlinePreflightIssue, _ rhs: DeadlinePreflightIssue) -> Bool {
        if lhs.severity.sortRank != rhs.severity.sortRank {
            return lhs.severity.sortRank < rhs.severity.sortRank
        }
        if lhs.checkRank != rhs.checkRank { return lhs.checkRank < rhs.checkRank }
        if lhs.imageIndex != rhs.imageIndex {
            return (lhs.imageIndex ?? Int.max) < (rhs.imageIndex ?? Int.max)
        }
        if lhs.occurrence != rhs.occurrence { return lhs.occurrence < rhs.occurrence }
        return lhs.id < rhs.id
    }
}

private extension MetadataValidationSeverity {
    nonisolated var preflightSeverity: DeadlinePreflightSeverity {
        switch self {
        case .blocker: return .blocker
        case .warning: return .warning
        case .information: return .information
        }
    }
}

private extension DeadlineStructuredMetadataField {
    nonisolated var technicalPath: String {
        switch self {
        case let .creatorContact(field, valueIndex):
            return "creatorContactInfo.\(field.rawValue)\(indexSuffix(valueIndex))"
        case let .locationCreated(locationIndex, field, valueIndex):
            return "locationsCreated[\(locationIndex)].\(field.rawValue)\(indexSuffix(valueIndex))"
        case let .locationShown(locationIndex, field, valueIndex):
            return "locationsShown[\(locationIndex)].\(field.rawValue)\(indexSuffix(valueIndex))"
        }
    }

    nonisolated func indexSuffix(_ index: Int?) -> String {
        index.map { "[\($0)]" } ?? ""
    }
}
