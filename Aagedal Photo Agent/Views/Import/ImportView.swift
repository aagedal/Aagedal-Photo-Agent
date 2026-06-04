import SwiftUI

struct ImportView: View {
    @Bindable var viewModel: ImportViewModel
    var templates: [MetadataTemplate]
    var thumbnailService: ThumbnailService
    var onDismiss: () -> Void

    @State private var showAdditionalFields = false
    /// Date group currently being edited in the shoot-split sheet.
    @State private var splitTarget: ImportDateGroup?

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
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Form Content

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import Photos")
                    .font(.title2.bold())

                sourceSection
                destinationSection
                dateSortingSection
                fileTypeSection
                conflictSection
                verificationSection
                backupSection
                metadataSection

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

    // MARK: - Source Section

    @ViewBuilder
    private var sourceSection: some View {
        GroupBox("Source") {
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
                        Text("No folder selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose...") {
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
                        thumbnailService: thumbnailService
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
        GroupBox("Destination") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.configuration.destinationBaseURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("Change...") {
                        viewModel.selectDestinationBase()
                    }
                }

                TextField("Import Title", text: $viewModel.configuration.importTitle)
                    .textFieldStyle(.roundedBorder)

                if !viewModel.configuration.importTitle.trimmingCharacters(in: .whitespaces).isEmpty
                    && !viewModel.sortByDate {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.configuration.destinationFolderName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.sortByDate
                    && !viewModel.configuration.importTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Appended to each per-date folder. Re-scan dates to apply changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Toggle("Group date folders by year", isOn: $viewModel.groupByYear)
                        .controlSize(.small)

                    if viewModel.dateGroups.isEmpty && !viewModel.isScanningDates {
                        Text("Click \"Scan Dates\" to detect capture dates from source files.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($viewModel.dateGroups) { $group in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.dateString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(group.files.count) files")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 100, alignment: .leading)

                                if viewModel.groupByYear, let year = group.yearFolder {
                                    Text("\(year)/")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                TextField("Folder name", text: $group.folderName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout)
                                    .onSubmit { viewModel.ensureUniqueFolderNames() }

                                ImportThumbnailStripView(
                                    files: group.files,
                                    captureTimes: group.captureTimes,
                                    thumbnailService: thumbnailService
                                )

                                if group.files.count > 1 {
                                    Button {
                                        splitTarget = group
                                    } label: {
                                        Image(systemName: "scissors")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Split this day into multiple shoots")
                                }

                                if viewModel.hasSiblingGroups(group) {
                                    Button {
                                        viewModel.mergeSiblings(of: group)
                                    } label: {
                                        Image(systemName: "arrow.triangle.merge")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Merge this day’s shoots back into one folder")
                                }
                            }
                        }

                        Text("Re-scanning dates rebuilds these groups and discards manual shoot splits.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(viewModel.groupByYear
                             ? "Each date group will be imported into <year>/<date>/ under the destination base."
                             : "Each date group will be imported into a separate folder under the destination base.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: viewModel.sortByDate) { _, newValue in
            if newValue && viewModel.dateGroups.isEmpty && !viewModel.sourceFiles.isEmpty {
                viewModel.scanCaptureDates()
            }
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
        }
    }

    // MARK: - File Type Section

    @ViewBuilder
    private var fileTypeSection: some View {
        GroupBox("File Types") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Filter", selection: $viewModel.configuration.fileTypeFilter) {
                    ForEach(ImportFileTypeFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.configuration.fileTypeFilter == .both {
                    Toggle("Create RAW and JPEG sub-folders", isOn: $viewModel.configuration.createSubFolders)
                }

                if !viewModel.sourceFiles.isEmpty {
                    Text("\(viewModel.filteredSourceFiles.count) files will be imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metadata Section

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

    // MARK: - Backup Section

    @ViewBuilder
    private var backupSection: some View {
        GroupBox("Backup Destination (Optional)") {
            VStack(alignment: .leading, spacing: 8) {
                if let backup = viewModel.configuration.backupDestination {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.secondary)
                        Text(backup.url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
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
                        .help("Remove backup destination")
                    }

                    Toggle("Verify backup copies", isOn: Binding(
                        get: { viewModel.configuration.backupDestination?.verifyAfterWrite ?? true },
                        set: { viewModel.configuration.backupDestination?.verifyAfterWrite = $0 }
                    ))
                    .disabled(viewModel.configuration.verificationMode == .off)

                    Text("Each file will copy to both the primary and backup destinations. If the backup fails, the primary import still completes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("No backup destination configured.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            viewModel.selectBackupDestination()
                        }
                    }
                    Text("Optional: copy each file to a second location during import (e.g., a NAS or external drive). Backup failures don't fail the import.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            EditableTextField(
                label: "Copyright",
                text: Binding(
                    get: { viewModel.configuration.metadata.copyright ?? "" },
                    set: { viewModel.configuration.metadata.copyright = $0.isEmpty ? nil : $0 }
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
                        label: "Credit",
                        text: Binding(
                            get: { viewModel.configuration.metadata.credit ?? "" },
                            set: { viewModel.configuration.metadata.credit = $0.isEmpty ? nil : $0 }
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
                        label: "Country",
                        text: Binding(
                            get: { viewModel.configuration.metadata.country ?? "" },
                            set: { viewModel.configuration.metadata.country = $0.isEmpty ? nil : $0 }
                        )
                    )

                    EditableTextField(
                        label: "Event",
                        text: Binding(
                            get: { viewModel.configuration.metadata.event ?? "" },
                            set: { viewModel.configuration.metadata.event = $0.isEmpty ? nil : $0 }
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
            .disabled(viewModel.filteredSourceFiles.isEmpty || (!viewModel.sortByDate && viewModel.configuration.importTitle.trimmingCharacters(in: .whitespaces).isEmpty) || (viewModel.sortByDate && viewModel.dateGroups.isEmpty))
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
}
