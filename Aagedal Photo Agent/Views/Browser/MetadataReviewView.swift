import AppKit
import SwiftUI

/// Folder-wide, read-only metadata overview. The browser's already-loaded basic metadata is used so
/// the list can scroll without issuing one metadata read per row.
struct MetadataReviewView: View {
    @Bindable var viewModel: BrowserViewModel
    @State private var levels = MetadataRequirements.load()
    @State private var minimumLengths = MetadataRequirements.loadMinimumLengths()

    var body: some View {
        Group {
            if viewModel.visibleImages.isEmpty {
                ContentUnavailableView(
                    "No Photos to Review",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Open a folder or adjust the current filters.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.visibleImages) { image in
                            MetadataReviewRow(
                                image: image,
                                thumbnailService: viewModel.thumbnailService,
                                levels: levels,
                                minimumLengths: minimumLengths,
                                isSelected: viewModel.selectedImageIDs.contains(image.url),
                                onSave: { viewModel.saveMetadataReviewEdit($0, for: image.url) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedImageIDs = [image.url]
                                viewModel.lastClickedImageURL = image.url
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear { reloadRequirements() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadRequirements()
        }
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
    let onSave: (IPTCMetadata) -> Void
    @State private var draft: IPTCMetadata
    @FocusState private var focusedField: IPTCMetadata.FieldKey?

    private let columns = [GridItem(.adaptive(minimum: 185, maximum: 320), spacing: 8, alignment: .top)]

    init(image: ImageFile, thumbnailService: ThumbnailService,
         levels: MetadataRequirements.Levels,
         minimumLengths: MetadataRequirements.MinimumLengths,
         isSelected: Bool, onSave: @escaping (IPTCMetadata) -> Void) {
        self.image = image
        self.thumbnailService = thumbnailService
        self.levels = levels
        self.minimumLengths = minimumLengths
        self.isSelected = isSelected
        self.onSave = onSave
        _draft = State(initialValue: image.metadata ?? IPTCMetadata())
    }

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
                ForEach(IPTCMetadata.FieldKey.userSelectable, id: \.self) { field in
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
        .onChange(of: image.metadata) { _, newValue in
            if focusedField == nil, let newValue { draft = newValue }
        }
    }

    @ViewBuilder
    private func fieldCell(_ field: IPTCMetadata.FieldKey) -> some View {
        let value = field.textValue(in: draft) ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = levels[field] ?? .optional
        let failed = MetadataRequirements.fieldFails(field, in: draft, levels: levels, minimumLengths: minimumLengths)
        let border: Color = level == .require ? .red : .orange

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
                .font(.caption)
                .lineLimit(field == .description || field == .extendedDescription ? 3...5 : 1...2)
                .focused($focusedField, equals: field)
                .onSubmit { commitDraft() }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(failed ? border : Color(nsColor: .separatorColor), lineWidth: failed ? 2 : 1)
                }
        }
        .help(failed ? validationHelp(field, value: trimmed, level: level) : value)
    }

    private func binding(for field: IPTCMetadata.FieldKey) -> Binding<String> {
        Binding(
            get: { field.textValue(in: draft) ?? "" },
            set: { field.setTextValue($0, in: &draft) }
        )
    }

    private func commitDraft() {
        guard draft != (image.metadata ?? IPTCMetadata()) else { return }
        onSave(draft)
    }

    private func validationHelp(_ field: IPTCMetadata.FieldKey, value: String,
                                level: MetadataRequirementLevel) -> String {
        let prefix = level == .require ? "Required" : "Warning"
        if value.isEmpty { return "\(prefix): \(field.displayName) is missing" }
        if let minimum = minimumLengths[field] {
            return "\(prefix): \(field.displayName) needs at least \(minimum) characters (currently \(value.count))"
        }
        return prefix
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
