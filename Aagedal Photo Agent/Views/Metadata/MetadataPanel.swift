import SwiftUI

struct MetadataPanel: View {
    @Bindable var viewModel: MetadataViewModel
    let browserViewModel: BrowserViewModel
    var onApplyTemplate: (() -> Void)?
    var onSaveTemplate: (() -> Void)?
    var onPendingStatusChanged: (() -> Void)?

    @State private var isShowingVariableReference = false
    @State private var showingHistoryPopover = false
    @State private var showingC2PAWarning = false
    @State private var showingEmbeddedValues = false

    var body: some View {
        Group {
            if viewModel.selectedCount == 0 {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if viewModel.isBatchEdit {
                                BatchEditBanner(count: viewModel.selectedCount)
                            }

                            ratingAndLabelSection
                            actionButtons
                            Divider()
                            priorityFieldsSection
                            Divider()
                            classificationSection
                            Divider()
                            additionalFieldsSection
                        }
                        .padding()
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        gpsSection
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .alert("C2PA Protected Image", isPresented: $showingC2PAWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Write Anyway") {
                viewModel.writeMetadataAndClearSidecar()
                onPendingStatusChanged?()
            }
        } message: {
            Text("This image has C2PA content credentials. Writing metadata will invalidate the authenticity chain.")
        }
    }

    // MARK: - Rating & Label

    @ViewBuilder
    private var ratingAndLabelSection: some View {
        if let image = browserViewModel.firstSelectedImage {
            HStack {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= image.starRating.rawValue ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(star <= image.starRating.rawValue ? .yellow : .secondary)
                    }
                }

                Spacer()

                if let color = image.colorLabel.color {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                    Text(image.colorLabel.displayName)
                        .font(.caption)
                }

                if image.hasC2PA {
                    Label("C2PA", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - Priority Fields

    @ViewBuilder
    private var priorityFieldsSection: some View {
        Section {
            // Toggle between Embedded and Pending views
            if !viewModel.isBatchEdit {
                Picker("View", selection: $showingEmbeddedValues) {
                    Text("Pending").tag(false)
                    Text("Embedded").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.originalImageMetadata == nil)
            }

            if showingEmbeddedValues && !viewModel.isBatchEdit {
                embeddedMetadataView
            } else {
                editableMetadataFields
            }
        } header: {
            HStack {
                Text("Metadata")
                    .font(.headline)
                Spacer()
                Button {
                    showingHistoryPopover = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(viewModel.sidecarHistory.isEmpty ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.sidecarHistory.isEmpty)
                .help(viewModel.sidecarHistory.isEmpty ? "No editing history" : "View editing history")
                .popover(isPresented: $showingHistoryPopover) {
                    MetadataHistoryView(history: viewModel.sidecarHistory)
                }
            }
        }
    }

    @ViewBuilder
    private var editableMetadataFields: some View {
        EditableTextField(
            label: "Title",
            text: Binding(
                get: { viewModel.editingMetadata.title ?? "" },
                set: { viewModel.editingMetadata.title = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? "Leave empty to skip" : "Enter title",
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.title)
        )

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: viewModel.fieldDiffers(\.description))
                Spacer()
                Button {
                    isShowingVariableReference = true
                } label: {
                    Image(systemName: "curlybraces")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Variable Reference")
            }
            TextField(
                viewModel.isBatchEdit ? "Leave empty to skip" : "Enter description",
                text: Binding(
                    get: { viewModel.editingMetadata.description ?? "" },
                    set: { viewModel.editingMetadata.description = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                ),
                axis: .vertical
            )
            .lineLimit(4...8)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .onSubmit {
                viewModel.saveToSidecar()
                onPendingStatusChanged?()
            }
        }
        .sheet(isPresented: $isShowingVariableReference) {
            VariableReferenceView(
                isPresented: $isShowingVariableReference,
                onInsert: { variable in
                    let current = viewModel.editingMetadata.description ?? ""
                    viewModel.editingMetadata.description = current + variable
                    viewModel.markChanged()
                }
            )
        }

        KeywordsEditorWithDiff(
            label: "Keywords",
            keywords: $viewModel.editingMetadata.keywords,
            differs: viewModel.keywordsDiffer(),
            onChange: { viewModel.markChanged() },
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() }
        )

        KeywordsEditorWithDiff(
            label: "Person Shown",
            keywords: $viewModel.editingMetadata.personShown,
            differs: viewModel.personShownDiffer(),
            onChange: { viewModel.markChanged() },
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() }
        )

        EditableTextField(
            label: "Copyright",
            text: Binding(
                get: { viewModel.editingMetadata.copyright ?? "" },
                set: { viewModel.editingMetadata.copyright = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? "Leave empty to skip" : "Enter copyright",
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.copyright)
        )
    }

    @ViewBuilder
    private var embeddedMetadataView: some View {
        if let original = viewModel.originalImageMetadata {
            ReadOnlyField(label: "Title", value: original.title)
            ReadOnlyField(label: "Description", value: original.description)
            ReadOnlyKeywords(label: "Keywords", keywords: original.keywords)
            ReadOnlyKeywords(label: "Person Shown", keywords: original.personShown)
            ReadOnlyField(label: "Copyright", value: original.copyright)
        } else {
            Text("No embedded metadata")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Classification

    @ViewBuilder
    private var classificationSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Digital Source Type")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { viewModel.editingMetadata.digitalSourceType },
                set: { viewModel.editingMetadata.digitalSourceType = $0; viewModel.markChanged() }
            )) {
                Text("None").tag(nil as DigitalSourceType?)
                ForEach(DigitalSourceType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type as DigitalSourceType?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: - Additional Fields

    @ViewBuilder
    private var additionalFieldsSection: some View {
        Section {
            if showingEmbeddedValues && !viewModel.isBatchEdit {
                embeddedAdditionalFieldsView
            } else {
                editableAdditionalFields
            }
        } header: {
            Text("Additional Fields")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var editableAdditionalFields: some View {
        EditableTextField(
            label: "Creator",
            text: Binding(
                get: { viewModel.editingMetadata.creator ?? "" },
                set: { viewModel.editingMetadata.creator = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.creator)
        )
        EditableTextField(
            label: "Credit",
            text: Binding(
                get: { viewModel.editingMetadata.credit ?? "" },
                set: { viewModel.editingMetadata.credit = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.credit)
        )
        EditableTextField(
            label: "City",
            text: Binding(
                get: { viewModel.editingMetadata.city ?? "" },
                set: { viewModel.editingMetadata.city = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.city)
        )
        EditableTextField(
            label: "Country",
            text: Binding(
                get: { viewModel.editingMetadata.country ?? "" },
                set: { viewModel.editingMetadata.country = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.country)
        )
        EditableTextField(
            label: "Event",
            text: Binding(
                get: { viewModel.editingMetadata.event ?? "" },
                set: { viewModel.editingMetadata.event = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            onCommit: { viewModel.saveToSidecar(); onPendingStatusChanged?() },
            showsDifference: viewModel.fieldDiffers(\.event)
        )
    }

    @ViewBuilder
    private var embeddedAdditionalFieldsView: some View {
        if let original = viewModel.originalImageMetadata {
            ReadOnlyField(label: "Creator", value: original.creator)
            ReadOnlyField(label: "Credit", value: original.credit)
            ReadOnlyField(label: "City", value: original.city)
            ReadOnlyField(label: "Country", value: original.country)
            ReadOnlyField(label: "Event", value: original.event)
        }
    }

    // MARK: - GPS

    @ViewBuilder
    private var gpsSection: some View {
        GPSSectionView(
            latitude: Binding(
                get: { viewModel.editingMetadata.latitude },
                set: { viewModel.editingMetadata.latitude = $0 }
            ),
            longitude: Binding(
                get: { viewModel.editingMetadata.longitude },
                set: { viewModel.editingMetadata.longitude = $0 }
            ),
            onChanged: { viewModel.markChanged() },
            isBatchMode: viewModel.isBatchEdit,
            isReverseGeocoding: viewModel.isReverseGeocoding,
            geocodingError: viewModel.geocodingError,
            geocodingProgress: viewModel.geocodingProgress,
            onReverseGeocode: {
                if viewModel.isBatchEdit {
                    viewModel.reverseGeocodeSelectedImages()
                } else {
                    viewModel.reverseGeocodeCurrentLocation()
                }
            }
        )
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = viewModel.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                if let onApplyTemplate {
                    Button {
                        onApplyTemplate()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Apply Template")
                }

                if let onSaveTemplate {
                    Button {
                        onSaveTemplate()
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .help("Save as Template")
                }

                Button {
                    let filename = browserViewModel.firstSelectedImage?.filename ?? ""
                    viewModel.processVariables(filename: filename)
                } label: {
                    Image(systemName: "curlybraces")
                }
                .disabled(!viewModel.hasVariables)
                .help("Process Variables")

                Spacer()

                if viewModel.isSaving {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    if browserViewModel.firstSelectedImage?.hasC2PA == true {
                        showingC2PAWarning = true
                    } else {
                        viewModel.writeMetadataAndClearSidecar()
                        onPendingStatusChanged?()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasChanges || viewModel.isSaving)
                .help("Write metadata to image")
            }
        }
    }
}

// MARK: - Keywords Editor With Diff

struct KeywordsEditorWithDiff: View {
    let label: String
    @Binding var keywords: [String]
    var differs: Bool = false
    var onChange: (() -> Void)? = nil
    var onCommit: (() -> Void)? = nil

    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: differs)
            }

            FlowLayout(spacing: 4) {
                ForEach(keywords, id: \.self) { keyword in
                    HStack(spacing: 2) {
                        Text(keyword)
                            .font(.caption)
                        Button {
                            keywords.removeAll { $0 == keyword }
                            onChange?()
                            onCommit?()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.2), in: Capsule())
                }
            }

            TextField("Add keyword", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit {
                    let trimmed = inputText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && !keywords.contains(trimmed) {
                        keywords.append(trimmed)
                        onChange?()
                        onCommit?()
                    }
                    inputText = ""
                }
        }
    }
}

// MARK: - Reusable Field Components

struct DifferenceIndicator: View {
    let differs: Bool

    var body: some View {
        if differs {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .help("Value differs from image file. Changes pending.")
        }
    }
}

struct EditableTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var onCommit: (() -> Void)? = nil
    var showsDifference: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: showsDifference)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit {
                    onCommit?()
                }
        }
    }
}

struct EditableTextEditor: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .font(.body)
        }
    }
}

struct BatchEditBanner: View {
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: "square.on.square")
            Text("Editing \(count) images")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(8)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ReadOnlyField: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.body)
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
    }
}

struct ReadOnlyKeywords: View {
    let label: String
    let keywords: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if keywords.isEmpty {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(keywords, id: \.self) { keyword in
                        Text(keyword)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
    }
}

/// Simple flow layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
