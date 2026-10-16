import AppKit
import SwiftUI

/// Native local consent only. This view grants no helper execution capability.
struct AutomationNativeFaceScanReviewView: View {
    @Bindable var model: MCPNativeFaceScanReviewModel
    private let fixedFolder: URL?
    private let scanner: FaceRecognitionViewModel?
    private let retainedRequest: Bool
    @State private var forceFullScan = false
    @State private var includeJerseyNumbers = false

    init(model: MCPNativeFaceScanReviewModel, fixedFolder: URL? = nil, scanner: FaceRecognitionViewModel? = nil,
         retainedRequest: Bool = false) {
        self.model = model; self.fixedFolder = fixedFolder; self.scanner = scanner
        self.retainedRequest = retainedRequest
    }

    init(scanner: FaceRecognitionViewModel, authorizationStore: MCPAuthorizationStore) throws {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), UITestNativeInvocationConfiguration.current == nil {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        let operationDirectory = try UITestNativeInvocationConfiguration.current?.rootURL
            .appendingPathComponent("native-face-review-operations", isDirectory: true)
            ?? AutomationOperationRegistry.defaultStorageDirectory()
        fixedFolder = nil; self.scanner = scanner; retainedRequest = false
        self.model = .native(scanner: scanner, authorizationStore: authorizationStore,
            operationDirectory: operationDirectory,
            receiptDirectory: try MCPFaceScanReceiptStore.defaultStorageDirectory())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !retainedRequest {
                Text("Prepare a local face scan for an authorized folder, then review its exact immediate photo inventory and saved-data effects. Preparing does not start a scan or download a model.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Full scan: reset saved face results", isOn: $forceFullScan)
                    .accessibilityIdentifier("automation.faceReview.fullScan")
                    .disabled(model.isRunning || model.isPreparing)
                Toggle("Recognize jersey numbers (requires a full scan)", isOn: $includeJerseyNumbers)
                    .accessibilityIdentifier("automation.faceReview.jersey")
                    .disabled(model.isRunning || model.isPreparing)
                Button(fixedFolder == nil ? "Choose Folder and Prepare Face Scan…" : "Prepare Current Folder Face Scan") { choose() }
                    .disabled(model.isRunning || model.isPreparing)
                    .accessibilityIdentifier("automation.faceReview.prepare")
            }
            if let review = model.review {
                Text(verbatim: review.intent.prepared.folderURL.path).textSelection(.enabled)
                Text("Exact reviewed inventory: \(review.intent.prepared.imageURLs.count) photos")
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(review.intent.prepared.imageURLs, id: \.self) { photo in
                            Text(verbatim: photo.lastPathComponent).font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160).accessibilityIdentifier("automation.faceReview.inventory")
                Text(review.intent.prepared.forceFullScan ? "Full scan; saved face results will be reset." : "Incremental scan.")
                Text(review.intent.prepared.includeJerseyNumbers ? "Jersey number recognition included." : "Jersey number recognition excluded.")
                ForEach(review.consequences.filter { !$0.hasPrefix("Physical scanner writes") }, id: \.self) { Text(verbatim: $0).font(.caption) }
                Text("Review expires at \(review.intent.expiresAt.formatted(date: .omitted, time: .standard)). Changed inventory, authorization, model readiness or dismissal requires a new review.")
                    .font(.caption).foregroundStyle(.secondary)
                if review.intent.durableRequest == nil {
                    Toggle("I approve scanning exactly these photos and saving local face data", isOn: $model.acknowledgesScan)
                        .accessibilityIdentifier("automation.faceReview.consent")
                    if review.intent.prepared.forceFullScan {
                        Toggle("I approve resetting saved face results and deleting their thumbnails", isOn: $model.acknowledgesReset)
                            .accessibilityIdentifier("automation.faceReview.resetConsent")
                    }
                    Button("Start Reviewed Face Scan") { Task { await model.start() } }
                        .disabled(!model.canStart).accessibilityIdentifier("automation.faceReview.start")
                } else {
                    Text("Scanning from retained client requests is not available yet. This review grants no scan consent.")
                        .font(.caption).accessibilityIdentifier("automation.faceReview.retainedReviewOnly")
                }
                Button("Dismiss Review") { model.dismiss() }
            }
            if model.isPreparing { ProgressView("Preparing exact inventory…").controlSize(.small) }
            if model.isRunning {
                if let scanner, scanner.scanTotalCount > 0 {
                    ProgressView(value: Double(scanner.scanProcessedCount), total: Double(scanner.scanTotalCount))
                    Text("Processed \(scanner.scanProcessedCount) of \(scanner.scanTotalCount) photos")
                        .font(.caption).accessibilityIdentifier("automation.faceReview.progress")
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel Retained Face Scan") { Task { await model.cancel() } }
                    .disabled(!model.canCancel).accessibilityIdentifier("automation.faceReview.cancel")
            }
            if let message = model.message {
                Text(verbatim: message).accessibilityIdentifier("automation.faceReview.status")
            }
            if let receipt = model.receipt, let completion = receipt.completion {
                Text("Receipt: \(receipt.operationID.uuidString.lowercased())").font(.caption).textSelection(.enabled)
                Text("Processed \(completion.processedCount); failed \(completion.failureCount). Committed thumbnails \(completion.committedThumbnailCount); documents \(completion.committedDocumentCount).")
                    .font(.caption)
                if completion.resetCommitted { Text("Saved face results reset was committed.").font(.caption) }
            }
        }
        .onChange(of: forceFullScan) { _, _ in model.dismiss() }
        .onChange(of: includeJerseyNumbers) { _, _ in model.dismiss() }
        .onDisappear { model.dismiss() }
    }

    private func choose() {
        if let fixedFolder { prepare(fixedFolder); return }
        let panel = NSOpenPanel()
        panel.title = "Prepare Native Face Scan"
        panel.prompt = "Prepare"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        prepare(folder)
    }

    private func prepare(_ folder: URL) {
        let full = forceFullScan, jersey = includeJerseyNumbers
        Task { await model.prepare(folder: folder, forceFullScan: full, includeJerseyNumbers: jersey) }
    }
}
