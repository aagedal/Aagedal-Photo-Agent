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
                    .disabled(model.isApplying)
                    .onSubmit { model.inspect() }
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
                    if model.isApplying || model.applicationResult != nil || (!model.isExpired && context.date < review.expiresAt) {
                        content(review)
                    } else {
                        Text("This plan has expired. Prepare a new patch in your client.")
                            .foregroundStyle(.secondary)
                            .onAppear { model.expireReview(at: context.date) }
                    }
                }
                Button("Clear Review") { model.clear() }
                    .disabled(model.isApplying)
            }
        }
        .onDisappear { model.clear() }
    }

    private func content(_ review: AutomationPatchReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: review.path).font(.caption).textSelection(.enabled)
            Text("Checked snapshot · expires \(review.expiresAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changes after inspection require a fresh check. Direct publication to the photo or XMP remains unavailable here.")
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
            if model.applicationResult == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Verify XMP Dry Run") { model.inspectXMPCandidate() }
                        .disabled(model.isLoading || model.isApplying)
                        .accessibilityIdentifier("automation.verifyPatchXMP")
                    Text("Builds and checks a temporary XMP candidate for this plan. It does not save beside the photo or approve publication. Starting a dry run revokes any current approval.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let result = model.xmpPreflight {
                        Text("XMP dry run verified. No photo or sidecar was changed.")
                            .accessibilityIdentifier("automation.patchXMPStatus")
                        Text(verbatim: "Proposed destination: \(result.targetPath)")
                            .font(.caption).textSelection(.enabled)
                        ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(verbatim: warning).font(.caption).foregroundStyle(.secondary)
                        }
                        if let publicationReview = model.xmpPublicationReview {
                            publicationConsent(publicationReview)
                        }
                        DisclosureGroup("Verification details") {
                            Text(verbatim: "Temporary XMP: \(result.stagedByteCount) bytes\nSHA-256: \(result.stagedSHA256)")
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            Text("Approve Reviewed Plan records consent for exactly these changes in this review session, after checking the files and authorization again. It does not write metadata. Clearing or leaving this review revokes consent.")
                .font(.caption).foregroundStyle(.secondary)
            if let result = model.applicationResult {
                Text(verbatim: applicationMessage(result))
                    .accessibilityIdentifier("automation.patchDraftStatus")
                Text(verbatim: "Operation: \(result.id.uuidString.lowercased())")
                    .font(.caption).textSelection(.enabled)
            } else if model.isApproved {
                Text("Reviewed plan approved for this session. No metadata has been written.")
                    .accessibilityIdentifier("automation.patchApprovalStatus")
                Text("Apply to Pending Draft saves exactly these changes in Photo Agent’s local metadata history. Deselect this photo in all metadata editors first. The photo and XMP stay unchanged. Review and publish the pending draft using the normal metadata workflow.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply to Pending Draft") { model.applyApprovedPlanToPendingDraft() }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("automation.applyPatchDraft")
                Button("Revoke Approval") { model.revokeApproval() }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("automation.revokePatchApproval")
            } else {
                Button("Approve Reviewed Plan") { model.approveReviewedPlan() }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("automation.approvePatchPlan")
            }
        }
    }

    private func publicationConsent(_ review: MCPIPTCPatchXMPPublicationApprovalStore.Review) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("XMP publication consent").font(.headline)
            ForEach(Array(review.consequences.enumerated()), id: \.offset) { _, consequence in
                Text(verbatim: consequence).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("I understand the C2PA and preservation limitations", isOn: $model.acknowledgesC2PA)
                .accessibilityIdentifier("automation.acknowledgeXMPC2PA")
                .disabled(model.isLoading || model.isApplying)
            if review.report.publicationBinding.promotesPendingDraft {
                Toggle("I approve publishing all pending draft values, including changes outside this patch", isOn: $model.acknowledgesPendingDraft)
                    .accessibilityIdentifier("automation.acknowledgeXMPPendingDraft")
                    .disabled(model.isLoading || model.isApplying)
            }
            Text("This records separate consent for the checked XMP candidate in this session. Publication is not available yet. No files are changed. Clearing, leaving, expiry or another approval revokes this consent.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isXMPPublicationApproved {
                Text("XMP candidate approved for this session. No metadata has been published.")
                    .accessibilityIdentifier("automation.patchXMPApprovalStatus")
                Button("Revoke XMP Approval") { model.revokeApproval() }
                    .accessibilityIdentifier("automation.revokeXMPApproval")
            } else {
                Button("Approve XMP Candidate") { model.approveReviewedXMPPublication() }
                    .disabled(!model.canApproveXMPPublication)
                    .accessibilityIdentifier("automation.approveXMPCandidate")
            }
        }
    }

    private func applicationMessage(_ result: AutomationOperationRegistry.Record) -> String {
        switch result.outcome {
        case .verified:
            "Pending draft saved and verified. The photo and XMP were unchanged. Review the draft in the metadata workspace before publishing."
        case .cancelled:
            "Draft application cancelled before saving. No metadata was changed."
        case .stale, .failed:
            "Draft application was refused before saving. Deselect the photo in all metadata editors, then prepare and review a fresh plan."
        case .partialUncertain, .recoveryRequired, nil:
            "Draft application needs recovery. Inspect the photo’s pending metadata and retained operation before retrying; a draft may have been saved."
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
