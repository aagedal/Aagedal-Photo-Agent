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
    @AccessibilityFocusState private var isSaveErrorFocused: Bool

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

            if viewModel.saveError != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Template wasn’t saved", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .accessibilityFocused($isSaveErrorFocused)
                        .accessibilityLabel(
                            AppAccessibilityAnnouncement.failure(.templateSave).spokenText
                        )

                    Text("Your edits are still here. Retry the save or save a new copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Retry Save") {
                            saveTemplate(isRecovery: true)
                        }
                        .keyboardShortcut(.defaultAction)

                        Button("Save as New") {
                            saveTemplateAsNew()
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    AccessibilityAnnouncementCenter.post(.cancellation(.templateEditing))
                    viewModel.cancelEditing()
                }
                Button("Save") {
                    saveTemplate(isRecovery: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingTemplate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 380)
        .onChange(of: viewModel.saveError) { _, newError in
            guard newError != nil else { return }
            DispatchQueue.main.async {
                isSaveErrorFocused = true
            }
        }
    }

    private func saveTemplate(isRecovery: Bool) {
        switch viewModel.saveEditingTemplate() {
        case .success:
            AccessibilityAnnouncementCenter.post(
                isRecovery ? .recovery(.templateSaved) : .success(.templateSaved)
            )
        case .failure:
            break
        }
    }

    private func saveTemplateAsNew() {
        switch viewModel.saveEditingTemplateAsNew() {
        case .success:
            AccessibilityAnnouncementCenter.post(.recovery(.templateSaved))
        case .failure:
            break
        }
    }
}
