import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// This presentation lives outside the flush barrier that retained variable work can block.
struct VariableConflictRecoveryHost: View {
    let viewModel: MetadataViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var review: VariableConflictSnapshot?
    @State private var receipt: VariableConflictExportReceipt?
    @State private var errorMessage: String?
    @State private var operation: UUID?
    @State private var lifetime: UUID?
    @State private var discardInFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review Retained Variable Edits").font(.title2.bold())
                    if let review {
                        Text(review.photoURL.lastPathComponent).font(.headline)
                        Text(review.photoURL.path).font(.caption).textSelection(.enabled)
                        Text(review.reason).textSelection(.enabled)
                        Text("\(review.requestCount) retained \(review.requestCount == 1 ? "request" : "requests") for this photo will be included in the recovery JSON.")
                        Text("Export first to keep a copy of the captured input, resolved edits, history and save details. Discard removes only these exported requests from this session. It keeps saved photos, metadata files and retained requests for other photos.")
                        Text("To reconcile with newer metadata, keep the recovery file, discard the exported requests, then review the saved photo and apply the edits you still want as a new operation.")
                            .font(.callout)
                        if let receipt {
                            Label("Recovery export verified", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(receipt.exportURL.path).font(.caption).textSelection(.enabled)
                        } else {
                            Text("Discard becomes available after saving and verifying the recovery JSON.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Choose one photo to review. Requests for other photos remain retained.")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(viewModel.variableRecoveryPhotos, id: \.self) { photo in
                                    Button { begin(photo) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(photo.lastPathComponent).font(.headline)
                                            Text(photo.path).font(.caption)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .accessibilityIdentifier("variable.conflictReview.photo.\(photo.path)")
                                }
                            }
                        }
                        .frame(maxHeight: 230)
                        if viewModel.variableRecoveryPhotos.isEmpty {
                            Text("No variable requests remain to review.").foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("variable.conflictReview.error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 420)
            if operation != nil { ProgressView().controlSize(.small) }
            Divider()
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if review != nil {
                    Button("Export Recovery JSON…", action: export)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("variable.conflictReview.export")
                    Button("Discard Exported Requests", role: .destructive, action: discard)
                        .disabled(receipt == nil)
                        .accessibilityIdentifier("variable.conflictReview.discard")
                }
            }
        }
        .padding(24)
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(operation != nil)
        .interactiveDismissDisabled(operation != nil)
        .accessibilityIdentifier("variable.conflictReview")
        .onAppear {
            lifetime = UUID()
            operation = nil; review = nil; receipt = nil; errorMessage = nil
            discardInFlight = false
        }
        .onDisappear {
            lifetime = nil
            // The captured discard operation owns release through verification and editor cleanup.
            if !discardInFlight, let review { Task { await viewModel.endVariableRecovery(review) } }
        }
    }

    private func owns(_ id: UUID, _ expected: UUID) -> Bool {
        lifetime == expected && operation == id
    }

    private func begin(_ photo: URL) {
        guard operation == nil, let expected = lifetime else { return }
        let id = UUID(); operation = id; errorMessage = nil
        Task { @MainActor in
            do {
                let captured = try await viewModel.beginVariableRecovery(for: photo)
                guard owns(id, expected) else {
                    await viewModel.endVariableRecovery(captured)
                    return
                }
                review = captured; receipt = nil
            } catch {
                if owns(id, expected) { errorMessage = error.localizedDescription }
            }
            if owns(id, expected) { operation = nil }
        }
    }

    private func export() {
        guard operation == nil, let expected = lifetime, let review else { return }
        let id = UUID(); operation = id; errorMessage = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(review.photoURL.lastPathComponent) Variable Recovery.json"
        panel.title = "Export Retained Variable Edits"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                guard owns(id, expected) else { return }
                defer { if owns(id, expected) { operation = nil } }
                guard response == .OK, let url = panel.url else { return }
                do {
                    let exported = try await viewModel.exportVariableRecovery(review, to: url)
                    guard owns(id, expected) else { return }
                    receipt = exported
                } catch {
                    guard owns(id, expected) else { return }
                    receipt = nil; errorMessage = error.localizedDescription
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func discard() {
        guard operation == nil, let expected = lifetime, let review, let receipt else { return }
        let id = UUID(); operation = id; errorMessage = nil
        discardInFlight = true
        Task { @MainActor in
            do {
                try await viewModel.discardVariableRecovery(review, receipt: receipt)
                guard owns(id, expected) else { return }
                self.review = nil; self.receipt = nil; operation = nil; discardInFlight = false
                dismiss()
            } catch {
                guard owns(id, expected) else {
                    await viewModel.endVariableRecovery(review)
                    return
                }
                self.receipt = nil; errorMessage = error.localizedDescription; operation = nil; discardInFlight = false
            }
        }
    }

    private func cancel() {
        guard operation == nil, let expected = lifetime else { return }
        let id = UUID(); operation = id
        Task { @MainActor in
            if let review { await viewModel.endVariableRecovery(review) }
            guard owns(id, expected) else { return }
            self.review = nil; operation = nil
            dismiss()
        }
    }
}
