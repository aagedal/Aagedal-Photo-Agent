import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A compact button + popover surfacing active work and recent background-operation history.
/// Layer 1 lists each operation (count + time); expanding a row reveals
/// Layer 2: the per-file list with destinations and a verification column.
struct ActivityHistoryButton: View {
    var history: ActivityHistoryStore
    var faceViewModel: FaceRecognitionViewModel
    var receiptLibrary: DeliveryReceiptLibraryModel
    var workflowActivity: DeliveryWorkflowActivityModel
    let onResumeWorkflow: (UUID) -> Bool
    @State private var isShowingHistory = false

    var body: some View {
        Button {
            isShowingHistory = true
        } label: {
            Group {
                if faceViewModel.isScanning {
                    Label("Face Scan \(faceViewModel.scanProgress)", systemImage: "viewfinder")
                } else {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
            ActivityHistoryView(
                history: history,
                faceViewModel: faceViewModel,
                receiptLibrary: receiptLibrary,
                workflowActivity: workflowActivity,
                onResumeWorkflow: onResumeWorkflow
            )
        }
    }
}

struct ActivityHistoryView: View {
    var history: ActivityHistoryStore
    var faceViewModel: FaceRecognitionViewModel
    @Bindable var receiptLibrary: DeliveryReceiptLibraryModel
    @Bindable var workflowActivity: DeliveryWorkflowActivityModel
    let onResumeWorkflow: (UUID) -> Bool

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case imports = "Imports"
        case uploads = "Uploads"
        case faceScans = "Face Scans"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .all
    @State private var expanded: Set<UUID> = []
    @State private var expandedReceipts: Set<UUID> = []
    @State private var pendingReceiptDeletion: DeliveryReceiptActivitySummary?
    @State private var pendingWorkflowDeletion: DeliveryWorkflowActivitySummary?

    private var filteredEntries: [ActivityEntry] {
        switch filter {
        case .all: return history.entries
        case .imports: return history.entries.filter { $0.kind == .importJob }
        case .uploads: return history.entries.filter { $0.kind == .upload }
        case .faceScans: return history.entries.filter { $0.kind == .faceScan }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity History")
                    .font(.headline)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Activity filter")
            }

            Divider()

            if faceViewModel.isScanning {
                ActiveFaceScanRow(viewModel: faceViewModel)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filteredEntries.isEmpty {
                        Text(faceViewModel.isScanning ? "No completed activity." : "No recent activity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(filteredEntries) { entry in
                            ActivityEntryRow(
                                entry: entry,
                                isExpanded: expanded.contains(entry.id),
                                toggle: { toggle(entry.id) }
                            )
                            Divider()
                        }
                    }

                    DeliveryReceiptSection(
                        model: receiptLibrary,
                        expanded: $expandedReceipts,
                        pendingDeletion: $pendingReceiptDeletion,
                        export: exportReceiptSummary
                    )

                    DeliveryWorkflowSection(
                        model: workflowActivity,
                        pendingDeletion: $pendingWorkflowDeletion,
                        resume: { workflowIdentifier in
                            Task {
                                guard await workflowActivity.requestResume(workflowIdentifier) else {
                                    return
                                }
                                guard onResumeWorkflow(workflowIdentifier) else {
                                    await workflowActivity.abandonResume(workflowIdentifier)
                                    return
                                }
                            }
                        }
                    )
                }
            }
            .frame(maxHeight: 600)
        }
        .padding(12)
        .frame(minWidth: 420, idealWidth: 680, maxWidth: 900)
        .accessibilityIdentifier("activity.history")
        .task {
            await receiptLibrary.reload()
            await workflowActivity.reload()
        }
        .confirmationDialog(
            "Delete this delivery receipt?",
            isPresented: Binding(
                get: { pendingReceiptDeletion != nil },
                set: { if !$0 { pendingReceiptDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Receipt", role: .destructive) {
                guard let receipt = pendingReceiptDeletion else { return }
                pendingReceiptDeletion = nil
                Task {
                    if await receiptLibrary.delete(id: receipt.id) {
                        expandedReceipts.remove(receipt.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingReceiptDeletion = nil }
        } message: {
            Text("This permanently removes the local audit receipt. Delivered files are not changed.")
        }
        .confirmationDialog(
            "Remove this retained delivery workflow?",
            isPresented: Binding(
                get: { pendingWorkflowDeletion != nil },
                set: { if !$0 { pendingWorkflowDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Workflow and Staging", role: .destructive) {
                guard let workflow = pendingWorkflowDeletion else { return }
                pendingWorkflowDeletion = nil
                Task { _ = await workflowActivity.removeConfirmedWorkflow(workflow.id) }
            }
            Button("Cancel", role: .cancel) { pendingWorkflowDeletion = nil }
        } message: {
            Text("This permanently removes the selected local workflow and any retained staged copies. It does not change delivered remote files or saved receipts.")
        }
        .alert("Delivery Receipt Error", isPresented: Binding(
            get: { receiptLibrary.error != nil },
            set: { if !$0 { receiptLibrary.error = nil } }
        )) {
            Button("OK", role: .cancel) { receiptLibrary.error = nil }
        } message: {
            Text(receiptLibrary.error?.localizedDescription ?? "Unknown error")
        }
        .alert("Delivery Workflow Error", isPresented: Binding(
            get: { workflowActivity.error != nil },
            set: { if !$0 { workflowActivity.error = nil } }
        )) {
            Button("OK", role: .cancel) { workflowActivity.error = nil }
        } message: {
            Text(workflowActivity.error?.localizedDescription ?? "Saved delivery workflows are unavailable.")
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func exportReceiptSummary(_ receipt: DeliveryReceiptActivitySummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Delivery-\(receipt.id.uuidString.lowercased()).txt"
        panel.message = "Export a privacy-preserving receipt summary. Existing files are not overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await receiptLibrary.exportSummary(id: receipt.id, to: destination) }
    }
}

private struct DeliveryWorkflowSection: View {
    @Bindable var model: DeliveryWorkflowActivityModel
    @Binding var pendingDeletion: DeliveryWorkflowActivitySummary?
    let resume: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.vertical, 4)

            HStack {
                Label("Delivery Workflows", systemImage: "shippingbox.and.arrow.backward")
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isReloading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload saved delivery workflows")
                .accessibilityLabel("Reload saved delivery workflows")
                .disabled(model.isReloading)
            }

            if model.workflows.isEmpty, model.isLoaded, !model.isReloading {
                Text("No retained delivery workflows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(model.workflows) { workflow in
                    DeliveryWorkflowRow(
                        workflow: workflow,
                        isBusy: model.isBusy(workflow.id),
                        resume: { resume(workflow.id) },
                        remove: { pendingDeletion = workflow }
                    )
                    Divider()
                }
            }
        }
    }
}

private struct DeliveryWorkflowRow: View {
    let workflow: DeliveryWorkflowActivitySummary
    let isBusy: Bool
    let resume: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: stageSymbol)
                    .foregroundStyle(stageColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delivery workflow")
                        .font(.caption.weight(.semibold))
                    Text("\(workflow.stageTitle) · \(workflow.completedItemCount)/\(workflow.itemCount) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 8) {
                if workflow.hasRetainedStaging {
                    Label("Staging retained", systemImage: "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(.secondary)
                }
                if let failureTitle = workflow.failureTitle {
                    Label(failureTitle, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption2)

            HStack(spacing: 10) {
                if workflow.canResume {
                    Button("Resume This Workflow", action: resume)
                        .disabled(isBusy)
                }
                Button("Remove…", role: .destructive, action: remove)
                    .disabled(isBusy)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var stageSymbol: String {
        switch workflow.stage {
        case .queued: "clock"
        case .staging: "shippingbox"
        case .writing: "pencil.and.list.clipboard"
        case .verifying: "checkmark.magnifyingglass"
        case .preservationVerifying: "doc.badge.gearshape"
        case .uploading: "arrow.up.circle"
        case .remoteConfirming: "network.badge.shield.half.filled"
        case .recordingReceipt: "doc.text"
        case .sent: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var stageColor: Color {
        switch workflow.stage {
        case .sent: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}

private struct DeliveryReceiptSection: View {
    @Bindable var model: DeliveryReceiptLibraryModel
    @Binding var expanded: Set<UUID>
    @Binding var pendingDeletion: DeliveryReceiptActivitySummary?
    let export: (DeliveryReceiptActivitySummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.vertical, 4)

            HStack {
                Label("Delivery Receipts", systemImage: "doc.text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isReloading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload delivery receipts")
                .accessibilityLabel("Reload delivery receipts")
                .disabled(model.isReloading)
            }

            if model.receipts.isEmpty, model.isLoaded, !model.isReloading {
                Text("No saved delivery receipts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(model.receipts) { receipt in
                    DeliveryReceiptRow(
                        receipt: receipt,
                        detail: model.detail(for: receipt.id),
                        isExpanded: expanded.contains(receipt.id),
                        isLoading: model.loadingDetailIDs.contains(receipt.id),
                        isDeleting: model.deletingReceiptIDs.contains(receipt.id),
                        toggle: { toggle(receipt.id) },
                        export: { export(receipt) },
                        delete: { pendingDeletion = receipt }
                    )
                    Divider()
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            Task { await model.loadDetail(id: id) }
        }
    }
}

private struct DeliveryReceiptRow: View {
    let receipt: DeliveryReceiptActivitySummary
    let detail: DeliveryReceiptActivityDetail?
    let isExpanded: Bool
    let isLoading: Bool
    let isDeleting: Bool
    let toggle: () -> Void
    let export: () -> Void
    let delete: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: receiptStatus.symbolName)
                        .foregroundStyle(receiptStatus.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delivery · \(receipt.evidenceSummary)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 5) {
                            Text(Self.dateFormatter.string(from: receipt.completedAt))
                            Text("·")
                            Text(receiptStatus.title)
                            if receipt.warningCount > 0 {
                                Text("· \(receipt.warningCount) accepted warning\(receipt.warningCount == 1 ? "" : "s")")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delivery receipt, \(receipt.evidenceSummary)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse receipt details" : "Expand receipt details")

            if isExpanded {
                Group {
                    if let detail {
                        DeliveryReceiptDetailView(detail: detail)
                    } else if isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading receipt evidence…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Receipt evidence is unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 28)

                HStack(spacing: 10) {
                    Button("Export Summary…", action: export)
                    Button("Delete…", role: .destructive, action: delete)
                        .disabled(isDeleting)
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.caption)
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }

    private var receiptStatus: DeliveryReceiptActivityStatus {
        detail?.status ?? receipt.status
    }
}

private struct DeliveryReceiptDetailView: View {
    let detail: DeliveryReceiptActivityDetail

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                safeFact("Batch", detail.batchIdentifier.uuidString.lowercased())
                safeFact("Profile", detail.profileIdentifier.uuidString.lowercased())
                safeFact("Connection", detail.destinationIdentifier)
                safeFact("Destination", detail.destinationPath)
                safeFact("Started", Self.dateFormatter.string(from: detail.startedAt))
                safeFact("Completed", Self.dateFormatter.string(from: detail.completedAt))
                safeFact(
                    "App",
                    "\(detail.applicationVersion.marketingVersion) (\(detail.applicationVersion.buildNumber))"
                )
            }
            .font(.caption2)

            if !detail.acceptedWarningIdentifiers.isEmpty {
                Text("Batch accepted warnings: \(detail.acceptedWarningIdentifiers.joined(separator: ", "))")
                    .font(.caption2)
            }

            Text("Item evidence")
                .font(.caption.weight(.semibold))

            ForEach(detail.items) { item in
                DeliveryReceiptEvidenceRow(item: item)
            }

            Text("Receipt details intentionally omit filenames, source paths, content hashes, credentials, and editorial metadata values.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func safeFact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct DeliveryReceiptEvidenceRow: View {
    let item: DeliveryReceiptActivityItemEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Item \(item.id)", systemImage: item.status.symbolName)
                    .foregroundStyle(item.status.color)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(item.status.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("\(item.renderSettings.formatIdentifier) · \(item.renderSettings.colorSpaceIdentifier) · \(item.renderSettings.pixelWidth)×\(item.renderSettings.pixelHeight) · \(Self.byteCount(item.deliveredByteSize))")
            Text("Metadata: \(metadataTitle) · Upload: \(uploadTitle) · Remote size: \(remoteTitle)")

            if !item.controlledFieldIdentifiers.isEmpty {
                Text("Controlled fields: \(item.controlledFieldIdentifiers.map(\.rawValue).joined(separator: ", "))")
            }
            if !item.metadataIssueIdentifiers.isEmpty {
                Text("Verification issues: \(item.metadataIssueIdentifiers.joined(separator: ", "))")
            }
            if !item.acceptedWarningIdentifiers.isEmpty {
                Text("Accepted warnings: \(item.acceptedWarningIdentifiers.joined(separator: ", "))")
            }
        }
        .font(.caption2)
        .padding(6)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
    }

    private var metadataTitle: String {
        switch item.metadataOutcome {
        case .notPerformed: "not performed"
        case .verified: "verified"
        case .verifiedWithWarnings: "verified with warnings"
        case .failed: "failed"
        }
    }

    private var uploadTitle: String {
        switch item.uploadAcknowledgement.status {
        case .notAttempted: "not attempted"
        case .protocolAcknowledged: "protocol acknowledged"
        case .rejected: "rejected"
        }
    }

    private var remoteTitle: String {
        switch item.remoteStatAcknowledgement.status {
        case .notRequested: "not requested"
        case .unavailable: "unavailable"
        case .matchesDeliveredByteSize: "matches delivered size"
        case .doesNotMatchDeliveredByteSize: "does not match delivered size"
        }
    }

    private static func byteCount(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private extension DeliveryReceiptActivityStatus {
    var symbolName: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .warnings: "exclamationmark.circle.fill"
        case .incomplete: "questionmark.circle.fill"
        case .needsReview: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .complete: .green
        case .warnings: .orange
        case .incomplete: .secondary
        case .needsReview: .red
        }
    }
}

private struct ActivityEntryRow: View {
    let entry: ActivityEntry
    let isExpanded: Bool
    let toggle: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Layer 1: summary row (click to reveal Layer 2)
            Button(action: { if !entry.files.isEmpty { toggle() } }) {
                HStack(spacing: 8) {
                    Group {
                        if entry.files.isEmpty {
                            Color.clear
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 10)

                    Image(systemName: iconName)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            if let title = entry.title, !title.isEmpty {
                                Text(title)
                                Text("·")
                            }
                            Text(Self.dateFormatter.string(from: entry.date))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: entry.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.isClean ? Color.green : Color.orange)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.files.isEmpty)
            .accessibilityLabel(entry.summary)
            .accessibilityValue(
                entry.files.isEmpty ? "No file details" : (isExpanded ? "Expanded" : "Collapsed")
            )
            .accessibilityHint(
                entry.files.isEmpty ? "" : (isExpanded ? "Collapse file details" : "Expand file details")
            )

            // Layer 2: per-file detail
            if isExpanded && !entry.files.isEmpty {
                ActivityFileTable(files: entry.files, kind: entry.kind)
                    .padding(.leading, 28)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.kind {
        case .importJob: "square.and.arrow.down"
        case .upload: "square.and.arrow.up"
        case .faceScan: "viewfinder"
        }
    }
}

private struct ActiveFaceScanRow: View {
    @Bindable var viewModel: FaceRecognitionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.isCancellingScan ? "Cancelling face scan…" : "Scanning faces")
                        .font(.caption.weight(.semibold))
                    if let folder = viewModel.scanningFolderURL {
                        Text(folder.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(viewModel.scanProgress)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { viewModel.cancelScan() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(viewModel.isCancellingScan)
            }
            ProgressView(
                value: Double(viewModel.scanProcessedCount),
                total: Double(max(viewModel.scanTotalCount, 1))
            )
        }
        .padding(.vertical, 2)
    }
}

private struct ActivityFileTable: View {
    let files: [ActivityFileRecord]
    let kind: ActivityKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("File").frame(maxWidth: .infinity, alignment: .leading)
                Text(kind == .importJob ? "Folder" : "Destination").frame(maxWidth: .infinity, alignment: .leading)
                Text("Verified").frame(width: 56, alignment: .center)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(files) { file in
                HStack {
                    Text(file.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(file.succeeded ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(displayDestination(file.destination))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    verificationCell(file.verification)
                        .frame(width: 56, alignment: .center)
                }
                .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func verificationCell(_ v: ActivityVerification) -> some View {
        switch v {
        case .verified:
            Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark").foregroundStyle(.red)
        case .notApplicable:
            Text("–").foregroundStyle(.secondary)
        }
    }

    /// Shows the folder name (or last two path components) rather than the full path.
    private func displayDestination(_ path: String) -> String {
        guard !path.isEmpty else { return "—" }
        let comps = path.split(separator: "/")
        if comps.count >= 2 {
            return comps.suffix(2).joined(separator: "/")
        }
        return comps.last.map(String.init) ?? path
    }
}
