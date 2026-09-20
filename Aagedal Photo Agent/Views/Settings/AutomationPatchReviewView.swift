import SwiftUI

struct AutomationPatchReviewView: View {
    @State private var model = AutomationPatchReviewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a plan ID from prepare_iptc_patch to inspect its proposed changes. Inspection checks the current photo, sidecars and folder authorization. It does not approve or write metadata.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Patch plan ID", text: $model.planID)
                    .accessibilityIdentifier("automation.patchPlanID")
                    .onSubmit { model.inspect() }
                    .onChange(of: model.planID) { _, _ in model.clear() }
                Button("Inspect Plan") { model.inspect() }
                    .disabled(model.isLoading || model.planID.isEmpty)
                    .accessibilityIdentifier("automation.inspectPatchPlan")
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            if let message = model.message {
                Text(verbatim: message).foregroundStyle(.red)
                    .accessibilityIdentifier("automation.patchPlanError")
            }
            if let review = model.review {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date < review.expiresAt {
                        content(review)
                    } else {
                        Text("This plan has expired. Prepare a new patch in your client.")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Clear Review") { model.clear() }
            }
        }
        .onDisappear { model.clear() }
    }

    private func content(_ review: AutomationPatchReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: review.path).font(.caption).textSelection(.enabled)
            Text("Checked snapshot · expires \(review.expiresAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changes after inspection require a fresh check. Commit is unavailable in this build.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(review.changes) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(change.id) — \(change.operation == "clear" ? "Clear" : "Set")")
                        .font(.headline)
                    Text("Before").font(.caption).foregroundStyle(.secondary)
                    value(change.before)
                    Text("Proposed").font(.caption).foregroundStyle(.secondary)
                    value(change.after)
                }
            }
            ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                Text(verbatim: warning).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(verbatim: text.isEmpty ? "(empty)" : text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
