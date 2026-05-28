import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Export selection

/// Sheet that lets the user pick which lists go into the export bundle, then
/// writes the archive via `KeywordListsArchive.exportSelected`.
struct KeywordListsExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Reported to the parent once the export completes (or fails). The caller
    /// is expected to surface this in its own UI.
    var onCompletion: (Result<Int, Error>) -> Void

    @State private var selection: Set<KeywordListKey> = []
    @State private var feedback: String?

    /// Lists that actually have content in the store today. We never offer
    /// empty lists for export — the bundle should describe meaningful data only.
    private var availableEntries: [(key: KeywordListKey, count: Int)] {
        let store = KeywordListsStore.shared
        var rows: [(KeywordListKey, Int)] = []
        for type in QuickListType.allCases where store.exists(.quick(type)) {
            rows.append((.quick(type), store.readEntries(.quick(type)).count))
        }
        for field in ApprovedListField.allCases where store.exists(.approved(field)) {
            rows.append((.approved(field), store.readEntries(.approved(field)).count))
        }
        if store.exists(.structured) {
            let text = store.readText(.structured) ?? ""
            let count = StructuredKeywordParser.parseString(text)
                .reduce(0) { $0 + countKeywords(in: $1) }
            rows.append((.structured, count))
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380, idealHeight: 460)
        .onAppear {
            // Default to all available lists selected.
            selection = Set(availableEntries.map { $0.key })
        }
    }

    private var header: some View {
        HStack {
            Text("Export Keyword Lists").font(.headline)
            Spacer()
            Text("\(selection.count) of \(availableEntries.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if availableEntries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("No lists to export").font(.headline)
                Text("Add entries via the Quick Lists, Approved Keywords, or Structured Keywords editors, then come back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(availableEntries, id: \.key.relativePath) { entry in
                        Toggle(isOn: Binding(
                            get: { selection.contains(entry.key) },
                            set: { isOn in
                                if isOn { selection.insert(entry.key) }
                                else { selection.remove(entry.key) }
                            }
                        )) {
                            HStack {
                                Text(entry.key.displayName)
                                Spacer()
                                Text("\(entry.count) \(entry.count == 1 ? "entry" : "entries")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    HStack {
                        Button("Select All") {
                            selection = Set(availableEntries.map { $0.key })
                        }
                        .buttonStyle(.borderless)
                        Button("Select None") {
                            selection.removeAll()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") {
                runExport()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Keyword Lists.zip"
        panel.message = "Export the selected lists as a single bundle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let exported = try KeywordListsArchive.exportSelected(selection, to: url)
            onCompletion(.success(exported))
            dismiss()
        } catch {
            feedback = "Export failed: \(error.localizedDescription)"
            onCompletion(.failure(error))
        }
    }

    private func countKeywords(in node: StructuredKeyword) -> Int {
        var n = node.isKeyword ? 1 : 0
        for child in node.children { n += countKeywords(in: child) }
        return n
    }
}

// MARK: - Import selection

/// Sheet that reads an archive's manifest and lets the user pick a per-list
/// import mode (Replace / Append / Skip) before committing.
struct KeywordListsImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: URL
    var onCompletion: (Result<Int, Error>) -> Void

    @State private var preview: KeywordListsArchive.ManifestPreview?
    @State private var choices: [KeywordListKey: KeywordListsArchive.ImportMode] = [:]
    @State private var localCounts: [KeywordListKey: Int] = [:]
    @State private var loadError: String?
    @State private var feedback: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 380, idealHeight: 500)
        .onAppear { loadPreview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Import Keyword Lists").font(.headline)
                Spacer()
                if let preview {
                    Text("\(preview.entries.count) \(preview.entries.count == 1 ? "list" : "lists") in archive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(source.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text("Could not read archive").font(.headline)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview, preview.entries.isEmpty {
            Text("Archive contains no recognized lists.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview {
            List {
                Section {
                    ForEach(preview.entries) { entry in
                        importRow(entry: entry)
                    }
                } footer: {
                    HStack(spacing: 8) {
                        Button("All: Replace") { applyToAll(.replace) }
                            .buttonStyle(.borderless)
                        Button("All: Append") { applyToAll(.append) }
                            .buttonStyle(.borderless)
                        Button("All: Skip") { applyToAll(.skip) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ProgressView("Reading archive…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func importRow(entry: KeywordListsArchive.ManifestPreview.Entry) -> some View {
        let key = entry.key
        let localCount = localCounts[key] ?? 0
        let isStructured = (key == .structured)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(key.displayName)
                Text("\(entry.entryCount) in archive · \(localCount) local")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { choices[key] ?? defaultMode(for: key) },
                set: { choices[key] = $0 }
            )) {
                Text("Replace").tag(KeywordListsArchive.ImportMode.replace)
                if !isStructured {
                    Text("Append").tag(KeywordListsArchive.ImportMode.append)
                }
                Text("Skip").tag(KeywordListsArchive.ImportMode.skip)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import") { runImport() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canImport: Bool {
        guard let preview, !preview.entries.isEmpty else { return false }
        return preview.entries.contains { (choices[$0.key] ?? defaultMode(for: $0.key)) != .skip }
    }

    // MARK: - Logic

    private func loadPreview() {
        do {
            let p = try KeywordListsArchive.inspect(source)
            preview = p
            for entry in p.entries {
                localCounts[entry.key] = localEntryCount(for: entry.key)
                choices[entry.key] = defaultMode(for: entry.key)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func localEntryCount(for key: KeywordListKey) -> Int {
        let store = KeywordListsStore.shared
        switch key {
        case .structured:
            let text = store.readText(.structured) ?? ""
            return StructuredKeywordParser.parseString(text).reduce(0) { $0 + countKeywords(in: $1) }
        case .quick, .approved:
            return store.readEntries(key).count
        }
    }

    /// Sensible default: Append when there's something local to preserve, else
    /// Replace. The structured tree always defaults to Replace (Append isn't
    /// well-defined for the tab-indented format).
    private func defaultMode(for key: KeywordListKey) -> KeywordListsArchive.ImportMode {
        if key == .structured { return .replace }
        return (localCounts[key] ?? 0) > 0 ? .append : .replace
    }

    private func applyToAll(_ mode: KeywordListsArchive.ImportMode) {
        guard let preview else { return }
        for entry in preview.entries {
            // `.append` doesn't apply to structured — fall back to Replace.
            if entry.key == .structured && mode == .append {
                choices[entry.key] = .replace
            } else {
                choices[entry.key] = mode
            }
        }
    }

    private func runImport() {
        do {
            let imported = try KeywordListsArchive.importSelected(from: source, choices: choices)
            onCompletion(.success(imported))
            dismiss()
        } catch {
            feedback = "Import failed: \(error.localizedDescription)"
            onCompletion(.failure(error))
        }
    }

    private func countKeywords(in node: StructuredKeyword) -> Int {
        var n = node.isKeyword ? 1 : 0
        for child in node.children { n += countKeywords(in: child) }
        return n
    }
}
