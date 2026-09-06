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
    @State private var loadedDestinationURL: URL?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadRequestID: UUID?
    @State private var persistenceTask: Task<Void, Never>?
    @State private var persistenceRequestID: UUID?
    @State private var importTask: Task<Void, Never>?
    @State private var importRequestID: UUID?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportRequestID: UUID?

    /// Indices to highlight from the filtered view back to `entries`. Computed
    /// lazily — recomputed when search text changes.
    private var filteredIndices: [Int] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(entries.indices)
        }
        let needle = searchText.lowercased()
        return entries.indices.filter { entries[$0].lowercased().contains(needle) }
    }

    private var canEdit: Bool { loadedDestinationURL != nil }

    /// Keep body evaluation in memory; validate the route at every mutation boundary.
    private func admitMutation() -> Bool {
        guard let loadedDestinationURL else { return false }
        guard loadedDestinationURL == KeywordListsStore.shared.url(for: storeKey) else {
            loadEntries()
            return false
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            addRow.disabled(!canEdit)
            Divider()
            list.disabled(!canEdit)
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460, idealHeight: 560)
        .onAppear {
            loadEntries()
        }
        .onDisappear {
            loadedDestinationURL = nil
            loadRequestID = nil
            loadTask?.cancel()
            loadTask = nil
            // Do not cancel the latest instant-save when the editor closes. It still owns the
            // user's final mutation, but invalidating its request prevents stale UI publication.
            persistenceRequestID = nil
            persistenceTask = nil
            importRequestID = nil
            importTask?.cancel()
            importTask = nil
            exportRequestID = nil
            exportTask?.cancel()
            exportTask = nil
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
            .disabled(!canEdit)
            if !canEdit, loadTask == nil {
                Button("Retry Load", action: loadEntries)
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
            // Changes are saved instantly on every edit, so closing needs no
            // separate save step. Esc (cancelAction) and the Done button both
            // just dismiss. Plain Return stays reserved for the "Add entry"
            // field's onCommit.
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func loadEntries() {
        loadedDestinationURL = nil
        loadTask?.cancel()
        let requestID = UUID()
        let sourceURL = KeywordListsStore.shared.url(for: storeKey)
        loadRequestID = requestID
        loadTask = Task {
            do {
                let result = try await KeywordListEditorPersistenceService.shared.loadEntries(
                    from: sourceURL,
                    requestID: requestID
                )
                guard loadRequestID == requestID, !Task.isCancelled else { return }
                guard KeywordListsStore.shared.url(for: storeKey) == sourceURL else {
                    loadEntries()
                    return
                }
                loadTask = nil
                loadRequestID = nil
                switch result {
                case .loaded(let snapshot):
                    entries = snapshot.entries
                    loadedDestinationURL = sourceURL
                case .missing:
                    entries = []
                    loadedDestinationURL = sourceURL
                case .cancelledBeforeAccess, .cancelledBeforeRead, .cancelledAfterRead:
                    break
                }
            } catch {
                guard loadRequestID == requestID, !Task.isCancelled else { return }
                loadTask = nil
                loadRequestID = nil
                feedback = "Load failed: \(error.localizedDescription)"
            }
        }
    }

    private func addEntry() {
        guard admitMutation() else { return }
        let trimmed = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !entries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            entries.append(trimmed)
            persist()
        }
        newEntry = ""
    }

    private func remove(at index: Int) {
        guard admitMutation() else { return }
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        persist()
    }

    /// `move` operates on the filtered view's indices, so it only reorders within
    /// the visible subset. When filtered, the relative order of off-screen items
    /// is preserved (we splice the filtered subarray back into the same slots).
    private func move(from source: IndexSet, to destination: Int) {
        guard admitMutation() else { return }
        let visible = filteredIndices
        guard !visible.isEmpty else { return }
        // Build a new array by reordering only the visible subset.
        var visibleEntries = visible.map { entries[$0] }
        visibleEntries.move(fromOffsets: source, toOffset: destination)
        for (offset, originalIdx) in visible.enumerated() {
            entries[originalIdx] = visibleEntries[offset]
        }
        persist()
    }

    /// Persists the current entries through the serialized filesystem owner. Called after every
    /// mutation so the editor saves instantly — there is no explicit Save step.
    private func persist() {
        guard admitMutation() else { return }
        loadRequestID = nil
        loadTask?.cancel()
        loadTask = nil
        persistenceTask?.cancel()

        let requestID = UUID()
        let snapshot = entries
        let destinationURL = KeywordListsStore.shared.url(for: storeKey)
        persistenceRequestID = requestID
        persistenceTask = Task {
            do {
                let result = try await KeywordListEditorPersistenceService.shared.saveEntries(
                    snapshot,
                    to: destinationURL,
                    requestID: requestID
                )
                switch result {
                case .committed(let commit):
                    // Durable effects are published even after dismissal invalidates this view's
                    // request. The approved-list cache can install the exact committed payload
                    // without reading the file again; only UI callbacks remain request-gated.
                    KeywordListsStore.shared.recordExternalWrite(
                        to: storeKey,
                        destinationURL: commit.destinationURL,
                        entries: commit.entries
                    )
                    guard persistenceRequestID == requestID else { return }
                    persistenceTask = nil
                    persistenceRequestID = nil
                    onSaved?(commit.entries.count)
                case .cancelledBeforeCommit:
                    guard persistenceRequestID == requestID else { return }
                    persistenceTask = nil
                    persistenceRequestID = nil
                    feedback = "Save cancelled"
                }
            } catch {
                guard persistenceRequestID == requestID else { return }
                persistenceTask = nil
                persistenceRequestID = nil
                feedback = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    private func importFromFile() {
        guard admitMutation() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.message = "Choose a list file (.txt or .csv)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importTask?.cancel()
        let requestID = UUID()
        let destinationURL = KeywordListsStore.shared.url(for: storeKey)
        importRequestID = requestID
        feedback = "Importing \(url.lastPathComponent)…"
        importTask = Task {
            // Preserve the existing managed entries if the initial load is still in flight.
            await loadTask?.value
            do {
                let snapshot = try await ApprovedListImportService.shared.loadEntries(
                    from: url, requestID: requestID
                )
                guard importRequestID == snapshot.requestID, !Task.isCancelled else { return }
                importTask = nil
                importRequestID = nil
                guard loadedDestinationURL == destinationURL,
                      KeywordListsStore.shared.url(for: storeKey) == destinationURL else {
                    feedback = "List storage changed. Import the file again."
                    loadEntries()
                    return
                }
                var seen = Set(entries.map { $0.lowercased() })
                var added = 0
                for entry in snapshot.entries where seen.insert(entry.lowercased()).inserted {
                    entries.append(entry)
                    added += 1
                }
                feedback = "Imported \(added) new \(added == 1 ? "entry" : "entries")"
                if added > 0 { persist() }
            } catch {
                guard importRequestID == requestID, !Task.isCancelled else { return }
                importTask = nil
                importRequestID = nil
                feedback = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultExportFilename()
        panel.message = "Export this list as a text file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = entries.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        let entryCount = entries.count
        exportTask?.cancel()
        let requestID = UUID()
        exportRequestID = requestID
        feedback = "Exporting \(url.lastPathComponent)…"
        exportTask = Task {
            do {
                let result = try await TextFileExportService.shared.writeText(
                    text,
                    to: url,
                    requestID: requestID
                )
                guard exportRequestID == requestID else { return }
                exportTask = nil
                exportRequestID = nil
                switch result {
                case .committed:
                    feedback = "Exported \(entryCount) entries"
                case .cancelledBeforeWrite:
                    feedback = "Export cancelled"
                }
            } catch {
                guard exportRequestID == requestID else { return }
                exportTask = nil
                exportRequestID = nil
                feedback = "Export failed: \(error.localizedDescription)"
            }
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
        case .structuredPersonShown:
            return "Structured Person Shown.txt"
        }
    }
}
