import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// In-app tree editor for the PhotoMechanic-style structured keywords list.
/// The user works only with words and relationships — the on-disk tab-indented
/// `{synonym}` / `[container]` syntax is rendered by `StructuredKeywordSerializer`
/// when the tree is saved.
///
/// Keyboard:
/// - Up / Down — change focused row
/// - Right / Left — expand / collapse a node with children (Left on a leaf jumps to parent)
/// - Return — add a sibling below the focused row
/// - Tab — indent (make a child of previous sibling)
/// - Shift-Tab — outdent (move out of parent)
/// - Backspace (when name empty) — delete the focused row
/// - Cmd-Enter — save and close
struct StructuredKeywordEditor: View {
    @Environment(\.dismiss) private var dismiss

    /// Which tree this editor loads and saves. Defaults to the keyword tree;
    /// the Person Shown editor passes `.personShown`.
    var service: StructuredKeywordService = .shared
    /// Title shown in the editor header.
    var title: String = "Structured Keywords"
    /// Capitalized noun for a leaf node, used in buttons/menus ("Add \(leafNoun)").
    var leafNoun: String = "Keyword"
    /// Default filename offered when exporting the tree.
    var exportFilename: String = "Structured Keywords.txt"

    private var leafNounLower: String { leafNoun.lowercased() }

    /// The synthetic root whose `children` are the file's top-level nodes.
    @State private var root: EditableStructuredKeyword = EditableStructuredKeyword(name: "", kind: .container)
    @State private var expandedIDs: Set<UUID> = []
    @State private var focusedID: UUID?
    @State private var renamingID: UUID?
    @State private var synonymPopoverFor: UUID?
    @State private var feedback: String?
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            treeList
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .onAppear {
            load()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Spacer()
            Text("\(keywordCount) \(keywordCount == 1 ? leafNounLower : leafNounLower + "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                addTopLevel(kind: .keyword)
            } label: {
                Label("Add \(leafNoun)", systemImage: "tag")
            }
            .help("Add a top-level \(leafNounLower) (\\u2318N)")
            .keyboardShortcut("n", modifiers: .command)
            Button {
                addTopLevel(kind: .container)
            } label: {
                Label("Add Category", systemImage: "folder")
            }
            .help("Add a top-level [bracketed] category that groups keywords without itself being one")
            Spacer()
            Button("Import from File…") { importFromFile() }
            Button("Export to File…") { exportToFile() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var treeList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(visibleRows(), id: \.id) { node in
                    row(for: node)
                        .id(node.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: focusedID) { _, newValue in
                if let newValue {
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
            .onKeyPress(.upArrow) { moveFocus(by: -1) }
            .onKeyPress(.downArrow) { moveFocus(by: +1) }
            .onKeyPress(.rightArrow) { expandOrDescend() }
            .onKeyPress(.leftArrow) { collapseOrAscend() }
            .onKeyPress(.return) { addSiblingViaShortcut() }
            .onKeyPress(.tab) { indentFocused() }
            .onKeyPress(keys: ["\u{19}"]) { _ in shiftTabOutdent() } // Shift-Tab
            .onKeyPress(.delete) { deleteFocusedIfRenameEmpty() }
        }
        .overlay {
            if root.children.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No \(leafNounLower)s yet")
                .font(.headline)
            Text("Click **Add \(leafNoun)** above (or press \\u2318N) to start building your tree. Use Tab to indent a row as a child of the row above it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
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
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for node: EditableStructuredKeyword) -> some View {
        let isFocused = (focusedID == node.id)
        let isRenaming = (renamingID == node.id)
        let depth = node.depthFromRoot
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(max(0, depth)) * 16)
            if node.hasChildren {
                Button {
                    toggleExpand(node)
                } label: {
                    Image(systemName: expandedIDs.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            // Kind icon (also a button to toggle keyword <-> category)
            Button {
                node.kind = node.isKeyword ? .container : .keyword
            } label: {
                Image(systemName: node.isContainer ? "folder" : "tag")
                    .foregroundStyle(node.isContainer ? .secondary : .primary)
                    .font(.caption)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(node.isContainer ? "Category (won't be applied as a keyword). Click to make it a keyword." : "Keyword. Click to make it a category.")

            // Name
            if isRenaming {
                TextField("Name", text: Binding(
                    get: { node.name },
                    set: { node.name = $0 }
                ), onCommit: {
                    renamingID = nil
                })
                .textFieldStyle(.plain)
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                .onSubmit { renamingID = nil }
                .onExitCommand { cancelRename(node) }
            } else {
                Text(node.name.isEmpty ? "(empty)" : node.name)
                    .foregroundStyle(node.name.isEmpty ? .secondary : (node.isContainer ? .secondary : .primary))
                    .italic(node.isContainer)
                    .onTapGesture(count: 2) { startRename(node) }
            }

            // Synonym summary
            if !node.synonyms.isEmpty {
                Button {
                    synonymPopoverFor = node.id
                } label: {
                    Text("\(node.synonyms.count) syn")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(node.synonyms.joined(separator: ", "))
            }

            Spacer()

            rowActions(node)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture {
            focusedID = node.id
        }
        .popover(isPresented: Binding(
            get: { synonymPopoverFor == node.id },
            set: { if !$0 { synonymPopoverFor = nil } }
        )) {
            SynonymEditorPopover(node: node)
        }
        .contextMenu {
            rowMenu(for: node)
        }
    }

    @ViewBuilder
    private func rowActions(_ node: EditableStructuredKeyword) -> some View {
        Menu {
            rowMenu(for: node)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Row actions")
    }

    @ViewBuilder
    private func rowMenu(for node: EditableStructuredKeyword) -> some View {
        Button("Rename") { startRename(node) }
        Button("Add Synonym…") { synonymPopoverFor = node.id }
        Divider()
        Button("Add Child \(leafNoun)") { addChild(under: node, kind: .keyword) }
        Button("Add Child Category") { addChild(under: node, kind: .container) }
        Button("Add Sibling Below") { addSibling(below: node) }
        Divider()
        Button("Indent (make child of previous sibling)") { indent(node) }
            .disabled(!canIndent(node))
        Button("Outdent (move out of parent)") { outdent(node) }
            .disabled(!canOutdent(node))
        Button("Move Up") { moveUp(node) }
            .disabled(!canMoveUp(node))
        Button("Move Down") { moveDown(node) }
            .disabled(!canMoveDown(node))
        Divider()
        Button(node.isContainer ? "Convert to \(leafNoun)" : "Convert to Category") {
            node.kind = node.isKeyword ? .container : .keyword
        }
        Divider()
        Button("Delete", role: .destructive) { delete(node) }
    }

    // MARK: - Visible-row flattening

    private func visibleRows() -> [EditableStructuredKeyword] {
        var rows: [EditableStructuredKeyword] = []
        for child in root.children {
            appendRows(child, into: &rows)
        }
        return rows
    }

    private func appendRows(_ node: EditableStructuredKeyword, into rows: inout [EditableStructuredKeyword]) {
        rows.append(node)
        if expandedIDs.contains(node.id) {
            for child in node.children {
                appendRows(child, into: &rows)
            }
        }
    }

    private var keywordCount: Int {
        countKeywords(in: root)
    }

    private func countKeywords(in node: EditableStructuredKeyword) -> Int {
        var n = (node !== root && node.isKeyword) ? 1 : 0
        for child in node.children { n += countKeywords(in: child) }
        return n
    }

    // MARK: - Tree edits

    private func addTopLevel(kind: StructuredKeyword.Kind) {
        let new = EditableStructuredKeyword(name: "", kind: kind, parent: root)
        root.children.append(new)
        focusedID = new.id
        startRename(new)
    }

    private func addChild(under parent: EditableStructuredKeyword, kind: StructuredKeyword.Kind) {
        let new = EditableStructuredKeyword(name: "", kind: kind, parent: parent)
        parent.children.append(new)
        expandedIDs.insert(parent.id)
        focusedID = new.id
        startRename(new)
    }

    private func addSibling(below node: EditableStructuredKeyword) {
        guard let parent = node.parent,
              let idx = parent.children.firstIndex(where: { $0 === node }) else { return }
        let new = EditableStructuredKeyword(name: "", kind: node.kind, parent: parent)
        parent.children.insert(new, at: idx + 1)
        focusedID = new.id
        startRename(new)
    }

    private func canIndent(_ node: EditableStructuredKeyword) -> Bool {
        guard let parent = node.parent,
              let idx = parent.children.firstIndex(where: { $0 === node }),
              idx > 0
        else { return false }
        return true
    }

    private func indent(_ node: EditableStructuredKeyword) {
        guard
            let parent = node.parent,
            let idx = parent.children.firstIndex(where: { $0 === node }),
            idx > 0
        else { return }
        let newParent = parent.children[idx - 1]
        parent.children.remove(at: idx)
        node.parent = newParent
        newParent.children.append(node)
        expandedIDs.insert(newParent.id)
    }

    private func canOutdent(_ node: EditableStructuredKeyword) -> Bool {
        guard let parent = node.parent, parent !== root else { return false }
        return true
    }

    private func outdent(_ node: EditableStructuredKeyword) {
        guard
            let parent = node.parent,
            parent !== root,
            let grand = parent.parent,
            let parentIdx = grand.children.firstIndex(where: { $0 === parent }),
            let idx = parent.children.firstIndex(where: { $0 === node })
        else { return }
        parent.children.remove(at: idx)
        node.parent = grand
        grand.children.insert(node, at: parentIdx + 1)
    }

    private func canMoveUp(_ node: EditableStructuredKeyword) -> Bool {
        guard let parent = node.parent,
              let idx = parent.children.firstIndex(where: { $0 === node }),
              idx > 0
        else { return false }
        return true
    }

    private func moveUp(_ node: EditableStructuredKeyword) {
        guard
            let parent = node.parent,
            let idx = parent.children.firstIndex(where: { $0 === node }),
            idx > 0
        else { return }
        parent.children.swapAt(idx, idx - 1)
    }

    private func canMoveDown(_ node: EditableStructuredKeyword) -> Bool {
        guard let parent = node.parent,
              let idx = parent.children.firstIndex(where: { $0 === node }),
              idx + 1 < parent.children.count
        else { return false }
        return true
    }

    private func moveDown(_ node: EditableStructuredKeyword) {
        guard
            let parent = node.parent,
            let idx = parent.children.firstIndex(where: { $0 === node }),
            idx + 1 < parent.children.count
        else { return }
        parent.children.swapAt(idx, idx + 1)
    }

    private func delete(_ node: EditableStructuredKeyword) {
        guard
            let parent = node.parent,
            let idx = parent.children.firstIndex(where: { $0 === node })
        else { return }
        parent.children.remove(at: idx)
        if focusedID == node.id {
            focusedID = parent.children[safe: idx]?.id
                ?? parent.children.last?.id
                ?? (parent !== root ? parent.id : nil)
        }
    }

    private func toggleExpand(_ node: EditableStructuredKeyword) {
        if expandedIDs.contains(node.id) { expandedIDs.remove(node.id) }
        else { expandedIDs.insert(node.id) }
    }

    private func startRename(_ node: EditableStructuredKeyword) {
        focusedID = node.id
        renamingID = node.id
        renameFieldFocused = true
    }

    /// Exits rename mode on Esc. If the node was never given a name (and has no
    /// children), it's a leftover blank row from an aborted add — remove it
    /// rather than leave an empty keyword in the list.
    private func cancelRename(_ node: EditableStructuredKeyword) {
        renamingID = nil
        if node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && node.children.isEmpty {
            delete(node)
        }
    }

    // MARK: - Keyboard helpers

    private func moveFocus(by delta: Int) -> KeyPress.Result {
        let rows = visibleRows()
        guard !rows.isEmpty else { return .ignored }
        if let id = focusedID, let idx = rows.firstIndex(where: { $0.id == id }) {
            let next = (idx + delta).clamped(to: 0...(rows.count - 1))
            focusedID = rows[next].id
        } else {
            focusedID = rows[0].id
        }
        renamingID = nil
        return .handled
    }

    private func expandOrDescend() -> KeyPress.Result {
        guard let id = focusedID, let node = findNode(id: id, in: root) else { return .ignored }
        if node.hasChildren {
            if !expandedIDs.contains(node.id) {
                expandedIDs.insert(node.id)
            } else if let first = node.children.first {
                focusedID = first.id
            }
            return .handled
        }
        return .ignored
    }

    private func collapseOrAscend() -> KeyPress.Result {
        guard let id = focusedID, let node = findNode(id: id, in: root) else { return .ignored }
        if node.hasChildren && expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
            return .handled
        }
        if let parent = node.parent, parent !== root {
            focusedID = parent.id
            return .handled
        }
        return .ignored
    }

    private func addSiblingViaShortcut() -> KeyPress.Result {
        guard let id = focusedID, let node = findNode(id: id, in: root) else {
            addTopLevel(kind: .keyword)
            return .handled
        }
        addSibling(below: node)
        return .handled
    }

    private func indentFocused() -> KeyPress.Result {
        guard let id = focusedID, let node = findNode(id: id, in: root), canIndent(node) else { return .ignored }
        indent(node)
        return .handled
    }

    private func shiftTabOutdent() -> KeyPress.Result {
        guard let id = focusedID, let node = findNode(id: id, in: root), canOutdent(node) else { return .ignored }
        outdent(node)
        return .handled
    }

    private func deleteFocusedIfRenameEmpty() -> KeyPress.Result {
        guard let id = focusedID, let node = findNode(id: id, in: root) else { return .ignored }
        // Only delete on a bare-Delete press when the row is empty; otherwise
        // Delete is left to the text field.
        if renamingID == node.id, !node.name.isEmpty { return .ignored }
        delete(node)
        return .handled
    }

    private func findNode(id: UUID, in node: EditableStructuredKeyword) -> EditableStructuredKeyword? {
        if node.id == id, node !== root { return node }
        for child in node.children {
            if let hit = findNode(id: id, in: child) { return hit }
        }
        return nil
    }

    // MARK: - Load / Save / Import / Export

    private func load() {
        let parsed = service.roots
        root = EditableStructuredKeyword.root(from: parsed)
        // Expand the first level by default so the user immediately sees structure.
        for child in root.children where child.hasChildren {
            expandedIDs.insert(child.id)
        }
        focusedID = root.children.first?.id
    }

    private func save() {
        // Drop empty-name nodes before serialising. This is forgiving — the user
        // can't accidentally lose a real node, only blanks they left behind.
        let cleaned = root.snapshotChildren().compactMap { strip($0) }
        do {
            try service.saveTree(cleaned)
            dismiss()
        } catch {
            feedback = "Save failed: \(error.localizedDescription)"
        }
    }

    private func strip(_ node: StructuredKeyword) -> StructuredKeyword? {
        let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedChildren = node.children.compactMap { strip($0) }
        if name.isEmpty && cleanedChildren.isEmpty { return nil }
        return StructuredKeyword(
            id: node.id,
            name: name,
            kind: node.kind,
            synonyms: node.synonyms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            children: cleanedChildren
        )
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
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
                feedback = "Could not decode file contents."
                return
            }
            let parsed = StructuredKeywordParser.parseString(text)
            root = EditableStructuredKeyword.root(from: parsed)
            for child in root.children where child.hasChildren {
                expandedIDs.insert(child.id)
            }
            focusedID = root.children.first?.id
            feedback = "Imported \(parsed.count) top-level entries — review and Save to commit."
        } catch {
            feedback = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = exportFilename
        panel.message = "Export the structured tree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = root.snapshotChildren().compactMap { strip($0) }
        let text = StructuredKeywordSerializer.serialize(snapshot)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            feedback = "Exported to \(url.lastPathComponent)"
        } catch {
            feedback = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Synonym editor popover

private struct SynonymEditorPopover: View {
    let node: EditableStructuredKeyword
    @State private var newSynonym: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synonyms for \"\(node.name.isEmpty ? "(unnamed)" : node.name)\"")
                .font(.headline)
            Text("Synonyms travel with the parent keyword when added to an image.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("Add synonym", text: $newSynonym, onCommit: addSynonym)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: addSynonym)
                    .disabled(newSynonym.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if node.synonyms.isEmpty {
                Text("No synonyms yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(Array(node.synonyms.enumerated()), id: \.offset) { idx, synonym in
                        HStack {
                            Text(synonym)
                            Spacer()
                            Button {
                                node.synonyms.remove(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 100, maxHeight: 200)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func addSynonym() {
        let trimmed = newSynonym.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !node.synonyms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            node.synonyms.append(trimmed)
        }
        newSynonym = ""
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
