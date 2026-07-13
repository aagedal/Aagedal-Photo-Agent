import SwiftUI

struct DevelopTemplatePaletteView: View {
    let templates: [DevelopTemplate]
    let onApply: (DevelopTemplate) -> Void
    let onSaveNew: () -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    private var calculatedHeight: CGFloat {
        templates.isEmpty ? 260 : min(CGFloat(templates.count * 52 + 100), 400)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if templates.isEmpty {
                emptyState
            } else {
                templateList
            }
            Divider()
            saveNewButton
        }
        .frame(width: 340, height: calculatedHeight)
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
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < templates.count { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            if selectedIndex == templates.count {
                onSaveNew()
            } else if templates.indices.contains(selectedIndex) {
                onApply(templates[selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var header: some View {
        HStack {
            Label("Apply Develop Template", systemImage: "slider.horizontal.3")
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No develop templates yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Save the current develop settings as a template")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var saveNewButton: some View {
        Button {
            onSaveNew()
        } label: {
            HStack {
                Image(systemName: "plus.circle")
                Text("Save Current as Template")
                Spacer()
                if selectedIndex == templates.count {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(selectedIndex == templates.count ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = templates.count }
        }
    }

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

    private func templateRow(_ template: DevelopTemplate, index: Int) -> some View {
        Button {
            onApply(template)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .foregroundStyle(.primary)
                    Text(template.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let slot = template.shortcutSlot {
                    Text("⌃\(slot)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
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
            if hovering { selectedIndex = index }
        }
    }
}
