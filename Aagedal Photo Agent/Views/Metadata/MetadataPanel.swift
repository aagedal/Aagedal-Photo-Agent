import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

nonisolated private let metadataPanelLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPanel")

struct MetadataPanel: View {
    @Bindable var viewModel: MetadataViewModel
    let browserViewModel: BrowserViewModel
    let settingsViewModel: SettingsViewModel
    var onApplyTemplate: (() -> Void)?
    var onSaveTemplate: (() -> Void)?
    var onPendingStatusChanged: (() -> Void)?

    @State private var isShowingVariableReference = false
    @State private var variableInsertTarget: VariableInsertTarget = .description
    @State private var fieldSelections: [String: NSRange] = [:]
    @State private var showExtendedDescription = false
    @State private var showingHistoryPopover = false
    @State private var showingC2PAWarning = false
    @State private var showingListFilePicker = false
    @State private var listFilePickerTarget: ListFileTarget = .keywords
    @FocusState private var focusedField: String?
    @State private var c2paOverwriteIntent: C2PAOverwriteIntent?
    @State private var pendingC2PASelection: [URL] = []
    @State private var commitDebounceTask: Task<Void, Never>?
    @State private var showingRawMetadata = false
    @State private var showingStructuredKeywords = false
    @State private var editingQuickList: QuickListType?

    enum ListFileTarget {
        case keywords
        case personShown
        case copyright
        case creator
        case credit
        case city
        case country
        case event
    }

    enum C2PAOverwriteIntent {
        case autoCommit
        case manualWrite
    }

    enum VariableInsertTarget {
        case title
        case description
        case extendedDescription
        case creator
        case credit
        case copyright
        case jobId
        case dateCreated
        case city
        case country
        case event

        var focusKey: String {
            switch self {
            case .title: return "title"
            case .description: return "description"
            case .extendedDescription: return "extendedDescription"
            case .creator: return "creator"
            case .credit: return "credit"
            case .copyright: return "copyright"
            case .jobId: return "jobId"
            case .dateCreated: return "dateCreated"
            case .city: return "city"
            case .country: return "country"
            case .event: return "event"
            }
        }
    }

    @ViewBuilder
    private var keywordsEditor: some View {
        let approved = settingsViewModel.approvedLists
        let approvedActive = approved.isActive(for: .keywords)
        let approvedMode = approved.mode(for: .keywords)
        let quickList = settingsViewModel.loadKeywordsList()

        let suggestionProvider: ((String) -> [ApprovedListSuggestion])? = {
            if approvedActive {
                return { prefix in approved.suggestions(prefix: prefix, in: .keywords) }
            }
            guard !quickList.isEmpty else { return nil }
            return { prefix in ApprovedListService.suggestions(prefix: prefix, in: quickList) }
        }()

        let validator: ((String) -> KeywordValidation)? = approvedActive
            ? { value in approved.validate(value, in: .keywords) }
            : nil

        let flagged: Set<String> = {
            guard approvedActive, approvedMode != .suggest else { return [] }
            return Set(viewModel.editingMetadata.keywords.filter { !approved.contains($0, in: .keywords) })
        }()

        KeywordsEditorWithDiff(
            label: "Keywords",
            keywords: $viewModel.editingMetadata.keywords,
            differs: viewModel.keywordsDiffer(),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("keywords"),
            partialKeywords: viewModel.isBatchEdit ? viewModel.batchPartialKeywords : [],
            selectedCount: viewModel.selectedCount,
            onPromotePartial: { keyword in
                viewModel.promotePartialKeyword(keyword)
            },
            onChange: { viewModel.markChanged() },
            onCommit: { commitEdits() },
            showPresetSelectionIndicator: true,
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .keywords, values: viewModel.editingMetadata.keywords)
            },
            presetList: quickList,
            onChooseListFile: {
                listFilePickerTarget = .keywords
                showingListFilePicker = true
            },
            focusKey: "keywords",
            focusedField: $focusedField,
            suggestionProvider: suggestionProvider,
            validator: validator,
            flaggedKeywords: flagged,
            hideQuickListMenu: false,
            autoHighlightFirstSuggestion: approvedActive && approvedMode != .suggest,
            onValidationReject: { rejected in
                let count = rejected.count
                let word = count == 1 ? "keyword" : "keywords"
                viewModel.notice = MetadataPanelNotice(
                    title: "\(count) \(word) not added — Not in approved list",
                    detail: rejected,
                    severity: .warning
                )
            },
            onShowStructuredKeywords: {
                showingStructuredKeywords = true
            },
            onEditQuickList: {
                editingQuickList = .keywords
            }
        )
        .sheet(isPresented: $showingStructuredKeywords) {
            StructuredKeywordsPicker(
                onAddKeywords: { expanded in
                    addStructuredKeywords(expanded)
                },
                onClose: {
                    showingStructuredKeywords = false
                }
            )
        }
        .sheet(item: $editingQuickList) { type in
            KeywordListEditor(
                title: "\(type.displayName) Quick List",
                storeKey: .quick(type)
            )
        }
    }

    private func addStructuredKeywords(_ expanded: [String]) {
        // Routes through approved-list validation with `.structuredTree` source
        // so the "Always allow keywords from structured list" toggle can short-
        // circuit when on (the default). When the toggle is off, structured
        // keywords get validated against the approved list like any other source.
        let validated = ApprovedListService.shared.validateBulk(expanded, in: .keywords, source: .structuredTree)
        let added = viewModel.appendKeywords(validated.accepted)
        if !validated.rejected.isEmpty {
            let count = validated.rejected.count
            let word = count == 1 ? "keyword" : "keywords"
            viewModel.notice = MetadataPanelNotice(
                title: "\(count) \(word) not added — Not in approved list",
                detail: validated.rejected,
                severity: .warning
            )
        }
        guard added > 0 else { return }
        commitEdits()
    }

    private func addCurrentToQuickList(type: QuickListType, values: [String]) {
        let sanitized = sanitizeQuickListValues(values)
        guard !sanitized.isEmpty else { return }

        if settingsViewModel.quickListURL(for: type) == nil {
            guard let url = promptForQuickListFile(type: type) else { return }
            settingsViewModel.setQuickListURL(url, for: type)
        }

        _ = settingsViewModel.appendToQuickList(for: type, values: sanitized)
    }

    private func addCurrentToQuickList(type: QuickListType, value: String?) {
        addCurrentToQuickList(type: type, values: [value].compactMap { $0 })
    }

    private func sanitizeQuickListValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func promptForQuickListFile(type: QuickListType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = type.defaultFilename
        panel.message = "Create Quick List file for \(type.displayName)"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try "".write(to: url, atomically: true, encoding: .utf8)
            } catch {
                metadataPanelLog.error("Failed to create quick list file at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return url
    }

    private func insertVariable(_ variable: String) {
        applyInsertion(variable, to: variableInsertTarget)
    }

    private func openVariableReference(for target: VariableInsertTarget) {
        variableInsertTarget = target
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            fieldSelections[target.focusKey] = editor.selectedRange()
        }
        isShowingVariableReference = true
    }

    private func openVariableReferenceFromShortcut() {
        let target = targetForFocusKey(focusedField) ?? variableInsertTarget
        openVariableReference(for: target)
    }

    private func targetForFocusKey(_ key: String?) -> VariableInsertTarget? {
        switch key {
        case "title": return .title
        case "description": return .description
        case "extendedDescription": return .extendedDescription
        case "creator": return .creator
        case "credit": return .credit
        case "copyright": return .copyright
        case "jobId": return .jobId
        case "dateCreated": return .dateCreated
        case "city": return .city
        case "country": return .country
        case "event": return .event
        default: return nil
        }
    }

    private func applyInsertion(_ insertion: String, to target: VariableInsertTarget) {
        let current = fieldValue(for: target)
        if focusedField == target.focusKey,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            fieldSelections[target.focusKey] = editor.selectedRange()
        }
        let selection = selectionForTarget(target, text: current)
        let (updated, newSelection) = insertText(insertion, into: current, selection: selection)
        setFieldValue(updated, for: target)
        fieldSelections[target.focusKey] = newSelection
        if focusedField == target.focusKey,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.selectedRange = newSelection
        }
        viewModel.markChanged()
    }

    private func fieldValue(for target: VariableInsertTarget) -> String {
        switch target {
        case .title: return viewModel.editingMetadata.title ?? ""
        case .description: return viewModel.editingMetadata.description ?? ""
        case .extendedDescription: return viewModel.editingMetadata.extendedDescription ?? ""
        case .creator: return viewModel.editingMetadata.creator ?? ""
        case .credit: return viewModel.editingMetadata.credit ?? ""
        case .copyright: return viewModel.editingMetadata.copyright ?? ""
        case .jobId: return viewModel.editingMetadata.jobId ?? ""
        case .dateCreated: return viewModel.editingMetadata.dateCreated ?? ""
        case .city: return viewModel.editingMetadata.city ?? ""
        case .country: return viewModel.editingMetadata.country ?? ""
        case .event: return viewModel.editingMetadata.event ?? ""
        }
    }

    private func setFieldValue(_ value: String, for target: VariableInsertTarget) {
        let normalized: String? = value.isEmpty ? nil : value
        switch target {
        case .title: viewModel.editingMetadata.title = normalized
        case .description: viewModel.editingMetadata.description = normalized
        case .extendedDescription: viewModel.editingMetadata.extendedDescription = normalized
        case .creator: viewModel.editingMetadata.creator = normalized
        case .credit: viewModel.editingMetadata.credit = normalized
        case .copyright: viewModel.editingMetadata.copyright = normalized
        case .jobId: viewModel.editingMetadata.jobId = normalized
        case .dateCreated: viewModel.editingMetadata.dateCreated = normalized
        case .city: viewModel.editingMetadata.city = normalized
        case .country: viewModel.editingMetadata.country = normalized
        case .event: viewModel.editingMetadata.event = normalized
        }
    }

    private func selectionForTarget(_ target: VariableInsertTarget, text: String) -> NSRange {
        let maxLength = text.utf16.count
        let selection = fieldSelections[target.focusKey] ?? NSRange(location: maxLength, length: 0)
        return clampedSelection(selection, maxLength: maxLength)
    }

    private func clampedSelection(_ selection: NSRange, maxLength: Int) -> NSRange {
        let location = min(maxLength, max(0, selection.location))
        let length = min(maxLength - location, max(0, selection.length))
        return NSRange(location: location, length: length)
    }

    private func insertText(_ insertion: String, into current: String, selection: NSRange) -> (String, NSRange) {
        guard let range = Range(selection, in: current) else {
            let updated = current + insertion
            return (updated, NSRange(location: updated.utf16.count, length: 0))
        }
        let updated = current.replacingCharacters(in: range, with: insertion)
        let newLocation = selection.location + insertion.utf16.count
        return (updated, NSRange(location: newLocation, length: 0))
    }

    /// Reads the current text from the active NSTextView for buffered fields
    /// and pushes it to editingMetadata. Call before any commit/write operation
    /// to ensure the view model has the latest text.
    private func flushBufferedFields() {
        guard let key = focusedField,
              (key == "description" || key == "extendedDescription"),
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let text = editor.string
        let normalized = text.isEmpty ? nil : text
        switch key {
        case "description":
            if normalized != viewModel.editingMetadata.description {
                viewModel.editingMetadata.description = normalized
                viewModel.markChanged()
            }
        case "extendedDescription":
            if normalized != viewModel.editingMetadata.extendedDescription {
                viewModel.editingMetadata.extendedDescription = normalized
                viewModel.markChanged()
            }
        default:
            break
        }
    }

    private func commitEdits() {
        flushBufferedFields()
        guard viewModel.hasChanges else { return }
        let hasC2PA = browserViewModel.selectedImages.contains { $0.hasC2PA }
        let isRaw = browserViewModel.selectedImages.contains { SupportedImageFormats.isRaw(url: $0.url) }
        let mode = MetadataWriteMode.current(forC2PA: hasC2PA, isRaw: isRaw)
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
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if viewModel.isBatchEdit {
                                    BatchEditBanner(
                                        count: viewModel.selectedCount,
                                        isLoading: viewModel.isLoadingBatchMetadata
                                    )
                                }

                                noticeBanner
                                comparisonBanner

                                metadataSourceBand
                                ratingAndLabelSection
                                actionButtons
                                Divider()
                                priorityFieldsSection
                                Divider()
                                classificationSection
                                Divider()
                                additionalFieldsSection
                                Divider()
                                gpsSection
                                    .id("gps")
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
                        .onChange(of: focusedField) { _, newValue in
                            if let field = newValue {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    scrollProxy.scrollTo(field, anchor: .center)
                                }
                            }
                        }
                    }
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
            guard viewModel.hasXmpMetadata else { return .ignored }
            let next: MetadataReferenceSource = viewModel.metadataReferenceSource == .embedded ? .xmp : .embedded
            viewModel.applyReferenceSource(next)
            return .handled
        }
        .onKeyPress(.escape) {
            guard focusedField != nil else { return .ignored }
            focusedField = nil
            browserViewModel.shouldRestoreGridFocus = true
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRawMetadata)) { _ in
            guard !viewModel.isBatchEdit, viewModel.selectedCount == 1 else { return }
            showingRawMetadata = true
        }
        .onAppear {
            StructuredKeywordsCoordinator.shared.register(owner: viewModel) { expanded in
                addStructuredKeywords(expanded)
            }
        }
        .onDisappear {
            StructuredKeywordsCoordinator.shared.unregister(owner: viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showVariableReference)) { _ in
            openVariableReferenceFromShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard !isShowingVariableReference,
                  let key = focusedField,
                  let editor = notification.object as? NSTextView else {
                return
            }
            fieldSelections[key] = editor.selectedRange()
        }
        .onChange(of: focusedField) { _, newValue in
            guard !isShowingVariableReference,
                  let key = newValue,
                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                return
            }
            fieldSelections[key] = editor.selectedRange()
        }
        .sheet(isPresented: $viewModel.showMetadataComparison) {
            MetadataComparisonSheet(
                comparison: viewModel.metadataComparison,
                isStale: viewModel.comparisonSidecarIsStale,
                onApply: { viewModel.resolveMetadataComparison($0) },
                onUseAll: { viewModel.resolveMetadataComparison(allFrom: $0) },
                onCancel: { viewModel.showMetadataComparison = false }
            )
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
                do {
                    switch listFilePickerTarget {
                    case .keywords:
                        try settingsViewModel.setKeywordsListURL(url)
                    case .personShown:
                        try settingsViewModel.setPersonShownListURL(url)
                    case .copyright:
                        try settingsViewModel.setCopyrightListURL(url)
                    case .creator:
                        try settingsViewModel.setCreatorListURL(url)
                    case .credit:
                        try settingsViewModel.setCreditListURL(url)
                    case .city:
                        try settingsViewModel.setCityListURL(url)
                    case .country:
                        try settingsViewModel.setCountryListURL(url)
                    case .event:
                        try settingsViewModel.setEventListURL(url)
                    }
                } catch {
                    let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    viewModel.notice = MetadataPanelNotice(
                        title: "Quick list import failed",
                        detail: [description],
                        severity: .error
                    )
                }
            }
        }
        .onChange(of: focusedField) { oldValue, newValue in
            guard oldValue != nil, oldValue != newValue else { return }
            flushBufferedFields()
            commitDebounceTask?.cancel()
            commitDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                commitEdits()
            }
        }
    }

    // MARK: - Rating & Label

    @ViewBuilder
    private var ratingAndLabelSection: some View {
        if let image = browserViewModel.firstSelectedImage {
            HStack(spacing: 8) {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= image.starRating.rawValue ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .frame(width: 18)
                            .foregroundStyle(star <= image.starRating.rawValue ? .yellow : .secondary.opacity(0.5))
                            .onTapGesture {
                                let rating = StarRating(rawValue: star) ?? .none
                                browserViewModel.setRating(image.starRating == rating ? .none : rating)
                            }
                    }
                }

                Divider()
                    .frame(height: 14)

                HStack(spacing: 4) {
                    ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { label in
                        Circle()
                            .fill(label.color!.opacity(image.colorLabel == label ? 1.0 : 0.35))
                            .frame(width: 12, height: 12)
                            .help(label.displayName)
                            .onTapGesture {
                                browserViewModel.setLabel(image.colorLabel == label ? .none : label)
                            }
                    }
                }

                Spacer()

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
            editableMetadataFields
        } header: {
            HStack {
                Text("Metadata")
                    .font(.headline)
                if !viewModel.isBatchEdit, viewModel.hasXmpMetadata {
                    referenceSourcePicker
                }
                if !viewModel.isBatchEdit, viewModel.hasEmbeddedCropNotLoaded {
                    Button {
                        viewModel.importEmbeddedCrop()
                    } label: {
                        Image(systemName: "crop")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Image has embedded crop metadata — click to load")
                }
                if !viewModel.isBatchEdit, viewModel.selectedCount == 1 {
                    Button {
                        showingRawMetadata = true
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("View raw metadata (JSON)")
                    .sheet(isPresented: $showingRawMetadata) {
                        if let url = viewModel.selectedURLs.first {
                            RawMetadataView(
                                filename: url.lastPathComponent,
                                readService: browserViewModel.metadataReadService,
                                imageURL: url
                            )
                        }
                    }
                }
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
                        onRestoreOriginal: {
                            viewModel.restoreToOriginal()
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
        let _ = settingsViewModel.quickListVersion

        EditableTextField(
            label: "Headline",
            text: Binding(
                get: { viewModel.editingMetadata.title ?? "" },
                set: { viewModel.editingMetadata.title = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "title") : "Enter headline",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.title),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("title"),
            onInsertVariable: {
                openVariableReference(for: .title)
            },
            focusKey: "title",
            focusedField: $focusedField
        )
        .id("title")

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
                    openVariableReference(for: .description)
                } label: {
                    Image(systemName: "curlybraces")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Variable Reference")
            }
            if let conflict = viewModel.descriptionConflict {
                DescriptionConflictBanner(conflict: conflict) { keepXMP in
                    viewModel.resolveDescriptionConflict(keepXMP: keepXMP)
                }
            }
            BufferedTextField(
                currentValue: viewModel.editingMetadata.description ?? "",
                placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "description") : "Enter description",
                lineLimit: 4...8,
                focusedField: $focusedField,
                focusKey: "description",
                onTextFinished: { newValue in
                    if newValue != viewModel.editingMetadata.description {
                        viewModel.editingMetadata.description = newValue
                        viewModel.markChanged()
                    }
                },
                onCommit: { commitEdits() }
            )
        }
        .id("description")
        .sheet(isPresented: $isShowingVariableReference) {
            VariableReferenceView(
                isPresented: $isShowingVariableReference,
                onInsert: insertVariable
            )
        }

        DisclosureGroup(isExpanded: $showExtendedDescription) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Spacer()
                    Button {
                        openVariableReference(for: .extendedDescription)
                    } label: {
                        Image(systemName: "curlybraces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Variable Reference")
                }
                BufferedTextField(
                    currentValue: viewModel.editingMetadata.extendedDescription ?? "",
                    placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "extendedDescription") : "Enter extended description",
                    lineLimit: 4...8,
                    focusedField: $focusedField,
                    focusKey: "extendedDescription",
                    onTextFinished: { newValue in
                        if newValue != viewModel.editingMetadata.extendedDescription {
                            viewModel.editingMetadata.extendedDescription = newValue
                            viewModel.markChanged()
                        }
                    },
                    onCommit: { commitEdits() }
                )
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 4) {
                Text("Extended Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DifferenceIndicator(differs: viewModel.fieldDiffers(\.extendedDescription))
                if viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("extendedDescription") {
                    MultipleValuesIndicator()
                }
            }
        }
        .id("extendedDescription")

        keywordsEditor
            .id("keywords")

        KeywordsEditorWithDiff(
            label: "Person Shown",
            keywords: $viewModel.editingMetadata.personShown,
            differs: viewModel.personShownDiffer(),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("personShown"),
            partialKeywords: viewModel.isBatchEdit ? viewModel.batchPartialPersonShown : [],
            selectedCount: viewModel.selectedCount,
            onPromotePartial: { person in
                viewModel.promotePartialPerson(person)
            },
            placeholder: "Add name",
            onChange: { viewModel.markChanged() },
            onCommit: { commitEdits() },
            showPresetSelectionIndicator: true,
            allowsPresetToggleRemoval: true,
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .personShown, values: viewModel.editingMetadata.personShown)
            },
            presetList: settingsViewModel.loadPersonShownList(),
            onChooseListFile: {
                listFilePickerTarget = .personShown
                showingListFilePicker = true
            },
            focusKey: "personShown",
            focusedField: $focusedField
        )
        .id("personShown")

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
            onInsertVariable: {
                openVariableReference(for: .copyright)
            },
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .copyright, value: viewModel.editingMetadata.copyright)
            },
            presetList: settingsViewModel.loadCopyrightList(),
            onChooseListFile: {
                listFilePickerTarget = .copyright
                showingListFilePicker = true
            },
            focusKey: "copyright",
            focusedField: $focusedField
        )
        .id("copyright")

        EditableTextField(
            label: "Job ID",
            text: Binding(
                get: { viewModel.editingMetadata.jobId ?? "" },
                set: { viewModel.editingMetadata.jobId = $0.isEmpty ? nil : $0; viewModel.markChanged() }
            ),
            placeholder: viewModel.isBatchEdit ? viewModel.batchPlaceholder(for: "jobId") : "Enter job ID",
            onCommit: { commitEdits() },
            showsDifference: viewModel.fieldDiffers(\.jobId),
            hasMultipleValues: viewModel.isBatchEdit && viewModel.fieldHasMultipleValues("jobId"),
            onInsertVariable: {
                openVariableReference(for: .jobId)
            },
            trailingLabelContent: AnyView(
                Button {
                    settingsViewModel.addJobIdToKeywords.toggle()
                } label: {
                    Image(systemName: settingsViewModel.addJobIdToKeywords ? "tag.fill" : "tag")
                        .font(.caption)
                        .foregroundStyle(settingsViewModel.addJobIdToKeywords ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(settingsViewModel.addJobIdToKeywords ? "Job ID will be added to keywords during variable processing (click to disable). Job IDs are not validated against the approved keywords list." : "Add Job ID to keywords during variable processing")
            ),
            focusKey: "jobId",
            focusedField: $focusedField
        )
        .id("jobId")
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

    // MARK: - Develop

    private var usesIncrementalWhiteBalance: Bool {
        // Non-RAW files always use incremental (relative) white balance
        if let url = browserViewModel.firstSelectedImage?.url, !SupportedImageFormats.isRaw(url: url) {
            return true
        }
        let cameraRaw = viewModel.editingMetadata.cameraRaw
        if cameraRaw?.temperature != nil || cameraRaw?.tint != nil {
            return false
        }
        if cameraRaw?.incrementalTemperature != nil || cameraRaw?.incrementalTint != nil {
            return true
        }
        return false
    }

    private func updateCameraRaw(_ update: (inout CameraRawSettings) -> Void) {
        var cameraRaw = viewModel.editingMetadata.cameraRaw ?? CameraRawSettings()
        update(&cameraRaw)
        cameraRaw.hasSettings = cameraRawHasEdits(cameraRaw) ? true : nil
        viewModel.editingMetadata.cameraRaw = cameraRawHasEdits(cameraRaw) ? cameraRaw : nil
        viewModel.markChanged()
    }

    private func cameraRawHasEdits(_ cameraRaw: CameraRawSettings) -> Bool {
        cameraRaw.whiteBalance != nil
            || cameraRaw.temperature != nil
            || cameraRaw.tint != nil
            || cameraRaw.incrementalTemperature != nil
            || cameraRaw.incrementalTint != nil
            || cameraRaw.exposure2012 != nil
            || cameraRaw.contrast2012 != nil
            || cameraRaw.highlights2012 != nil
            || cameraRaw.shadows2012 != nil
            || cameraRaw.whites2012 != nil
            || cameraRaw.blacks2012 != nil
            || (cameraRaw.crop?.isEmpty == false)
    }

    private func toneSliderBinding(_ keyPath: WritableKeyPath<CameraRawSettings, Int?>) -> Binding<Double> {
        Binding(
            get: { Double(viewModel.editingMetadata.cameraRaw?[keyPath: keyPath] ?? 0) },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw[keyPath: keyPath] = Int(newValue.rounded())
                }
            }
        )
    }

    private var exposureBinding: Binding<Double> {
        Binding(
            get: { viewModel.editingMetadata.cameraRaw?.exposure2012 ?? 0.0 },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.exposure2012 = (newValue * 100).rounded() / 100
                }
            }
        )
    }

    private var whiteBalanceBinding: Binding<String> {
        Binding(
            get: { viewModel.editingMetadata.cameraRaw?.whiteBalance ?? "Custom" },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    cameraRaw.whiteBalance = newValue
                }
                commitEdits()
            }
        )
    }

    private var useIncrementalWhiteBalanceBinding: Binding<Bool> {
        Binding(
            get: { usesIncrementalWhiteBalance },
            set: { enabled in
                updateCameraRaw { cameraRaw in
                    if enabled {
                        cameraRaw.temperature = nil
                        cameraRaw.tint = nil
                        if cameraRaw.incrementalTemperature == nil { cameraRaw.incrementalTemperature = 0 }
                        if cameraRaw.incrementalTint == nil { cameraRaw.incrementalTint = 0 }
                    } else {
                        cameraRaw.incrementalTemperature = nil
                        cameraRaw.incrementalTint = nil
                        if cameraRaw.temperature == nil { cameraRaw.temperature = 6500 }
                        if cameraRaw.tint == nil { cameraRaw.tint = 0 }
                    }
                }
                commitEdits()
            }
        )
    }

    private var whiteBalanceTemperatureBinding: Binding<Double> {
        Binding(
            get: {
                if usesIncrementalWhiteBalance {
                    return Double(viewModel.editingMetadata.cameraRaw?.incrementalTemperature ?? 0)
                }
                return Double(viewModel.editingMetadata.cameraRaw?.temperature ?? 6500)
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    if usesIncrementalWhiteBalance {
                        cameraRaw.incrementalTemperature = Int(newValue.rounded())
                    } else {
                        cameraRaw.temperature = Int(newValue.rounded())
                    }
                }
            }
        )
    }

    private var whiteBalanceTintBinding: Binding<Double> {
        Binding(
            get: {
                if usesIncrementalWhiteBalance {
                    return Double(viewModel.editingMetadata.cameraRaw?.incrementalTint ?? 0)
                }
                return Double(viewModel.editingMetadata.cameraRaw?.tint ?? 0)
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    if usesIncrementalWhiteBalance {
                        cameraRaw.incrementalTint = Int(newValue.rounded())
                    } else {
                        cameraRaw.tint = Int(newValue.rounded())
                    }
                }
            }
        )
    }

    private var cropEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.editingMetadata.cameraRaw?.crop?.hasCrop ?? false },
            set: { enabled in
                updateCameraRaw { cameraRaw in
                    if cameraRaw.crop == nil {
                        cameraRaw.crop = CameraRawCrop()
                    }
                    cameraRaw.crop?.hasCrop = enabled
                    if enabled {
                        if cameraRaw.crop?.top == nil { cameraRaw.crop?.top = 0.0 }
                        if cameraRaw.crop?.left == nil { cameraRaw.crop?.left = 0.0 }
                        if cameraRaw.crop?.bottom == nil { cameraRaw.crop?.bottom = 1.0 }
                        if cameraRaw.crop?.right == nil { cameraRaw.crop?.right = 1.0 }
                        if cameraRaw.crop?.angle == nil { cameraRaw.crop?.angle = 0.0 }
                    }
                }
                commitEdits()
            }
        )
    }

    private func cropBinding(_ keyPath: WritableKeyPath<CameraRawCrop, Double?>, defaultValue: Double) -> Binding<Double> {
        Binding(
            get: {
                guard let crop = viewModel.editingMetadata.cameraRaw?.crop else { return defaultValue }
                return crop[keyPath: keyPath] ?? defaultValue
            },
            set: { newValue in
                updateCameraRaw { cameraRaw in
                    var crop = cameraRaw.crop ?? CameraRawCrop()
                    crop[keyPath: keyPath] = newValue
                    crop.hasCrop = true
                    cameraRaw.crop = crop
                }
            }
        )
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: { editing in
                    if !editing {
                        commitEdits()
                    }
                }
            )
        }
    }

    private func signedIntString(_ value: Double) -> String {
        let intValue = Int(value.rounded())
        if intValue > 0 { return "+\(intValue)" }
        return "\(intValue)"
    }

    private func signedDoubleString(_ value: Double, precision: Int = 2) -> String {
        let format = "%.\(precision)f"
        let absValue = String(format: format, abs(value))
        if value > 0 { return "+\(absValue)" }
        if value < 0 { return "-\(absValue)" }
        return absValue
    }

    @ViewBuilder
    private var developSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Develop (Camera Raw)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.isBatchEdit {
                    Text("Single image only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.isBatchEdit {
                Picker("White Balance", selection: whiteBalanceBinding) {
                    Text("As Shot").tag("As Shot")
                    Text("Auto").tag("Auto")
                    Text("Custom").tag("Custom")
                }
                .pickerStyle(.menu)
                .font(.caption)

                Toggle("Use incremental WB values", isOn: useIncrementalWhiteBalanceBinding)
                    .toggleStyle(.switch)
                    .font(.caption)

                sliderRow(
                    usesIncrementalWhiteBalance ? "WB Temp (Inc)" : "Temperature",
                    value: whiteBalanceTemperatureBinding,
                    range: usesIncrementalWhiteBalance ? -100...100 : 2000...50000,
                    step: 1,
                    formatter: signedIntString
                )

                sliderRow(
                    usesIncrementalWhiteBalance ? "WB Tint (Inc)" : "Tint",
                    value: whiteBalanceTintBinding,
                    range: -150...150,
                    step: 1,
                    formatter: signedIntString
                )

                sliderRow(
                    "Exposure",
                    value: exposureBinding,
                    range: -5...5,
                    step: 0.01,
                    formatter: { signedDoubleString($0, precision: 2) }
                )

                sliderRow("Contrast", value: toneSliderBinding(\.contrast2012), range: -100...100, step: 1, formatter: signedIntString)
                sliderRow("Highlights", value: toneSliderBinding(\.highlights2012), range: -100...100, step: 1, formatter: signedIntString)
                sliderRow("Shadows", value: toneSliderBinding(\.shadows2012), range: -100...100, step: 1, formatter: signedIntString)
                sliderRow("Whites", value: toneSliderBinding(\.whites2012), range: -100...100, step: 1, formatter: signedIntString)
                sliderRow("Blacks", value: toneSliderBinding(\.blacks2012), range: -100...100, step: 1, formatter: signedIntString)

                Toggle("Enable Crop", isOn: cropEnabledBinding)
                    .toggleStyle(.switch)
                    .font(.caption)

                if cropEnabledBinding.wrappedValue {
                    sliderRow("Crop Top", value: cropBinding(\.top, defaultValue: 0.0), range: 0...1, step: 0.001) {
                        String(format: "%.3f", $0)
                    }
                    sliderRow("Crop Left", value: cropBinding(\.left, defaultValue: 0.0), range: 0...1, step: 0.001) {
                        String(format: "%.3f", $0)
                    }
                    sliderRow("Crop Bottom", value: cropBinding(\.bottom, defaultValue: 1.0), range: 0...1, step: 0.001) {
                        String(format: "%.3f", $0)
                    }
                    sliderRow("Crop Right", value: cropBinding(\.right, defaultValue: 1.0), range: 0...1, step: 0.001) {
                        String(format: "%.3f", $0)
                    }
                    sliderRow("Crop Angle", value: cropBinding(\.angle, defaultValue: 0.0), range: -45...45, step: 0.1) {
                        String(format: "%.1f", $0)
                    }
                }
            }
        }
    }

    // MARK: - Additional Fields

    @ViewBuilder
    private var additionalFieldsSection: some View {
        Section {
            editableAdditionalFields
        } header: {
            Text("Additional Fields")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var editableAdditionalFields: some View {
        let _ = settingsViewModel.quickListVersion

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
            onInsertVariable: {
                openVariableReference(for: .creator)
            },
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .creator, value: viewModel.editingMetadata.creator)
            },
            presetList: settingsViewModel.loadCreatorList(),
            onChooseListFile: {
                listFilePickerTarget = .creator
                showingListFilePicker = true
            },
            focusKey: "creator",
            focusedField: $focusedField
        )
        .id("creator")
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
            onInsertVariable: {
                openVariableReference(for: .credit)
            },
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .credit, value: viewModel.editingMetadata.credit)
            },
            presetList: settingsViewModel.loadCreditList(),
            onChooseListFile: {
                listFilePickerTarget = .credit
                showingListFilePicker = true
            },
            focusKey: "credit",
            focusedField: $focusedField
        )
        .id("credit")
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
            onInsertVariable: {
                openVariableReference(for: .city)
            },
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .city, value: viewModel.editingMetadata.city)
            },
            presetList: settingsViewModel.loadCityList(),
            onChooseListFile: {
                listFilePickerTarget = .city
                showingListFilePicker = true
            },
            focusKey: "city",
            focusedField: $focusedField
        )
        .id("city")
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
            onInsertVariable: {
                openVariableReference(for: .country)
            },
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .country, value: viewModel.editingMetadata.country)
            },
            presetList: settingsViewModel.loadCountryList(),
            onChooseListFile: {
                listFilePickerTarget = .country
                showingListFilePicker = true
            },
            focusKey: "country",
            focusedField: $focusedField
        )
        .id("country")
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
            onInsertVariable: {
                openVariableReference(for: .event)
            },
            onAddCurrentToQuickList: {
                addCurrentToQuickList(type: .event, value: viewModel.editingMetadata.event)
            },
            presetList: settingsViewModel.loadEventList(),
            onChooseListFile: {
                listFilePickerTarget = .event
                showingListFilePicker = true
            },
            focusKey: "event",
            focusedField: $focusedField
        )
        .id("event")
    }

    private var referenceSourcePicker: some View {
        Picker("", selection: Binding(
            get: { viewModel.metadataReferenceSource },
            set: { viewModel.applyReferenceSource($0) }
        )) {
            Text("Embedded").tag(MetadataReferenceSource.embedded)
            Text("XMP Sidecar")
                .tag(MetadataReferenceSource.xmp)
                .disabled(!viewModel.hasXmpMetadata)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
    }

    /// Shown when the embedded image and its `.xmp` sidecar have differing descriptive
    /// fields. Opens the per-field comparison sheet. Hidden while the sheet is open.
    @ViewBuilder
    private var comparisonBanner: some View {
        if !viewModel.metadataComparison.isEmpty, !viewModel.showMetadataComparison {
            let isStale = viewModel.comparisonSidecarIsStale
            Button {
                viewModel.showMetadataComparison = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isStale ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(isStale ? Color.yellow : Color.secondary)
                        .font(.caption)
                    Text(isStale
                         ? "Sidecar may be stale — \(viewModel.metadataComparison.count) field\(viewModel.metadataComparison.count == 1 ? "" : "s") differ"
                         : "Embedded and sidecar differ in \(viewModel.metadataComparison.count) field\(viewModel.metadataComparison.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("Compare…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((isStale ? Color.yellow : Color.accentColor).opacity(0.08))
                        .strokeBorder((isStale ? Color.yellow : Color.accentColor).opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = viewModel.notice {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: noticeIcon(for: notice.severity))
                        .foregroundStyle(noticeColor(for: notice.severity))
                    Text(notice.title)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        viewModel.notice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                if !notice.detail.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(notice.detail, id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.leading, 22)
                }
            }
            .padding(8)
            .background(noticeColor(for: notice.severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func noticeIcon(for severity: MetadataPanelNotice.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func noticeColor(for severity: MetadataPanelNotice.Severity) -> Color {
        switch severity {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    @ViewBuilder
    private var metadataSourceBand: some View {
        if let destinations = viewModel.nextWriteDestination {
            let readingDest = viewModel.isBatchEdit
                ? MetadataDestination.mixed
                : viewModel.metadataReferenceSource.asDestination
            let sourcesDiffer = readingDest != destinations.iptc
            let developSplits = destinations.develop != destinations.iptc

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    readingChip(destination: readingDest)
                    MetadataSourceChip(role: .writing, destination: destinations.iptc)
                    Spacer(minLength: 0)
                }
                if developSplits {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                        Text("Develop edits \u{2192} \(destinations.develop.shortLabel)")
                            .font(.caption2)
                            .foregroundStyle(destinations.develop.color)
                    }
                }
                if sourcesDiffer {
                    Label("Sources differ \u{2014} reading and writing target different surfaces.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func readingChip(destination: MetadataDestination) -> some View {
        if viewModel.hasXmpMetadata, !viewModel.isBatchEdit {
            Menu {
                Button("Embedded") { viewModel.applyReferenceSource(.embedded) }
                Button("XMP Sidecar") { viewModel.applyReferenceSource(.xmp) }
            } label: {
                MetadataSourceChip(role: .reading, destination: destination)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            MetadataSourceChip(role: .reading, destination: destination)
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

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = viewModel.saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let status = viewModel.variableProcessingStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(viewModel.variableProcessingHadFailures ? .red : .secondary)
            }

            HStack(spacing: 12) {
                let hasC2PA = browserViewModel.selectedImages.contains { $0.hasC2PA }
                let isRaw = browserViewModel.selectedImages.contains { SupportedImageFormats.isRaw(url: $0.url) }
                let mode = MetadataWriteMode.current(forC2PA: hasC2PA, isRaw: isRaw)

                if let onApplyTemplate {
                    Button {
                        onApplyTemplate()
                    } label: {
                        Image(systemName: "wand.and.stars")
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
                    flushBufferedFields()
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

                if mode != .writeToFile {
                    Button {
                        flushBufferedFields()
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
                    .disabled(!viewModel.canWriteMetadataToImage)
                    .help("Write metadata to image")
                }
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
    var partialKeywords: [String] = []
    var selectedCount: Int = 0
    var onPromotePartial: ((String) -> Void)? = nil
    var placeholder: String = "Add keyword"
    var onChange: (() -> Void)? = nil
    var onCommit: (() -> Void)? = nil
    var showPresetSelectionIndicator: Bool = false
    var allowsPresetToggleRemoval: Bool = false
    var onAddCurrentToQuickList: (() -> Void)? = nil
    var presetList: [String] = []
    var onChooseListFile: (() -> Void)? = nil
    var focusKey: String? = nil
    var focusedField: FocusState<String?>.Binding? = nil

    // Approved-keywords integration. All optional — other callers keep current behavior.
    var suggestionProvider: ((String) -> [ApprovedListSuggestion])? = nil
    var validator: ((String) -> KeywordValidation)? = nil
    var flaggedKeywords: Set<String> = []
    var hideQuickListMenu: Bool = false
    /// When true, the first suggestion is highlighted as soon as the popover opens,
    /// so Enter commits it. Used in Warn/Strict modes.
    var autoHighlightFirstSuggestion: Bool = false
    /// Invoked when a Quick List menu pick is rejected by the validator. If nil,
    /// rejection falls back to the inline flash used by the typing path.
    var onValidationReject: (([String]) -> Void)? = nil
    /// When set, a tree icon appears in the toolbar that invokes this callback,
    /// typically to open the structured-keywords picker as a sheet.
    var onShowStructuredKeywords: (() -> Void)? = nil
    /// When set, the overflow menu inside the quick-list popover gains an
    /// "Edit Quick List…" item. Caller is expected to present `KeywordListEditor`.
    var onEditQuickList: (() -> Void)? = nil

    @State private var inputText = ""
    @State private var promotingKeyword: String?
    @State private var visibleSuggestions: [ApprovedListSuggestion] = []
    @State private var highlightedIndex: Int? = nil
    @State private var rejectErrorMessage: String?
    @State private var isRejectFlashing: Bool = false
    @State private var rejectClearTask: Task<Void, Never>?
    @State private var rejectFlashTask: Task<Void, Never>?
    @State private var inputIsFocused: Bool = false
    @State private var quickListPopoverShown: Bool = false

    private var typeaheadEnabled: Bool { suggestionProvider != nil }
    private var quickListMenuVisible: Bool { onChooseListFile != nil && !hideQuickListMenu }
    private var popoverIsActive: Bool { typeaheadEnabled && inputIsFocused && !visibleSuggestions.isEmpty }

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
                if quickListMenuVisible {
                    Button {
                        quickListPopoverShown.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.caption)
                            .foregroundStyle(presetList.isEmpty ? .secondary : .primary)
                    }
                    .buttonStyle(.borderless)
                    .help(presetList.isEmpty ? "Choose a Quick List file" : "Choose from Quick List")
                    .popover(isPresented: $quickListPopoverShown, arrowEdge: .bottom) {
                        QuickKeywordPicker(
                            presetList: presetList,
                            currentKeywords: Set(keywords),
                            allowsToggleRemoval: allowsPresetToggleRemoval,
                            onAddSelected: { picks in
                                for item in picks {
                                    addPresetItem(item)
                                }
                            },
                            onRemoveItem: { item in
                                keywords.removeAll { $0 == item }
                                onChange?()
                                onCommit?()
                            },
                            onAddCurrentToQuickList: onAddCurrentToQuickList,
                            onChooseListFile: onChooseListFile,
                            onEditQuickList: onEditQuickList,
                            onClose: { quickListPopoverShown = false }
                        )
                    }
                }
                if let onShowStructuredKeywords {
                    Button {
                        onShowStructuredKeywords()
                    } label: {
                        Image(systemName: "list.bullet.indent")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open Structured Keywords picker")
                }
            }

            FlowLayout(spacing: 4) {
                ForEach(keywords, id: \.self) { keyword in
                    let isFlagged = flaggedKeywords.contains(keyword)
                    HStack(spacing: 2) {
                        Text(keyword)
                            .font(.caption)
                            .foregroundStyle(isFlagged ? Color.orange : Color.primary)
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
                    .background(
                        isFlagged ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.secondary.opacity(0.2)),
                        in: Capsule()
                    )
                    .overlay {
                        if isFlagged {
                            Capsule().strokeBorder(.orange.opacity(0.4), lineWidth: 0.5)
                        }
                    }
                    .help(isFlagged ? "Not in approved list" : "")
                }

                ForEach(partialKeywords, id: \.self) { keyword in
                    Button {
                        promotingKeyword = keyword
                    } label: {
                        Text(keyword)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5))
                    .help("Present in some images — click to add to all")
                    .popover(isPresented: Binding(
                        get: { promotingKeyword == keyword },
                        set: { if !$0 { promotingKeyword = nil } }
                    )) {
                        VStack(spacing: 8) {
                            Text("Add \"\(keyword)\" to all \(selectedCount) images?")
                                .font(.caption)
                            HStack(spacing: 8) {
                                Button("Cancel") {
                                    promotingKeyword = nil
                                }
                                Button("Add to All") {
                                    onPromotePartial?(keyword)
                                    promotingKeyword = nil
                                    onChange?()
                                    onCommit?()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(10)
                    }
                }
            }

            inputField
                .overlay {
                    if isRejectFlashing {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.red, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .popover(isPresented: Binding(
                    get: { popoverIsActive },
                    set: { _ in }
                ), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    suggestionsPopover
                }

            if let rejectErrorMessage {
                Text(rejectErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .onChange(of: keywords) { _, _ in
            inputText = ""
            updateSuggestions(for: "")
        }
        .onChange(of: inputText) { _, newValue in
            // Comma/semicolon trigger immediate commit (existing behavior). The popover
            // is deliberately bypassed so paste of "berlin, paris" doesn't expand.
            if newValue.contains(",") || newValue.contains(";") {
                addKeywords(useHighlightedSuggestion: false)
                return
            }
            updateSuggestions(for: newValue)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if typeaheadEnabled {
            TypeaheadTextField(
                text: $inputText,
                placeholder: placeholder,
                isFocused: $inputIsFocused,
                onSubmit: { addKeywords(useHighlightedSuggestion: true) },
                onArrowDown: { moveHighlight(by: 1) },
                onArrowUp: { moveHighlight(by: -1) },
                onEscape: { dismissPopover() }
            )
            .frame(height: 22)
        } else if let focusedField, let focusKey {
            TextField(placeholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .focused(focusedField, equals: focusKey)
                .onSubmit { addKeywords(useHighlightedSuggestion: false) }
        } else {
            TextField(placeholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit { addKeywords(useHighlightedSuggestion: false) }
        }
    }

    @ViewBuilder
    private var suggestionsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleSuggestions.enumerated()), id: \.element.canonical) { idx, sug in
                HStack(spacing: 6) {
                    Text(sug.canonical)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if sug.matchKind == .substring {
                        Image(systemName: "text.magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlightedIndex == idx ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { commitSuggestion(sug) }
                .onHover { hovering in if hovering { highlightedIndex = idx } }
            }
        }
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
        .padding(.vertical, 2)
    }

    // MARK: Typeahead helpers

    private func updateSuggestions(for prefix: String) {
        guard let suggestionProvider else {
            visibleSuggestions = []
            highlightedIndex = nil
            return
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            visibleSuggestions = []
            highlightedIndex = nil
            return
        }
        visibleSuggestions = suggestionProvider(trimmed)
        if visibleSuggestions.isEmpty {
            highlightedIndex = nil
        } else if autoHighlightFirstSuggestion {
            highlightedIndex = 0
        } else if let idx = highlightedIndex, idx >= visibleSuggestions.count {
            highlightedIndex = nil
        }
    }

    private func moveHighlight(by delta: Int) {
        guard !visibleSuggestions.isEmpty else { return }
        let count = visibleSuggestions.count
        switch highlightedIndex {
        case nil:
            highlightedIndex = delta > 0 ? 0 : count - 1
        case let current?:
            let next = current + delta
            if next < 0 {
                highlightedIndex = nil
            } else if next >= count {
                highlightedIndex = 0
            } else {
                highlightedIndex = next
            }
        }
    }

    private func dismissPopover() {
        visibleSuggestions = []
        highlightedIndex = nil
    }

    private func commitSuggestion(_ suggestion: ApprovedListSuggestion) {
        inputText = suggestion.canonical
        addKeywords(useHighlightedSuggestion: false)
    }

    // MARK: addKeywords with validation

    private func addKeywords(useHighlightedSuggestion: Bool) {
        if useHighlightedSuggestion,
           let idx = highlightedIndex,
           idx < visibleSuggestions.count {
            commitSuggestion(visibleSuggestions[idx])
            return
        }

        let rawParts = inputText
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var accepted: [String] = []
        var rejected: [String] = []
        for part in rawParts where !keywords.contains(part) {
            switch validator?(part) ?? .accept {
            case .accept:
                accepted.append(part)
            case .acceptCanonical(let canonical):
                if !keywords.contains(canonical) {
                    accepted.append(canonical)
                }
            case .reject:
                rejected.append(part)
            }
        }

        if !accepted.isEmpty {
            keywords.append(contentsOf: accepted)
            onChange?()
            onCommit?()
        }

        if rejected.isEmpty {
            inputText = ""
        } else if accepted.isEmpty {
            // Keep typed text so user can edit and retry.
            flashRejectState(rejected: rejected)
        } else {
            inputText = ""
            flashRejectState(rejected: rejected)
        }

        updateSuggestions(for: inputText)
    }

    /// Quick List menu pick. Runs the validator (canonical-cases approved entries,
    /// rejects non-approved in Strict mode). Rejections route through onValidationReject
    /// when provided so the metadata panel can surface them in the banner; otherwise
    /// they fall back to the inline flash used by the typing path.
    private func addPresetItem(_ item: String) {
        switch validator?(item) ?? .accept {
        case .accept:
            if !keywords.contains(item) {
                keywords.append(item)
                onChange?()
                onCommit?()
            }
        case .acceptCanonical(let canonical):
            if !keywords.contains(canonical) {
                keywords.append(canonical)
                onChange?()
                onCommit?()
            }
        case .reject:
            if let onValidationReject {
                onValidationReject([item])
            } else {
                flashRejectState(rejected: [item])
            }
        }
    }

    private func flashRejectState(rejected: [String]) {
        guard let first = rejected.first else { return }
        let suffix = rejected.count > 1 ? " (+\(rejected.count - 1) more)" : ""
        rejectErrorMessage = "Not in approved list: \"\(first)\"\(suffix)"
        isRejectFlashing = true

        rejectFlashTask?.cancel()
        rejectFlashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            isRejectFlashing = false
        }

        rejectClearTask?.cancel()
        rejectClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            rejectErrorMessage = nil
        }
    }
}

// MARK: - Typeahead Text Field (NSTextField wrapper for arrow-key support)

struct TypeaheadTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.isBezeled = true
        field.focusRingType = .default
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Keep the Coordinator's `parent` snapshot fresh so its closures see the latest state.
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TypeaheadTextField

        init(_ parent: TypeaheadTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
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
    var onInsertVariable: (() -> Void)? = nil
    var trailingLabelContent: AnyView? = nil
    var onAddCurrentToQuickList: (() -> Void)? = nil
    var presetList: [String] = []
    var onChooseListFile: (() -> Void)? = nil
    var focusKey: String? = nil
    var focusedField: FocusState<String?>.Binding? = nil

    @State private var localText: String = ""

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
                Spacer()
                if let onInsertVariable {
                    Button {
                        onInsertVariable()
                    } label: {
                        Image(systemName: "curlybraces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Variable Reference")
                }
                if let trailingLabelContent {
                    trailingLabelContent
                }
                if !presetList.isEmpty || onChooseListFile != nil {
                    Menu {
                        if let onAddCurrentToQuickList {
                            Button("Add Current to Quick List") {
                                onAddCurrentToQuickList()
                            }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Divider()
                        }
                        if let onChooseListFile {
                            Button("Choose Quick List File...") {
                                onChooseListFile()
                            }
                        }
                        if !presetList.isEmpty {
                            Divider()
                            ForEach(presetList, id: \.self) { item in
                                let isSelected = text == item
                                Button {
                                    if !isSelected {
                                        text = item
                                        onCommit?()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(item)
                                    }
                                }
                                .disabled(isSelected)
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.caption)
                            .foregroundStyle(presetList.isEmpty ? .secondary : .primary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(presetList.isEmpty ? "Choose a Quick List file" : "Choose from Quick List")
                }
            }
            if let focusedField, let focusKey {
                let isFocused = focusedField.wrappedValue == focusKey
                TextField(placeholder, text: $localText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .focused(focusedField, equals: focusKey)
                    .onAppear { localText = text }
                    .onChange(of: text) { _, newValue in
                        if newValue != localText { localText = newValue }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { flush() }
                    }
                    .onSubmit {
                        flush()
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

    private func flush() {
        if localText != text { text = localText }
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

/// Text field that buffers keystrokes locally to prevent per-keystroke
/// re-evaluation of the parent view. Syncs on focus loss or Return.
private struct BufferedTextField: View {
    let currentValue: String
    let placeholder: String
    let lineLimit: ClosedRange<Int>
    let focusedField: FocusState<String?>.Binding
    let focusKey: String
    var onTextFinished: (String?) -> Void
    var onCommit: () -> Void

    @State private var localText = ""

    var body: some View {
        let isFocused = focusedField.wrappedValue == focusKey
        TextField(placeholder, text: $localText, axis: .vertical)
            .lineLimit(lineLimit)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .focused(focusedField, equals: focusKey)
            .onAppear { localText = currentValue }
            .onChange(of: currentValue) { _, newValue in
                if newValue != localText {
                    localText = newValue
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    flush()
                }
            }
            .onKeyPress(.return) {
                if NSEvent.modifierFlags.contains(.shift) {
                    insertNewlineAtCursor()
                    return .handled
                }
                flush()
                onCommit()
                return .handled
            }
    }

    private func flush() {
        let normalized = localText.isEmpty ? nil : localText
        onTextFinished(normalized)
    }

    private func insertNewlineAtCursor() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            let selection = editor.selectedRange()
            if let range = Range(selection, in: localText) {
                localText = localText.replacingCharacters(in: range, with: "\n")
                let newLocation = selection.location + 1
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.setSelectedRange(NSRange(location: newLocation, length: 0))
                    }
                }
            } else {
                localText.append("\n")
            }
        } else {
            localText.append("\n")
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

// MARK: - Description Conflict Banner

struct DescriptionConflictBanner: View {
    let conflict: DescriptionConflict
    let onResolve: (Bool) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("XMP and IPTC descriptions differ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    conflictValueRow(label: "XMP", value: conflict.xmpDescription, keepXMP: true)
                    conflictValueRow(label: "IPTC", value: conflict.iptcCaptionAbstract, keepXMP: false)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.08))
                .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func conflictValueRow(label: String, value: String, keepXMP: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use This") {
                    onResolve(keepXMP)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(value)
                .font(.caption)
                .lineLimit(4)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }
}
