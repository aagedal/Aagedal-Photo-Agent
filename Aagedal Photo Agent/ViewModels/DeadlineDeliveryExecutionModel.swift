import Foundation

nonisolated struct DeadlineDeliveryPreparation: Sendable {
    let preflightRequest: DeadlinePreflightRequest
    let publication: DeadlinePreflightPublication
    let preflightDevelopSnapshots: [DevelopVersionSnapshot?]
    let preflightSourceRevisions: [SourceImageRevision?]
    let acceptedWarningIDs: Set<String>
}

nonisolated struct DeadlinePreparedDeliveryBatch: Sendable {
    let workflowIdentifier: UUID
    let plan: DeliveryPlan
    let stagingRootURL: URL
    let c2paConsequences: [DeadlineC2PAConsequence]
}

nonisolated struct DeadlineDeliveryConfirmationItem: Equatable, Identifiable, Sendable {
    let itemIndex: Int
    let outputFilename: String
    let format: String
    let gamut: DeadlineExportSnapshot.ColorGamut
    let qualityPercent: Int?
    let resolution: DeadlineExportSnapshot.ResolutionLimit
    let c2paConsequence: DeadlineC2PAConsequence

    var id: Int { itemIndex }
}

/// Exact, value-only projection shown before any staging directory or network operation exists.
nonisolated struct DeadlineDeliveryConfirmation: Equatable, Sendable {
    let planFingerprint: String
    let items: [DeadlineDeliveryConfirmationItem]
    let destinationConnectionIdentifier: String
    let destinationPath: String
    let metadataWriteStrategy: DeadlineMetadataWriteStrategy
    let maximumOutputByteCount: Int64?
    let acceptedWarningIDs: [String]

    init(prepared: DeadlinePreparedDeliveryBatch) {
        let export = prepared.plan.renderAndWrite.export
        planFingerprint = prepared.plan.fingerprint
        destinationConnectionIdentifier = prepared.plan.destination.connectionIdentifier
        destinationPath = prepared.plan.destination.resolvedRemotePath
        metadataWriteStrategy = prepared.plan.renderAndWrite.metadataWriteStrategy
        maximumOutputByteCount = export.maximumOutputByteCount
        acceptedWarningIDs = prepared.plan.acceptedWarningIDs
        items = prepared.plan.items.map { item in
            DeadlineDeliveryConfirmationItem(
                itemIndex: item.itemIndex,
                outputFilename: item.outputFilename,
                format: item.isHDR ? export.hdrFormat.rawValue : export.sdrFormat.rawValue,
                gamut: item.isHDR ? export.hdrGamut : export.sdrGamut,
                qualityPercent: Self.qualityPercent(item.isHDR ? export.hdrQuality : export.sdrQuality),
                resolution: export.resolutionLimit,
                c2paConsequence: prepared.c2paConsequences.indices.contains(item.itemIndex)
                    ? prepared.c2paConsequences[item.itemIndex]
                    : .none
            )
        }
    }

    private static func qualityPercent(_ quality: Double) -> Int? {
        guard quality.isFinite, (0 ... 1).contains(quality) else { return nil }
        return Int((quality * 100).rounded())
    }
}

nonisolated enum DeadlineDeliveryExecutionError: Error, Equatable, LocalizedError, Sendable {
    case stalePreflight
    case preflightBlocked
    case warningsNotAccepted
    case unsupportedWriteStrategy
    case preparationFailed
    case executionFailed
    case resumeUnavailable

    var errorDescription: String? {
        switch self {
        case .stalePreflight: "Run preflight again before sending."
        case .preflightBlocked: "Resolve every preflight blocker before sending."
        case .warningsNotAccepted: "Accept the current batch warnings before sending."
        case .unsupportedWriteStrategy: "Delivery requires the staged-copies metadata strategy."
        case .preparationFailed: "The exact delivery plan could not be prepared."
        case .executionFailed: "Delivery did not complete. Verified staged evidence was retained."
        case .resumeUnavailable: "No exact verified staged delivery is available to resume."
        }
    }
}

/// Injection boundary for UI composition. Production owns filesystem, renderer, transport, and
/// repositories; tests can prove the UI lifecycle without touching any of those resources.
@MainActor
struct DeadlineDeliveryExecutionDependencies {
    typealias Progress = @Sendable (DeliveryWorkflowProgress) async -> Void

    let prepare: (DeadlineDeliveryPreparation) async throws -> DeadlinePreparedDeliveryBatch
    let start: (DeadlinePreparedDeliveryBatch, @escaping Progress) async throws -> DeliveryWorkflowResult
    let resume: (DeadlinePreparedDeliveryBatch, @escaping Progress) async throws -> DeliveryWorkflowResult
    let cancel: () async -> Void
    let recover: () async throws -> DeadlinePreparedDeliveryBatch?
    let recoverWorkflow: (UUID) async throws -> DeadlinePreparedDeliveryBatch
    let releaseRecoveredWorkflow: (UUID) async -> Void
    let reloadReceipts: () async -> Void

    init(
        prepare: @escaping (DeadlineDeliveryPreparation) async throws -> DeadlinePreparedDeliveryBatch,
        start: @escaping (
            DeadlinePreparedDeliveryBatch,
            @escaping Progress
        ) async throws -> DeliveryWorkflowResult,
        resume: @escaping (
            DeadlinePreparedDeliveryBatch,
            @escaping Progress
        ) async throws -> DeliveryWorkflowResult,
        cancel: @escaping () async -> Void,
        recover: @escaping () async throws -> DeadlinePreparedDeliveryBatch?,
        reloadReceipts: @escaping () async -> Void,
        recoverWorkflow: @escaping (UUID) async throws -> DeadlinePreparedDeliveryBatch = { _ in
            throw DeadlineDeliveryExecutionError.resumeUnavailable
        },
        releaseRecoveredWorkflow: @escaping (UUID) async -> Void = { _ in }
    ) {
        self.prepare = prepare
        self.start = start
        self.resume = resume
        self.cancel = cancel
        self.recover = recover
        self.recoverWorkflow = recoverWorkflow
        self.releaseRecoveredWorkflow = releaseRecoveredWorkflow
        self.reloadReceipts = reloadReceipts
    }
}

@MainActor
@Observable
final class DeadlineDeliveryExecutionModel {
    enum State: Equatable {
        case idle
        case awaitingWarningAcceptance([String])
        case preparing
        case awaitingConfirmation(DeadlineDeliveryConfirmation)
        case executing(DeliveryWorkflowProgress)
        case sent(receiptIdentifier: UUID)
        case failed(DeliveryWorkflowFailureCode?)
        case cancelled
    }

    private(set) var state: State = .idle
    private(set) var error: DeadlineDeliveryExecutionError?
    private(set) var acceptedWarningIDs: Set<String> = []
    private(set) var canResume = false
    private(set) var isRecovering = false

    @ObservationIgnored private let dependencies: DeadlineDeliveryExecutionDependencies
    @ObservationIgnored private var preparedBatch: DeadlinePreparedDeliveryBatch?
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var preflightIdentity: DeadlinePreflightRevisionToken?
    @ObservationIgnored private var didAttemptRelaunchRecovery = false
    @ObservationIgnored private var activeExecutionWorkflowIdentifier: UUID?
    @ObservationIgnored private var recoveredWorkflowIdentifier: UUID?

    init(dependencies: DeadlineDeliveryExecutionDependencies) {
        self.dependencies = dependencies
    }

    deinit { activeTask?.cancel() }

    var isBusy: Bool {
        if isRecovering { return true }
        switch state {
        case .preparing, .executing: return true
        default: return false
        }
    }

    func sendIsEnabled(
        input: DeadlineWorkspaceInput?,
        publication: DeadlinePreflightPublication?,
        isEvaluating: Bool
    ) -> Bool {
        guard !isEvaluating, !isBusy, !canResume, canBeginNewBatch,
              let input, let publication,
              publication.token == input.revisionToken,
              !publication.report.isBlocked,
              input.request.profile.metadataWriteStrategy == .stagedCopies,
              !input.request.items.isEmpty,
              input.sourceRevisions.count == input.request.items.count,
              input.sourceRevisions.allSatisfy({ $0 != nil }) else { return false }
        return true
    }

    func synchronizePreflight(_ publication: DeadlinePreflightPublication?) {
        let identity = publication?.token
        guard identity != preflightIdentity else { return }
        if case .executing = state {
            // A live-preflight refresh must not cancel an already confirmed exact delivery.
            preflightIdentity = identity
            return
        }
        activeTask?.cancel()
        activeTask = nil
        releaseRecoveredWorkflowIfNeeded()
        preflightIdentity = identity
        acceptedWarningIDs = []
        preparedBatch = nil
        canResume = false
        error = nil
        state = .idle
    }

    func requestSend(input: DeadlineWorkspaceInput, publication: DeadlinePreflightPublication) {
        guard sendIsEnabled(input: input, publication: publication, isEvaluating: false) else {
            error = publication.report.isBlocked ? .preflightBlocked : .stalePreflight
            return
        }
        let warningIDs = publication.report.issues
            .filter { $0.severity == .warning }
            .map(\.id)
            .sorted()
        if Set(warningIDs) != acceptedWarningIDs {
            state = .awaitingWarningAcceptance(warningIDs)
            error = nil
            return
        }
        prepare(input: input, publication: publication)
    }

    func acceptWarningsAndPrepare(
        input: DeadlineWorkspaceInput,
        publication: DeadlinePreflightPublication
    ) {
        let warningIDs = Set(publication.report.issues
            .filter { $0.severity == .warning }
            .map(\.id))
        guard !warningIDs.isEmpty else {
            prepare(input: input, publication: publication)
            return
        }
        acceptedWarningIDs = warningIDs
        prepare(input: input, publication: publication)
    }

    func rejectWarnings() {
        acceptedWarningIDs = []
        preparedBatch = nil
        state = .idle
    }

    func confirmAndStart() {
        guard let preparedBatch,
              case .awaitingConfirmation = state else { return }
        execute(preparedBatch, resume: false)
    }

    func cancelConfirmation() {
        guard case .awaitingConfirmation = state else { return }
        preparedBatch = nil
        acceptedWarningIDs = []
        state = .idle
    }

    func requestCancellation() {
        guard case .executing = state else { return }
        activeTask?.cancel()
        Task { await dependencies.cancel() }
    }

    func resume() {
        guard canResume, let preparedBatch else {
            error = .resumeUnavailable
            return
        }
        execute(preparedBatch, resume: true)
    }

    func recoverAfterRelaunch() async {
        guard !didAttemptRelaunchRecovery, !isBusy else { return }
        didAttemptRelaunchRecovery = true
        do {
            guard let recovered = try await dependencies.recover() else { return }
            preparedBatch = recovered
            canResume = true
            state = .failed(nil)
            error = nil
        } catch {
            self.error = .resumeUnavailable
        }
    }

    func abandonRecoveredWorkflow(_ selectedWorkflowIdentifier: UUID? = nil) {
        if let selectedWorkflowIdentifier,
           selectedWorkflowIdentifier != recoveredWorkflowIdentifier {
            let release = dependencies.releaseRecoveredWorkflow
            Task { await release(selectedWorkflowIdentifier) }
        } else {
            releaseRecoveredWorkflowIfNeeded()
        }
        preparedBatch = nil
        canResume = false
        if case .failed(nil) = state { state = .idle }
    }

    /// Loads only the workflow explicitly selected in Activity. No catalog ordering or
    /// single-candidate heuristic participates in this path.
    func recover(workflowIdentifier: UUID) async {
        guard !isBusy else {
            error = .resumeUnavailable
            return
        }
        isRecovering = true
        canResume = false
        preparedBatch = nil
        defer { isRecovering = false }
        do {
            let recovered = try await dependencies.recoverWorkflow(workflowIdentifier)
            guard !Task.isCancelled,
                  recovered.workflowIdentifier == workflowIdentifier else {
                throw DeadlineDeliveryExecutionError.resumeUnavailable
            }
            preparedBatch = recovered
            recoveredWorkflowIdentifier = workflowIdentifier
            canResume = true
            state = .failed(nil)
            error = nil
        } catch {
            await dependencies.releaseRecoveredWorkflow(workflowIdentifier)
            preparedBatch = nil
            canResume = false
            self.error = .resumeUnavailable
            state = .failed(nil)
        }
    }

    private func prepare(
        input: DeadlineWorkspaceInput,
        publication: DeadlinePreflightPublication
    ) {
        guard publication.token == input.revisionToken,
              publication.report.isBlocked == false,
              input.request.profile.metadataWriteStrategy == .stagedCopies else {
            error = .stalePreflight
            return
        }
        let expectedIdentity = publication.token
        state = .preparing
        error = nil
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await dependencies.prepare(DeadlineDeliveryPreparation(
                    preflightRequest: input.request,
                    publication: publication,
                    preflightDevelopSnapshots: input.developSnapshots,
                    preflightSourceRevisions: input.sourceRevisions,
                    acceptedWarningIDs: acceptedWarningIDs
                ))
                guard !Task.isCancelled, preflightIdentity == expectedIdentity,
                      prepared.plan.preflight.revision == expectedIdentity,
                      prepared.plan.acceptedWarningIDs == acceptedWarningIDs.sorted(),
                      prepared.plan.renderAndWrite.metadataWriteStrategy
                        == DeadlineMetadataWriteStrategy.stagedCopies else {
                    throw DeadlineDeliveryExecutionError.stalePreflight
                }
                preparedBatch = prepared
                canResume = false
                state = State.awaitingConfirmation(DeadlineDeliveryConfirmation(prepared: prepared))
            } catch is CancellationError {
                acceptedWarningIDs = []
                state = .idle
            } catch let typed as DeadlineDeliveryExecutionError {
                acceptedWarningIDs = []
                error = typed
                state = .idle
            } catch {
                acceptedWarningIDs = []
                self.error = DeadlineDeliveryExecutionError.preparationFailed
                state = State.idle
            }
        }
    }

    private func execute(_ batch: DeadlinePreparedDeliveryBatch, resume: Bool) {
        error = nil
        activeTask?.cancel()
        activeExecutionWorkflowIdentifier = batch.workflowIdentifier
        if resume, recoveredWorkflowIdentifier == batch.workflowIdentifier {
            recoveredWorkflowIdentifier = nil
        }
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if activeExecutionWorkflowIdentifier == batch.workflowIdentifier {
                    activeExecutionWorkflowIdentifier = nil
                }
            }
            do {
                let reportProgress: DeadlineDeliveryExecutionDependencies.Progress = {
                    [weak self] (progress: DeliveryWorkflowProgress) in
                    await MainActor.run { self?.state = State.executing(progress) }
                }
                let result: DeliveryWorkflowResult
                if resume {
                    result = try await dependencies.resume(batch, reportProgress)
                } else {
                    result = try await dependencies.start(batch, reportProgress)
                }
                // A file-boundary cancellation can return a persisted `.cancelled` result even
                // though the owning task is marked cancelled. Apply that exact result unless a
                // newer preflight publication has replaced this batch.
                guard executionIsCurrent(batch, resume: resume) else { return }
                canResume = result.hasRecoverableStagedEvidence && !result.isSent
                switch result.manifest.stage {
                case .sent:
                    guard let receiptID = result.manifest.completedReceiptIdentifier else {
                        throw DeadlineDeliveryExecutionError.executionFailed
                    }
                    state = State.sent(receiptIdentifier: receiptID)
                    canResume = false
                    preparedBatch = nil
                    acceptedWarningIDs = []
                    await dependencies.reloadReceipts()
                case .cancelled:
                    state = State.cancelled
                    resetCompletedBatchAcceptanceIfNeeded()
                case .failed:
                    state = State.failed(result.manifest.failureCode)
                    self.error = DeadlineDeliveryExecutionError.executionFailed
                    resetCompletedBatchAcceptanceIfNeeded()
                default:
                    state = State.failed(nil)
                    self.error = DeadlineDeliveryExecutionError.executionFailed
                    resetCompletedBatchAcceptanceIfNeeded()
                }
            } catch is CancellationError {
                guard executionIsCurrent(batch, resume: resume) else { return }
                state = State.cancelled
                resetCompletedBatchAcceptanceIfNeeded()
            } catch {
                guard executionIsCurrent(batch, resume: resume) else { return }
                state = State.failed(nil)
                self.error = DeadlineDeliveryExecutionError.executionFailed
                resetCompletedBatchAcceptanceIfNeeded()
            }
        }
    }

    private func executionIsCurrent(
        _ batch: DeadlinePreparedDeliveryBatch,
        resume: Bool
    ) -> Bool {
        guard activeExecutionWorkflowIdentifier == batch.workflowIdentifier else { return false }
        return resume || preflightIdentity == batch.plan.preflight.revision
    }

    private var canBeginNewBatch: Bool {
        switch state {
        case .idle, .sent, .failed, .cancelled: true
        case .awaitingWarningAcceptance, .preparing, .awaitingConfirmation, .executing: false
        }
    }

    private func resetCompletedBatchAcceptanceIfNeeded() {
        guard !canResume else { return }
        preparedBatch = nil
        acceptedWarningIDs = []
    }

    private func releaseRecoveredWorkflowIfNeeded() {
        guard let recoveredWorkflowIdentifier else { return }
        self.recoveredWorkflowIdentifier = nil
        let release = dependencies.releaseRecoveredWorkflow
        Task { await release(recoveredWorkflowIdentifier) }
    }
}

/// Owns the one active production coordinator so Cancel reaches the exact upload actor. All
/// configuration copied into a run is secret-free; the FTP transport resolves Keychain material
/// only inside its operation boundary.
@MainActor
final class DeadlineDeliveryProductionSession {
    private var activeCoordinator: DeliveryWorkflowCoordinator?
    private let registry: DeliveryWorkflowRegistry
    private var workflowsBeingRemoved: Set<UUID> = []
    private(set) var activeWorkflowIdentifier: UUID?
    private var reservedResumeWorkflowIdentifier: UUID?

    var protectedWorkflowIdentifier: UUID? {
        activeWorkflowIdentifier ?? reservedResumeWorkflowIdentifier
    }

    init(
        registryRootURL: URL = AppPaths.applicationSupport.appendingPathComponent(
            "Delivery Workflows",
            isDirectory: true
        )
    ) {
        registry = DeliveryWorkflowRegistry(rootURL: registryRootURL)
    }

    func prepare(
        _ preparation: DeadlineDeliveryPreparation,
        browser: BrowserViewModel,
        profileLibrary: DeadlineProfileLibraryModel,
        liveSnapshot: DeadlinePreflightLiveSnapshotModel
    ) async throws -> DeadlinePreparedDeliveryBatch {
        try CaptionWorkspaceFlushCoordinator.shared.flush()
        let flush = await DevelopVersionFlushCoordinator.shared.flush(.workspaceExit)
        guard flush == .succeeded,
              let liveInput = liveSnapshot.workspaceInput,
              liveInput.revisionToken == preparation.publication.token,
              liveInput.request == preparation.preflightRequest,
              profileLibrary.selectedProfile == preparation.preflightRequest.profile,
              preparation.preflightDevelopSnapshots.count
                == preparation.preflightRequest.items.count,
              preparation.preflightSourceRevisions.count
                == preparation.preflightRequest.items.count else {
            throw DeadlineDeliveryExecutionError.stalePreflight
        }

        let selectedURLs = browser.selectedImageIDs
        let selectedImages = browser.sortedImages.filter {
            selectedURLs.contains($0.url) && $0.isImageFile
        }
        let imagesByURL = Dictionary(uniqueKeysWithValues: selectedImages.map {
            ($0.url.standardizedFileURL, $0)
        })
        let orderedImages = try preparation.preflightRequest.items.map { item -> ImageFile in
            guard let image = imagesByURL[item.sourceURL.standardizedFileURL],
                  !image.hasPendingMetadataChanges else {
                throw DeadlineDeliveryExecutionError.stalePreflight
            }
            return image
        }
        guard orderedImages.count == imagesByURL.count else {
            throw DeadlineDeliveryExecutionError.stalePreflight
        }

        let currentDevelopSnapshots: [DevelopVersionSnapshot?] = orderedImages.map { image in
            guard let settings = browser.currentCameraRawSettings(for: image.url) else { return nil }
            return DevelopVersionSnapshot(settings: settings)
        }
        var currentMetadata = orderedImages.map { $0.metadata ?? IPTCMetadata() }
        for index in currentMetadata.indices {
            currentMetadata[index].cameraRaw = currentDevelopSnapshots[index]?.settings
        }
        guard currentMetadata == preparation.preflightRequest.items.map(\.metadata),
              currentDevelopSnapshots == preparation.preflightDevelopSnapshots else {
            throw DeadlineDeliveryExecutionError.stalePreflight
        }

        let captureInputs = preparation.preflightRequest.items.enumerated().map { index, item in
            DeadlineDeliverySourceCaptureInput(
                url: item.sourceURL,
                pixelWidth: item.source.pixelWidth,
                pixelHeight: item.source.pixelHeight,
                exifOrientation: orderedImages[index].exifOrientation
            )
        }
        let currentRevisions = try await Task.detached(priority: .userInitiated) {
            var revisions: [SourceImageRevision] = []
            revisions.reserveCapacity(captureInputs.count)
            for input in captureInputs {
                revisions.append(try await SourceImageRevision.capture(
                    at: input.url,
                    pixelWidth: input.pixelWidth,
                    pixelHeight: input.pixelHeight,
                    exifOrientation: input.exifOrientation
                ))
            }
            return revisions
        }.value

        let planningItems = try currentRevisions.indices.map { index in
            guard let preflightRevision = preparation.preflightSourceRevisions[index] else {
                throw DeadlineDeliveryExecutionError.stalePreflight
            }
            return DeliveryPlanningItemInput(
                preflightSourceRevision: preflightRevision,
                currentSourceRevision: currentRevisions[index],
                resolvedMetadata: currentMetadata[index],
                preflightDevelopSnapshot: preparation.preflightDevelopSnapshots[index],
                currentDevelopSnapshot: currentDevelopSnapshots[index]
            )
        }
        let plan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: preparation.preflightRequest,
            publication: preparation.publication,
            currentRevision: liveInput.revisionToken,
            currentProfile: preparation.preflightRequest.profile,
            items: planningItems,
            acceptedWarningIDs: preparation.acceptedWarningIDs
        ))
        let workflowIdentifier = UUID()
        let locations = try await locations(for: workflowIdentifier)
        return DeadlinePreparedDeliveryBatch(
            workflowIdentifier: workflowIdentifier,
            plan: plan,
            stagingRootURL: locations.stagingRootURL,
            c2paConsequences: preparation.preflightRequest.items.map(\.c2paConsequence)
        )
    }

    func locations(for workflowIdentifier: UUID) async throws -> DeliveryWorkflowRegistryLocations {
        try await registry.locations(for: workflowIdentifier)
    }

    func recoverableBatch() async throws -> DeadlinePreparedDeliveryBatch? {
        let catalog = try await registry.catalog()
        let eligible = catalog.workflows.filter { $0.hasRetainedStaging && $0.stage != .sent }
        guard !eligible.isEmpty else { return nil }
        // Never guess among multiple recoverable deliveries. A future Activity picker can pass a
        // specific UUID; the automatic relaunch path is deliberately limited to one exact choice.
        guard eligible.count == 1 else { throw DeadlineDeliveryExecutionError.resumeUnavailable }
        let identifier = eligible[0].workflowIdentifier
        try await validateResume(workflowIdentifier: identifier)
        return try await recoverReservedBatch(for: identifier)
    }

    func recoverableBatch(
        for workflowIdentifier: UUID
    ) async throws -> DeadlinePreparedDeliveryBatch {
        let record = try await registry.resumeRecord(for: workflowIdentifier)
        return DeadlinePreparedDeliveryBatch(
            workflowIdentifier: record.workflowIdentifier,
            plan: record.plan,
            stagingRootURL: record.stagingRootURL,
            c2paConsequences: Array(repeating: .none, count: record.plan.items.count)
        )
    }

    func workflowCatalog() async throws -> DeliveryWorkflowRegistryCatalog {
        try await registry.catalog()
    }

    func validateResume(workflowIdentifier: UUID) async throws {
        guard activeWorkflowIdentifier == nil,
              reservedResumeWorkflowIdentifier == nil,
              !workflowsBeingRemoved.contains(workflowIdentifier) else {
            throw DeadlineDeliveryExecutionError.resumeUnavailable
        }
        // Claim before the actor hop so cleanup and a second resume cannot enter the gap.
        reservedResumeWorkflowIdentifier = workflowIdentifier
        do {
            _ = try await registry.resumeRecord(for: workflowIdentifier)
        } catch {
            if reservedResumeWorkflowIdentifier == workflowIdentifier {
                reservedResumeWorkflowIdentifier = nil
            }
            throw error
        }
        guard activeWorkflowIdentifier == nil,
              reservedResumeWorkflowIdentifier == workflowIdentifier,
              !workflowsBeingRemoved.contains(workflowIdentifier) else {
            reservedResumeWorkflowIdentifier = nil
            throw DeadlineDeliveryExecutionError.resumeUnavailable
        }
    }

    func releaseResumeReservation(for workflowIdentifier: UUID) {
        if reservedResumeWorkflowIdentifier == workflowIdentifier {
            reservedResumeWorkflowIdentifier = nil
        }
    }

    func recoverReservedBatch(
        for workflowIdentifier: UUID
    ) async throws -> DeadlinePreparedDeliveryBatch {
        guard activeWorkflowIdentifier == nil,
              reservedResumeWorkflowIdentifier == workflowIdentifier else {
            throw DeadlineDeliveryExecutionError.resumeUnavailable
        }
        do {
            let batch = try await recoverableBatch(for: workflowIdentifier)
            guard reservedResumeWorkflowIdentifier == workflowIdentifier else {
                throw DeadlineDeliveryExecutionError.resumeUnavailable
            }
            return batch
        } catch {
            releaseResumeReservation(for: workflowIdentifier)
            throw error
        }
    }

    func removeWorkflow(_ workflowIdentifier: UUID) async throws {
        guard activeWorkflowIdentifier != workflowIdentifier,
              reservedResumeWorkflowIdentifier != workflowIdentifier,
              workflowsBeingRemoved.insert(workflowIdentifier).inserted else {
            throw DeliveryWorkflowRegistryError.cleanupFailed
        }
        defer { workflowsBeingRemoved.remove(workflowIdentifier) }
        try await registry.removeWorkflow(workflowIdentifier)
    }

    func execute(
        _ batch: DeadlinePreparedDeliveryBatch,
        connections: [FTPConnection],
        writeEngine: any MetadataWriteEngine,
        resume: Bool,
        progress: @escaping DeadlineDeliveryExecutionDependencies.Progress
    ) async throws -> DeliveryWorkflowResult {
        guard activeCoordinator == nil,
              !workflowsBeingRemoved.contains(batch.workflowIdentifier) else {
            throw DeliveryWorkflowError.alreadyExecuting
        }
        if resume {
            guard reservedResumeWorkflowIdentifier == batch.workflowIdentifier else {
                throw DeliveryWorkflowError.resumeUnavailable
            }
            reservedResumeWorkflowIdentifier = nil
        } else {
            guard reservedResumeWorkflowIdentifier == nil else {
                throw DeliveryWorkflowError.alreadyExecuting
            }
        }
        activeWorkflowIdentifier = batch.workflowIdentifier
        defer { activeWorkflowIdentifier = nil }
        let locations: DeliveryWorkflowRegistryLocations
        if resume {
            let record = try await registry.resumeRecord(for: batch.workflowIdentifier)
            guard record.plan == batch.plan,
                  record.stagingRootURL == batch.stagingRootURL else {
                throw DeliveryWorkflowRegistryError.invalidStagingEvidence
            }
            locations = record.locations
        } else {
            locations = try await registry.createWorkflow(
                plan: batch.plan,
                workflowIdentifier: batch.workflowIdentifier,
                remoteStatPolicy: .attemptIfAvailable
            )
            guard locations.stagingRootURL == batch.stagingRootURL else {
                throw DeliveryWorkflowRegistryError.unsafeStoredPath
            }
        }

        let receiptRepository = DeliveryReceiptRepository(
            documentURL: AppPaths.applicationSupport
                .appendingPathComponent("DeliveryReceipts", isDirectory: true)
                .appendingPathComponent("receipts.json")
        )
        let coordinator = DeliveryWorkflowCoordinator(
            stagingCoordinator: try DeliveryStagingProductionFactory(
                writeEngine: writeEngine
            ).makeCoordinator(for: batch.plan),
            uploadCoordinator: VerifiedDeliveryUploadCoordinator(
                transport: DeliveryFTPTransportFactory.make(connections: connections)
            ),
            receiptAssembler: DeliveryReceiptAssembler(applicationVersion: {
                DeliveryApplicationVersion(
                    marketingVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "unknown",
                    buildNumber: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion"
                    ) as? String ?? "unknown"
                )
            }),
            receiptRecorder: .repository(receiptRepository),
            manifestPersistence: locations.manifestPersistence,
            stagingEvidencePersistence: locations.stagingEvidencePersistence
        )
        activeCoordinator = coordinator
        defer { activeCoordinator = nil }
        let request = DeliveryWorkflowRequest(
            workflowIdentifier: batch.workflowIdentifier,
            plan: batch.plan,
            currentProfile: batch.plan.profile,
            stagingRootURL: batch.stagingRootURL,
            remoteStatPolicy: .attemptIfAvailable
        )
        return if resume {
            try await coordinator.resume(request, progress: progress)
        } else {
            try await coordinator.start(request, progress: progress)
        }
    }

    func requestCancellation() async {
        await activeCoordinator?.requestCancellation()
    }
}

private nonisolated struct DeadlineDeliverySourceCaptureInput: Sendable {
    let url: URL
    let pixelWidth: Int?
    let pixelHeight: Int?
    let exifOrientation: Int?
}
