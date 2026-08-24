import SwiftUI

nonisolated struct DeadlineWorkspaceInput: Equatable, Sendable {
    let request: DeadlinePreflightRequest
    let revisionToken: DeadlinePreflightRevisionToken
    /// Exact Develop values captured with the preflight input, aligned by item index.
    let developSnapshots: [DevelopVersionSnapshot?]
    /// Exact source-byte revisions captured off-main as part of this preflight publication.
    let sourceRevisions: [SourceImageRevision?]
    var cachePolicy: DeadlinePreflightCachePolicy = .useCompositeRevisionToken
}

@MainActor
@Observable
final class DeadlineWorkspaceModel {
    private(set) var state: DeadlineWorkspaceState?
    private(set) var progressState: DeadlineWorkspaceProgressState?
    private(set) var publication: DeadlinePreflightPublication?
    private(set) var isEvaluating = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let coordinator: DeadlinePreflightCoordinator
    @ObservationIgnored private var requestedToken: DeadlinePreflightRevisionToken?

    init(coordinator: DeadlinePreflightCoordinator = DeadlinePreflightCoordinator()) {
        self.coordinator = coordinator
    }

    var presentedState: DeadlineWorkspaceState? {
        state ?? progressState?.workspaceState
    }

    func clear() {
        requestedToken = nil
        state = nil
        progressState = nil
        publication = nil
        isEvaluating = false
        errorMessage = nil
    }

    func refresh(_ input: DeadlineWorkspaceInput) async {
        requestedToken = input.revisionToken
        isEvaluating = true
        state = nil
        progressState = nil
        publication = nil
        errorMessage = nil
        do {
            let publication = try await coordinator.evaluate(
                request: input.request,
                token: input.revisionToken,
                cachePolicy: input.cachePolicy,
                onProgress: { [weak self] progressPublication in
                    await self?.acceptProgress(progressPublication, request: input.request)
                }
            )
            guard !Task.isCancelled,
                  requestedToken == input.revisionToken,
                  let publication else { return }
            self.publication = publication
            state = DeadlineWorkspaceState(request: input.request, report: publication.report)
            progressState = nil
        } catch is CancellationError {
            // A replacement `.task(id:)` owns the next publication.
        } catch {
            guard requestedToken == input.revisionToken else { return }
            errorMessage = error.localizedDescription
        }
        if requestedToken == input.revisionToken {
            isEvaluating = false
        }
    }

    private func acceptProgress(
        _ publication: DeadlinePreflightProgressPublication,
        request: DeadlinePreflightRequest
    ) {
        guard requestedToken == publication.token, isEvaluating else { return }
        progressState = DeadlineWorkspaceProgressState(
            request: request,
            progress: publication.progress
        )
    }
}

struct DeadlineWorkspaceView: View {
    let input: DeadlineWorkspaceInput?
    let resumeWorkflowIdentifier: UUID?
    let onFixNext: (DeadlineRemediationDestination) -> Void
    let onManageProfiles: () -> Void
    let onResumeWorkflowConsumed: (UUID) -> Void
    let onClose: () -> Void

    @State private var model: DeadlineWorkspaceModel
    @State private var deliveryModel: DeadlineDeliveryExecutionModel
    @State private var filter: DeadlineWorkspaceFilter = .blockers

    init(
        input: DeadlineWorkspaceInput?,
        deliveryDependencies: DeadlineDeliveryExecutionDependencies,
        resumeWorkflowIdentifier: UUID? = nil,
        onFixNext: @escaping (DeadlineRemediationDestination) -> Void,
        onManageProfiles: @escaping () -> Void,
        onResumeWorkflowConsumed: @escaping (UUID) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.input = input
        self.resumeWorkflowIdentifier = resumeWorkflowIdentifier
        self.onFixNext = onFixNext
        self.onManageProfiles = onManageProfiles
        self.onResumeWorkflowConsumed = onResumeWorkflowConsumed
        self.onClose = onClose
        _model = State(initialValue: DeadlineWorkspaceModel())
        _deliveryModel = State(initialValue: DeadlineDeliveryExecutionModel(
            dependencies: deliveryDependencies
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusStrip
            Divider()
            overview
            Divider()
            summary
            Divider()
            results
            Divider()
            footer
        }
        .accessibilityIdentifier("deadline.workspace")
        .task(id: DeadlineWorkspaceTaskIdentity(
            preflight: input?.revisionToken,
            resumeWorkflowIdentifier: resumeWorkflowIdentifier
        )) {
            if let input {
                await model.refresh(input)
                deliveryModel.synchronizePreflight(model.publication)
            } else {
                model.clear()
                deliveryModel.synchronizePreflight(nil)
            }
            if let resumeWorkflowIdentifier {
                await deliveryModel.recover(workflowIdentifier: resumeWorkflowIdentifier)
                guard !Task.isCancelled else { return }
                onResumeWorkflowConsumed(resumeWorkflowIdentifier)
            }
        }
        .alert("Accept Batch Warnings?", isPresented: warningAcceptancePresented) {
            Button("Cancel", role: .cancel) { deliveryModel.rejectWarnings() }
            Button("Accept and Continue") {
                guard let input, let publication = model.publication else { return }
                deliveryModel.acceptWarningsAndPrepare(input: input, publication: publication)
            }
        } message: {
            Text("This acceptance applies only to the warning identifiers in this exact preflight batch. Any input change requires a new acceptance.")
        }
        .sheet(isPresented: confirmationPresented) {
            if case let .awaitingConfirmation(confirmation) = deliveryModel.state {
                DeadlineDeliveryConfirmationView(
                    confirmation: confirmation,
                    onCancel: { deliveryModel.cancelConfirmation() },
                    onConfirm: { deliveryModel.confirmAndStart() }
                )
            }
        }
        .onDisappear {
            deliveryModel.abandonRecoveredWorkflow(resumeWorkflowIdentifier)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Deadline Workspace")
                    .font(.title2.weight(.semibold))
                Text("Selected profile: \(model.presentedState?.profileName ?? input?.request.profile.name ?? "None")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isEvaluating {
                if let progress = model.progressState {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(
                            value: Double(progress.completedImageCount),
                            total: Double(max(progress.totalImageCount, 1))
                        )
                        .frame(width: 140)
                        Text("\(progress.stageTitle) \(progress.completedImageCount)/\(progress.totalImageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Starting preflight…")
                        .controlSize(.small)
                }
            }
            Button("Manage Profiles…", action: onManageProfiles)
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(DeadlineWorkspaceStage.allCases.enumerated()), id: \.element) { index, stage in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Label(stage.rawValue, systemImage: stageIcon(stage))
                    .foregroundStyle(stageColor(stage))
                    .font(.callout.weight(.medium))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder
    private var overview: some View {
        if let state = model.presentedState {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                GridRow {
                    overviewLabel("Current phase", systemImage: "flag.checkered")
                    Text(currentPhaseSummary(state))
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("deadline.currentPhase")
                }
                GridRow {
                    overviewLabel("Readiness", systemImage: "checklist")
                    Text(state.readinessSummary)
                        .accessibilityIdentifier("deadline.readinessSummary")
                }
                GridRow {
                    overviewLabel("Next required action", systemImage: "arrow.right.circle")
                    Text(nextRequiredAction(state))
                        .lineLimit(2)
                        .accessibilityIdentifier("deadline.nextRequiredAction")
                }
                GridRow {
                    overviewLabel("Send eligibility", systemImage: "paperplane.circle")
                    Text(sendAvailability.summary)
                        .foregroundStyle(sendAvailability.isEnabled ? Color.green : Color.secondary)
                        .accessibilityIdentifier("deadline.sendEligibility")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let state = model.presentedState {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    Text("Planned Outputs")
                        .font(.headline)
                    summaryValue("Ready", value: state.readyCount, color: .green)
                    summaryValue("Blockers", value: state.blockerCount, color: .red)
                    summaryValue("Warnings", value: state.warningCount, color: .orange)
                    Spacer()
                    Picker("Filter", selection: $filter) {
                        ForEach(DeadlineWorkspaceFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 330)
                    .help(DeadlineWorkspaceState.filterScopeExplanation)
                    .accessibilityLabel("Deadline result filter")
                }
                HStack(spacing: 20) {
                    Label(state.writeStrategySummary, systemImage: "square.and.pencil")
                    Label(state.destinationSummary, systemImage: "paperplane")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(DeadlineWorkspaceState.filterScopeExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        } else if input == nil {
            ContentUnavailableView(
                "No Deadline Profile Selected",
                systemImage: "doc.badge.gearshape",
                description: Text("Open Manage Profiles to create, import, or select a saved profile.")
            )
            .padding()
        } else if let error = model.errorMessage {
            ContentUnavailableView("Preflight Failed", systemImage: "exclamationmark.triangle", description: Text(error))
                .padding()
        }
    }

    @ViewBuilder
    private var results: some View {
        if let state = model.presentedState {
            let rows = state.rows(matching: filter)
            if rows.isEmpty {
                ContentUnavailableView(
                    "No \(filter.rawValue)",
                    systemImage: filter == .ready ? "checkmark.circle" : "line.3.horizontal.decrease.circle"
                )
            } else {
                List(rows) { row in
                    if let remediation = row.issues.first(where: {
                        $0.severity == .blocker || $0.severity == .warning
                    })?.remediationDestination {
                        Button {
                            onFixNext(remediation)
                        } label: {
                            resultRow(row)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isEvaluating)
                    } else {
                        resultRow(row)
                    }
                }
            }
        } else if model.isEvaluating {
            Spacer()
            ProgressView("Running preflight…")
            Spacer()
        } else if input == nil {
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Fix Next") {
                if let destination = model.state?.nextRemediation {
                    onFixNext(destination)
                }
            }
            .disabled(model.state?.nextRemediation == nil)
            .help("Open the exact editor or settings surface for the next issue")

            Spacer()

            deliveryStatus
            if deliveryModel.canResume {
                Button("Resume") { deliveryModel.resume() }
            }
            if deliveryModel.isBusy {
                Button("Cancel") { deliveryModel.requestCancellation() }
            } else {
                Button("Send") {
                    guard let input, let publication = model.publication else { return }
                    deliveryModel.requestSend(input: input, publication: publication)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!sendAvailability.isEnabled)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        switch deliveryModel.state {
        case .idle, .awaitingWarningAcceptance, .awaitingConfirmation:
            if let error = deliveryModel.error {
                Text(error.localizedDescription).foregroundStyle(.red)
            } else if let input,
                      input.sourceRevisions.count != input.request.items.count
                        || input.sourceRevisions.contains(where: { $0 == nil }) {
                Text("Exact source identity capture is unavailable. Run preflight again.")
                    .foregroundStyle(.red)
            }
        case .preparing:
            ProgressView().controlSize(.small)
            Text("Freezing exact delivery plan…")
        case let .executing(progress):
            ProgressView(value: Double(progress.completedItemCount), total: Double(max(progress.itemCount, 1)))
                .frame(width: 100)
            Text("\(stageTitle(progress.stage)) \(progress.completedItemCount)/\(progress.itemCount)")
        case .sent:
            Label("Sent and receipt recorded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Text(deliveryModel.error?.localizedDescription ?? "Delivery failed; evidence retained.")
                .foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled at a file boundary; evidence retained.")
                .foregroundStyle(.secondary)
        }
    }

    private var warningAcceptancePresented: Binding<Bool> {
        Binding(
            get: {
                if case let .awaitingWarningAcceptance(ids) = deliveryModel.state {
                    return !ids.isEmpty
                }
                return false
            },
            set: { if !$0 { deliveryModel.rejectWarnings() } }
        )
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: {
                if case .awaitingConfirmation = deliveryModel.state { return true }
                return false
            },
            set: { if !$0 { deliveryModel.cancelConfirmation() } }
        )
    }

    private var sendAvailability: DeadlineSendAvailability {
        deliveryModel.sendAvailability(
            input: input,
            publication: model.publication,
            isEvaluating: model.isEvaluating
        )
    }

    private func overviewLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .leading)
    }

    private func currentPhaseSummary(_ state: DeadlineWorkspaceState) -> String {
        switch deliveryModel.state {
        case .preparing:
            return "Send — freezing plan"
        case let .executing(progress):
            return "Send — \(stageTitle(progress.stage))"
        case .sent:
            return "Send — completed"
        case .failed:
            return "Send — failed"
        case .cancelled:
            return "Send — cancelled"
        case .awaitingWarningAcceptance:
            return "Send — review warnings"
        case .awaitingConfirmation:
            return "Send — confirm outputs"
        case .idle:
            if model.isEvaluating { return "Verify — preflight running" }
            return state.currentStage.rawValue
        }
    }

    private func nextRequiredAction(_ state: DeadlineWorkspaceState) -> String {
        if deliveryModel.canResume {
            return "Resume the retained verified delivery, or remove it from Activity."
        }
        switch deliveryModel.state {
        case .preparing:
            return "Wait while the exact delivery plan is frozen."
        case .executing:
            return "Monitor delivery or cancel at the next safe file boundary."
        case .sent:
            return "Inspect the recorded receipt in Activity."
        case .failed:
            return "Review the failure and retained evidence in Activity."
        case .cancelled:
            return "Review the retained evidence before starting another delivery."
        case .awaitingWarningAcceptance:
            return "Review and accept this batch's warning identifiers, or cancel."
        case .awaitingConfirmation:
            return "Confirm the frozen outputs and destination, or cancel."
        case .idle:
            if model.isEvaluating { return "Wait for preflight to finish." }
            return state.nextRequiredAction
        }
    }

    private func stageTitle(_ stage: DeliveryWorkflowStage) -> String {
        switch stage {
        case .queued: "Queued"
        case .staging: "Staging"
        case .writing: "Writing metadata"
        case .verifying: "Verifying metadata"
        case .preservationVerifying: "Verifying preservation"
        case .uploading: "Uploading"
        case .remoteConfirming: "Confirming remote file"
        case .recordingReceipt: "Recording receipt"
        case .sent: "Sent"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func summaryValue(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(value.formatted())
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func resultRow(_ row: DeadlineWorkspaceRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: readinessIcon(row.readiness))
                .foregroundStyle(readinessColor(row.readiness))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.imageURL.lastPathComponent)
                    .lineLimit(1)
                Text(row.plannedOutputFilename.map { "Output: \($0)" } ?? "Output is not planned")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if row.blockerCount > 0 {
                Text("\(row.blockerCount) blocker\(row.blockerCount == 1 ? "" : "s")")
                    .foregroundStyle(.red)
            } else if row.warningCount > 0 {
                Text("\(row.warningCount) warning\(row.warningCount == 1 ? "" : "s")")
                    .foregroundStyle(.orange)
            } else {
                Text("Ready")
                    .foregroundStyle(.green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.imageURL.lastPathComponent), \(row.readiness.rawValue), \(row.blockerCount) blockers, \(row.warningCount) warnings"
        )
    }

    private func stageIcon(_ stage: DeadlineWorkspaceStage) -> String {
        switch model.presentedState?.status(for: stage) ?? (stage == .select ? .current : .locked) {
        case .complete: return "checkmark.circle.fill"
        case .current: return "circle.inset.filled"
        case .locked: return "lock.circle"
        }
    }

    private func stageColor(_ stage: DeadlineWorkspaceStage) -> Color {
        switch model.presentedState?.status(for: stage) ?? (stage == .select ? .current : .locked) {
        case .complete: return .green
        case .current: return .accentColor
        case .locked: return .secondary
        }
    }

    private func readinessIcon(_ readiness: DeadlineWorkspaceReadiness) -> String {
        switch readiness {
        case .blocked: return "xmark.octagon.fill"
        case .warnings: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle.fill"
        }
    }

    private func readinessColor(_ readiness: DeadlineWorkspaceReadiness) -> Color {
        switch readiness {
        case .blocked: return .red
        case .warnings: return .orange
        case .ready: return .green
        }
    }
}

private struct DeadlineWorkspaceTaskIdentity: Hashable {
    let preflight: DeadlinePreflightRevisionToken?
    let resumeWorkflowIdentifier: UUID?
}

private struct DeadlineDeliveryConfirmationView: View {
    let confirmation: DeadlineDeliveryConfirmation
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm Delivery").font(.title2.weight(.semibold))
            Text("Every output below will be rendered to a unique staged-copy batch, verified from its final bytes, and retained until you remove it.")
                .foregroundStyle(.secondary)
            List {
                ForEach(Array(confirmation.items.enumerated()), id: \.offset) { entry in
                    DeadlineDeliveryConfirmationRow(item: entry.element)
                }
            }
            .frame(minHeight: 180)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Connection").foregroundStyle(.secondary); Text(confirmation.destinationConnectionIdentifier).monospaced() }
                GridRow { Text("Remote path").foregroundStyle(.secondary); Text(confirmation.destinationPath).monospaced() }
                GridRow { Text("Metadata policy").foregroundStyle(.secondary); Text("Staged copies only") }
                GridRow {
                    Text("Maximum file size").foregroundStyle(.secondary)
                    Text(confirmation.maximumOutputByteCount.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "No limit")
                }
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Stage, Verify, and Send", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 480)
    }

}

private struct DeadlineDeliveryConfirmationRow: View {
    let item: DeadlineDeliveryConfirmationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.outputFilename).font(.body.monospaced())
            Text("\(item.format) · \(item.gamut.rawValue) · \(quality) · \(item.resolution.rawValue)")
                .font(.caption)
            Text(c2paText)
                .font(.caption)
                .foregroundStyle(item.c2paConsequence == .none ? Color.secondary : Color.orange)
        }
    }

    private var quality: String {
        item.qualityPercent.map { "quality \($0)%" } ?? "quality n/a"
    }

    private var c2paText: String {
        let consequence = item.c2paConsequence
        return switch consequence {
        case .none: "C2PA: no source manifest detected"
        case .preserved: "C2PA: manifest preserved"
        case .originalWriteInvalidatesManifest: "C2PA: original write would invalidate the manifest"
        case .derivedOutputDropsManifest: "C2PA: derived output does not carry the source manifest"
        case .requiresResigning: "C2PA: derived output requires signing for new credentials"
        case .unsupportedProtectedSource: "C2PA: protected source is unsupported"
        }
    }
}
