import SwiftUI

/// Searchable, keyboard-navigable Quick List picker shared by every metadata
/// field that has a quick list. Presented through `.instantPopover` so it
/// appears with no grow animation.
///
/// Two modes:
/// - `allowsMultiple` (Keywords, Person shown): clicking a row adds that value
///   immediately and leaves the popover open, so several can be added in a row.
///   Rows already applied can be toggled off when `allowsToggleRemoval` is set.
/// - single value (Copyright, Creator, City, …): clicking a row sets the field's
///   one value and closes the popover.
///
/// Keyboard:
/// - Up / Down — move focus
/// - Space / Return — activate the focused row
/// - Cmd-F — focus search
/// - Esc — close
struct QuickListPicker: View {
    /// The quick list, in stored order.
    let presetList: [String]
    /// Values already applied to the field. For single-value fields this holds
    /// 0 or 1 entry; for multi-value fields it's the full current set. Drives the
    /// row checkmark and suppresses duplicate adds.
    let currentValues: Set<String>

    /// Multi-value fields add on click and stay open; single-value fields set the
    /// one value and close.
    var allowsMultiple: Bool = true
    /// When `allowsMultiple`, whether clicking an already-applied value removes it
    /// rather than being a no-op.
    var allowsToggleRemoval: Bool = false
    /// Optional badge shown on rows already applied (e.g. "on image" for keywords).
    var appliedBadge: String? = nil
    /// Compact sizing for short single-value lists.
    var compact: Bool = false

    /// Invoked with the value to add/set when a row is activated. Caller dedupes
    /// and writes to the underlying field.
    let onPick: (String) -> Void
    /// Invoked when an already-applied value is toggled off (multi-value only).
    var onRemove: ((String) -> Void)? = nil

    var onAddCurrentToQuickList: (() -> Void)? = nil
    var onChooseListFile: (() -> Void)? = nil
    var onEditQuickList: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var searchText: String = ""
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
        .frame(
            minWidth: compact ? 240 : 320,
            idealWidth: compact ? 300 : 380,
            minHeight: compact ? 220 : 340,
            idealHeight: compact ? 300 : 460
        )
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
                    .disabled(currentValues.isEmpty)
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
                activate(entries[i])
                return .handled
            }
            .onKeyPress(.return) {
                guard let i = focusedIndex, entries.indices.contains(i) else { return .ignored }
                activate(entries[i])
                return .handled
            }
        }
    }

    private func row(for entry: String, index: Int) -> some View {
        let isFocused = (focusedIndex == index)
        let isApplied = currentValues.contains(entry)
        let iconName = isApplied
            ? "checkmark.circle.fill"
            : (allowsMultiple ? "plus.circle" : "circle")
        return HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(isApplied ? Color.accentColor : .secondary)
                .font(.caption)
            Text(entry)
                .foregroundStyle(isApplied ? .secondary : .primary)
            Spacer()
            if isApplied, let appliedBadge {
                Text(appliedBadge)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(isFocused ? Color.accentColor.opacity(0.18) : Color.clear)
        // Single tap only — activates immediately. No double-tap gesture, so
        // SwiftUI doesn't stall the tap waiting to disambiguate a second click.
        .onTapGesture {
            focusedIndex = index
            activate(entry)
        }
    }

    private var footer: some View {
        HStack {
            Text(allowsMultiple ? "Click to add" : "Click to set")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { onClose?() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    /// Apply a row's primary action. Multi-value: add, or toggle off when already
    /// applied and removal is allowed; stays open. Single-value: set and close.
    private func activate(_ entry: String) {
        if allowsMultiple {
            if currentValues.contains(entry) {
                if allowsToggleRemoval { onRemove?(entry) }
                return
            }
            onPick(entry)
        } else {
            onPick(entry)
            onClose?()
        }
    }
}
