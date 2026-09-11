import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rows acquire a verified baseline before accepting edits. Their live buffers and failed
/// persistence remain in BrowserVM and the shared Caption FIFO when lazy rows leave the screen.
struct MetadataReviewView: View {
    @Bindable var viewModel: BrowserViewModel
    @State private var levels = MetadataRequirements.load()
    @State private var minimumLengths = MetadataRequirements.loadMinimumLengths()
    @State private var owner = UUID()
    @State private var lifetime: UUID?
    @State private var operation: UUID?
    @State private var review: CaptionConflictSnapshot?
    @State private var receipt: CaptionConflictExportReceipt?
    @State private var reviewedEditorID: UUID?
    @State private var frozenPhoto: URL?
    @State private var freezeOwner: UUID?
    @State private var discardInFlight = false
    @State private var recoveryError: String?
    @State private var notice: String?

    private var coordinator: CaptionWorkspaceFlushCoordinator { viewModel.metadataReviewCoordinator }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = coordinator.failure {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Queued Metadata Needs Attention").font(.headline)
                        if let photo = failure.photoURL { Text(photo.path).font(.caption).textSelection(.enabled) }
                        Text(failure.message).font(.callout).lineLimit(3)
                    }
                    Spacer()
                    if failure.kind == .replayConflict {
                        Button("Review Queued Conflict…") { beginReview(failure) }
                            .accessibilityIdentifier("metadataReview.conflict.review")
                    } else {
                        Button("Retry Saving") { retrySaving() }
                            .accessibilityIdentifier("metadataReview.conflict.retry")
                    }
                }
                .padding(12).background(.orange.opacity(0.1))
                .disabled(operation != nil)
            }
            if let notice { Text(notice).font(.callout).padding(8).textSelection(.enabled) }
            if let recoveryError, review == nil {
                Text(recoveryError).foregroundStyle(.red).padding(8).textSelection(.enabled)
            }
            if viewModel.visibleImages.isEmpty {
                ContentUnavailableView("No Photos to Review", systemImage: "list.bullet.rectangle",
                    description: Text("Open a folder or adjust the current filters."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.visibleImages) { image in
                            let editorID = viewModel.metadataReviewEditor(for: image.url)?.id
                            VStack(alignment: .leading, spacing: 4) {
                                MetadataReviewRow(
                                    image: image, thumbnailService: viewModel.thumbnailService,
                                    levels: levels, minimumLengths: minimumLengths,
                                    isSelected: viewModel.selectedImageIDs.contains(image.url),
                                    isEditable: viewModel.metadataReviewEditor(for: image.url) != nil && !viewModel.isMetadataReviewFrozen(for: image.url),
                                    draft: viewModel.metadataReviewEditor(for: image.url)?.draft ?? image.metadata ?? IPTCMetadata(),
                                    text: { viewModel.metadataReviewText(for: $0, imageURL: image.url) },
                                    onTextChange: { field, text in
                                        guard let editorID else { return }
                                        viewModel.updateMetadataReviewText(text, field: field, for: image.url, editorID: editorID)
                                    },
                                    onSave: {
                                        guard let editorID else { return }
                                        viewModel.commitMetadataReviewEditor(for: image.url, editorID: editorID)
                                    })
                                if let error = viewModel.metadataReviewEditor(for: image.url)?.error
                                    ?? viewModel.metadataReviewLoadErrors[BrowserViewModel.metadataReviewKey(image.url)] {
                                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                }
                                if viewModel.metadataReviewEditor(for: image.url) == nil {
                                    HStack {
                                        if viewModel.metadataReviewLoading.contains(BrowserViewModel.metadataReviewKey(image.url)) {
                                            ProgressView().controlSize(.small)
                                            Text("Loading saved metadata…").font(.caption)
                                        } else {
                                            Button("Load Saved Metadata") { Task { await viewModel.prepareMetadataReviewEditor(for: image.url) } }
                                        }
                                    }
                                }
                            }
                            .task(id: viewModel.metadataReviewSourceGeneration) { await viewModel.prepareMetadataReviewEditor(for: image.url) }
                            .onChange(of: image.metadata) { _, metadata in
                                guard let editor = viewModel.metadataReviewEditor(for: image.url),
                                      editor.latestRequestID == nil, editor.draft == editor.previous,
                                      editor.textBuffers.isEmpty, editor.previous != metadata else { return }
                                Task { await viewModel.prepareMetadataReviewEditor(for: image.url) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedImageIDs = [image.url]
                                viewModel.lastClickedImageURL = image.url
                            }
                        }
                    }.padding(12)
                }
            }
        }
        .onAppear {
            lifetime = UUID()
            discardInFlight = false
            reloadRequirements()
            coordinator.register(owner: owner,
                compositionState: { BrowserViewModel.metadataReviewCompositionIsCommitted ? .committed : .active },
                handler: { try viewModel.captureMetadataReviewDrafts() })
        }
        .onDisappear {
            lifetime = nil
            operation = nil
            coordinator.unregister(owner: owner)
            if let review { Task { await coordinator.endConflictReview(review) } }
            if !discardInFlight, let frozenPhoto, let freezeOwner { viewModel.endMetadataReviewRecovery(for: frozenPhoto, owner: freezeOwner) }
            frozenPhoto = nil; freezeOwner = nil
            review = nil
            receipt = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in reloadRequirements() }
        .onChange(of: coordinator.failure) { _, failure in
            guard let review, let failure, failure.photoURL == review.photoURL,
                  failure.generation != review.failure.generation || failure.affectedRequestCount != review.requestCount else { return }
            receipt = nil
            recoveryError = "The queued edits changed. Cancel this review and open Review Queued Conflict again to export the current set."
        }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { cancelReview() } })) {
            if let review {
                CaptionConflictRecoveryView(photoURL: review.photoURL, reason: review.failure.message,
                    requestCount: review.requestCount, exportURL: receipt?.exportURL,
                    isBusy: operation != nil, errorMessage: recoveryError,
                    onExport: exportReview, onDiscard: discardReview, onCancel: cancelReview,
                    title: "Review Queued Metadata Conflict")
            }
        }
    }

    private func owns(_ id: UUID, lifetime expected: UUID, reviewID: UUID? = nil) -> Bool {
        lifetime == expected && operation == id && (reviewID == nil || review?.id == reviewID)
    }

    private func finish(_ id: UUID, lifetime expected: UUID) {
        if owns(id, lifetime: expected) { operation = nil }
    }

    private func beginReview(_ failure: CaptionQueueFailure) {
        guard let currentLifetime = lifetime, operation == nil, let photo = failure.photoURL else { return }
        do {
            freezeOwner = try viewModel.beginMetadataReviewRecovery(for: photo)
            frozenPhoto = photo
            reviewedEditorID = viewModel.metadataReviewEditor(for: photo)?.id
        } catch { recoveryError = error.localizedDescription; return }
        let id = UUID(); operation = id; recoveryError = nil; receipt = nil
        let frozenOwner = freezeOwner
        Task { @MainActor in
            defer { finish(id, lifetime: currentLifetime) }
            guard owns(id, lifetime: currentLifetime) else {
                if let frozenOwner { viewModel.endMetadataReviewRecovery(for: photo, owner: frozenOwner) }
                return
            }
            do {
                let snapshot = try await coordinator.beginConflictReview(failure)
                guard owns(id, lifetime: currentLifetime) else {
                    await coordinator.endConflictReview(snapshot)
                    if let frozenOwner { viewModel.endMetadataReviewRecovery(for: photo, owner: frozenOwner) }
                    return
                }
                review = snapshot
            } catch {
                if let frozenOwner { viewModel.endMetadataReviewRecovery(for: photo, owner: frozenOwner) }
                if owns(id, lifetime: currentLifetime) { frozenPhoto = nil; freezeOwner = nil; recoveryError = error.localizedDescription }
            }
        }
    }

    private func exportReview() {
        guard let review, let currentLifetime = lifetime, operation == nil else { return }
        let id = UUID(); operation = id; recoveryError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(review.photoURL.lastPathComponent) Metadata Recovery.json"
        panel.title = "Export Queued Metadata Recovery"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                guard owns(id, lifetime: currentLifetime, reviewID: review.id) else { return }
                defer { finish(id, lifetime: currentLifetime) }
                guard response == .OK, let url = panel.url else { return }
                do {
                    let exported = try await coordinator.exportConflict(review, to: url)
                    guard owns(id, lifetime: currentLifetime, reviewID: review.id) else { return }
                    receipt = exported
                } catch {
                    guard owns(id, lifetime: currentLifetime, reviewID: review.id) else { return }
                    receipt = nil; recoveryError = recoveryMessage(error)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func discardReview() {
        guard let review, let receipt, let currentLifetime = lifetime, operation == nil else { return }
        let id = UUID(); operation = id; recoveryError = nil
        let editorID = reviewedEditorID
        let frozenOwner = freezeOwner
        discardInFlight = true
        Task { @MainActor in
            defer {
                if owns(id, lifetime: currentLifetime) { discardInFlight = false }
                finish(id, lifetime: currentLifetime)
            }
            do {
                let result = try await coordinator.discardExportedConflict(review, receipt: receipt)
                // Storage removal succeeded even if this view unmounted. Invalidate only the
                // exact exported row's baseline so it cannot recreate discarded work later.
                await viewModel.finishMetadataReviewDiscard(for: review.photoURL, editorID: editorID)
                if let frozenOwner { viewModel.endMetadataReviewRecovery(for: review.photoURL, owner: frozenOwner) }
                guard owns(id, lifetime: currentLifetime, reviewID: review.id) else { return }
                self.review = nil; self.receipt = nil; reviewedEditorID = nil; frozenPhoto = nil; freezeOwner = nil
                notice = "Removed \(result.discardedCount) exported queued edits. Saved files and other photos' queued edits were kept."
                recoveryError = result.remainingFailure?.message
            } catch {
                guard owns(id, lifetime: currentLifetime, reviewID: review.id) else {
                    if let frozenOwner { viewModel.endMetadataReviewRecovery(for: review.photoURL, owner: frozenOwner) }
                    return
                }
                self.receipt = nil; recoveryError = recoveryMessage(error)
            }
        }
    }

    private func cancelReview() {
        guard let review, let currentLifetime = lifetime, operation == nil else { return }
        let id = UUID(); operation = id
        let frozenOwner = freezeOwner
        Task { @MainActor in
            defer { finish(id, lifetime: currentLifetime) }
            await coordinator.endConflictReview(review)
            if let frozenOwner { viewModel.endMetadataReviewRecovery(for: review.photoURL, owner: frozenOwner) }
            guard owns(id, lifetime: currentLifetime, reviewID: review.id) else { return }
            self.review = nil; receipt = nil; reviewedEditorID = nil; frozenPhoto = nil; freezeOwner = nil; recoveryError = nil
        }
    }

    private func retrySaving() {
        guard let currentLifetime = lifetime, operation == nil else { return }
        let id = UUID(); operation = id; recoveryError = nil
        Task { @MainActor in
            defer { finish(id, lifetime: currentLifetime) }
            do { try await coordinator.retryQueuedPersistence() }
            catch { if owns(id, lifetime: currentLifetime) { recoveryError = error.localizedDescription } }
        }
    }

    private func recoveryMessage(_ error: any Error) -> String {
        if let error = error as? CaptionConflictRecoveryError, case .obsoleteReview = error {
            return "The queued edits changed. Cancel this review and open Review Queued Conflict again to export the current set."
        }
        return error.localizedDescription
    }

    private func reloadRequirements() {
        levels = MetadataRequirements.load()
        minimumLengths = MetadataRequirements.loadMinimumLengths()
    }
}

private struct MetadataReviewRow: View {
    let image: ImageFile
    let thumbnailService: ThumbnailService
    let levels: MetadataRequirements.Levels
    let minimumLengths: MetadataRequirements.MinimumLengths
    let isSelected: Bool
    let isEditable: Bool
    let draft: IPTCMetadata
    let text: (MetadataFieldID) -> String
    let onTextChange: (MetadataFieldID, String) -> Void
    let onSave: () -> Void
    @FocusState private var focusedField: MetadataFieldID?

    private let columns = [GridItem(.adaptive(minimum: 185, maximum: 320), spacing: 8, alignment: .top)]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ReviewThumbnail(url: image.url, service: thumbnailService)
                    .frame(width: 112, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(image.filename)
                    .font(.caption)
                    .lineLimit(2)
                    .help(image.filename)
            }
            .frame(width: 112, alignment: .leading)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(MetadataFieldID.userSelectable, id: \.self) { field in
                    fieldCell(field)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        }
        .onChange(of: focusedField) { oldField, _ in
            if oldField != nil { commitDraft() }
        }
    }

    @ViewBuilder
    private func fieldCell(_ field: MetadataFieldID) -> some View {
        let value = field.textValue(in: draft) ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = levels[field] ?? .optional
        let failures = MetadataReviewValidation.failures(
            for: field,
            in: draft,
            imageURL: image.url,
            levels: levels,
            minimumLengths: minimumLengths
        )
        let primaryFailure = failures.first

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(field.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let minimum = minimumLengths[field], level != .optional {
                    Text("min \(minimum)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            TextField(trimmed.isEmpty ? "Missing" : field.displayName, text: binding(for: field), axis: .vertical)
                .textFieldStyle(.plain)
                .disabled(!isEditable)
                .font(.caption)
                .lineLimit(field == .description || field == .extendedDescription ? 3...5 : 1...2)
                .focused($focusedField, equals: field)
                .onSubmit { commitDraft() }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            primaryFailure.map { validationColor(for: $0.severity) }
                                ?? Color(nsColor: .separatorColor),
                            lineWidth: primaryFailure == nil ? 1 : 2
                        )
                }
                .accessibilityLabel(field.displayName)
                .accessibilityValue(
                    failures.isEmpty
                        ? "No validation issues"
                        : failures.map(\.accessibleDescription).joined(separator: "; ")
                )

            ForEach(failures) { failure in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: failure.systemImageName)
                        .accessibilityHidden(true)
                    Text(failure.accessibleDescription)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(validationColor(for: failure.severity))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(failure.accessibleDescription)
            }
        }
        .help(failures.isEmpty ? value : failures.map(\.accessibleDescription).joined(separator: "\n"))
    }

    private func binding(for field: MetadataFieldID) -> Binding<String> {
        Binding(
            get: { text(field) },
            set: { onTextChange(field, $0) }
        )
    }

    private func commitDraft() {
        guard isEditable else { return }
        onSave()
    }

    private func validationColor(for severity: MetadataValidationSeverity) -> Color {
        switch severity {
        case .blocker: .red
        case .warning: .orange
        case .information: .blue
        }
    }
}

private struct ReviewThumbnail: View {
    let url: URL
    let service: ThumbnailService
    @State private var thumbnail: NSImage?
    @State private var isShowingPreview = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoverTask?.cancel()
            if isHovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    isShowingPreview = true
                }
            } else {
                isShowingPreview = false
            }
        }
        .popover(isPresented: $isShowingPreview, arrowEdge: .leading) {
            ZStack {
                Color.black
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 480, height: 360)
            .accessibilityLabel("Preview of \(url.lastPathComponent)")
        }
        .task(id: url) {
            if let cached = service.thumbnail(for: url) {
                thumbnail = cached
            } else {
                thumbnail = await service.loadThumbnail(for: url)
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            isShowingPreview = false
        }
    }
}
