import SwiftUI
import AppKit

extension View {
    /// Drop-in replacement for `.popover(isPresented:arrowEdge:)` that presents
    /// through an `NSPopover` with `animates = false`, so it appears instantly
    /// instead of running AppKit's grow/fade transition.
    ///
    /// Behavior matches the system popover where it matters: `.transient`, so it
    /// dismisses on an outside click or when the window loses key, and the
    /// `isPresented` binding is kept in sync when that happens.
    func instantPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .bottom,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(
            InstantPopoverPresenter(
                isPresented: isPresented,
                preferredEdge: arrowEdge,
                content: content
            )
        )
    }
}

/// Flipped so its coordinate origin is top-left, letting `.maxY` mean "below"
/// the way SwiftUI's `arrowEdge` semantics read.
private final class AnchorView: NSView {
    override var isFlipped: Bool { true }
}

private struct InstantPopoverPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: Edge
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Refresh the binding each pass — SwiftUI hands out a fresh Binding value.
        context.coordinator.isPresented = $isPresented
        context.coordinator.sync(
            present: isPresented,
            preferredEdge: preferredEdge,
            content: content()
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        weak var anchorView: NSView?
        private var popover: NSPopover?
        private var hostingController: NSHostingController<AnyView>?

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func sync(present: Bool, preferredEdge: Edge, content: Content) {
            // Keep the hosted SwiftUI content fresh while shown (e.g. the
            // "on image" state changes as the user adds keywords).
            hostingController?.rootView = AnyView(content)

            if present {
                show(content: AnyView(content), preferredEdge: preferredEdge)
            } else {
                close()
            }
        }

        private func show(content: AnyView, preferredEdge: Edge) {
            guard let anchorView, anchorView.window != nil else { return }
            if let popover, popover.isShown { return }

            let controller = NSHostingController(rootView: content)
            // Let SwiftUI's ideal size drive the popover size.
            controller.sizingOptions = [.preferredContentSize]

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
            popover.contentViewController = controller

            self.popover = popover
            self.hostingController = controller

            popover.show(
                relativeTo: anchorView.bounds,
                of: anchorView,
                preferredEdge: preferredEdge.nsRectEdge
            )
        }

        func close() {
            guard let popover, popover.isShown else { return }
            popover.performClose(nil)
        }

        // MARK: NSPopoverDelegate

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            hostingController = nil
            // Mirror a user-driven dismissal (outside click / lost key) back into
            // the SwiftUI binding. Deferred to avoid mutating state mid-update.
            guard isPresented.wrappedValue else { return }
            let binding = isPresented
            DispatchQueue.main.async { binding.wrappedValue = false }
        }
    }
}

private extension Edge {
    /// Maps to the edge of the anchor the popover should appear off of, using the
    /// flipped `AnchorView` coordinate space (origin top-left).
    var nsRectEdge: NSRectEdge {
        switch self {
        case .top: return .minY
        case .bottom: return .maxY
        case .leading: return .minX
        case .trailing: return .maxX
        }
    }
}
