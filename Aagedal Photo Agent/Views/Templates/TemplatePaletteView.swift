import SwiftUI

struct TemplatePaletteView: View {
    let templates: [MetadataTemplate]
    let onApply: (MetadataTemplate) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if templates.isEmpty {
                emptyState
            } else {
                templateList
            }
        }
        .frame(width: 320, height: min(CGFloat(templates.count * 52 + 60), 400))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < templates.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.return) {
            if !templates.isEmpty && selectedIndex < templates.count {
                onApply(templates[selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Apply Template", systemImage: "doc.on.clipboard")
                .font(.headline)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No templates")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Create a template in Settings")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Template List

    private var templateList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        templateRow(template, index: index)
                            .id(index)
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func templateRow(_ template: MetadataTemplate, index: Int) -> some View {
        Button {
            onApply(template)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(template.fields.count) fields")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if index == selectedIndex {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                selectedIndex = index
            }
        }
    }
}
