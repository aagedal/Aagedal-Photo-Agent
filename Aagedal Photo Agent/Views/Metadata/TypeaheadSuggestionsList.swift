import SwiftUI

/// Shared rows for metadata typeahead and face-group naming.
struct TypeaheadSuggestionsList: View {
    let suggestions: [ApprovedListSuggestion]
    @Binding var highlightedIndex: Int?
    let onSelect: (ApprovedListSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.canonical) { index, suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 6) {
                        Text(suggestion.canonical)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if suggestion.matchKind == .substring {
                            Image(systemName: "text.magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovering in if hovering { highlightedIndex = index } }
                .accessibilityLabel(suggestion.canonical)
            }
        }
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
        .padding(.vertical, 2)
    }
}
