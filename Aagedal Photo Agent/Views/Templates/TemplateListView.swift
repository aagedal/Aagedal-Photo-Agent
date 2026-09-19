import SwiftUI

struct TemplateListView: View {
    @Bindable var viewModel: TemplateViewModel
    var onApply: ((MetadataTemplate) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Templates")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.startEditing()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New metadata template")
                .help("Create a metadata template")
            }

            if viewModel.templates.isEmpty {
                Text("No templates saved")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(viewModel.templates) { template in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(template.name)
                                    .font(.body)
                                Text("\(template.fields.count) fields")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Edit") {
                                viewModel.startEditing(template)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit \(template.name)")
                            .accessibilityIdentifier("metadata-template-edit-\(template.id.uuidString)")

                            Button("Move to Trash", role: .destructive) {
                                viewModel.deleteTemplate(template)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Move \(template.name) to Trash")
                            .accessibilityIdentifier("metadata-template-trash-\(template.id.uuidString)")
                        }
                        // Keep both native buttons available to VoiceOver and keyboard
                        // navigation instead of allowing List to combine the row.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(template.name)
                    }
                }
            }

            Text("Deleted templates remain in Finder’s Trash until it is emptied.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
