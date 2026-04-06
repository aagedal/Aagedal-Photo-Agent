import AppKit
import SwiftUI

/// Vertical variant of EditSlider. Bottom = min, top = max.
/// Same two-phase drag pattern: `onDragValueChanged` during drag (bypasses binding),
/// binding committed on drag end.
/// Hold Option for 10x precision. Double-click to reset.
struct EditVerticalSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var onEditingChanged: ((Bool) -> Void)?
    var onDragValueChanged: ((Double) -> Void)?
    var onReset: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> EditVerticalSliderNSView {
        let view = EditVerticalSliderNSView(coordinator: context.coordinator)
        context.coordinator.sliderView = view
        updateViewState(view)
        return view
    }

    func updateNSView(_ nsView: EditVerticalSliderNSView, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isDragging {
            updateViewState(nsView)
        }
    }

    private func updateViewState(_ view: EditVerticalSliderNSView) {
        let span = range.upperBound - range.lowerBound
        view.fraction = span > 0 ? (value - range.lowerBound) / span : 0
        view.isBipolar = range.lowerBound < 0 && range.upperBound > 0
        if view.isBipolar {
            view.centerFraction = -range.lowerBound / span
        }
        view.needsDisplay = true
    }

    class Coordinator {
        var parent: EditVerticalSlider
        weak var sliderView: EditVerticalSliderNSView?

        var isDragging = false
        var currentDragValue: Double = 0
        var wasPrecision = false
        var precisionAnchorFraction: Double = 0
        var precisionAnchorY: CGFloat = 0
        var lastMouseDownTime: Date = .distantPast

        private let precisionFactor: Double = 10.0
        private let doubleClickInterval: TimeInterval = 0.3

        init(parent: EditVerticalSlider) {
            self.parent = parent
        }

        private var fraction: Double {
            let span = parent.range.upperBound - parent.range.lowerBound
            guard span > 0 else { return 0 }
            return (currentDragValue - parent.range.lowerBound) / span
        }

        private func snapped(_ raw: Double) -> Double {
            let clamped = max(parent.range.lowerBound, min(parent.range.upperBound, raw))
            return parent.step > 0 ? (clamped / parent.step).rounded() * parent.step : clamped
        }

        private func fractionForValue(_ value: Double) -> Double {
            let span = parent.range.upperBound - parent.range.lowerBound
            guard span > 0 else { return 0 }
            return (value - parent.range.lowerBound) / span
        }

        /// Convert Y location (flipped: 0=top) to fraction (0=min=bottom, 1=max=top).
        private func yToFraction(_ y: CGFloat, height: CGFloat) -> Double {
            // Flipped coordinates: y=0 is top, y=height is bottom
            // We want top=max(1), bottom=min(0)
            max(0, min(1, 1.0 - Double(y / height)))
        }

        func handleMouseDown(at locationY: CGFloat, height: CGFloat) {
            let now = Date()
            if now.timeIntervalSince(lastMouseDownTime) < doubleClickInterval,
               let onReset = parent.onReset
            {
                onReset()
                lastMouseDownTime = .distantPast
                return
            }
            lastMouseDownTime = now
            isDragging = true
            wasPrecision = false
            currentDragValue = parent.value
            parent.onEditingChanged?(true)

            let frac = yToFraction(locationY, height: height)
            let span = parent.range.upperBound - parent.range.lowerBound
            currentDragValue = snapped(parent.range.lowerBound + frac * span)
            updateVisualAndNotify()
        }

        func handleMouseDragged(at locationY: CGFloat, height: CGFloat, isOptionDown: Bool) {
            guard isDragging else { return }

            if isOptionDown {
                if !wasPrecision {
                    precisionAnchorFraction = fraction
                    precisionAnchorY = locationY
                    wasPrecision = true
                }
                let delta = -(locationY - precisionAnchorY) / height // negative because flipped
                let frac = max(0, min(1, precisionAnchorFraction + delta / precisionFactor))
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + frac * span)
            } else {
                if wasPrecision { wasPrecision = false }
                let frac = yToFraction(locationY, height: height)
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + frac * span)
            }
            updateVisualAndNotify()
        }

        func handleMouseUp(at locationY: CGFloat, height: CGFloat, isOptionDown: Bool) {
            guard isDragging else { return }

            if isOptionDown && wasPrecision {
                let delta = -(locationY - precisionAnchorY) / height
                let frac = max(0, min(1, precisionAnchorFraction + delta / precisionFactor))
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + frac * span)
            } else {
                let frac = yToFraction(locationY, height: height)
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + frac * span)
            }

            isDragging = false
            wasPrecision = false
            parent.value = currentDragValue
            parent.onEditingChanged?(false)
        }

        private func updateVisualAndNotify() {
            sliderView?.fraction = fractionForValue(currentDragValue)
            sliderView?.needsDisplay = true

            if parent.onDragValueChanged != nil {
                parent.onDragValueChanged?(currentDragValue)
            } else {
                parent.value = currentDragValue
            }
        }
    }
}

final class EditVerticalSliderNSView: NSView {
    private weak var coordinator: EditVerticalSlider.Coordinator?

    var fraction: Double = 0
    var isBipolar = false
    var centerFraction: Double = 0.5

    init(coordinator: EditVerticalSlider.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let trackX = (bounds.width - 4) / 2
        let trackRect = NSRect(x: trackX, y: 0, width: 4, height: bounds.height)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2)

        NSColor.white.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        // Center mark for bipolar sliders
        if isBipolar {
            let centerY = bounds.height * CGFloat(1.0 - centerFraction)
            let markRect = NSRect(x: (bounds.width - 8) / 2, y: centerY - 0.5, width: 8, height: 1)
            NSColor.white.withAlphaComponent(0.25).setFill()
            markRect.fill()
        }

        // Playhead — horizontal line (fraction: 0=bottom, 1=top → y inverted)
        let isDragging = coordinator?.isDragging ?? false
        let playheadY = max(0, min(bounds.height - 2, bounds.height * CGFloat(1.0 - fraction) - 1))
        let playheadRect = NSRect(x: (bounds.width - 14) / 2, y: playheadY, width: 14, height: 2)
        NSColor.white.withAlphaComponent(isDragging ? 1.0 : 0.8).setFill()
        playheadRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseDown(at: location.y, height: bounds.height)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isOption = event.modifierFlags.contains(.option)
        coordinator?.handleMouseDragged(at: location.y, height: bounds.height, isOptionDown: isOption)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isOption = event.modifierFlags.contains(.option)
        coordinator?.handleMouseUp(at: location.y, height: bounds.height, isOptionDown: isOption)
    }
}
