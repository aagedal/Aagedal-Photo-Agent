import SwiftUI

/// A custom slider matching the playhead/timeline design from Aagedal Media Player.
/// Thin 4pt track with a 2pt vertical playhead line instead of the default circle knob.
/// Hold Option while dragging for 10x precision scrubbing.
/// Double-click to reset to default via `onReset` callback.
struct EditSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var gradient: LinearGradient?
    var onEditingChanged: ((Bool) -> Void)?
    var onReset: (() -> Void)?

    @State private var isDragging = false
    @State private var wasPrecision = false
    @State private var precisionAnchorFraction: Double = 0
    @State private var precisionAnchorX: CGFloat = 0
    @State private var lastDragStartTime: Date = .distantPast

    private let precisionFactor: Double = 10.0
    private let doubleClickInterval: TimeInterval = 0.3

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    private func snapped(_ raw: Double) -> Double {
        let clamped = max(range.lowerBound, min(range.upperBound, raw))
        return step > 0 ? (clamped / step).rounded() * step : clamped
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                // Track background
                if let gradient {
                    gradient
                        .frame(height: 4)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .opacity(0.5)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 4)
                }

                // Center mark for bipolar sliders (range spans negative to positive)
                if range.lowerBound < 0 && range.upperBound > 0 {
                    let centerFrac = -range.lowerBound / (range.upperBound - range.lowerBound)
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 1, height: 8)
                        .offset(x: width * CGFloat(centerFrac) - 0.5)
                }

                // Playhead — thin vertical line
                Rectangle()
                    .fill(Color.white.opacity(isDragging ? 1.0 : 0.8))
                    .frame(width: 2, height: 14)
                    .offset(x: max(0, min(width - 2, width * CGFloat(fraction) - 1)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            let now = Date()
                            if now.timeIntervalSince(lastDragStartTime) < doubleClickInterval,
                               let onReset
                            {
                                // Double-click detected — reset and cancel this drag
                                onReset()
                                lastDragStartTime = .distantPast
                                return
                            }
                            lastDragStartTime = now
                            isDragging = true
                            wasPrecision = false
                            onEditingChanged?(true)
                            // Jump to click position
                            let frac = max(0, min(1, drag.location.x / width))
                            let span = range.upperBound - range.lowerBound
                            value = snapped(range.lowerBound + Double(frac) * span)
                        }

                        let isPrecision = NSEvent.modifierFlags.contains(.option)
                        if isPrecision {
                            if !wasPrecision {
                                // Entering precision: anchor at current playhead
                                precisionAnchorFraction = fraction
                                precisionAnchorX = drag.location.x
                                wasPrecision = true
                            }
                            let delta = (drag.location.x - precisionAnchorX) / width
                            let frac = max(0, min(1, precisionAnchorFraction + delta / precisionFactor))
                            let span = range.upperBound - range.lowerBound
                            value = snapped(range.lowerBound + Double(frac) * span)
                        } else {
                            wasPrecision = false
                            let frac = max(0, min(1, drag.location.x / width))
                            let span = range.upperBound - range.lowerBound
                            value = snapped(range.lowerBound + Double(frac) * span)
                        }
                    }
                    .onEnded { drag in
                        let isPrecision = NSEvent.modifierFlags.contains(.option)
                        if isPrecision && wasPrecision {
                            let delta = (drag.location.x - precisionAnchorX) / width
                            let frac = max(0, min(1, precisionAnchorFraction + delta / precisionFactor))
                            let span = range.upperBound - range.lowerBound
                            value = snapped(range.lowerBound + Double(frac) * span)
                        } else {
                            let frac = max(0, min(1, drag.location.x / width))
                            let span = range.upperBound - range.lowerBound
                            value = snapped(range.lowerBound + Double(frac) * span)
                        }
                        isDragging = false
                        wasPrecision = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: 20)
    }
}
