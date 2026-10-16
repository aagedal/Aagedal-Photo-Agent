import SwiftUI

/// Displays authenticated durable evidence. Native scanner consent and execution
/// are deliberately absent from this presentation-only handoff.
struct AutomationFaceScanIntentReviewView: View {
    @State private var nativeInvocation = AutomationNativeInvocationController.shared

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
                Button("Dismiss Face Intent") { nativeInvocation.consumeFaceReview(review) }
                    .accessibilityIdentifier("automation.faceIntentReview.dismiss")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("automation.faceIntentReview.detail")
            .onDisappear { nativeInvocation.consumeFaceReview(review) }
        } else {
            Text("Open a retained face scan request from an authenticated local client to inspect its exact original inventory and options. This review starts no scan.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
