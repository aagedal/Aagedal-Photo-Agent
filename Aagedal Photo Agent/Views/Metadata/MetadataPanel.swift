import SwiftUI
import UniformTypeIdentifiers

struct MetadataPanel: View {
    @Bindable var viewModel: MetadataViewModel
    let browserViewModel: BrowserViewModel
    let settingsViewModel: SettingsViewModel
    var onApplyTemplate: (() -> Void)?
    var onSaveTemplate: (() -> Void)?
    var onPendingStatusChanged: (() -> Void)?

    @State private var isShowingVariableReference = false
    @State private var showingHistoryPopover = false
    @State private var showingC2PAWarning = false
    @State private var showingListFilePicker = false
    @State private var listFilePickerTarget: ListFileTarget = .keywords
    @FocusState private var focusedField: String?
    @State private var c2paOverwriteIntent: C2PAOverwriteIntent?
    @State private var pendingC2PASelection: [URL] = []

    enum ListFileTarget {
        case keywords
        case personShown
    }

    enum C2PAOverwriteIntent {
        case autoCommit
        case manualWrite
    }

    private func commitEdits() {
        guard viewModel.hasChanges else { return }
        let hasC2PA = browserViewModel.selectedImages.contains { $0.hasC2PA }
        let mode = hasC2PA ? settingsViewModel.metadataWriteModeC2PA : settingsViewModel.metadataWriteModeNonC2PA
        if hasC2PA, mode == .writeToFile {
            if !pendingC2PASelection.isEmpty, Set(pendingC2PASelection) == Set(viewModel.selectedURLs) {
                return
            }
            viewModel.saveToSidecar()
            onPendingStatusChanged?()
            pendingC2PASelection = viewModel.selectedURLs
            c2paOverwriteIntent = .autoCommit
            showingC2PAWarning = true
            return
        }
        viewModel.commitEdits(
            mode: mode,
            hasC2PA: hasC2PA,
            onComplete: onPendingStatusChanged
        )
    }

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
                                BatchEditBanner(
                                    count: viewModel.selectedCount,
                                    isLoading: viewModel.isLoadingBatchMetadata
                                )
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
        .onKeyPress("m") {
            guard NSEvent.modifierFlags.contains(.option),
                  !viewModel.isBatchEdit,
                  viewModel.originalImageMetadata != nil else {
                return .ignored
            }
            if viewModel.metadataDisplayMode == .embedded {
                viewModel.metadataDisplayMode = .pending
            } else {
                viewModel.metadataDisplayMode = .embedded
            }
            return .handled
        }
        .alert("C2PA Protected Image", isPresented: $showingC2PAWarning) {
            Button("Cancel", role: .cancel) {
                c2paOverwriteIntent = nil
                pendingC2PASelection = []
            }
            Button("Write Anyway") {
                let intent = c2paOverwriteIntent
                c2paOverwriteIntent = nil

                switch intent {
                case .autoCommit:
                    if Set(pendingC2PASelection) == Set(viewModel.selectedURLs) {
                        viewModel.commitEdits(
                            mode: .writeToFile,
                            hasC2PA: true,
                            allowC2PAOverwrite: true,
                            onComplete: onPendingStatusChanged
                        )
                    }
                    pendingC2PASelection = []
                case .manualWrite, .none:
                    viewModel.writeMetadataAndClearSidecar()
                    onPendingStatusChanged?()
                }
            }
        } message: {
            Text("This image has C2PA content credentials. Writing metadata will invalidate the authenticity chain.")
        }
        .fileImporter(
            isPresented: $showingListFilePicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                switch listFilePickerTarget {
                case .keywords:
                    settingsViewModel.setKeywordsListURL(url)
                case .personShown:
                    settingsViewModel.setPersonShownListURL(url)
                }
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            guard oldValue != nil, oldValue != newValue else { return }
            commitEdits()
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
                Picker("", selection: $viewModel.metadataDisplayMode) {
                    Text("Pending").tag(MetadataDisplayMode.pending)
                    Text("XMP")
                        .tag(MetadataDisplayMode.xmp)
                        .disabled(!viewModel.hasXmpMetadata)
                    Text("Embedded").tag(MetadataDisplayMode.embedded)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.originalImageMetadata == nil)
            }

            if viewModel.metadataDisplayMode != .pending && !viewModel.isBatchEdit {
                readOnlyPriorityFieldsView
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
                    MetadataHistoryView(
                        history: viewModel.sidecarHistory,
                        onRestoreToPoint: { index in
                            viewModel.restoreToHistoryPoint(at: index)
                            showingHistoryPopover = false
                            onPendingStatusChanged?()
                        },
                        onClearHistory: {
                            viewModel.clearHistory()
                            showingHistoryPopover = false
                        }
                    )
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
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "title") : "Enter title",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.title),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("title"),
            focusKey: "title",
            focusedField: $focusedField
        )

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: viewModel.fieldDiffers(\.description))
                if viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("description") {
                    MultipleValuesIndicator()
                }
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
                viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "description") : "Enter description",
                text: Binding(
                    get: { viewModel.editingMetadata.description ?? "" },
                    set: { viewModel.editingMetadata.description = $0.isEmpty ? nil : $0; viewModel.markChanged() }
                ),
                axis: .vertical
            )
            .lineLimit(4...8)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .focused($focusedField, equals: "description")
            .onSubmit {
                commitEdits()
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
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("keywords"),
            onChange: { viewModel.markChanged() },
            onCommit: { commitEdits() },
            presetList: settingsViewModel.loadKeywordsList(),
            onChooseListFile: {
                listFilePickerTarget = .keywords
                showingListFilePicker = true
            },
            focusKey: "keywords",
            focusedField: $focusedField
        )

        KeywordsEditorWithDiff(
            label: "Person Shown",
            keywords: $viewModel.editingMetadata.personShown,
            differs: viewModel.personShownDiffer(),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("personShown"),
            placeholder: "Add name",
            onChange: { viewModel.markChanged() },
            onCommit: { commitEdits() },
            presetList: settingsViewModel.loadPersonShownList(),
            onChooseListFile: {
                listFilePickerTarget = .personShown
                showingListFilePicker = true
            },
            focusKey: "personShown",
            focusedField: $focusedField
        )

        EditableTextField(
            label: "Copyright",
            text: Binding(
                get: { viewModel.editingMetadata.copyright ?? "" },
                set: { viewModel.editingMetadata.copyright = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "copyright") : "Enter copyright",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.copyright),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("copyright"),
            focusKey: "copyright",
            focusedField: $focusedField
        )
    }

    private var readOnlyEmptyMessage: String {
        switch viewModel.metadataDisplayMode {
        case .xmp:
            return "No XMP sidecar found"
        case .embedded:
            return "No embedded metadata"
        case .pending:
            return ""
        }
    }

    @ViewBuilder
    private var readOnlyPriorityFieldsView: some View {
        if let metadata = viewModel.readOnlyMetadata {
            ReadOnlyField(label: "Title", value: metadata.title)
            ReadOnlyField(label: "Description", value: metadata.description)
            ReadOnlyKeywords(label: "Keywords", keywords: metadata.keywords)
            ReadOnlyKeywords(label: "Person Shown", keywords: metadata.personShown)
            ReadOnlyField(label: "Copyright", value: metadata.copyright)
        } else {
            Text(readOnlyEmptyMessage)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Classification

    @ViewBuilder
    private var classificationSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.metadataDisplayMode != .pending && !viewModel.isBatchEdit {
                let displayValue = viewModel.readOnlyMetadata?.digitalSourceType?.displayName
                ReadOnlyField(label: "Digital Source Type", value: displayValue)
            } else {
                Text("Digital Source Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: Binding(
                    get: { viewModel.editingMetadata.digitalSourceType },
                    set: {
                        viewModel.editingMetadata.digitalSourceType = $0
                        viewModel.markChanged()
                        commitEdits()
                    }
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
    }

    // MARK: - Additional Fields

    @ViewBuilder
    private var additionalFieldsSection: some View {
        Section {
            if viewModel.metadataDisplayMode != .pending && !viewModel.isBatchEdit {
                readOnlyAdditionalFieldsView
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
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "creator") : "",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.creator),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("creator"),
            focusKey: "creator",
            focusedField: $focusedField
        )
        EditableTextField(
            label: "Credit",
            text: Binding(
                get: { viewModel.editingMetadata.credit ?? "" },
                set: { viewModel.editingMetadata.credit = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "credit") : "",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.credit),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("credit"),
            focusKey: "credit",
            focusedField: $focusedField
        )
        EditableTextField(
            label: "City",
            text: Binding(
                get: { viewModel.editingMetadata.city ?? "" },
                set: { viewModel.editingMetadata.city = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "city") : "",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.city),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("city"),
            focusKey: "city",
            focusedField: $focusedField
        )
        EditableTextField(
            label: "Country",
            text: Binding(
                get: { viewModel.editingMetadata.country ?? "" },
                set: { viewModel.editingMetadata.country = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "country") : "",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.country),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("country"),
            focusKey: "country",
            focusedField: $focusedField
        )
        EditableTextField(
            label: "Event",
            text: Binding(
                get: { viewModel.editingMetadata.event ?? "" },
                set: { viewModel.editingMetadata.event = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "event") : "",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.event),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("event"),
            focusKey: "event",
            focusedField: $focusedField
        )
    }

    @ViewBuilder
    private var readOnlyAdditionalFieldsView: some View {
        if let metadata = viewModel.readOnlyMetadata {
            ReadOnlyField(label: "Creator", value: metadata.creator)
            ReadOnlyField(label: "Credit", value: metadata.credit)
            ReadOnlyField(label: "City", value: metadata.city)
            ReadOnlyField(label: "Country", value: metadata.country)
            ReadOnlyField(label: "Event", value: metadata.event)
        } else {
            Text(readOnlyEmptyMessage)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - GPS

    @ViewBuilder
    private var gpsSection: some View {
        if viewModel.metadataDisplayMode != .pending && !viewModel.isBatchEdit {
            readOnlyGPSView
        } else {
            GPSSectionView(
                latitude: Binding(
                    get: { viewModel.editingMetadata.latitude },
                    set: { viewModel.editingMetadata.latitude = $0 }
                ),
                longitude: Binding(
                    get: { viewModel.editingMetadata.longitude },
                    set: { viewModel.editingMetadata.longitude = $0 }
                ),
                onChanged: {
                    viewModel.markChanged()
                    commitEdits()
                },
                focusKey: "gps",
                focusedField: $focusedField,
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
    }

    @ViewBuilder
    private var readOnlyGPSView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GPS Location")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let metadata = viewModel.readOnlyMetadata {
                if let lat = metadata.latitude, let lon = metadata.longitude {
                    Text(String(format: "%.6f, %.6f", lat, lon))
                        .font(.body)
                } else {
                    Text("No GPS data")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(readOnlyEmptyMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
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
                    viewModel.discardPendingChanges()
                    onPendingStatusChanged?()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled((!viewModel.hasChanges && !viewModel.selectedHavePendingSidecars) || viewModel.isSaving)
                .help("Discard pending changes")

                Button {
                    if browserViewModel.firstSelectedImage?.hasC2PA == true {
                        c2paOverwriteIntent = .manualWrite
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
    var hasMultipleValues: Bool = false
    var placeholder: String = "Add keyword"
    var onChange: (() -> Void)? = nil
    var onCommit: (() -> Void)? = nil
    var presetList: [String] = []
    var onChooseListFile: (() -> Void)? = nil
    var focusKey: String? = nil
    var focusedField: FocusState<String?>.Binding? = nil

    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: differs)
                if hasMultipleValues {
                    MultipleValuesIndicator()
                }
                Spacer()
                if onChooseListFile != nil {
                    Menu {
                        if !presetList.isEmpty {
                            ForEach(presetList, id: \.self) { item in
                                Button(item) {
                                    if !keywords.contains(item) {
                                        keywords.append(item)
                                        onChange?()
                                        onCommit?()
                                    }
                                }
                            }
                            Divider()
                        }
                        Button("Choose List File...") {
                            onChooseListFile?()
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.caption)
                            .foregroundStyle(presetList.isEmpty ? .secondary : .primary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(presetList.isEmpty ? "Choose a list file to load presets" : "Add from preset list")
                }
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

            if let focusedField, let focusKey {
                TextField(placeholder, text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .focused(focusedField, equals: focusKey)
                    .onSubmit {
                        addKeywords()
                    }
                    .onChange(of: inputText) { _, newValue in
                        if newValue.contains(",") || newValue.contains(";") {
                            addKeywords()
                        }
                    }
            } else {
                TextField(placeholder, text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit {
                        addKeywords()
                    }
                    .onChange(of: inputText) { _, newValue in
                        if newValue.contains(",") || newValue.contains(";") {
                            addKeywords()
                        }
                    }
            }
        }
    }

    private func addKeywords() {
        let parts = inputText
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !keywords.contains($0) }
        guard !parts.isEmpty else {
            inputText = ""
            return
        }
        keywords.append(contentsOf: parts)
        inputText = ""
        onChange?()
        onCommit?()
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

struct MultipleValuesIndicator: View {
    var body: some View {
        Text("Multiple")
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.secondary, in: Capsule())
            .help("Selected images have different values for this field")
    }
}

struct EditableTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var onCommit: (() -> Void)? = nil
    var showsDifference: Bool = false
    var hasMultipleValues: Bool = false
    var focusKey: String? = nil
    var focusedField: FocusState<String?>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: showsDifference)
                if hasMultipleValues {
                    MultipleValuesIndicator()
                }
            }
            if let focusedField, let focusKey {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .focused(focusedField, equals: focusKey)
                    .onSubmit {
                        onCommit?()
                    }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit {
                        onCommit?()
                    }
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
    var isLoading: Bool = false

    var body: some View {
        HStack {
            Image(systemName: "square.on.square")
            Text("Editing \(count) images")
                .font(.subheadline.weight(.medium))
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
