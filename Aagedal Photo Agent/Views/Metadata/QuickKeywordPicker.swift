import SwiftUI

/// Popover picker for a Quick List of keywords. Peer in style to
/// `StructuredKeywordsPicker`: searchable, keyboard-navigable, multi-select.
///
/// Keyboard:
/// - Up / Down — move focus
/// - Space — toggle selection of focused row
/// - Return — add selected rows
/// - Cmd-F — focus search
/// - Esc — close
struct QuickKeywordPicker: View {
    /// The quick list, in stored order.
    let presetList: [String]
    /// Keywords already on the image(s) — used to render checkmarks and to
    /// suppress re-add of duplicates when the user activates a selection.
    let currentKeywords: Set<String>

    /// Whether selecting an already-present keyword should remove it from
    /// the image(s) instead of being a no-op. Matches `KeywordsEditorWithDiff`'s
    /// `allowsPresetToggleRemoval`.
    var allowsToggleRemoval: Bool = false

    /// Invoked with the user's selection when they hit Add / Return. Caller is
    /// responsible for dedupe and adding to the underlying field.
    let onAddSelected: ([String]) -> Void

    /// Invoked when the user toggles an already-present keyword off (only
    /// relevant when `allowsToggleRemoval` is true).
    var onRemoveItem: ((String) -> Void)? = nil

    var onAddCurrentToQuickList: (() -> Void)? = nil
    var onChooseListFile: (() -> Void)? = nil
    var onEditQuickList: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var searchText: String = ""
    @State private var selection: Set<String> = []
    @State private var focusedIndex: Int? = 0
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var rowsFocused: Bool

    private var filteredEntries: [String] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return presetList }
        return presetList.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 340, idealHeight: 460)
        .onKeyPress(keys: ["f"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            searchFieldFocused = true
            return .handled
        }
        .onKeyPress(.escape) {
            onClose?()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter quick list…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Menu {
                if let onAddCurrentToQuickList {
                    Button("Add Current to Quick List") {
                        onAddCurrentToQuickList()
                    }
                    .disabled(currentKeywords.isEmpty)
                }
                if let onEditQuickList {
                    Button("Edit Quick List…") { onEditQuickList() }
                }
                if let onChooseListFile {
                    Button("Import Quick List File…") { onChooseListFile() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More quick list actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: searchText) { _, _ in
            let f = filteredEntries
            focusedIndex = f.isEmpty ? nil : 0
        }
    }

    @ViewBuilder
    private var content: some View {
        if presetList.isEmpty {
            emptyView
        } else {
            entriesList
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "list.bullet")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Quick list is empty")
                .font(.headline)
            Text("Add entries via the overflow menu, then re-open this picker.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entriesList: some View {
        let entries = filteredEntries
        return ScrollViewReader { proxy in
            // A `ScrollView { LazyVStack }` is used here rather than `List`:
            // `List` bridges to AppKit's NSTableView and is costly to instantiate,
            // and the enclosing popover rebuilds its content on every open — so the
            // table setup cost was paid on each click, making the picker feel slow
            // to appear. LazyVStack mounts far faster while keeping scroll + keyboard
            // navigation (ScrollViewReader still resolves `.id(index)`).
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                        row(for: entry, index: index)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($rowsFocused)
            .focusEffectDisabled()
            .onAppear {
                rowsFocused = true
                if focusedIndex == nil { focusedIndex = entries.isEmpty ? nil : 0 }
            }
            .onChange(of: focusedIndex) { _, newValue in
                if let newValue {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onKeyPress(.upArrow) {
                guard !entries.isEmpty else { return .ignored }
                focusedIndex = max(0, (focusedIndex ?? 0) - 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard !entries.isEmpty else { return .ignored }
                focusedIndex = min(entries.count - 1, (focusedIndex ?? -1) + 1)
                return .handled
            }
            .onKeyPress(.space) {
                guard let i = focusedIndex, entries.indices.contains(i) else { return .ignored }
                toggleSelection(of: entries[i])
                return .handled
            }
            .onKeyPress(.return) {
                commitSelection(from: entries)
                return .handled
            }
        }
    }

    private func row(for entry: String, index: Int) -> some View {
        let isFocused = (focusedIndex == index)
        let isInImage = currentKeywords.contains(entry)
        let isSelectedForAdd = selection.contains(entry)
        return HStack(spacing: 6) {
            Image(systemName: isSelectedForAdd ? "checkmark.square.fill" : (isInImage ? "circle.fill" : "square"))
                .foregroundStyle(isSelectedForAdd ? Color.accentColor : (isInImage ? .secondary : .secondary))
                .font(.caption)
            Text(entry)
                .foregroundStyle(isInImage ? .secondary : .primary)
            Spacer()
            if isInImage {
                Text("on image")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture(count: 1) {
            focusedIndex = index
            toggleSelection(of: entry)
        }
        .onTapGesture(count: 2) {
            focusedIndex = index
            onAddSelected([entry])
            selection.remove(entry)
        }
    }

    private var footer: some View {
        HStack {
            Text(selection.isEmpty ? "No selection" : "\(selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { onClose?() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                commitSelection(from: filteredEntries)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func toggleSelection(of entry: String) {
        if selection.contains(entry) {
            selection.remove(entry)
            return
        }
        if currentKeywords.contains(entry) {
            // Already on the image. If the field allows removal, remove it; else
            // treat as a no-op selection (don't allow duplicate-add).
            if allowsToggleRemoval {
                onRemoveItem?(entry)
            }
            return
        }
        selection.insert(entry)
    }

    private func commitSelection(from entries: [String]) {
        let toAdd = entries.filter { selection.contains($0) && !currentKeywords.contains($0) }
        guard !toAdd.isEmpty else { return }
        onAddSelected(toAdd)
        selection.removeAll()
    }
}
