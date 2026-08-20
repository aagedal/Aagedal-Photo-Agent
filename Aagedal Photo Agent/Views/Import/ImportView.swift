import SwiftUI

struct ImportView: View {
    @Bindable var viewModel: ImportViewModel
    var templates: [MetadataTemplate]
    var thumbnailService: ThumbnailService
    /// Maximum height for the sheet (and the split-editor sub-sheet), so they don't
    /// span the full window height. `nil` leaves the height unconstrained.
    var maxSheetHeight: CGFloat?
    var onDismiss: () -> Void

    @State private var showAdditionalFields = false
    @State private var showAdvancedOptions = false
    /// Date group currently being edited in the shoot-split sheet.
    @State private var splitTarget: ImportDateGroup?
    @State private var prefetchImportThumbnails = true
    @State private var showSlowThumbnailWarning = false

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.importPhase {
            case .copying, .applyingMetadata:
                progressContent
            case .complete, .cancelled:
                completionContent
            default:
                formContent
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .frame(maxHeight: maxSheetHeight)
        .alert("Thumbnail previews are slow", isPresented: $showSlowThumbnailWarning) {
            Button("OK") { }
        } message: {
            Text("Generating previews from this card is taking more than 10 seconds. Import can continue normally; thumbnails will load only when you hover a preview strip.")
        }
    }

    // MARK: - Form Content

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import Photos")
                    .font(.title2.bold())

                importNameSection
                sourceSection
                destinationSection
                dateSortingSection
                fileTypeSection
                advancedOptionsSection

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
        }

        Divider()
        formFooter
    }

    // MARK: - Import Setup

    @ViewBuilder
    private var importNameSection: some View {
        GroupBox("Import Name") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Import Title", text: $viewModel.configuration.importTitle)
                    .textFieldStyle(.roundedBorder)

                Text(viewModel.sortByDate
                    ? "Optional. Added to each capture-date folder name."
                    : "Required. Used with today’s date to name the new import folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !viewModel.sortByDate {
                    let suggestions = viewModel.suggestedFoldersForCurrentImportDate()
                    if !suggestions.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text("Existing folders for \(viewModel.currentImportDateFolderName):")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Menu {
                                ForEach(suggestions, id: \.self) { folder in
                                    Button(folder.lastPathComponent) {
                                        viewModel.useSuggestedFolderForCurrentImport(folder)
                                    }
                                }
                            } label: {
                                Text("Choose Folder…")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    } else if viewModel.isScanningPreviousImportFolders {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Looking for existing folders with this date…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !viewModel.configuration.importTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.sortByDate
                            ? "The title will be included in each new date folder."
                            : "New folder: \(viewModel.configuration.destinationFolderName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        GroupBox("Source — Memory Card or Folder") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let sourceURL = viewModel.configuration.sourceURL {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(sourceURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                    } else {
                        Text("No memory card or folder selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Card or Folder…") {
                        viewModel.selectSource()
                    }
                }

                if !viewModel.sourceFiles.isEmpty {
                    Text("\(viewModel.sourceFiles.count) supported images found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // When not sorting into per-date folders, the date rows (and their
                // strips) are hidden, so offer a single preview of the whole import.
                if !viewModel.sortByDate && !viewModel.filteredSourceFiles.isEmpty {
                    ImportThumbnailStripView(
                        files: viewModel.filteredSourceFiles,
                        captureTimes: [:],
                        thumbnailService: thumbnailService,
                        prefetchThumbnails: prefetchImportThumbnails,
                        onPrefetchTimeout: handleSlowThumbnailPrefetch
                    )
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Destination Section

    @ViewBuilder
    private var destinationSection: some View {
        GroupBox("Destinations") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Primary Destination Root")
                    .font(.subheadline.weight(.medium))

                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.configuration.destinationBaseURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Change…") {
                        viewModel.selectDestinationBase()
                    }
                }

                Text("This is the parent folder. New date and import folders are created inside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                if let backup = viewModel.configuration.backupDestination {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Additional Copy")
                                .font(.subheadline.weight(.medium))
                            Text(backup.url.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Change…") {
                            viewModel.selectBackupDestination()
                        }

                        Button {
                            viewModel.clearBackupDestination()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove additional copy destination")
                        .accessibilityLabel("Remove additional copy destination")
                    }

                    Toggle("Verify additional copy after writing", isOn: Binding(
                        get: { viewModel.configuration.backupDestination?.verifyAfterWrite ?? true },
                        set: {
                            viewModel.configuration.backupDestination?.verifyAfterWrite = $0
                            UserDefaults.standard.set($0, forKey: UserDefaultsKeys.importBackupVerifyAfterWrite)
                        }
                    ))
                    .controlSize(.small)
                    .disabled(viewModel.configuration.verificationMode == .off)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Additional Copy")
                                .font(.subheadline.weight(.medium))
                            Text("Optionally copy the import to a second drive or NAS.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            viewModel.selectBackupDestination()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add an additional copy destination")
                        .accessibilityLabel("Add an additional copy destination")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Date Sorting Section

    @ViewBuilder
    private var dateSortingSection: some View {
        GroupBox("Sort by Capture Date") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Sort files into per-date folders", isOn: $viewModel.sortByDate)
                    Spacer()
                    if viewModel.isScanningDates {
                        ProgressView()
                            .controlSize(.small)
                    } else if viewModel.sortByDate && viewModel.dateGroups.isEmpty && !viewModel.sourceFiles.isEmpty {
                        Button("Scan Dates") {
                            viewModel.scanCaptureDates()
                        }
                        .controlSize(.small)
                    }
                }

                if viewModel.sortByDate {
                    Picker("Group date folders", selection: $viewModel.dateFolderGrouping) {
                        ForEach(ImportDateFolderGrouping.allCases, id: \.self) { grouping in
                            Text(grouping.displayName).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    Toggle("Put split shoots in subfolders", isOn: $viewModel.splitShootsIntoSubfolders)
                        .controlSize(.small)

                    if viewModel.dateGroups.isEmpty && !viewModel.isScanningDates {
                        Text("Click \"Scan Dates\" to detect capture dates from source files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($viewModel.dateGroups) { $group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Toggle("", isOn: $group.isIncluded)
                                        .labelsHidden()
                                        .help(group.isIncluded ? "Import this date folder" : "Skip this date folder")

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.dateString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\(group.files.count) files")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .frame(width: 100, alignment: .leading)

                                    let groupingPrefix = viewModel.folderPathGroupingPrefix(for: group)
                                    if !groupingPrefix.isEmpty {
                                        Text("\(groupingPrefix)/")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    TextField("Folder name", text: $group.folderName)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout)
                                        .onSubmit { viewModel.ensureUniqueFolderNames() }
                                        .disabled(!group.isIncluded)

                                    let folderSuggestions = viewModel.suggestedFolders(for: group)
                                    if !folderSuggestions.isEmpty {
                                        Menu {
                                            ForEach(folderSuggestions, id: \.self) { folder in
                                                Button(folder.lastPathComponent) {
                                                    viewModel.useSuggestedFolder(folder, for: group.id)
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "clock.arrow.circlepath")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                        .help("Use an existing folder for this capture date")
                                        .disabled(!group.isIncluded)
                                    }

                                    if group.shootFolderName != nil {
                                        Text("/")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        TextField("Shoot folder", text: Binding(
                                            get: { group.shootFolderName ?? "" },
                                            set: { group.shootFolderName = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout)
                                        .frame(width: 110)
                                        .onSubmit { viewModel.ensureUniqueFolderNames() }
                                        .disabled(!group.isIncluded)
                                    }

                                    ImportThumbnailStripView(
                                        files: group.files,
                                        captureTimes: group.captureTimes,
                                        thumbnailService: thumbnailService,
                                        prefetchThumbnails: prefetchImportThumbnails,
                                        onPrefetchTimeout: handleSlowThumbnailPrefetch
                                    )

                                    if group.files.count > 1 {
                                        Button {
                                            splitTarget = group
                                        } label: {
                                            Image(systemName: "scissors")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Split this day into multiple shoots")
                                        .disabled(!group.isIncluded)
                                    }

                                    if viewModel.hasSiblingGroups(group) {
                                        Button {
                                            viewModel.mergeSiblings(of: group)
                                        } label: {
                                            Image(systemName: "arrow.triangle.merge")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Merge this day’s shoots back into one folder")
                                        .disabled(!group.isIncluded)
                                    }
                                }
                                .opacity(group.isIncluded ? 1 : 0.55)

                                // Full destination preview for this group.
                                HStack(spacing: 4) {
                                    Image(systemName: group.isIncluded ? "folder" : "nosign")
                                    Text(group.isIncluded ? viewModel.folderPathPreview(for: group) : "Skipped")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 132)
                            }
                            .padding(.vertical, 4)
                        }

                        Text("Re-scanning dates rebuilds these groups and discards manual shoot splits.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(viewModel.dateFolderGrouping.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: viewModel.sortByDate) { _, newValue in
            viewModel.refreshPreviousImportFolderSuggestions()
            if newValue && viewModel.dateGroups.isEmpty && !viewModel.sourceFiles.isEmpty {
                viewModel.scanCaptureDates()
            }
        }
        .onChange(of: viewModel.configuration.importTitle) { oldValue, newValue in
            // Keep auto-named per-date folders in sync with the title as the user types,
            // without forcing a re-scan. Manually-renamed groups are left untouched.
            viewModel.updateGroupFolderTitles(from: oldValue, to: newValue)
        }
        .sheet(item: $splitTarget) { group in
            ImportSplitEditorView(
                group: group,
                thumbnailService: thumbnailService,
                onSplit: { boundaries in
                    viewModel.splitGroup(group.id, boundaries: boundaries)
                },
                onMove: { fileURLs in
                    viewModel.splitOff(group.id, fileURLs: fileURLs)
                }
            )
            .frame(maxHeight: maxSheetHeight)
        }
    }

    // MARK: - File Type Section

    @ViewBuilder
    private var fileTypeSection: some View {
        GroupBox("File Types") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Filter", selection: Binding(
                    get: { viewModel.configuration.fileTypeFilter },
                    set: { newValue in
                        viewModel.configuration.fileTypeFilter = newValue
                        UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter)
                    }
                )) {
                    ForEach(ImportFileTypeFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.configuration.fileTypeFilter == .both {
                    Toggle("Create RAW and JPEG sub-folders", isOn: $viewModel.configuration.createSubFolders)
                }

                if !viewModel.sourceFiles.isEmpty {
                    Text("\(viewModel.selectedSourceFiles.count) files will be imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Advanced Options

    @ViewBuilder
    private var advancedOptionsSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showAdvancedOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    conflictSection
                    verificationSection
                    metadataSection
                }
                .padding(.top, 12)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Advanced Options", systemImage: "slider.horizontal.3")
                    if !showAdvancedOptions {
                        Text(advancedOptionsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var advancedOptionsSummary: String {
        let metadata = viewModel.configuration.applyMetadata ? "On" : "Off"
        return "Conflicts: \(viewModel.configuration.conflictPolicy.displayName) · Verification: \(viewModel.configuration.verificationMode.displayName) · Metadata: \(metadata)"
    }

    @ViewBuilder
    private var conflictSection: some View {
        GroupBox("File Name Conflicts") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("When destination file exists", selection: $viewModel.configuration.conflictPolicy) {
                    ForEach(ImportConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.configuration.conflictPolicy.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Skip duplicates from previous same-day imports", isOn: $viewModel.configuration.skipPreviouslyImported)
                    .controlSize(.small)

                Text("Checks destination folders beginning with the same date, then requires a matching file name, size, and quick content checksum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Verification Section

    @ViewBuilder
    private var verificationSection: some View {
        GroupBox("Copy Verification") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Verify each file after copy", selection: $viewModel.configuration.verificationMode) {
                    ForEach(CopyVerificationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.configuration.verificationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        GroupBox("IPTC Metadata") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Apply metadata on import", isOn: $viewModel.configuration.applyMetadata)

                if viewModel.configuration.applyMetadata {
                    Toggle("Process {variables} per file", isOn: $viewModel.configuration.processVariables)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Resolve {date}, {filename}, and other variables individually for each imported file")

                    if !templates.isEmpty {
                        HStack {
                            Text("Template:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Menu {
                                ForEach(templates) { template in
                                    Button(template.name) {
                                        viewModel.applyTemplate(template)
                                    }
                                }
                            } label: {
                                Text("Choose Template...")
                                    .font(.caption)
                            }
                        }
                    }

                    metadataFields
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Headline reuses the import title from the Destination section
            HStack(spacing: 4) {
                Text("Headline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("(uses import title)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { viewModel.configuration.metadata.description ?? "" },
                    set: { viewModel.configuration.metadata.description = $0.isEmpty ? nil : $0 }
                ))
                .font(.body)
                .frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Extended Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { viewModel.configuration.metadata.extendedDescription ?? "" },
                    set: { viewModel.configuration.metadata.extendedDescription = $0.isEmpty ? nil : $0 }
                ))
                .font(.body)
                .frame(height: 56)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }

            KeywordsEditor(
                label: "Keywords",
                keywords: $viewModel.configuration.metadata.keywords
            )

            KeywordsEditor(
                label: "Person Shown",
                keywords: $viewModel.configuration.metadata.personShown
            )

            KeywordsEditor(
                label: "Organisation Shown Name",
                keywords: $viewModel.configuration.metadata.organisationsShownNames
            )

            KeywordsEditor(
                label: "Organisation Shown Code",
                keywords: $viewModel.configuration.metadata.organisationsShownCodes
            )

            EditableTextField(
                label: "Copyright",
                text: Binding(
                    get: { viewModel.configuration.metadata.copyright ?? "" },
                    set: { viewModel.configuration.metadata.copyright = $0.isEmpty ? nil : $0 }
                )
            )

            EditableTextField(
                label: "Rights Usage Terms",
                text: Binding(
                    get: { viewModel.configuration.metadata.rightsUsageTerms ?? "" },
                    set: { viewModel.configuration.metadata.rightsUsageTerms = $0.isEmpty ? nil : $0 }
                )
            )

            EditableTextField(
                label: "Web Statement of Rights",
                text: Binding(
                    get: { viewModel.configuration.metadata.webStatementOfRights ?? "" },
                    set: { viewModel.configuration.metadata.webStatementOfRights = $0.isEmpty ? nil : $0 }
                )
            )

            EditableTextField(
                label: "Job ID",
                text: Binding(
                    get: { viewModel.configuration.metadata.jobId ?? "" },
                    set: { viewModel.configuration.metadata.jobId = $0.isEmpty ? nil : $0 }
                )
            )

            // Digital Source Type
            VStack(alignment: .leading, spacing: 2) {
                Text("Digital Source Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $viewModel.configuration.metadata.digitalSourceType) {
                    Text("None").tag(nil as DigitalSourceType?)
                    ForEach(DigitalSourceType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type as DigitalSourceType?)
                    }
                }
                .labelsHidden()
            }

            // Additional fields
            DisclosureGroup("Additional Fields", isExpanded: $showAdditionalFields) {
                VStack(alignment: .leading, spacing: 6) {
                    EditableTextField(
                        label: "Creator",
                        text: Binding(
                            get: { viewModel.configuration.metadata.creator ?? "" },
                            set: { viewModel.configuration.metadata.creator = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Creator Job Title",
                        text: Binding(
                            get: { viewModel.configuration.metadata.creatorJobTitle ?? "" },
                            set: { viewModel.configuration.metadata.creatorJobTitle = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Description Writer",
                        text: Binding(
                            get: { viewModel.configuration.metadata.descriptionWriter ?? "" },
                            set: { viewModel.configuration.metadata.descriptionWriter = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Credit",
                        text: Binding(
                            get: { viewModel.configuration.metadata.credit ?? "" },
                            set: { viewModel.configuration.metadata.credit = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Source",
                        text: Binding(
                            get: { viewModel.configuration.metadata.source ?? "" },
                            set: { viewModel.configuration.metadata.source = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Date Created",
                        text: Binding(
                            get: { viewModel.configuration.metadata.dateCreated ?? "" },
                            set: { viewModel.configuration.metadata.dateCreated = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "City",
                        text: Binding(
                            get: { viewModel.configuration.metadata.city ?? "" },
                            set: { viewModel.configuration.metadata.city = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Sublocation",
                        text: Binding(
                            get: { viewModel.configuration.metadata.sublocation ?? "" },
                            set: { viewModel.configuration.metadata.sublocation = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "State / Province",
                        text: Binding(
                            get: { viewModel.configuration.metadata.provinceState ?? "" },
                            set: { viewModel.configuration.metadata.provinceState = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Country",
                        text: Binding(
                            get: { viewModel.configuration.metadata.country ?? "" },
                            set: { viewModel.configuration.metadata.country = $0.isEmpty ? nil : $0 }
                        )
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Country Code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.configuration.metadata.countryCode) {
                            Text("None").tag(nil as String?)
                            if let current = viewModel.configuration.metadata.countryCode,
                               !ISO3166Country.isValidAlpha3(current) {
                                Text("Unknown code (\(current))").tag(current as String?)
                            }
                            ForEach(ISO3166Country.all.sorted {
                                $0.localizedName().localizedStandardCompare($1.localizedName()) == .orderedAscending
                            }) { country in
                                Text("\(country.localizedName()) (\(country.alpha3))")
                                    .tag(country.alpha3 as String?)
                            }
                        }
                        .labelsHidden()
                    }

                    EditableTextField(
                        label: "Event",
                        text: Binding(
                            get: { viewModel.configuration.metadata.event ?? "" },
                            set: { viewModel.configuration.metadata.event = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Instructions",
                        text: Binding(
                            get: { viewModel.configuration.metadata.instructions ?? "" },
                            set: { viewModel.configuration.metadata.instructions = $0.isEmpty ? nil : $0 }
                        )
                    )
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var formFooter: some View {
        HStack {
            if let reason = viewModel.importBlockingReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel("Import unavailable. \(reason)")
            }

            Spacer()

            Button("Cancel") {
                viewModel.reset()
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Import") {
                viewModel.startImport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.importBlockingReason != nil)
        }
        .padding()
    }

    // MARK: - Progress Content

    @ViewBuilder
    private var progressContent: some View {
        let backupEnabled = viewModel.configuration.backupDestination != nil
        CopyProgressView(
            title: "Copying files…",
            primaryCopied: viewModel.copiedFiles,
            totalFiles: viewModel.totalFiles,
            backupCopied: backupEnabled ? viewModel.backupCopiedFiles : nil,
            backupTotal: backupEnabled ? viewModel.totalFiles : nil,
            backupFailed: viewModel.backupFailedFiles,
            verifiedCount: viewModel.verifiedFiles,
            mismatchedCount: viewModel.mismatchedFiles,
            currentFile: viewModel.currentFile,
            isApplyingMetadata: viewModel.importPhase == .applyingMetadata,
            onCancel: {
                viewModel.cancelImport()
            }
        )
    }

    // MARK: - Completion Content

    @ViewBuilder
    private var completionContent: some View {
        let cancelled = viewModel.importPhase == .cancelled
        let backupEnabled = viewModel.configuration.backupDestination != nil
        VStack(spacing: 12) {
            VerificationSummaryView(
                title: "Import Complete",
                succeededLabel: "imported",
                copiedFiles: viewModel.copiedFiles,
                totalFiles: viewModel.totalFiles,
                renamedFiles: viewModel.renamedFiles,
                skippedFiles: viewModel.skippedFiles,
                failedFiles: viewModel.failedFiles,
                verifiedFiles: viewModel.verifiedFiles,
                mismatchedFiles: viewModel.mismatchedFiles,
                backupCopiedFiles: viewModel.backupCopiedFiles,
                backupFailedFiles: viewModel.backupFailedFiles,
                backupEnabled: backupEnabled,
                failureRecords: viewModel.failureRecords,
                summaryLine: viewModel.importSummary,
                cancelled: cancelled
            )

            HStack(spacing: 12) {
                Button("Import More") {
                    viewModel.reset()
                }
                Button("Done") {
                    viewModel.reset()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom)
        }
    }

    private func handleSlowThumbnailPrefetch() {
        guard prefetchImportThumbnails else { return }
        prefetchImportThumbnails = false
        showSlowThumbnailWarning = true
    }
}
