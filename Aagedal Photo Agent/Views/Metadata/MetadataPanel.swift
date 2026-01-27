import SwiftUI

struct MetadataPanel: View {
    @Bindable var viewModel: MetadataViewModel
    let browserViewModel: BrowserViewModel
    var onApplyPreset: (() -> Void)?
    var onSavePreset: (() -> Void)?

    @State private var isShowingVariableReference = false

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading metadata...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.selectedCount == 0 {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if viewModel.isBatchEdit {
                            BatchEditBanner(count: viewModel.selectedCount)
                        }

                        ratingAndLabelSection
                        Divider()
                        priorityFieldsSection
                        Divider()
                        classificationSection
                        Divider()
                        additionalFieldsSection
                        Divider()
                        actionButtons
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 320)
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
            EditableTextField(
                label: "Title",
                text: Binding(
                    get: { viewModel.editingMetadata.title ?? "" },
                    set: { viewModel.editingMetadata.title = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                ),
                placeholder: viewModel.isBatchEdit ? "Leave empty to skip" : "Enter title"
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(
                        get: { viewModel.editingMetadata.description ?? "" },
                        set: { viewModel.editingMetadata.description = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    ))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    if (viewModel.editingMetadata.description ?? "").isEmpty {
                        Text(viewModel.isBatchEdit ? "Leave empty to skip" : "Enter description")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
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

            KeywordsEditor(
                label: "Keywords",
                keywords: $viewModel.editingMetadata.keywords,
                onChange: { viewModel.markChanged() }
            )

            KeywordsEditor(
                label: "Person Shown",
                keywords: $viewModel.editingMetadata.personShown,
                onChange: { viewModel.markChanged() }
            )

            EditableTextField(
                label: "Copyright",
                text: Binding(
                    get: { viewModel.editingMetadata.copyright ?? "" },
                    set: { viewModel.editingMetadata.copyright = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                ),
                placeholder: viewModel.isBatchEdit ? "Leave empty to skip" : "Enter copyright"
            )
        } header: {
            Text("Priority Fields")
                .font(.headline)
        }
    }

    // MARK: - Classification

    @ViewBuilder
    private var classificationSection: some View {
        Section {
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
        } header: {
            Text("Classification")
                .font(.headline)
        }
    }

    // MARK: - Additional Fields

    @ViewBuilder
    private var additionalFieldsSection: some View {
        DisclosureGroup("Additional Fields") {
            VStack(alignment: .leading, spacing: 8) {
                EditableTextField(
                    label: "Creator",
                    text: Binding(
                        get: { viewModel.editingMetadata.creator ?? "" },
                        set: { viewModel.editingMetadata.creator = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    )
                )
                EditableTextField(
                    label: "Credit",
                    text: Binding(
                        get: { viewModel.editingMetadata.credit ?? "" },
                        set: { viewModel.editingMetadata.credit = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    )
                )
                EditableTextField(
                    label: "Date Created",
                    text: Binding(
                        get: { viewModel.editingMetadata.dateCreated ?? "" },
                        set: { viewModel.editingMetadata.dateCreated = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    )
                )
                EditableTextField(
                    label: "City",
                    text: Binding(
                        get: { viewModel.editingMetadata.city ?? "" },
                        set: { viewModel.editingMetadata.city = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    )
                )
                EditableTextField(
                    label: "Country",
                    text: Binding(
                        get: { viewModel.editingMetadata.country ?? "" },
                        set: { viewModel.editingMetadata.country = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    )
                )
                EditableTextField(
                    label: "Event",
                    text: Binding(
                        get: { viewModel.editingMetadata.event ?? "" },
                        set: { viewModel.editingMetadata.event = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                    )
                )
            }
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        if let error = viewModel.saveError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        HStack {
            if let onApplyPreset {
                Button("Apply Preset") { onApplyPreset() }
            }
            if let onSavePreset {
                Button("Save as Preset") { onSavePreset() }
            }
            Spacer()
        }

        HStack {
            Button {
                let filename = browserViewModel.firstSelectedImage?.filename ?? ""
                viewModel.processVariables(filename: filename)
            } label: {
                Label("Process Variables", systemImage: "curlybraces")
            }
            .disabled(!viewModel.hasVariables)
            .help("Resolve all {variable} placeholders in the fields above")

            Spacer()

            Button("Write") {
                viewModel.writeMetadata()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.hasChanges || viewModel.isSaving)
        }

        if viewModel.isSaving {
            ProgressView("Writing metadata...")
                .font(.caption)
        }
    }
}

// MARK: - Reusable Field Components

struct EditableTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body)
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
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
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
