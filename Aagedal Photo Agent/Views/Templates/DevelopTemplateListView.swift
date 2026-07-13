import SwiftUI

struct DevelopTemplateListView: View {
    @Bindable var viewModel: DevelopTemplateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Develop Templates")
                .font(.headline)

            if viewModel.templates.isEmpty {
                ContentUnavailableView(
                    "No develop templates saved",
                    systemImage: "slider.horizontal.3",
                    description: Text("In Develop, press Command-T and choose Save Current as Template.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.templates) { template in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                Text(template.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let slot = template.shortcutSlot {
                                Text("Ctrl+\(slot)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Button("Edit") {
                                viewModel.startEditing(template)
                            }

                            Button("Delete", role: .destructive) {
                                viewModel.deleteTemplate(template)
                            }
                        }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DevelopTemplateEditorView: View {
    @Bindable var viewModel: DevelopTemplateViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Develop Template")
                .font(.headline)

            TextField("Template Name", text: $viewModel.editingTemplate.name)
                .textFieldStyle(.roundedBorder)

            Picker("Keyboard Shortcut", selection: $viewModel.editingTemplate.shortcutSlot) {
                Text("None").tag(nil as Int?)
                ForEach(1...9, id: \.self) { slot in
                    Text("Ctrl+\(slot)").tag(slot as Int?)
                }
            }
            .frame(width: 240)

            Toggle("Include crop when applying", isOn: $viewModel.editingTemplate.includesCrop)
                .toggleStyle(.checkbox)
                .help("When disabled, the destination image's existing crop is preserved.")

            LabeledContent("Included Settings", value: viewModel.editingTemplate.summary)

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.cancelEditing()
                }
                Button("Save") {
                    viewModel.saveEditingTemplate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingTemplate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 380)
    }
}
