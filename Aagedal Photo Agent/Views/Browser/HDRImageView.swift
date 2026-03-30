import SwiftUI
import AppKit
import QuartzCore

struct HDRImageView: NSViewRepresentable {
    let cgImage: CGImage
    var isHDR: Bool = true
    var useNearestNeighbor: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        updateLayer(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateLayer(nsView)
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
