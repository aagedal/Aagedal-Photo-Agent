import SwiftUI

/// Tree picker for the PhotoMechanic-style structured keywords file.
///
/// Mouse: double-click a keyword to add it (with ancestors + synonyms). Click
/// the disclosure triangle on a container to expand/collapse.
///
/// Keyboard:
/// - Up / Down — move focus between visible rows
/// - Right — expand the focused container (or jump to first child if expanded)
/// - Left — collapse the focused container (or jump to parent)
/// - Space / Return — activate the focused keyword (= double-click)
/// - Cmd-Return — activate and close the picker
/// - Cmd-F — focus the search field
/// - Esc — clear search if active; otherwise close
struct StructuredKeywordsPicker: View {
    /// Called when the user activates a keyword. The receiver is responsible for
    /// deduping against existing keywords and appending in whatever order it prefers.
    let onAddKeywords: ([String]) -> Void
    /// Called with the full activation payload. When nil, activation falls back
    /// to `onAddKeywords` with only the primary values.
    var onActivate: ((StructuredKeywordActivation) -> Void)? = nil

    /// Optional dismiss handler used by the modal-sheet presentation.
    var onClose: (() -> Void)? = nil

    /// Which tree to browse. Defaults to the keyword tree; Person Shown passes
    /// `.personShown`.
    var service: StructuredKeywordService = .shared
    /// Shows and applies `#keyword` side payloads. Used by the Person Shown tree.
    var supportsRelatedKeywords: Bool = false

    /// Placeholder shown in the search field.
    var searchPrompt: String = "Search keywords or synonyms…"
    /// Title shown when no tree file is loaded.
    var emptyTitle: String = "No structured keywords file loaded"
    /// Subtitle pointing the user at the relevant Settings location.
    var emptySubtitle: String = "Choose a PhotoMechanic-style tree file in Settings → Metadata → Structured Keywords."

    @State private var searchText: String = ""
    @State private var feedback: Feedback?
    @State private var expandedIDs: Set<UUID> = []
    @State private var focusedIndex: Int? = 0
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var rowsFocused: Bool

    private struct Feedback: Equatable {
        let message: String
        let kind: Kind
        enum Kind { case added, noAction }
    }

    /// A single visible row in tree mode. Captures the node, its ancestors
    /// (used for the activation payload), and the indentation depth.
    private struct VisibleRow: Identifiable {
        let id: UUID
        let node: StructuredKeyword
        let ancestors: [StructuredKeyword]
        let depth: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let feedback {
                Divider()
                feedbackBar(feedback)
            }
            Divider()
            footer
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 560)
        .onAppear {
            // Focus the search field as soon as the picker opens. Deferring to the
            // next runloop tick lets the sheet finish presenting first; setting
            // focus synchronously in onAppear is dropped on a freshly-shown sheet.
            DispatchQueue.main.async {
                searchFieldFocused = true
            }
        }
        .onKeyPress(keys: ["f"]) { press in
            // Cmd-F: jump to search field.
            guard press.modifiers.contains(.command) else { return .ignored }
            searchFieldFocused = true
            return .handled
        }
        .onKeyPress(.escape) {
            if !searchText.isEmpty {
                searchText = ""
                return .handled
            }
            onClose?()
            return .handled
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit {
                    _ = activateFocused()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    focusedIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: searchText) { _, _ in
            focusedIndex = visibleRowCount() > 0 ? 0 : nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if !service.isLoaded {
            emptyStateView
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResultsView
        } else {
            treeView
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var treeView: some View {
        let rows = flattenedRows()
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    treeRow(row, index: index)
                        .id(index)
                }
            }
            .listStyle(.sidebar)
            .focusable()
            .focused($rowsFocused)
            .focusEffectDisabled()
            .onAppear {
                if focusedIndex == nil { focusedIndex = rows.isEmpty ? nil : 0 }
                rowsFocused = true
            }
            .onChange(of: focusedIndex) { _, newValue in
                if let newValue {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onKeyPress(.upArrow) { moveFocus(by: -1, in: rows) }
            .onKeyPress(.downArrow) { moveFocus(by: +1, in: rows) }
            .onKeyPress(.rightArrow) { expandOrDescend(in: rows) }
            .onKeyPress(.leftArrow) { collapseOrAscend(in: rows) }
            .onKeyPress(.return) { activateFocused() }
            .onKeyPress(.space) { activateFocused() }
        }
    }

    @ViewBuilder
    private func treeRow(_ row: VisibleRow, index: Int) -> some View {
        let isFocused = (focusedIndex == index)
        HStack(spacing: 4) {
            // Indent
            if row.depth > 0 {
                Spacer().frame(width: CGFloat(row.depth) * 12)
            }
            // Disclosure triangle for containers
            if row.node.hasChildren {
                Button {
                    toggleExpanded(row.node.id)
                } label: {
                    Image(systemName: expandedIDs.contains(row.node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            if row.node.isContainer {
                Text(row.node.name).italic().foregroundStyle(.secondary)
            } else {
                Text(row.node.name)
            }
            if !row.node.synonyms.isEmpty, !row.node.isContainer {
                Text(row.node.synonyms.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if supportsRelatedKeywords, !row.node.relatedKeywords.isEmpty, !row.node.isContainer {
                Text("\(row.node.relatedKeywords.count) #")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture(count: 2) {
            focusedIndex = index
            activate(row.node, ancestors: row.ancestors)
        }
        .onTapGesture(count: 1) {
            focusedIndex = index
        }
        .contextMenu {
            if !row.node.isContainer {
                Button("Add Keyword + Ancestors + Synonyms") {
                    activate(row.node, ancestors: row.ancestors)
                }
            }
            if row.node.hasChildren {
                Button(expandedIDs.contains(row.node.id) ? "Collapse" : "Expand") {
                    toggleExpanded(row.node.id)
                }
            }
        }
    }

    private var searchResultsView: some View {
        let results = service.search(searchText)
        return Group {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No matches")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, hit in
                            searchRow(hit, index: index)
                                .id(index)
                        }
                    }
                    .listStyle(.inset)
                    .focusable()
                    .focused($rowsFocused)
                    .focusEffectDisabled()
                    .onChange(of: focusedIndex) { _, newValue in
                        if let newValue {
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                    .onKeyPress(.upArrow) {
                        focusedIndex = max(0, (focusedIndex ?? 0) - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        focusedIndex = min(results.count - 1, (focusedIndex ?? -1) + 1)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard let i = focusedIndex, results.indices.contains(i) else { return .ignored }
                        activate(results[i].node, ancestors: results[i].ancestors)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        guard let i = focusedIndex, results.indices.contains(i) else { return .ignored }
                        activate(results[i].node, ancestors: results[i].ancestors)
                        return .handled
                    }
                }
            }
        }
    }

    private func searchRow(_ hit: StructuredKeywordPath, index: Int) -> some View {
        let isFocused = (focusedIndex == index)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(hit.node.name)
                Spacer()
                if !hit.node.synonyms.isEmpty {
                    Text(hit.node.synonyms.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if supportsRelatedKeywords, !hit.node.relatedKeywords.isEmpty {
                    Text("\(hit.node.relatedKeywords.count) #")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !hit.ancestors.isEmpty {
                Text(breadcrumb(hit.ancestors))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture(count: 1) { focusedIndex = index }
        .onTapGesture(count: 2) {
            activate(hit.node, ancestors: hit.ancestors)
        }
    }

    private func breadcrumb(_ ancestors: [StructuredKeyword]) -> String {
        ancestors.map { $0.isContainer ? "[\($0.name)]" : $0.name }.joined(separator: " › ")
    }

    private func feedbackBar(_ feedback: Feedback) -> some View {
        HStack(spacing: 6) {
            Image(systemName: feedback.kind == .added ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(feedback.kind == .added ? .green : .secondary)
            Text(feedback.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            if let path = service.sourcePath {
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            Spacer()
            if let onClose {
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tree flatten + focus helpers

    private func flattenedRows() -> [VisibleRow] {
        var rows: [VisibleRow] = []
        for root in service.roots {
            appendRow(root, ancestors: [], depth: 0, into: &rows)
        }
        return rows
    }

    private func appendRow(
        _ node: StructuredKeyword,
        ancestors: [StructuredKeyword],
        depth: Int,
        into rows: inout [VisibleRow]
    ) {
        rows.append(VisibleRow(id: node.id, node: node, ancestors: ancestors, depth: depth))
        guard expandedIDs.contains(node.id) else { return }
        let childAncestors = ancestors + [node]
        for child in node.children {
            appendRow(child, ancestors: childAncestors, depth: depth + 1, into: &rows)
        }
    }

    private func visibleRowCount() -> Int {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return service.search(searchText).count
        }
        return flattenedRows().count
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private func moveFocus(by delta: Int, in rows: [VisibleRow]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = focusedIndex ?? -1
        let next = (current + delta).clamped(to: 0...(rows.count - 1))
        focusedIndex = next
        return .handled
    }

    private func expandOrDescend(in rows: [VisibleRow]) -> KeyPress.Result {
        guard let i = focusedIndex, rows.indices.contains(i) else { return .ignored }
        let row = rows[i]
        if row.node.hasChildren {
            if !expandedIDs.contains(row.node.id) {
                expandedIDs.insert(row.node.id)
            } else if i + 1 < rows.count {
                focusedIndex = i + 1
            }
            return .handled
        }
        return .ignored
    }

    private func collapseOrAscend(in rows: [VisibleRow]) -> KeyPress.Result {
        guard let i = focusedIndex, rows.indices.contains(i) else { return .ignored }
        let row = rows[i]
        if row.node.hasChildren && expandedIDs.contains(row.node.id) {
            expandedIDs.remove(row.node.id)
            return .handled
        }
        // Jump to parent: scan backwards for the row whose node matches our last ancestor.
        if let parent = row.ancestors.last,
           let parentIndex = rows.firstIndex(where: { $0.node.id == parent.id }) {
            focusedIndex = parentIndex
            return .handled
        }
        return .ignored
    }

    private func activateFocused() -> KeyPress.Result {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let results = service.search(searchText)
            guard let i = focusedIndex, results.indices.contains(i) else { return .ignored }
            activate(results[i].node, ancestors: results[i].ancestors)
            return .handled
        }
        let rows = flattenedRows()
        guard let i = focusedIndex, rows.indices.contains(i) else { return .ignored }
        let row = rows[i]
        if row.node.isContainer {
            toggleExpanded(row.node.id)
            return .handled
        }
        activate(row.node, ancestors: row.ancestors)
        return .handled
    }

    // MARK: - Actions

    private func activate(_ node: StructuredKeyword, ancestors: [StructuredKeyword]) {
        guard node.isKeyword else { return }
        let path = StructuredKeywordPath(ancestors: ancestors, node: node)
        let activation = service.activation(path)
        guard !activation.values.isEmpty else { return }
        if let onActivate {
            onActivate(activation)
        } else {
            onAddKeywords(activation.values)
        }
        var sideKeywords = activation.relatedKeywords
        if supportsRelatedKeywords,
           UserDefaults.standard.bool(forKey: UserDefaultsKeys.structuredPersonShownCategoriesAsKeywords) {
            sideKeywords = activation.categoryKeywords + sideKeywords
        }
        let detailValues = activation.values + (supportsRelatedKeywords ? sideKeywords.map { "#\($0)" } : [])
        let detail = detailValues.joined(separator: ", ")
        feedback = Feedback(message: "Added: \(detail)", kind: .added)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
