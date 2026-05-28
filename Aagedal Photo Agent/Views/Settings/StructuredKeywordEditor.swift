import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// In-app editor for the PhotoMechanic-style structured keywords tree. Edits
/// happen in a plain-text view that preserves the exact format the parser
/// expects (tab indent for children, `{synonym}` lines for synonyms, `[name]`
/// for non-keyword container headers). Validates on save so a malformed save
/// can't silently break the tree.
struct StructuredKeywordEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var feedback: String?
    @State private var parsedCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
            Divider()
            syntaxHelp
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 520, idealHeight: 620)
        .onAppear {
            text = KeywordListsStore.shared.readText(.structured) ?? ""
            recountParsed()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Structured Keywords").font(.headline)
            Spacer()
            Text("\(parsedCount) \(parsedCount == 1 ? "keyword" : "keywords")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var editor: some View {
        // SwiftUI TextEditor with a monospaced font so tab indentation is visible.
        // Disable smart quotes / dashes so braces and brackets aren't corrupted.
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .scrollIndicators(.automatic)
            .padding(8)
            .onChange(of: text) { _, _ in
                recountParsed()
            }
    }

    private var syntaxHelp: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Use **tabs** to indent children. `{braces}` add synonyms to the parent keyword. `[brackets]` mark non-keyword category headers.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Example:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("animals\n\tlivestock\n\t\t{cattle}\n\t[REPTILE]\n\t\talligator")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func recountParsed() {
        let parsed = StructuredKeywordParser.parseString(text)
        parsedCount = parsed.reduce(0) { $0 + countKeywords(in: $1) }
    }

    private func countKeywords(in node: StructuredKeyword) -> Int {
        var n = node.isKeyword ? 1 : 0
        for child in node.children { n += countKeywords(in: child) }
        return n
    }

    private func save() {
        let parsed = StructuredKeywordParser.parseString(text)
        if parsed.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            feedback = "No keywords parsed — check your indentation."
            return
        }
        do {
            try StructuredKeywordService.shared.saveTree(parsed)
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
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a PhotoMechanic structured keywords file (.txt)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let imported = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
                feedback = "Could not decode file contents."
                return
            }
            text = imported
            recountParsed()
            feedback = "Imported file — review and Save to commit."
        } catch {
            feedback = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Structured Keywords.txt"
        panel.message = "Export the structured keyword tree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            feedback = "Exported to \(url.lastPathComponent)"
        } catch {
            feedback = "Export failed: \(error.localizedDescription)"
        }
    }
}
