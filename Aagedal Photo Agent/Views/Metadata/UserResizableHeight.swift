import AppKit
import SwiftUI

/// Lets the user drag a multi-line field taller or shorter by a grip in its bottom-right corner,
/// like a browser text area. Each field remembers its height (by `key`) across launches;
/// double-clicking the grip restores the default.
private struct UserResizableHeight: ViewModifier {
    let key: String
    let defaultHeight: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var height: CGFloat?
    @State private var dragStartHeight: CGFloat?

    private var defaultsKey: String { "userResizableHeight.\(key)" }

    private var storedHeight: CGFloat? {
        let value = AppDefaults.store.double(forKey: defaultsKey)
        return value > 0 ? clamped(CGFloat(value)) : nil
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, minHeight), maxHeight)
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height ?? storedHeight ?? defaultHeight)
            .overlay(alignment: .bottomTrailing) { grip }
    }

    private var grip: some View {
        Canvas { context, size in
            var lines = Path()
            for inset in [3.0, 7.0] {
                lines.move(to: CGPoint(x: size.width - 3, y: inset))
                lines.addLine(to: CGPoint(x: inset, y: size.height - 3))
            }
            context.stroke(lines, with: .style(.secondary), lineWidth: 1)
        }
        .frame(width: 12, height: 12)
        .padding(2)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        // Global space: the grip moves with the growing field, so a local translation would feed
        // back into itself and jitter.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? height ?? storedHeight ?? defaultHeight
                    if dragStartHeight == nil { dragStartHeight = start }
                    height = clamped(start + value.translation.height)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    if let height { AppDefaults.store.set(Double(height), forKey: defaultsKey) }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                height = defaultHeight
                AppDefaults.store.removeObject(forKey: defaultsKey)
            }
        )
        .help("Drag to resize. Double-click to restore the default height.")
        .accessibilityHidden(true)
    }
}

extension View {
    /// A fixed height the user can change by dragging the bottom-right grip; see `UserResizableHeight`.
    func userResizableHeight(
        key: String,
        defaultHeight: CGFloat,
        minHeight: CGFloat = 44,
        maxHeight: CGFloat = 800
    ) -> some View {
        modifier(UserResizableHeight(
            key: key,
            defaultHeight: defaultHeight,
            minHeight: min(minHeight, defaultHeight),
            maxHeight: max(maxHeight, defaultHeight)
        ))
    }
}
