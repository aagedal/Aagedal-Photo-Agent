import SwiftUI

struct TemplateEditorView: View {
    @Bindable var viewModel: TemplateViewModel

    @State private var isShowingVariableReference = false
    @State private var activeFieldID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.editingTemplate.id == UUID() ? "New Template" : "Edit Template")
                .font(.headline)

            TextField("Template Name", text: $viewModel.editingTemplate.name)
                .textFieldStyle(.roundedBorder)

            Picker("Type", selection: $viewModel.editingTemplate.templateType) {
                ForEach(MetadataTemplate.TemplateType.allCases, id: \.self) { type in
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

            ForEach($viewModel.editingTemplate.fields) { $field in
                HStack {
                    Picker("", selection: $field.fieldKey) {
                        ForEach(TemplateField.availableFields, id: \.key) { f in
                            Text(f.label).tag(f.key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    TextField("Template value", text: $field.templateValue)
                        .textFieldStyle(.roundedBorder)

                    variableMenu(for: $field)

                    Button {
                        viewModel.editingTemplate.fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                let firstAvailable = TemplateField.availableFields.first?.key ?? "title"
                viewModel.editingTemplate.fields.append(
                    TemplateField(fieldKey: firstAvailable, templateValue: "")
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
                    viewModel.saveEditingTemplate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingTemplate.name.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 450)
        .sheet(isPresented: $isShowingVariableReference) {
            VariableReferenceView(isPresented: $isShowingVariableReference)
        }
    }

    private func variableMenu(for field: Binding<TemplateField>) -> some View {
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
                ForEach(TemplateField.availableFields, id: \.key) { f in
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
