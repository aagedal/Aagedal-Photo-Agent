import SwiftUI

struct AutomationPatchReviewView: View {
    @State private var model = AutomationPatchReviewModel()
    @State private var showsRequests = false
    @State private var confirmsRequestCleanup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(showsRequests ? "Hide Client Review Requests" : "Show Client Review Requests") {
                showsRequests.toggle()
            }
            .accessibilityIdentifier("automation.showReviewRequests")
            if showsRequests {
                Text("Client requests await your review here. Select a request to inspect its current changes, then approve and apply them explicitly. Request IDs grant no consent.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh Review Requests") { model.refreshNativeRequests() }
                    .disabled(model.isBusyWithNativeRequestCapacity || model.isRefreshingNativeRequests || (model.isLoading && !model.isApplying))
                    .accessibilityIdentifier("automation.refreshReviewRequests")
                if model.isRefreshingNativeRequests { ProgressView().controlSize(.small) }
                if let message = model.nativeRequestMessage {
                    Text(verbatim: message).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("automation.reviewRequestEvidenceError")
                }
                Button("Review request capacity") { model.inspectNativeRequestCapacity() }
                    .disabled(model.isBusyWithNativeRequestCapacity || model.isApplying)
                    .accessibilityIdentifier("automation.inspectReviewRequestCapacity")
                if model.isBusyWithNativeRequestCapacity { ProgressView().controlSize(.small) }
                if let capacity = model.nativeRequestCapacity {
                    Text("Retained requests: \(capacity.retainedCount) of \(capacity.maximumRecords). Cancelled before admission: \(capacity.cancelledBeforeAdmissionCount).")
                        .font(.caption)
                        .accessibilityIdentifier("automation.reviewRequestCapacity")
                    Button("Remove cancelled review requests", role: .destructive) { confirmsRequestCleanup = true }
                        .disabled(!model.canRecoverCancelledNativeReviewCapacity)
                        .accessibilityIdentifier("automation.removeCancelledReviewRequests")
                    Text("Removes only requests cancelled before admission. Active, admitted, uncertain and linked requests remain retained. Removed requests cannot be retried. New intents need a new request ID and current epoch; retained requests keep their original epoch. Cleanup grants no consent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.nativeRequestCapacityMessage {
                    Text(verbatim: message).font(.caption)
                        .accessibilityIdentifier("automation.reviewRequestCapacityMessage")
                }
                ForEach(model.nativeRequests, id: \.requestID) { request in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: request.requestID.uuidString.lowercased())
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text(request.purpose == .pendingDraft ? "Apply to Pending Draft" : "Publish XMP")
                        if request.state == .awaitingReview {
                            Button("Inspect Requested Plan") { model.inspectNativeRequest(request.requestID) }
                                .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading || model.isApplying)
                                .accessibilityIdentifier("automation.inspectRequestedPlan.\(request.requestID.uuidString.lowercased())")
                        } else if let operationID = request.operationID {
                            Text(verbatim: "Operation: \(operationID.uuidString.lowercased())")
                                .font(.caption).textSelection(.enabled)
                            Text(verbatim: model.nativeRequestOperationStatus(request))
                                .font(.caption)
                                .accessibilityIdentifier("automation.reviewRequestOperationStatus.\(request.requestID.uuidString.lowercased())")
                            if let operation = model.operation(for: request) {
                                Text("Last recorded \(operation.updatedAt.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if request.state == .cancelled {
                            Text("Cancelled before admission.").font(.caption)
                        } else {
                            Text("Admission disposition is unknown. Inspect operation history and recovery before preparing another request.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.canCancelNativeRequest(request) {
                            Button(request.operationID == nil ? "Cancel Review Request" : "Request Cancellation") {
                                model.cancelNativeRequest(request.requestID)
                            }
                            .disabled(model.isBusyWithNativeRequestCapacity || model.isRefreshingNativeRequests || (model.isLoading && !model.isApplying))
                            .accessibilityIdentifier("automation.cancelReviewRequest.\(request.requestID.uuidString.lowercased())")
                        }
                    }.padding(.vertical, 4)
                }
            }
            Text("Paste a plan ID from prepare_iptc_patch to inspect its proposed changes. Inspection checks the current photo, sidecars and folder authorization. It does not approve or write metadata.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Patch plan ID", text: $model.planID)
                    .accessibilityIdentifier("automation.patchPlanID")
                    .disabled(model.isBusyWithNativeRequestCapacity || model.isApplying)
                    .onSubmit { model.inspect() }
                Button("Inspect Plan") { model.inspect() }
                    .disabled(model.isBusyWithNativeRequestCapacity || model.isLoading || model.planID.isEmpty)
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
                    .disabled(model.isBusyWithNativeRequestCapacity || model.isApplying)
            }
        }
        .task(id: showsRequests) {
            guard showsRequests else { return }
            model.refreshNativeRequestEvidence()
            // Observe helper cancellation and the durable operation link while native
            // execution waits. Polling evidence never grants or clears idle consent.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled else { return }
                model.refreshNativeRequestEvidence()
            }
        }
        .confirmationDialog("Remove cancelled review requests?", isPresented: $confirmsRequestCleanup) {
            Button("Remove cancelled review requests", role: .destructive) { model.recoverCancelledNativeReviewCapacity() }
        } message: {
            Text("Only requests cancelled before admission will be removed. Retained operation and recovery evidence stays available. Retries of removed requests and new requests using the previous current epoch will be refused. Retained requests keep their original epoch. Current reviews and approvals will be cleared. This grants no consent and changes no photo metadata.")
        }
        .onDisappear { model.clear() }
    }

    private func content(_ review: AutomationPatchReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let request = model.selectedRequest {
                Text(request.purpose == .pendingDraft ? "Client request: Apply to Pending Draft" : "Client request: Publish XMP")
                    .accessibilityIdentifier("automation.selectedReviewRequest")
            }
            Text(verbatim: review.path).font(.caption).textSelection(.enabled)
            Text("Checked snapshot · expires \(review.expiresAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changes after inspection require a fresh check. XMP publication requires a verified dry run and separate consent below.")
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
            if model.applicationResult == nil && (model.selectedRequest == nil || model.selectedRequest?.purpose == .xmpPublication) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Verify XMP Dry Run") { model.inspectXMPCandidate() }
                        .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading || model.isApplying)
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
            } else if model.isApproved && (model.selectedRequest == nil || model.selectedRequest?.purpose == .pendingDraft) {
                Text("Reviewed plan approved for this session. No metadata has been written.")
                    .accessibilityIdentifier("automation.patchApprovalStatus")
                Text("Apply to Pending Draft saves exactly these changes in Photo Agent’s local metadata history. Deselect this photo in all metadata editors first. The photo and XMP stay unchanged. Review and publish the pending draft using the normal metadata workflow.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply to Pending Draft") { model.applyApprovedPlanToPendingDraft() }
                    .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading)
                    .accessibilityIdentifier("automation.applyPatchDraft")
                Button("Revoke Approval") { model.revokeApproval() }
                    .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading)
                    .accessibilityIdentifier("automation.revokePatchApproval")
            } else if model.selectedRequest == nil || model.selectedRequest?.purpose == .pendingDraft {
                Button("Approve Reviewed Plan") { model.approveReviewedPlan() }
                    .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading)
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
                .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading || model.isApplying)
            if review.report.publicationBinding.promotesPendingDraft {
                Toggle("I approve publishing all pending draft values, including changes outside this patch", isOn: $model.acknowledgesPendingDraft)
                    .accessibilityIdentifier("automation.acknowledgeXMPPendingDraft")
                    .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading || model.isApplying)
            }
            Text("This records separate consent for the checked XMP candidate in this session. Approval changes no files. Publish Approved XMP then saves beside the photo and reconciles local metadata history. Deselect this photo in all metadata editors first. Clearing, leaving, expiry or another approval revokes consent.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isXMPPublicationApproved {
                Text("XMP candidate approved for this session. No metadata has been published.")
                    .accessibilityIdentifier("automation.patchXMPApprovalStatus")
                Button("Publish Approved XMP") { model.publishApprovedXMP() }
                    .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading || model.isApplying)
                    .accessibilityIdentifier("automation.publishApprovedXMP")
                Button("Revoke XMP Approval") { model.revokeApproval() }
                    .accessibilityIdentifier("automation.revokeXMPApproval")
                    .disabled(model.isRecoveringNativeRequestCapacity || model.isLoading || model.isApplying)
            } else {
                Button("Approve XMP Candidate") { model.approveReviewedXMPPublication() }
                    .disabled(!model.canApproveXMPPublication)
                    .accessibilityIdentifier("automation.approveXMPCandidate")
            }
        }
    }

    private func applicationMessage(_ result: AutomationOperationRegistry.Record) -> String {
        if result.kind == .iptcPatch {
            switch result.outcome {
            case .verified:
                return "XMP published and local metadata history verified. Original photo bytes were unchanged."
            case .cancelled:
                return "XMP publication cancelled before saving. No metadata was changed."
            case .stale, .failed:
                return "XMP publication was refused before saving. Deselect the photo in all metadata editors and inspect a fresh plan. Retained recovery may need review before retrying."
            case .partialUncertain, .recoveryRequired, nil:
                return "XMP publication needs recovery. Metadata may have changed. Original and candidate recovery files are retained; inspect operation history and the photo’s metadata before retrying. Automatic restore is unavailable."
            }
        }
        return switch result.outcome {
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
