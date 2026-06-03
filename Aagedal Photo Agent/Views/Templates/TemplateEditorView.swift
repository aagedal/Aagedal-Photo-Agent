import SwiftUI

struct TemplateEditorView: View {
    @Bindable var viewModel: TemplateViewModel

    @State private var isShowingVariableReference = false
    @State private var activeFieldID: UUID?

    /// Returns field keys that are already used in the template
    private var usedFieldKeys: Set<String> {
        Set(viewModel.editingTemplate.fields.map { $0.fieldKey })
    }

    /// Returns available fields that haven't been added to the template yet
    private var unusedFields: [(key: String, label: String)] {
        TemplateField.availableFields.filter { !usedFieldKeys.contains($0.key) }
    }

    /// Returns fields available for a picker, including the current field's key plus all unused fields
    private func availableFieldsForPicker(currentKey: String) -> [(key: String, label: String)] {
        TemplateField.availableFields.filter { field in
            field.key == currentKey || !usedFieldKeys.contains(field.key)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.isEditingExistingTemplate ? "Edit Template" : "New Template")
                .font(.headline)

            TextField("Template Name", text: $viewModel.editingTemplate.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 20) {
                Picker("Keyboard Shortcut", selection: $viewModel.editingTemplate.shortcutSlot) {
                    Text("None").tag(nil as Int?)
                    ForEach(1...9, id: \.self) { slot in
                        Text("Ctrl+\(slot)").tag(slot as Int?)
                    }
                }
                .frame(width: 240)

                Toggle("Process variables instantly", isOn: $viewModel.editingTemplate.processInstantly)
                    .toggleStyle(.switch)
                    .help("After this template is applied, immediately resolve metadata variables (like {date}, {seq}, {filename}) for the images it was applied to, instead of waiting for a separate Process Variables pass.")
            }

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
                        ForEach(availableFieldsForPicker(currentKey: field.fieldKey), id: \.key) { f in
                            Text(f.label).tag(f.key)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    if field.fieldKey == "digitalSourceType" {
                        // Digital Source Type is an enum — offer its cases as a
                        // dropdown rather than free text. The template stores the
                        // raw value, matching applyTemplateFields' DigitalSourceType(rawValue:).
                        Picker("", selection: Binding(
                            get: { DigitalSourceType(rawValue: $field.templateValue.wrappedValue) },
                            set: { $field.templateValue.wrappedValue = $0?.rawValue ?? "" }
                        )) {
                            Text("None").tag(nil as DigitalSourceType?)
                            ForEach(DigitalSourceType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type as DigitalSourceType?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Template value", text: $field.templateValue)
                            .textFieldStyle(.roundedBorder)

                        variableMenu(for: $field)
                    }

                    let fieldID = field.id
                    Button {
                        viewModel.editingTemplate.fields.removeAll { $0.id == fieldID }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                if let firstUnused = unusedFields.first {
                    viewModel.editingTemplate.fields.append(
                        TemplateField(fieldKey: firstUnused.key, templateValue: "")
                    )
                }
            } label: {
                Label("Add Field", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(unusedFields.isEmpty)

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
                Button("{date} — today, medium format") {
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
                Button("{dateCreated} — metadata") {
                    field.wrappedValue.templateValue += "{dateCreated}"
                }
                Button("{dateCaptured} — EXIF DateTimeOriginal") {
                    field.wrappedValue.templateValue += "{dateCaptured}"
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
