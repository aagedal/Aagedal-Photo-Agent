import AppKit
import SwiftUI

/// Historical physical evidence only; inspection never issues scan consent or replay.
struct AutomationFaceScanRecoveryView: View {
    @State private var directory: URL?
    @State private var receipts: [MCPFaceScanReceiptStore.Receipt] = []
    @State private var message: String?
    @State private var inspection: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var isLoading = false
    @State private var expandedReceipts: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review retained face scan receipts, including interrupted scans and uncertain file effects. Inspection does not check current photos, restore face data, or start another scan.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Review Managed Face Scan Receipts") { inspectManaged() }
                    .accessibilityIdentifier("automation.faceReceipts.managed")
                if let directory {
                    Button("Refresh") { inspect(directory) }
                        .accessibilityIdentifier("automation.faceReceipts.refresh")
                }
            }.disabled(isLoading)
            Button("Choose Face Scan Receipt Folder…") { choose() }
                .accessibilityIdentifier("automation.faceReceipts.chooseFolder")
                .disabled(isLoading)
            if let directory { Text(verbatim: directory.path).font(.caption).textSelection(.enabled) }
            if isLoading { ProgressView().controlSize(.small) }
            if let message {
                Text(verbatim: message).accessibilityIdentifier("automation.faceReceipts.status")
            }
            ForEach(receipts, id: \.operationID) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        if !expandedReceipts.insert(receipt.operationID).inserted {
                            expandedReceipts.remove(receipt.operationID)
                        }
                    } label: {
                        HStack {
                            Image(systemName: expandedReceipts.contains(receipt.operationID) ? "chevron.down" : "chevron.right")
                            Text(verbatim: receiptLabel(receipt)).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: receiptLabel(receipt)))
                    .accessibilityValue(expandedReceipts.contains(receipt.operationID) ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("automation.faceReceipts.entry.\(receipt.operationID.uuidString.lowercased())")
                    if expandedReceipts.contains(receipt.operationID) {
                        Text("Prepared photos: \(receipt.photoCount)")
                        Text(receipt.forceFullScan ? "Full scan; saved face results may have been reset." : "Incremental scan.")
                        if receipt.includeJerseyNumbers { Text("Jersey number recognition requested.") }
                        if let completion = receipt.completion {
                            Text("Processed: \(completion.processedCount). Failed: \(completion.failureCount). Unqualified files: \(completion.unsignedFileCount).")
                            Text("Committed thumbnails: \(completion.committedThumbnailCount). Committed documents: \(completion.committedDocumentCount).")
                            if let reset = completion.reset, reset.completed == false,
                               let removed = reset.removedRelativePaths, !removed.isEmpty {
                                Text("Reset stopped after removing \(removed.count) saved face-data entries. Review the folder before retrying.")
                                    .foregroundStyle(.orange)
                            } else if completion.resetCommitted { Text("Saved face data reset was committed.") }
                            if completion.persistenceFailed || completion.completionUnavailable || completion.submissionMismatch || completion.coordinationFailed {
                                Text("Completion or persistence is uncertain. Preserve this evidence and inspect the saved files before another scan.")
                                    .foregroundStyle(.orange)
                            }
                            if completion.documents.contains(where: { $0.authorityRefused || !$0.failedThumbnailIDs.isEmpty }) {
                                Text("A document effect refused authority or thumbnail deletion failed. Review required.")
                                    .foregroundStyle(.orange)
                            }
                            if completion.documents.contains(where: \.cancellationRequestedAfterCommit)
                                || completion.reset?.cancellationRequestedAfterCommit == true {
                                Text("Cancellation arrived after a committed effect; cancellation did not undo that effect.")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text(receipt.phase == .executionPossible
                                ? "Execution was admitted; physical effects may have occurred without a completion receipt."
                                : "Admitted without a completion receipt. This record cannot prove whether execution started.")
                                .foregroundStyle(.orange)
                        }
                        if let admission = receipt.durableAdmission {
                            Text(verbatim: "Original request: \(admission.requestID)").font(.caption)
                            Text(verbatim: "Admission: \(admission.admissionID)").font(.caption)
                            Text("Historical client correlation; inspection does not restore consent or prove current folder contents.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: "Intent: \(receipt.intentID.uuidString.lowercased())").font(.caption)
                        Text(verbatim: "Inventory revision: \(receipt.snapshotRevision)").font(.caption)
                    }
                }
            }
        }
        .onDisappear {
            generation = UUID(); inspection?.cancel(); inspection = nil
            receipts = []; expandedReceipts = []; message = nil; isLoading = false
        }
    }

    private func receiptLabel(_ receipt: MCPFaceScanReceiptStore.Receipt) -> String {
        "\(receipt.operationID.uuidString.lowercased()) — \(receipt.completion?.outcome.rawValue ?? receipt.phase.rawValue)"
    }

    private func inspectManaged() {
        do { inspect(try MCPFaceScanReceiptStore.defaultStorageDirectory()) }
        catch { message = "The managed face scan receipt location is unavailable. Choose its private folder to inspect retained evidence." }
    }

    private func choose() {
        let expected = generation
        let panel = NSOpenPanel()
        panel.title = "Choose Retained Face Scan Receipts"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard generation == expected, response == .OK, let selected = panel.url else { return }
            inspect(selected)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func inspect(_ selected: URL) {
        guard !isLoading else { return }
        directory = selected; receipts = []; expandedReceipts = []; message = nil; isLoading = true
        let request = UUID(); generation = request
        inspection = Task { @MainActor in
            let scoped = selected.startAccessingSecurityScopedResource()
            defer {
                if scoped { selected.stopAccessingSecurityScopedResource() }
                if generation == request { isLoading = false; inspection = nil }
            }
            do {
                let result = try await Task.detached {
                    try Task.checkCancellation()
                    return try MCPFaceScanReceiptStore(storageDirectory: selected).receipts()
                }.value
                guard generation == request, !Task.isCancelled else { return }
                receipts = result
                message = result.isEmpty ? "No retained face scan receipts found in this folder."
                    : "Historical receipts inspected. Current photos and saved face data have not been checked."
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                message = "Cannot inspect this private receipt archive. Check access, symbolic links, corruption, or an active writer. Retained evidence is unchanged."
            }
        }
    }
}
