import SwiftUI

struct VariableDefinition: Identifiable {
    let id = UUID()
    let variable: String
    let category: String
    let description: String
    let example: String
}

private let allVariables: [VariableDefinition] = [
    // Date
    VariableDefinition(
        variable: "{date}",
        category: "Date",
        description: "Today's date in the system's medium format.",
        example: "Jan 27, 2026"
    ),
    VariableDefinition(
        variable: "{date:yyyy-MM-dd}",
        category: "Date",
        description: "Current date in ISO 8601 format.",
        example: "2026-01-27"
    ),
    VariableDefinition(
        variable: "{date:dd MMM yyyy}",
        category: "Date",
        description: "Day, abbreviated month, and full year.",
        example: "27 Jan 2026"
    ),
    VariableDefinition(
        variable: "{date:dd.MM.yyyy}",
        category: "Date",
        description: "European dot-separated date.",
        example: "27.01.2026"
    ),
    VariableDefinition(
        variable: "{date:yyyy}",
        category: "Date",
        description: "Four-digit year only.",
        example: "2026"
    ),
    VariableDefinition(
        variable: "{date:MMMM yyyy}",
        category: "Date",
        description: "Full month name and year.",
        example: "January 2026"
    ),
    VariableDefinition(
        variable: "{date:FORMAT}",
        category: "Date",
        description: "Custom date using any DateFormatter pattern. Replace FORMAT with your own pattern (e.g. HH:mm, EEE dd MMM).",
        example: "{date:EEE dd MMM} \u{2192} Mon 27 Jan"
    ),
    VariableDefinition(
        variable: "{dateCreated}",
        category: "Date",
        description: "Date Created from metadata (if available).",
        example: "2026-01-27"
    ),
    VariableDefinition(
        variable: "{dateCaptured}",
        category: "Date",
        description: "EXIF DateTimeOriginal from metadata (if available).",
        example: "2026-01-27"
    ),

    // Shortcuts
    VariableDefinition(
        variable: "{persons}",
        category: "Shortcuts",
        description: "Comma-separated list of all Person Shown names. Reads from the current editing state, so names entered before applying the preset are included.",
        example: "John Doe, Jane Smith"
    ),
    VariableDefinition(
        variable: "{keywords}",
        category: "Shortcuts",
        description: "Comma-separated list of all keywords from the current editing state.",
        example: "landscape, sunset, mountains"
    ),
    VariableDefinition(
        variable: "{filename}",
        category: "Shortcuts",
        description: "Filename of the selected image without its file extension.",
        example: "IMG_4023"
    ),

    // Field references
    VariableDefinition(
        variable: "{field:title}",
        category: "Field Reference",
        description: "Value of the Headline field from the current metadata.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:description}",
        category: "Field Reference",
        description: "Value of the Description field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:extendedDescription}",
        category: "Field Reference",
        description: "Value of the Extended Description field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:keywords}",
        category: "Field Reference",
        description: "Comma-separated keywords.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:personShown}",
        category: "Field Reference",
        description: "Comma-separated Person Shown names (same as {persons}).",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:creator}",
        category: "Field Reference",
        description: "Value of the Creator field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:credit}",
        category: "Field Reference",
        description: "Value of the Credit field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:copyright}",
        category: "Field Reference",
        description: "Value of the Copyright field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:jobId}",
        category: "Field Reference",
        description: "Value of the Job ID field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:dateCreated}",
        category: "Field Reference",
        description: "Value of the Date Created field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:city}",
        category: "Field Reference",
        description: "Value of the City field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:country}",
        category: "Field Reference",
        description: "Value of the Country field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:event}",
        category: "Field Reference",
        description: "Value of the Event field.",
        example: ""
    ),
    VariableDefinition(
        variable: "{field:digitalSourceType}",
        category: "Field Reference",
        description: "Display name of the Digital Source Type.",
        example: ""
    ),
]

struct VariableReferenceView: View {
    @Binding var isPresented: Bool
    var onInsert: ((String) -> Void)?

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var filteredVariables: [VariableDefinition] {
        guard !searchText.isEmpty else { return allVariables }
        let query = searchText.lowercased()
        return allVariables.filter {
            $0.variable.lowercased().contains(query) ||
            $0.description.lowercased().contains(query) ||
            $0.category.lowercased().contains(query) ||
            $0.example.lowercased().contains(query)
        }
    }

    private var groupedVariables: [(category: String, items: [VariableDefinition])] {
        let order = ["Date", "Shortcuts", "Field Reference"]
        let grouped = Dictionary(grouping: filteredVariables, by: \.category)
        return order.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (category: cat, items: items)
        }
    }

    private var orderedVariables: [VariableDefinition] {
        groupedVariables.flatMap(\.items)
    }

    private var selectedVariable: VariableDefinition? {
        guard !orderedVariables.isEmpty else { return nil }
        let clampedIndex = min(max(selectedIndex, 0), orderedVariables.count - 1)
        return orderedVariables[clampedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            variableList
        }
        .frame(width: 480, height: 420)
        .focusable()
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            insertSelectedVariable()
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Variable Reference", systemImage: "curlybraces")
                .font(.headline)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter variables\u{2026}", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.return) {
                    insertSelectedVariable()
                    return .handled
                }
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
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var variableList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groupedVariables.isEmpty {
                        Text("No matching variables")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(groupedVariables, id: \.category) { group in
                            sectionHeader(group.category)
                            ForEach(group.items) { item in
                                variableRow(item, isSelected: item.id == selectedVariable?.id)
                                    .id(item.id)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, _ in
                if let selected = selectedVariable {
                    proxy.scrollTo(selected.id, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func variableRow(_ item: VariableDefinition, isSelected: Bool) -> some View {
        Button {
            select(item)
            onInsert?(item.variable)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(item.variable)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 160, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    if !item.example.isEmpty {
                        Text("e.g. \(item.example)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .primary.opacity(0.001))
        }
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func select(_ item: VariableDefinition) {
        if let index = orderedVariables.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !orderedVariables.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), orderedVariables.count - 1)
        selectedIndex = next
    }

    private func insertSelectedVariable() {
        guard let selected = selectedVariable else { return }
        onInsert?(selected.variable)
    }
}
