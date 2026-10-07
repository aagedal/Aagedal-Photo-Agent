import SwiftUI
import AVFoundation

/// The Media Player timeline's four-point track, pink playhead, orange markers,
/// and Option-drag precision scrubbing, adapted to the still-extraction workspace.
struct VideoStillTimeline: View {
    @Binding var position: Double
    let duration: Double
    let markers: [CMTime]
    let onScrub: (Double, Bool) -> Void
    @State private var dragging = false
    @State private var precision = false
    @State private var anchorX = 0.0
    @State private var anchorTime = 0.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.3)).frame(height: 4)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, time in
                    Capsule().fill(.orange).frame(width: 3, height: 14)
                        .offset(x: x(time.seconds, width: width) - 1.5)
                        .allowsHitTesting(false)
                }
                Rectangle().fill(Color(red: 1, green: 0.071, blue: 0.361))
                    .frame(width: 2, height: 14)
                    .offset(x: x(position, width: width) - 1)
                    .allowsHitTesting(false)
            }
            .frame(height: 20).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0, duration > 0 else { return }
                    let option = NSEvent.modifierFlags.contains(.option)
                    if !dragging { dragging = true; precision = false }
                    if option && !precision { anchorX = value.location.x; anchorTime = position }
                    position = min(duration, max(0, option
                        ? anchorTime + (value.location.x - anchorX) / width * duration / 10
                        : value.location.x / width * duration))
                    precision = option
                    onScrub(position, false)
                }
                .onEnded { _ in
                    onScrub(position, true)
                    dragging = false
                    precision = false
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Video playhead")
            .accessibilityValue("\(markers.count) markers")
            .accessibilityAdjustableAction { direction in
                position = min(duration, max(0, position + (direction == .increment ? 1 : -1)))
                onScrub(position, true)
            }
            .help("Drag to seek. Hold Option for precision scrubbing. Orange ticks mark frames for extraction.")
        }.frame(height: 20)
    }

    private func x(_ time: Double, width: Double) -> Double {
        min(max(1.5, width - 1.5), max(1.5, time / max(duration, 0.001) * width))
    }
}

/// A video-only surface; playback and keyboard controls belong to the workspace.
struct VideoStillPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.wantsLayer = true
        view.layer = layer
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
