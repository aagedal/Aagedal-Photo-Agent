import SwiftUI
import UniformTypeIdentifiers

struct CodeReplacementSettingsView: View {
    @Bindable var store: CodeReplacementSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingSource = false
    @State private var importError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Code Replacement") {
                    Toggle("Enabled", isOn: Binding(
                        get: { store.configuration.isEnabled },
                        set: { store.setEnabled($0) }
                    ))

                    LabeledContent("Start delimiter") {
                        TextField("Required", text: Binding(
                            get: { store.configuration.startDelimiter },
                            set: { store.setStartDelimiter($0) }
                        ))
                        .frame(width: 120)
                    }
                    LabeledContent("End delimiter") {
                        TextField("Required", text: Binding(
                            get: { store.configuration.endDelimiter },
                            set: { store.setEndDelimiter($0) }
                        ))
                        .frame(width: 120)
                    }

                    Text("Matching is case-sensitive and exact. Double either delimiter in caption text to insert it literally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("UTF-8 Tab List") {
                    LabeledContent("Source") {
                        Text(store.configuration.source?.displayName ?? "Not selected")
                            .lineLimit(1)
                    }
                    if let path = store.configuration.source?.path {
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("Choose File…") { choosingSource = true }
                        Button("Reload") { store.reloadSource() }
                            .disabled(store.configuration.source == nil)
                        Button("Remove", role: .destructive) { store.removeSource() }
                            .disabled(store.configuration.source == nil)
                    }

                    if let sourceLoadError = store.sourceLoadError {
                        Label(sourceLoadError, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }

                    if store.list.diagnostics.isEmpty, store.configuration.source != nil,
                       store.sourceLoadError == nil {
                        Label("\(store.list.entries.count) codes loaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(Array(store.list.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Label {
                                Text(diagnosticMessage(diagnostic))
                            } icon: {
                                Image(systemName: diagnostic.severity == .error
                                    ? "xmark.octagon.fill"
                                    : "exclamationmark.triangle.fill")
                            }
                            .font(.caption)
                            .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
                        }
                    }
                }

                Section("Format") {
                    Text("Each nonblank line must contain exactly two columns: code, one tab, and replacement. UTF-8 BOM and CRLF/LF/CR line endings are accepted. Quoted, multiline, and tab-containing values are intentionally rejected with diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 540)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .fileImporter(
            isPresented: $choosingSource,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            do {
                try store.selectSource(url)
            } catch {
                importError = "The selected code-replacement file could not be bookmarked or read."
            }
        }
        .alert("Code Replacement Source", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func diagnosticMessage(_ diagnostic: CodeReplacementDiagnostic) -> String {
        let prefix = diagnostic.line.map { "Line \($0): " } ?? ""
        switch diagnostic.kind {
        case .invalidUTF8:
            return "The source is not valid UTF-8."
        case let .malformedRow(columnCount):
            return "\(prefix)expected 2 tab-delimited columns, found \(columnCount)."
        case .emptyCode:
            return "\(prefix)the code is empty."
        case let .emptyValue(code):
            return "\(prefix)the replacement for “\(code)” is empty."
        case let .duplicateCode(code, originalLine):
            return "\(prefix)“\(code)” duplicates line \(originalLine) with the same value."
        case let .ambiguousCode(code, originalLine):
            return "\(prefix)“\(code)” conflicts with line \(originalLine) and will never expand."
        }
    }
}

struct CodeReplacementApplyPreviewView: View {
    let result: CaptionCodeReplacementResult
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Code Replacement Preview")
                        .font(.title3.weight(.semibold))
                    Text("Only caption-style text fields are included. No selection or image metadata changes until Apply is clicked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(result.fields, id: \.field) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(field.field.displayName)
                                    .font(.headline)
                                Spacer()
                                Text(field.changed ? "\(field.replacements.count) replacement(s)" : "Unchanged")
                                    .font(.caption)
                                    .foregroundStyle(field.changed ? Color.accentColor : Color.secondary)
                            }

                            previewText("Before", field.originalText)
                            previewText("After", field.proposedText)
                        }
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    onApply()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(result.status != .completed || !result.changed)
            }
            .padding()
        }
        .frame(width: 620, height: 600)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func previewText(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "—" : text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }
}
