import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Generic in-app editor for any flat (one-per-line) keyword list — used by the
/// 8 Quick List types and by the Approved Keywords list. Reads/writes through
/// `KeywordListsStore` so iCloud sync (when enabled) propagates automatically.
struct KeywordListEditor: View {
    let title: String
    let storeKey: KeywordListKey
    /// Optional callback invoked after a save with the new entry count.
    var onSaved: ((Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [String] = []
    @State private var newEntry: String = ""
    @State private var searchText: String = ""
    @State private var selection: Set<String> = []
    @State private var feedback: String?

    /// Indices to highlight from the filtered view back to `entries`. Computed
    /// lazily — recomputed when search text changes.
    private var filteredIndices: [Int] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(entries.indices)
        }
        let needle = searchText.lowercased()
        return entries.indices.filter { entries[$0].lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            addRow
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460, idealHeight: 560)
        .onAppear {
            entries = KeywordListsStore.shared.readEntries(storeKey)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Spacer()
            Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            TextField("Add entry", text: $newEntry, onCommit: addEntry)
                .textFieldStyle(.roundedBorder)
            Button("Add", action: addEntry)
                .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            Divider().frame(height: 16)
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                .frame(maxWidth: 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filteredIndices, id: \.self) { idx in
                HStack {
                    Text(entries[idx])
                    Spacer()
                    Button {
                        remove(at: idx)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove entry")
                }
                .tag(entries[idx])
            }
            .onMove(perform: move)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Import from File…") {
                importFromFile()
            }
            Button("Export to File…") {
                exportToFile()
            }
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
            Button("Save") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func addEntry() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !entries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            entries.append(trimmed)
        }
        newEntry = ""
    }

    private func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }

    /// `move` operates on the filtered view's indices, so it only reorders within
    /// the visible subset. When filtered, the relative order of off-screen items
    /// is preserved (we splice the filtered subarray back into the same slots).
    private func move(from source: IndexSet, to destination: Int) {
        let visible = filteredIndices
        guard !visible.isEmpty else { return }
        // Build a new array by reordering only the visible subset.
        var visibleEntries = visible.map { entries[$0] }
        visibleEntries.move(fromOffsets: source, toOffset: destination)
        for (offset, originalIdx) in visible.enumerated() {
            entries[originalIdx] = visibleEntries[offset]
        }
    }

    private func save() {
        do {
            switch storeKey {
            case .approved(let field):
                try ApprovedListService.shared.saveEntries(entries, for: field)
            case .quick, .structured:
                // Writing directly through the store posts `.keywordListChanged`
                // so observers (SettingsViewModel quick-list cache, services)
                // refresh automatically.
                try KeywordListsStore.shared.writeEntries(entries, to: storeKey)
            }
            onSaved?(entries.count)
            dismiss()
        } catch {
            feedback = "Save failed: \(error.localizedDescription)"
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.message = "Choose a list file (.txt or .csv)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ApprovedListParser.parse(url)
            var seen = Set(entries.map { $0.lowercased() })
            var added = 0
            for entry in imported where seen.insert(entry.lowercased()).inserted {
                entries.append(entry)
                added += 1
            }
            feedback = "Imported \(added) new \(added == 1 ? "entry" : "entries")"
        } catch {
            feedback = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultExportFilename()
        panel.message = "Export this list as a text file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            feedback = "Exported \(entries.count) entries"
        } catch {
            feedback = "Export failed: \(error.localizedDescription)"
        }
    }

    private func defaultExportFilename() -> String {
        switch storeKey {
        case .approved(let field):
            return "Approved \(field.displayName).txt"
        case .quick(let type):
            return type.defaultFilename
        case .structured:
            return "Structured Keywords.txt"
        }
    }
}
