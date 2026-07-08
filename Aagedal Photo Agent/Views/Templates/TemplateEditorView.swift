import AppKit
import SwiftUI

struct TemplateEditorView: View {
    @Bindable var viewModel: TemplateViewModel

    @State private var isShowingVariableReference = false
    @State private var activeFieldID: UUID?
    @State private var fieldSelections: [UUID: NSRange] = [:]
    @FocusState private var focusedTemplateValueFieldID: UUID?

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
                        let fieldID = field.id
                        templateValueField(for: $field, fieldID: fieldID)

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
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard let activeFieldID,
                  focusedTemplateValueFieldID == activeFieldID,
                  let editor = notification.object as? NSTextView else {
                return
            }
            fieldSelections[activeFieldID] = editor.selectedRange()
        }
        .onChange(of: focusedTemplateValueFieldID) { _, newValue in
            guard let newValue else { return }
            activeFieldID = newValue
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                fieldSelections[newValue] = editor.selectedRange()
            }
        }
    }

    @ViewBuilder
    private func templateValueField(for field: Binding<TemplateField>, fieldID: UUID) -> some View {
        if isMultilineTemplateField(field.wrappedValue.fieldKey) {
            TextField("Template value", text: field.templateValue, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($focusedTemplateValueFieldID, equals: fieldID)
                .onTapGesture {
                    activeFieldID = fieldID
                }
                .onSubmit {
                    activeFieldID = fieldID
                }
        } else {
            TextField("Template value", text: field.templateValue)
                .textFieldStyle(.roundedBorder)
                .focused($focusedTemplateValueFieldID, equals: fieldID)
                .onTapGesture {
                    activeFieldID = fieldID
                }
                .onSubmit {
                    activeFieldID = fieldID
                }
        }
    }

    private func isMultilineTemplateField(_ fieldKey: String) -> Bool {
        fieldKey == "description" || fieldKey == "extendedDescription"
    }

    @ViewBuilder
    private func variableMenu(for field: Binding<TemplateField>) -> some View {
        let fieldID = field.wrappedValue.id
        Menu {
            Section("Date") {
                Button("{date} — today, medium format") {
                    insertVariable("{date}", into: field)
                }
                Button("{date:yyyy-MM-dd}") {
                    insertVariable("{date:yyyy-MM-dd}", into: field)
                }
                Button("{date:dd MMM yyyy}") {
                    insertVariable("{date:dd MMM yyyy}", into: field)
                }
                Button("{date:dd.MM.yyyy}") {
                    insertVariable("{date:dd.MM.yyyy}", into: field)
                }
                Button("{date:yyyy}") {
                    insertVariable("{date:yyyy}", into: field)
                }
                Button("{dateCreated} — metadata") {
                    insertVariable("{dateCreated}", into: field)
                }
                Button("{dateCaptured} — EXIF DateTimeOriginal") {
                    insertVariable("{dateCaptured}", into: field)
                }
                Button("{dateCaptured:yyyy-MM-dd}") {
                    insertVariable("{dateCaptured:yyyy-MM-dd}", into: field)
                }
                Button("{dateCaptured:YYYYMMDD}") {
                    insertVariable("{dateCaptured:YYYYMMDD}", into: field)
                }
                Button("{dateCaptured:DDMMYYYY}") {
                    insertVariable("{dateCaptured:DDMMYYYY}", into: field)
                }
                Button("{dateCaptured:YYYY-MM-DD}") {
                    insertVariable("{dateCaptured:YYYY-MM-DD}", into: field)
                }
                Button("{dateCaptured:DD-MM-YYYY}") {
                    insertVariable("{dateCaptured:DD-MM-YYYY}", into: field)
                }
            }

            Section("Shortcuts") {
                Button("{persons} — Person Shown names") {
                    insertVariable("{persons}", into: field)
                }
                Button("{keywords} — Keywords list") {
                    insertVariable("{keywords}", into: field)
                }
                Button("{filename} — Image filename") {
                    insertVariable("{filename}", into: field)
                }
            }

            Section("Field Reference") {
                ForEach(TemplateField.availableFields, id: \.key) { f in
                    Button("{field:\(f.key)}") {
                        insertVariable("{field:\(f.key)}", into: field)
                    }
                }
            }
        } label: {
            Image(systemName: "curlybraces")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .onTapGesture {
            activeFieldID = fieldID
            if focusedTemplateValueFieldID == fieldID,
               let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                fieldSelections[fieldID] = editor.selectedRange()
            }
        }
    }

    private func insertVariable(_ variable: String, into field: Binding<TemplateField>) {
        let fieldID = field.wrappedValue.id
        activeFieldID = fieldID
        let current = field.wrappedValue.templateValue
        if focusedTemplateValueFieldID == fieldID,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            fieldSelections[fieldID] = editor.selectedRange()
        }
        let selection = clampedSelection(
            fieldSelections[fieldID] ?? NSRange(location: current.utf16.count, length: 0),
            maxLength: current.utf16.count
        )
        let (updated, newSelection) = insertText(variable, into: current, selection: selection)
        field.wrappedValue.templateValue = updated
        fieldSelections[fieldID] = newSelection
        if focusedTemplateValueFieldID == fieldID,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.selectedRange = newSelection
        }
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
}
