import SwiftUI

/// Authenticated evidence may be explicitly adopted into a revocable native
/// review with separate explicit consent for exact retained scanner execution.
struct AutomationFaceScanIntentReviewView: View {
    @State private var nativeInvocation = AutomationNativeInvocationController.shared
    @Environment(FaceRecognitionViewModel.self) private var scanner
    @State private var model: MCPNativeFaceScanReviewModel?
    @State private var preparation: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        if let review = nativeInvocation.pendingFaceReview {
            let presentation = review.presentation
            let intent = presentation.record.intent
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: intent.canonicalPath).textSelection(.enabled)
                Text("Exact reviewed inventory: \(presentation.imageURLs.count) photos")
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(presentation.imageURLs, id: \.self) { photo in
                            Text(verbatim: photo.lastPathComponent).font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
                    .accessibilityIdentifier("automation.faceIntentReview.inventory")
                Text(intent.forceFullScan ? "Full scan requested; saved face results would be reset." : "Incremental scan requested.")
                    .accessibilityIdentifier("automation.faceIntentReview.scanMode")
                Text(intent.includeJerseyNumbers ? "Jersey number recognition requested." : "Jersey number recognition excluded.")
                    .accessibilityIdentifier("automation.faceIntentReview.jerseyMode")
                Text("Prepared \(intent.preparedAt.formatted(date: .omitted, time: .standard)); expires \(intent.expiresAt.formatted(date: .omitted, time: .standard)). Opening this request keeps its original expiry.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("automation.faceIntentReview.expiry")
                Text("This is a snapshot checked when opened. It grants no scan consent and starts no scan. Scanning requires a separate native review of current photos and saved-data effects.")
                    .font(.caption)
                Text(verbatim: presentation.record.requestID).font(.caption).textSelection(.enabled)
                    .accessibilityIdentifier("automation.faceIntentReview.requestID")
                HStack {
                    Button("Review Original Face Request") { adopt(presentation) }
                        .disabled(model?.isPreparing == true || model?.isRunning == true)
                        .accessibilityIdentifier("automation.faceIntentReview.adopt")
                    Button("Dismiss Face Intent") { dismiss(); nativeInvocation.consumeFaceReview(review) }
                        .accessibilityIdentifier("automation.faceIntentReview.dismiss")
                }
                if let model {
                    AutomationNativeFaceScanReviewView(model: model, scanner: scanner, retainedRequest: true)
                }
                if let message { Text(verbatim: message).font(.caption) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("automation.faceIntentReview.detail")
            .onChange(of: review.id) { _, _ in dismiss() }
            .onDisappear { dismiss(); nativeInvocation.consumeFaceReview(review) }
        } else {
            Text("Open a retained face scan request from an authenticated local client to inspect its exact original inventory and options. This review starts no scan.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func adopt(_ presentation: AutomationNativeFaceScanReviewInvocationService.Presentation) {
        preparation?.cancel(); message = nil
        do {
            let fixture = UITestNativeInvocationConfiguration.current
            guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") || fixture != nil else {
                throw AutomationOperationRegistry.Failure.storageUnavailable
            }
            let requests = try fixture?.faceRequests ?? MCPFaceScanReviewRequestStore(
                storageDirectory: MCPFaceScanReviewRequestStore.defaultStorageDirectory())
            let model = try self.model ?? MCPNativeFaceScanReviewModel.native(
                scanner: scanner,
                authorizationStore: fixture?.authorizationStore ?? MCPAuthorizationStore(),
                operationDirectory: try fixture?.rootURL.appendingPathComponent("native-face-review-operations")
                    ?? AutomationOperationRegistry.defaultStorageDirectory(),
                receiptDirectory: try MCPFaceScanReceiptStore.defaultStorageDirectory())
            self.model = model
            preparation = Task { await model.prepare(record: presentation.record, requests: requests) }
        } catch { message = error.localizedDescription }
    }

    private func dismiss() {
        preparation?.cancel(); preparation = nil
        model?.dismiss(); model = nil; message = nil
    }
}
