import SwiftUI

/// Tree picker for the PhotoMechanic-style structured keywords file.
///
/// On double-click of a keyword node the picker invokes `onAddKeywords` with the
/// expanded list (ancestors + clicked keyword + its synonyms). Container nodes
/// (`[Bracketed]`) are shown in muted style and ignored on double-click.
struct StructuredKeywordsPicker: View {
    /// Called when the user double-clicks a keyword. The receiver is responsible for
    /// deduping against existing keywords and appending in whatever order it prefers.
    let onAddKeywords: ([String]) -> Void

    /// Optional dismiss handler used by the modal-sheet presentation.
    var onClose: (() -> Void)? = nil

    private let service = StructuredKeywordService.shared

    @State private var searchText: String = ""
    @State private var feedback: Feedback?
    @State private var expandedIDs: Set<UUID> = []

    private struct Feedback: Equatable {
        let message: String
        let kind: Kind
        enum Kind { case added, noAction }
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
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search keywords or synonyms…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            Text("No structured keywords file loaded")
                .font(.headline)
            Text("Choose a PhotoMechanic-style tree file in Settings → Metadata → Structured Keywords.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var treeView: some View {
        List {
            ForEach(service.roots) { node in
                StructuredKeywordTreeRow(
                    node: node,
                    ancestors: [],
                    expandedIDs: $expandedIDs,
                    onActivate: activate
                )
            }
        }
        .listStyle(.sidebar)
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
                List(results, id: \.self) { hit in
                    searchRow(hit)
                }
                .listStyle(.inset)
            }
        }
    }

    private func searchRow(_ hit: StructuredKeywordPath) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .contentShape(Rectangle())
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

    // MARK: - Actions

    private func activate(_ node: StructuredKeyword, ancestors: [StructuredKeyword]) {
        guard node.isKeyword else { return }
        let path = StructuredKeywordPath(ancestors: ancestors, node: node)
        let expanded = service.expand(path)
        guard !expanded.isEmpty else { return }
        onAddKeywords(expanded)
        let detail = expanded.joined(separator: ", ")
        feedback = Feedback(message: "Added: \(detail)", kind: .added)
    }
}

/// Recursive row used by the tree view. Defined as a struct so the recursion is
/// expressed via the type system rather than an opaque-return inference loop.
private struct StructuredKeywordTreeRow: View {
    let node: StructuredKeyword
    let ancestors: [StructuredKeyword]
    @Binding var expandedIDs: Set<UUID>
    let onActivate: (StructuredKeyword, [StructuredKeyword]) -> Void

    var body: some View {
        if node.hasChildren {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedIDs.contains(node.id) },
                    set: { isOpen in
                        if isOpen { expandedIDs.insert(node.id) }
                        else { expandedIDs.remove(node.id) }
                    }
                )
            ) {
                ForEach(node.children) { child in
                    StructuredKeywordTreeRow(
                        node: child,
                        ancestors: ancestors + [node],
                        expandedIDs: $expandedIDs,
                        onActivate: onActivate
                    )
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if node.isContainer {
                Text(node.name)
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                Text(node.name)
            }
            if !node.synonyms.isEmpty, !node.isContainer {
                Text(node.synonyms.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onActivate(node, ancestors)
        }
        .contextMenu {
            if !node.isContainer {
                Button("Add Keyword + Ancestors + Synonyms") {
                    onActivate(node, ancestors)
                }
            }
            if node.hasChildren {
                Button(expandedIDs.contains(node.id) ? "Collapse" : "Expand") {
                    if expandedIDs.contains(node.id) {
                        expandedIDs.remove(node.id)
                    } else {
                        expandedIDs.insert(node.id)
                    }
                }
            }
        }
    }
}
