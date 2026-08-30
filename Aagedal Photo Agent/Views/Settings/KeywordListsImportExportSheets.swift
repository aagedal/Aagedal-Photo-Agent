import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Scope

/// Restricts the import/export sheets to a subset of keyword lists so each
/// settings tab only manages its own lists (the Quick Lists tab handles the
/// quick lists; the Keywords tab handles approved + structured keywords).
enum KeywordListScope {
    /// All quick lists.
    case quickLists
    /// Approved keywords + the structured keyword tree.
    case keywords
    /// Everything (legacy / combined).
    case all

    func includes(_ key: KeywordListKey) -> Bool {
        switch self {
        case .all:
            return true
        case .quickLists:
            if case .quick = key { return true }
            return false
        case .keywords:
            switch key {
            case .approved, .structured, .structuredPersonShown: return true
            case .quick: return false
            }
        }
    }

    var exportTitle: String {
        switch self {
        case .quickLists: return "Export Quick Lists"
        case .keywords: return "Export Keywords"
        case .all: return "Export Keyword Lists"
        }
    }

    var importTitle: String {
        switch self {
        case .quickLists: return "Import Quick Lists"
        case .keywords: return "Import Keywords"
        case .all: return "Import Keyword Lists"
        }
    }

    var exportFileName: String {
        switch self {
        case .quickLists: return "Quick Lists.zip"
        case .keywords: return "Keywords.zip"
        case .all: return "Keyword Lists.zip"
        }
    }

    /// Plural noun used in empty-state messages.
    var noun: String {
        switch self {
        case .quickLists: return "quick lists"
        case .keywords: return "keyword lists"
        case .all: return "lists"
        }
    }
}

// MARK: - Export selection

/// Sheet that lets the user pick which lists go into the export bundle, then
/// writes the archive via `KeywordListsArchive.exportSelected`.
struct KeywordListsExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Restricts which lists this sheet offers (defaults to everything).
    var scope: KeywordListScope = .all

    /// Reported to the parent once the export completes (or fails). The caller
    /// is expected to surface this in its own UI.
    var onCompletion: (Result<Int, Error>) -> Void

    @State private var selection: Set<KeywordListKey> = []
    @State private var feedback: String?

    /// Lists that actually have content in the store today and fall within
    /// `scope`. We never offer empty lists for export — the bundle should
    /// describe meaningful data only.
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
        if store.exists(.structuredPersonShown) {
            let text = store.readText(.structuredPersonShown) ?? ""
            let count = StructuredKeywordParser.parseString(text)
                .reduce(0) { $0 + countKeywords(in: $1) }
            rows.append((.structuredPersonShown, count))
        }
        return rows.filter { scope.includes($0.0) }
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
            Text(scope.exportTitle).font(.headline)
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
        panel.nameFieldStringValue = scope.exportFileName
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
    /// Restricts which lists from the archive this sheet will import.
    var scope: KeywordListScope = .all
    var onCompletion: (Result<Int, Error>) -> Void

    @State private var preview: KeywordListsArchive.ManifestPreview?
    @State private var choices: [KeywordListKey: KeywordListsArchive.ImportMode] = [:]
    @State private var localCounts: [KeywordListKey: Int] = [:]
    @State private var loadError: String?
    @State private var feedback: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequestID: UUID?

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
        .onDisappear { cancelPreview() }
    }

    /// Archive entries that fall within this sheet's scope.
    private func scopedEntries(_ preview: KeywordListsArchive.ManifestPreview) -> [KeywordListsArchive.ManifestPreview.Entry] {
        preview.entries.filter { scope.includes($0.key) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(scope.importTitle).font(.headline)
                Spacer()
                if let preview {
                    let count = scopedEntries(preview).count
                    Text("\(count) \(count == 1 ? "list" : "lists") in archive")
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
        } else if let preview, scopedEntries(preview).isEmpty {
            Text("Archive contains no \(scope.noun) to import.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview {
            List {
                Section {
                    ForEach(scopedEntries(preview)) { entry in
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
        let isStructured = (key == .structured || key == .structuredPersonShown)
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
        guard let preview else { return false }
        let entries = scopedEntries(preview)
        guard !entries.isEmpty else { return false }
        return entries.contains { (choices[$0.key] ?? defaultMode(for: $0.key)) != .skip }
    }

    // MARK: - Logic

    private func loadPreview() {
        previewTask?.cancel()
        let requestID = UUID()
        previewRequestID = requestID
        preview = nil
        choices.removeAll()
        localCounts.removeAll()
        loadError = nil

        previewTask = Task {
            do {
                let result = try await KeywordListsArchivePreviewService.shared.loadPreview(
                    from: source,
                    requestID: requestID
                )
                guard previewRequestID == requestID else { return }
                previewTask = nil
                previewRequestID = nil

                switch result {
                case .loaded(let snapshot):
                    let loadedPreview = KeywordListsArchive.manifestPreview(from: snapshot.payload)
                    preview = loadedPreview
                    // Only stage choices for in-scope entries; anything else stays absent
                    // from `choices` and is treated as skip by `importSelected`.
                    for entry in scopedEntries(loadedPreview) {
                        localCounts[entry.key] = localEntryCount(for: entry.key)
                        choices[entry.key] = defaultMode(for: entry.key)
                    }
                case .cancelledBeforeInspection, .cancelledAfterInspection:
                    break
                }
            } catch is CancellationError {
                guard previewRequestID == requestID else { return }
                previewTask = nil
                previewRequestID = nil
            } catch {
                guard previewRequestID == requestID else { return }
                previewTask = nil
                previewRequestID = nil
                loadError = error.localizedDescription
            }
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = nil
    }

    private func localEntryCount(for key: KeywordListKey) -> Int {
        let store = KeywordListsStore.shared
        switch key {
        case .structured, .structuredPersonShown:
            let text = store.readText(key) ?? ""
            return StructuredKeywordParser.parseString(text).reduce(0) { $0 + countKeywords(in: $1) }
        case .quick, .approved:
            return store.readEntries(key).count
        }
    }

    /// Sensible default: Append when there's something local to preserve, else
    /// Replace. The structured tree always defaults to Replace (Append isn't
    /// well-defined for the tab-indented format).
    private func defaultMode(for key: KeywordListKey) -> KeywordListsArchive.ImportMode {
        if key == .structured || key == .structuredPersonShown { return .replace }
        return (localCounts[key] ?? 0) > 0 ? .append : .replace
    }

    private func applyToAll(_ mode: KeywordListsArchive.ImportMode) {
        guard let preview else { return }
        for entry in scopedEntries(preview) {
            // `.append` doesn't apply to structured — fall back to Replace.
            if (entry.key == .structured || entry.key == .structuredPersonShown) && mode == .append {
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
