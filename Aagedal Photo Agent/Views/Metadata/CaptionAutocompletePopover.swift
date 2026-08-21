import SwiftUI

/// Compact explicit-insertion picker for the field that opened it. The captured field never
/// changes while the popover is open, so keyboard focus transitions cannot redirect a suggestion
/// into a neighboring editor.
struct CaptionAutocompletePopover: View {
    let field: MetadataFieldID
    let currentMetadata: IPTCMetadata
    let seeds: [CaptionAutocompleteSeed]
    let onApply: (CaptionAutocompleteSuggestion) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var searchFocused: Bool

    private var suggestions: [CaptionAutocompleteSuggestion] {
        CaptionAutocompleteService.suggestions(
            for: field,
            query: query,
            currentMetadata: currentMetadata,
            seeds: seeds
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(field.displayName, systemImage: "text.badge.plus")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close suggestions")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            TextField("Filter suggestions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .accessibilityLabel("Filter \(field.displayName) suggestions")
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.return) { applyHighlighted() }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }

            Divider()

            if suggestions.isEmpty {
                ContentUnavailableView(
                    "No Suggestions",
                    systemImage: "text.magnifyingglass",
                    description: Text(query.isEmpty ? "No values are available for this field." : "Try a different filter.")
                )
                .frame(width: 340, height: 150)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                suggestionRow(suggestion, index: index)
                                    .id(index)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onChange(of: highlightedIndex) { _, index in
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
                .frame(width: 340, height: 220)
            }
        }
        .frame(width: 340)
        .onAppear {
            searchFocused = true
            highlightedIndex = 0
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
        .onChange(of: suggestions.count) { _, count in
            highlightedIndex = min(highlightedIndex, max(0, count - 1))
        }
    }

    private func suggestionRow(_ suggestion: CaptionAutocompleteSuggestion, index: Int) -> some View {
        Button {
            onApply(suggestion)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.displayValue)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(suggestion.provenances.map(\.displayName).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "return")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == highlightedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { highlightedIndex = index } }
        .accessibilityLabel("Insert \(suggestion.displayValue)")
        .accessibilityHint("From \(suggestion.provenances.map(\.displayName).joined(separator: ", "))")
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlightedIndex = min(max(0, highlightedIndex + delta), suggestions.count - 1)
        return .handled
    }

    private func applyHighlighted() -> KeyPress.Result {
        guard suggestions.indices.contains(highlightedIndex) else { return .ignored }
        onApply(suggestions[highlightedIndex])
        return .handled
    }
}
