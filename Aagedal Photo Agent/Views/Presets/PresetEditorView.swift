import SwiftUI

struct PresetEditorView: View {
    @Bindable var viewModel: PresetViewModel

    @State private var isShowingVariableReference = false
    @State private var activeFieldID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.editingPreset.id == UUID() ? "New Preset" : "Edit Preset")
                .font(.headline)

            TextField("Preset Name", text: $viewModel.editingPreset.name)
                .textFieldStyle(.roundedBorder)

            Picker("Type", selection: $viewModel.editingPreset.presetType) {
                ForEach(MetadataPreset.PresetType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            HStack {
                Text("Fields")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    isShowingVariableReference = true
                } label: {
                    Label("Variable Reference", systemImage: "curlybraces")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ForEach($viewModel.editingPreset.fields) { $field in
                HStack {
                    Picker("", selection: $field.fieldKey) {
                        ForEach(PresetField.availableFields, id: \.key) { f in
                            Text(f.label).tag(f.key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    TextField("Template value", text: $field.templateValue)
                        .textFieldStyle(.roundedBorder)

                    variableMenu(for: $field)

                    Button {
                        viewModel.editingPreset.fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                let firstAvailable = PresetField.availableFields.first?.key ?? "title"
                viewModel.editingPreset.fields.append(
                    PresetField(fieldKey: firstAvailable, templateValue: "")
                )
            } label: {
                Label("Add Field", systemImage: "plus")
            }
            .buttonStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.cancelEditing()
                }
                Button("Save") {
                    viewModel.saveEditingPreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingPreset.name.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 450)
        .sheet(isPresented: $isShowingVariableReference) {
            VariableReferenceView(isPresented: $isShowingVariableReference)
        }
    }

    private func variableMenu(for field: Binding<PresetField>) -> some View {
        Menu {
            Section("Date") {
                Button("{date} — medium format") {
                    field.wrappedValue.templateValue += "{date}"
                }
                Button("{date:yyyy-MM-dd}") {
                    field.wrappedValue.templateValue += "{date:yyyy-MM-dd}"
                }
                Button("{date:dd MMM yyyy}") {
                    field.wrappedValue.templateValue += "{date:dd MMM yyyy}"
                }
                Button("{date:dd.MM.yyyy}") {
                    field.wrappedValue.templateValue += "{date:dd.MM.yyyy}"
                }
                Button("{date:yyyy}") {
                    field.wrappedValue.templateValue += "{date:yyyy}"
                }
            }

            Section("Shortcuts") {
                Button("{persons} — Person Shown names") {
                    field.wrappedValue.templateValue += "{persons}"
                }
                Button("{keywords} — Keywords list") {
                    field.wrappedValue.templateValue += "{keywords}"
                }
                Button("{filename} — Image filename") {
                    field.wrappedValue.templateValue += "{filename}"
                }
            }

            Section("Field Reference") {
                ForEach(PresetField.availableFields, id: \.key) { f in
                    Button("{field:\(f.key)}") {
                        field.wrappedValue.templateValue += "{field:\(f.key)}"
                    }
                }
            }
        } label: {
            Image(systemName: "curlybraces")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }
}
