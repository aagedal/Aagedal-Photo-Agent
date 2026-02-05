import SwiftUI

struct ImportView: View {
    @Bindable var viewModel: ImportViewModel
    var templates: [MetadataTemplate]
    var onDismiss: () -> Void

    @State private var showAdditionalFields = false

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.importPhase {
            case .copying, .applyingMetadata:
                progressContent
            case .complete:
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
                fileTypeSection
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

                if !viewModel.configuration.importTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.configuration.destinationFolderName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Toggle("Open folder after import", isOn: $viewModel.configuration.openFolderAfterImport)
                .font(.caption)

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Import") {
                viewModel.startImport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.filteredSourceFiles.isEmpty || viewModel.configuration.importTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    // MARK: - Progress Content

    @ViewBuilder
    private var progressContent: some View {
        VStack(spacing: 16) {
            Spacer()

            if viewModel.importPhase == .copying {
                Text("Copying files...")
                    .font(.headline)
                ProgressView(value: Double(viewModel.copiedFiles), total: Double(viewModel.totalFiles))
                    .frame(maxWidth: 300)
                Text("\(viewModel.copiedFiles) of \(viewModel.totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.importPhase == .applyingMetadata {
                Text("Applying metadata...")
                    .font(.headline)
                ProgressView()
                    .controlSize(.large)
                Text("Writing IPTC metadata to imported files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Completion Content

    @ViewBuilder
    private var completionContent: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Import Complete")
                .font(.title2.bold())

            Text("\(viewModel.copiedFiles) files imported to")
                .foregroundStyle(.secondary)
            Text(viewModel.configuration.destinationFolderName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 12) {
                Button("Import More") {
                    viewModel.reset()
                }

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
