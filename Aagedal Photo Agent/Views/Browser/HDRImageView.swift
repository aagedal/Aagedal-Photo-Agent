import SwiftUI
import AppKit
import QuartzCore

struct HDRImageView: NSViewRepresentable {
    let cgImage: CGImage
    var isHDR: Bool = true
    var useNearestNeighbor: Bool = false
    var onPanChanged: ((CGSize) -> Void)?
    var onPanEnded: ((CGSize) -> Void)?

    final class Coordinator: NSObject {
        var onPanChanged: ((CGSize) -> Void)?
        var onPanEnded: ((CGSize) -> Void)?

        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            // Measure in the unscaled window content view. Reading in the image view's local
            // coordinates would divide motion by SwiftUI's zoom transform.
            let coordinateView = view.window?.contentView ?? view
            let translation = recognizer.translation(in: coordinateView)
            let swiftUITranslation = CGSize(
                width: translation.x,
                height: coordinateView.isFlipped ? translation.y : -translation.y
            )

            switch recognizer.state {
            case .began, .changed:
                onPanChanged?(swiftUITranslation)
            case .ended:
                onPanEnded?(swiftUITranslation)
            case .cancelled, .failed:
                onPanEnded?(.zero)
            default:
                break
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        let panRecognizer = NSPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        view.addGestureRecognizer(panRecognizer)
        updateCoordinator(context.coordinator)
        updateLayer(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateCoordinator(context.coordinator)
        updateLayer(nsView)
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.onPanChanged = onPanChanged
        coordinator.onPanEnded = onPanEnded
    }

    private func updateLayer(_ view: NSView) {
        guard let layer = view.layer else { return }
        layer.contents = cgImage
        // Use half-float backing store for HDR so values > 1.0 are preserved.
        // Default RGBA8Uint clips extended-range values to [0, 1].
        layer.contentsFormat = isHDR ? .RGBA16Float : .RGBA8Uint
        let filter: CALayerContentsFilter = useNearestNeighbor ? .nearest : .linear
        layer.magnificationFilter = filter
        layer.minificationFilter = filter
        // Opaque when HDR — non-opaque layer compositing can clip EDR values to SDR.
        layer.isOpaque = isHDR
        layer.preferredDynamicRange = isHDR ? .high : .standard
        // Walk ancestor layers to ensure SwiftUI intermediate hosting layers
        // don't clip extended-range pixel values to [0, 1] during compositing.
        Self.enableEDRAncestors(for: view, isHDR: isHDR)
    }

    /// Walk from the given view up to the window content view, enabling EDR on every
    /// ancestor layer so SwiftUI intermediates don't clip HDR values.
    private static func enableEDRAncestors(for view: NSView, isHDR: Bool) {
        var current: NSView? = view.superview
        while let ancestor = current {
            ancestor.wantsLayer = true
            if let layer = ancestor.layer {
                let target: CALayer.DynamicRange = isHDR ? .high : .standard
                if layer.preferredDynamicRange != target {
                    layer.preferredDynamicRange = target
                }
            }
            current = ancestor.superview
        }
    }
}
