import Foundation

nonisolated enum DeadlineWorkspaceFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case blockers = "Blockers"
    case warnings = "Warnings"
    case ready = "Ready"

    var id: Self { self }
}

/// A semantic, UI-independent place where a preflight issue can actually be addressed. Image
/// destinations retain the exact source identity; metadata destinations additionally retain the
/// exact editor field whenever the Caption workspace has an editor for it.
nonisolated enum DeadlineRemediationDestination: Equatable, Sendable {
    case caption(imageURL: URL, field: MetadataFieldID?)
    case sourceImage(URL)
    case profileSettings
    case renameSettings(imageURL: URL?)
    case exportSettings(imageURL: URL?)
    case connectionSettings(identifier: String?)
    case stagingSettings

    static func resolve(
        code: DeadlinePreflightIssueCode,
        imageURL: URL?
    ) -> DeadlineRemediationDestination? {
        switch code {
        case .missingValidationProfile,
             .missingMetadataTemplate,
             .missingRequiredList,
             .unresolvedStructuredVariable,
             .unsupportedDeliveryWriteStrategy,
             .remotePathInvalid,
             .remotePathHasUnresolvedVariables:
            return .profileSettings

        case let .metadataValidation(_, field), let .unresolvedVariable(field):
            guard let imageURL else { return nil }
            return .caption(imageURL: imageURL, field: field)

        case .sidecarPending, .sidecarFailed, .staleDescriptiveMetadataConflict:
            guard let imageURL else { return nil }
            return .caption(imageURL: imageURL, field: nil)

        case .missingRenameRecipe, .renameEnvironmentUnavailable, .rename:
            return .renameSettings(imageURL: imageURL)

        case .sourceUnavailable,
             .sourceUnreadable,
             .sourceWritabilityUnknown,
             .sourceNotWritable,
             .unsupportedSourceFormat,
             .sourceCannotDecode,
             .invalidSourceDimensions:
            guard let imageURL else { return nil }
            return .sourceImage(imageURL)

        case .c2pa:
            return .profileSettings

        case .missingExportConfiguration,
             .exportCapabilitiesUnknown,
             .unavailableSDRExportFormat,
             .unavailableHDRExportFormat,
             .unavailableSDRExportGamut,
             .unavailableHDRExportGamut,
             .invalidExportQuality,
             .invalidMaximumOutputByteCount,
             .exportWillDownscale,
             .outputSizeEstimateUnknown,
             .estimatedOutputExceedsMaximum,
             .deliverySizeUnknown:
            return .exportSettings(imageURL: imageURL)

        case .destinationSpaceUnknown, .insufficientDestinationSpace:
            return .connectionSettings(identifier: nil)

        case .stagingUnavailable, .stagingInsufficientSpace:
            return .stagingSettings

        case let .connectionNotConfigured(identifier),
             let .connectionReachabilityUnknown(identifier),
             let .connectionUnreachable(identifier):
            return .connectionSettings(identifier: identifier)
        }
    }
}

nonisolated extension DeadlinePreflightIssue {
    var remediationDestination: DeadlineRemediationDestination? {
        DeadlineRemediationDestination.resolve(code: code, imageURL: imageURL)
    }
}

nonisolated enum DeadlineWorkspaceReadiness: String, Equatable, Sendable {
    case blocked
    case warnings
    case ready
}

nonisolated enum DeadlineWorkspaceStage: String, CaseIterable, Hashable, Sendable {
    case select = "Select"
    case caption = "Caption"
    case verify = "Verify"
    case send = "Send"
}

nonisolated enum DeadlineWorkspaceStageStatus: Equatable, Sendable {
    case complete
    case current
    case locked
}

nonisolated struct DeadlineWorkspaceRow: Identifiable, Equatable, Sendable {
    var id: URL { imageURL }
    let imageIndex: Int
    let imageURL: URL
    let plannedOutputFilename: String?
    let readiness: DeadlineWorkspaceReadiness
    let blockerCount: Int
    let warningCount: Int
    let informationCount: Int
    let issues: [DeadlinePreflightIssue]
}

/// Ready-to-render projection built when progress arrives, never from SwiftUI's body traversal.
nonisolated struct DeadlineWorkspaceProgressState: Equatable, Sendable {
    let stageTitle: String
    let completedImageCount: Int
    let totalImageCount: Int
    let workspaceState: DeadlineWorkspaceState

    init(request: DeadlinePreflightRequest, progress: DeadlinePreflightProgress) {
        stageTitle = switch progress.stage {
        case .resolvingDependencies: "Resolving dependencies"
        case .checkingImages: "Checking images"
        case .planningRename: "Planning rename"
        case .checkingDelivery: "Checking delivery"
        }
        completedImageCount = progress.completedImageCount
        totalImageCount = progress.totalImageCount
        workspaceState = DeadlineWorkspaceState(
            request: request,
            report: progress.reportSnapshot
        )
    }
}

/// Presentation-ready, deterministic projection of a preflight request and report.
nonisolated struct DeadlineWorkspaceState: Equatable, Sendable {
    /// Delivery workflow and receipt summaries deliberately contain no image identity. Adding
    /// Failed/Sent here would therefore invent per-image delivery state; those batch summaries
    /// remain in Activity while this picker stays scoped to the current preflight.
    static let filterScopeExplanation =
        "Filters show this preflight only. Sent and failed delivery history remains batch-level in Activity."

    let profileName: String
    let rows: [DeadlineWorkspaceRow]
    let blockerCount: Int
    let warningCount: Int
    let informationCount: Int
    let readyCount: Int
    let writeStrategySummary: String
    let destinationSummary: String
    let nextIssue: DeadlinePreflightIssue?

    var nextRemediation: DeadlineRemediationDestination? {
        nextIssue.flatMap { issue in
            guard issue.severity == .blocker || issue.severity == .warning else { return nil }
            return issue.remediationDestination
        }
    }

    init(request: DeadlinePreflightRequest, report: DeadlinePreflightReport) {
        profileName = request.profile.name
        blockerCount = report.blockerCount
        warningCount = report.warningCount
        informationCount = report.informationCount
        nextIssue = report.nextIssue
        writeStrategySummary = Self.writeStrategySummary(request.profile.metadataWriteStrategy)
        destinationSummary = Self.destinationSummary(request.profile.destination)

        let renameEntries = Dictionary(uniqueKeysWithValues: (report.renamePlan?.entries ?? []).map {
            ($0.itemIndex, $0)
        })
        rows = report.imageReports.map { imageReport in
            let blockers = imageReport.issues.count { $0.severity == .blocker }
            let warnings = imageReport.issues.count { $0.severity == .warning }
            let information = imageReport.issues.count { $0.severity == .information }
            let readiness: DeadlineWorkspaceReadiness = blockers > 0
                ? .blocked
                : (warnings > 0 ? .warnings : .ready)
            let entry = renameEntries[imageReport.imageIndex]
            let outputURL = entry?.plannedDestinationImageURL
                ?? (entry?.disposition == .unchanged ? imageReport.imageURL : nil)
                ?? (report.renamePlan == nil ? imageReport.imageURL : nil)
            return DeadlineWorkspaceRow(
                imageIndex: imageReport.imageIndex,
                imageURL: imageReport.imageURL,
                plannedOutputFilename: outputURL?.lastPathComponent,
                readiness: readiness,
                blockerCount: blockers,
                warningCount: warnings,
                informationCount: information,
                issues: imageReport.issues
            )
        }
        readyCount = rows.count { $0.readiness == .ready }
    }

    func rows(matching filter: DeadlineWorkspaceFilter) -> [DeadlineWorkspaceRow] {
        switch filter {
        case .blockers: return rows.filter { $0.readiness == .blocked }
        case .warnings: return rows.filter { $0.readiness == .warnings }
        case .ready: return rows.filter { $0.readiness == .ready }
        }
    }

    func status(for stage: DeadlineWorkspaceStage) -> DeadlineWorkspaceStageStatus {
        switch stage {
        case .select:
            return rows.isEmpty ? .current : .complete
        case .caption:
            if rows.isEmpty { return .locked }
            let hasCaptionBlocker = rows.lazy.flatMap(\.issues).contains {
                switch $0.code {
                case .metadataValidation, .unresolvedVariable, .unresolvedStructuredVariable,
                     .sidecarPending, .sidecarFailed:
                    return $0.severity == .blocker
                default:
                    return false
                }
            }
            return hasCaptionBlocker ? .current : .complete
        case .verify:
            guard !rows.isEmpty else { return .locked }
            return blockerCount > 0 ? .current : .complete
        case .send:
            guard !rows.isEmpty else { return .locked }
            return blockerCount == 0 ? .current : .locked
        }
    }

    private static func writeStrategySummary(_ strategy: DeadlineMetadataWriteStrategy) -> String {
        switch strategy {
        case .originals: return "Write metadata to originals"
        case .xmpSidecars: return "Write metadata to XMP sidecars"
        case .stagedCopies: return "Write metadata to staged copies"
        }
    }

    private static func destinationSummary(_ destination: DeadlineDestinationConfiguration?) -> String {
        guard let destination else { return "No delivery destination configured" }
        return "\(destination.connectionIdentifier): \(destination.remotePathTemplate)"
    }
}
