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
        let filter: CALayerContentsFilter = useNearestNeighbor ? .nearest : .linear
        layer.magnificationFilter = filter
        layer.minificationFilter = filter
        if #available(macOS 26.0, *) {
            layer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            layer.wantsExtendedDynamicRangeContent = isHDR
        }
    }
}
