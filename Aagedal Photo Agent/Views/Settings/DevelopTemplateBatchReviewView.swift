import AppKit
import SwiftUI

/// App-owned so dismissed Settings can return to failed retirement and retry it.
@MainActor @Observable
final class DevelopTemplateBatchReviewPresentation {
    static let shared = DevelopTemplateBatchReviewPresentation()
    private(set) var model: DevelopTemplateBatchReviewModel?
    private(set) var templates: [DevelopTemplateBatchNativeReviewService.Template] = []
    var selectedTemplateID: UUID?
    var photos: [URL] = []
    private(set) var isLoading = false
    private(set) var message: String?
    private var service: DevelopTemplateBatchNativeReviewService?
    private var generation = UUID()

    init(service: DevelopTemplateBatchNativeReviewService? = nil) {
        self.service = service
        if let service { model = DevelopTemplateBatchReviewModel(service: service) }
    }

    var selectionGeneration: UUID { generation }

    var inputsLocked: Bool { isLoading || model?.isBusy == true || model?.review != nil || model?.cleanupRequiredID != nil }

    func refresh() async {
        guard !inputsLocked else { return }
        let request = UUID(); generation = request; isLoading = true; message = nil
        defer { if generation == request { isLoading = false } }
        do {
            let service = try self.service ?? DevelopTemplateBatchNativeReviewService.native()
            self.service = service
            if model == nil { model = DevelopTemplateBatchReviewModel(service: service) }
            let result = try await service.templates()
            guard generation == request, !Task.isCancelled else { return }
            templates = result
            if !result.contains(where: { $0.id == selectedTemplateID }) { selectedTemplateID = result.first?.id }
            if result.isEmpty { message = "No Develop templates found in the authorized local template library." }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            templates = []; selectedTemplateID = nil
            message = error.localizedDescription
        }
    }

    func selectPhotos(_ selected: [URL], generation expected: UUID) {
        guard generation == expected, !inputsLocked else { return }
        guard selected.count <= DevelopTemplateBatchIntent.maximumPhotos else {
            photos = []; message = "Select at most eight photos before preparing a review."
            return
        }
        photos = selected; message = nil
    }

    func prepare() async {
        guard !inputsLocked, let service, let model,
              let template = templates.first(where: { $0.id == selectedTemplateID }),
              !photos.isEmpty, photos.count <= DevelopTemplateBatchIntent.maximumPhotos else { return }
        let selected = photos
        await model.prepare { try await service.prepare(template: template, photos: selected) }
    }

    func dismiss() {
        generation = UUID(); isLoading = false; message = nil; photos = []
        model?.dismiss()
    }
}

struct DevelopTemplateBatchReviewView: View {
    @State private var presentation = DevelopTemplateBatchReviewPresentation.shared
    let authorizationRevision: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose up to eight authorized photos and a saved Develop template to capture a new review. This saves review evidence locally. Photo edits cannot be applied from this review yet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh Develop Templates") { Task { await presentation.refresh() } }
                    .accessibilityIdentifier("develop.nativeReview.refresh")
                Button("Choose Photos…", action: choosePhotos)
                    .accessibilityIdentifier("develop.nativeReview.choosePhotos")
            }.disabled(presentation.inputsLocked)
            Picker("Develop template", selection: $presentation.selectedTemplateID) {
                Text("Choose a template").tag(nil as UUID?)
                ForEach(presentation.templates) { template in
                    Text(verbatim: template.name).tag(Optional(template.id))
                }
            }.disabled(presentation.inputsLocked)
                .accessibilityIdentifier("develop.nativeReview.template")
            if presentation.photos.count > DevelopTemplateBatchIntent.maximumPhotos {
                Text("Select at most eight photos before preparing a review.").foregroundStyle(.orange)
            }
            if presentation.model?.review == nil {
                ForEach(Array(presentation.photos.enumerated()), id: \.offset) { index, photo in
                    Text(verbatim: "\(index + 1). \(photo.path)").font(.caption).textSelection(.enabled)
                }
            }
            HStack {
                Button("Prepare Develop Review") { Task { await presentation.prepare() } }
                    .disabled(presentation.inputsLocked || presentation.selectedTemplateID == nil || presentation.photos.isEmpty
                        || presentation.photos.count > DevelopTemplateBatchIntent.maximumPhotos)
                    .accessibilityIdentifier("develop.nativeReview.prepare")
                if presentation.model?.review != nil || presentation.model?.isBusy == true {
                    Button("Close Develop Review") { presentation.dismiss() }
                        .accessibilityIdentifier("develop.nativeReview.close")
                }
                if let model = presentation.model, model.cleanupRequiredID != nil {
                    Button("Retry Review Cleanup") { Task { await model.retryCleanup() } }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("develop.nativeReview.retryCleanup")
                }
            }
            if presentation.isLoading || presentation.model?.isBusy == true { ProgressView().controlSize(.small) }
            if let review = presentation.model?.review {
                reviewDetails(review.evidence)
                    .accessibilityIdentifier("develop.nativeReview.evidence")
            }
            if let message = presentation.model?.message {
                Text(verbatim: message).font(.caption).accessibilityIdentifier("develop.nativeReview.status")
            }
            if let message = presentation.message {
                Text(verbatim: message).font(.caption).accessibilityIdentifier("develop.nativeReview.discoveryStatus")
            }
        }
        .task { await presentation.refresh() }
        .onChange(of: authorizationRevision) { _, _ in presentation.dismiss() }
        .onDisappear { presentation.dismiss() }
    }

    private func reviewDetails(_ evidence: DevelopTemplateBatchAdmissionEvidence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: evidence.template.name).font(.headline)
            Text(verbatim: evidence.template.summary).font(.caption)
            Text(evidence.template.includesCrop ? "Template crop replaces each destination crop." : "Each destination crop is preserved.")
            Text("Captured for XMP sidecar edits; saved photos and metadata are unchanged.")
            Text("\(evidence.photos.count) photos in captured order")
            ForEach(Array(evidence.photos.enumerated()), id: \.element.requestID) { index, photo in
                DisclosureGroup {
                    Text(verbatim: "Source: \(photo.sourceRevision)")
                    Text(verbatim: "XMP: \(photo.xmpRevision)")
                    Text(verbatim: "App metadata: \(photo.appRevision)")
                    if let temperature = photo.neutralTemperature, let tint = photo.neutralTint {
                        Text("RAW as-shot neutral: \(temperature) K, tint \(tint)")
                    }
                    Text(photo.isRAW ? "RAW decoder state captured." : "Non-RAW decoder state captured.")
                } label: {
                    Text(verbatim: "\(index + 1). \(photo.url.path)")
                }.font(.caption).textSelection(.enabled)
            }
            DisclosureGroup("Capture identity") {
                Text(verbatim: evidence.batchID.uuidString)
                Text(verbatim: evidence.templateRevision)
            }.font(.caption).textSelection(.enabled)
        }
    }

    private func choosePhotos() {
        let request = presentation.selectionGeneration
        let panel = NSOpenPanel()
        panel.title = "Choose Photos for Develop Review"
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.resolvesAliases = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !presentation.inputsLocked, presentation.selectionGeneration == request else { return }
            presentation.selectPhotos(panel.urls, generation: request)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
