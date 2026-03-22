import AppKit
import os
import SwiftUI

nonisolated(unsafe) private let sliderLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "EditSlider"
)

/// A custom slider using AppKit mouse event handling for high-frequency updates.
/// Delivers drag events at the full hardware mouse rate (~60-120 Hz) instead of
/// SwiftUI DragGesture's throttled ~10 Hz.
///
/// During drag, the binding is NOT updated to avoid triggering SwiftUI observation
/// cascades. Instead, `onDragValueChanged` is called with the raw value for direct
/// Metal pipeline updates. The binding is committed once on drag end.
///
/// Thin 4pt track with a 2pt vertical playhead line instead of the default circle knob.
/// Hold Option while dragging for 10x precision scrubbing.
/// Double-click to reset to default via `onReset` callback.
struct EditSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var gradientColors: [Color]?
    var onEditingChanged: ((Bool) -> Void)?
    /// Called on every drag event with the raw value. Use for direct Metal rendering
    /// that bypasses SwiftUI's observation/re-evaluation cycle.
    /// The binding is NOT updated during drag — only on drag end.
    var onDragValueChanged: ((Double) -> Void)?
    var onReset: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> EditSliderNSView {
        let view = EditSliderNSView(coordinator: context.coordinator)
        context.coordinator.sliderView = view
        updateViewState(view, context: context)
        return view
    }

    func updateNSView(_ nsView: EditSliderNSView, context: Context) {
        context.coordinator.parent = self
        // Don't override visual state during drag — coordinator controls it
        if !context.coordinator.isDragging {
            updateViewState(nsView, context: context)
        }
    }

    private func updateViewState(_ view: EditSliderNSView, context: Context) {
        let span = range.upperBound - range.lowerBound
        view.fraction = span > 0 ? (value - range.lowerBound) / span : 0
        view.isBipolar = range.lowerBound < 0 && range.upperBound > 0
        if view.isBipolar {
            view.centerFraction = -range.lowerBound / span
        }
        if let colors = gradientColors, colors.count >= 2 {
            view.gradientNSColors = colors.map { NSColor($0) }
        } else {
            view.gradientNSColors = nil
        }
        view.needsDisplay = true
    }

    class Coordinator {
        var parent: EditSlider
        weak var sliderView: EditSliderNSView?

        // Drag state
        var isDragging = false
        var currentDragValue: Double = 0
        var wasPrecision = false
        var precisionAnchorFraction: Double = 0
        var precisionAnchorX: CGFloat = 0
        var lastMouseDownTime: Date = .distantPast
        var lastBindingUpdateTime: ContinuousClock.Instant = .now
        private let bindingThrottleInterval: Duration = .milliseconds(32) // ~30 Hz

        // Logging
        var dragEventCount: Int = 0
        var dragStartTimestamp: ContinuousClock.Instant = .now
        var lastDragEventTimestamp: ContinuousClock.Instant = .now

        private let precisionFactor: Double = 10.0
        private let doubleClickInterval: TimeInterval = 0.3

        init(parent: EditSlider) {
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

        func handleMouseDown(at locationX: CGFloat, width: CGFloat) {
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
            dragEventCount = 0
            dragStartTimestamp = .now
            lastDragEventTimestamp = .now
            currentDragValue = parent.value
            sliderLog.info("⏱ Drag started")
            parent.onEditingChanged?(true)

            // Jump to click position
            let frac = max(0, min(1, locationX / width))
            let span = parent.range.upperBound - parent.range.lowerBound
            currentDragValue = snapped(parent.range.lowerBound + Double(frac) * span)

            // Update visual + Metal directly, skip binding
            updateVisualAndNotify()
        }

        func handleMouseDragged(at locationX: CGFloat, width: CGFloat, isOptionDown: Bool) {
            guard isDragging else { return }

            if isOptionDown {
                if !wasPrecision {
                    precisionAnchorFraction = fraction
                    precisionAnchorX = locationX
                    wasPrecision = true
                }
                let delta = (locationX - precisionAnchorX) / width
                let frac = max(0, min(1, precisionAnchorFraction + delta / precisionFactor))
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + Double(frac) * span)
            } else {
                if wasPrecision { wasPrecision = false }
                let frac = max(0, min(1, locationX / width))
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + Double(frac) * span)
            }

            // Update visual + Metal directly, skip binding
            updateVisualAndNotify()
        }

        func handleMouseUp(at locationX: CGFloat, width: CGFloat, isOptionDown: Bool) {
            guard isDragging else { return }

            if isOptionDown && wasPrecision {
                let delta = (locationX - precisionAnchorX) / width
                let frac = max(0, min(1, precisionAnchorFraction + delta / precisionFactor))
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + Double(frac) * span)
            } else {
                let frac = max(0, min(1, locationX / width))
                let span = parent.range.upperBound - parent.range.lowerBound
                currentDragValue = snapped(parent.range.lowerBound + Double(frac) * span)
            }

            isDragging = false
            wasPrecision = false

            // Commit final value to binding (triggers one SwiftUI update)
            parent.value = currentDragValue

            let elapsed = ContinuousClock.now - dragStartTimestamp
            let totalSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let totalMs = Int(totalSeconds * 1000)
            let rate = totalSeconds > 0 ? Double(dragEventCount) / totalSeconds : 0
            sliderLog.info("⏱ Drag ended: \(self.dragEventCount) events over \(totalMs)ms = \(rate, format: .fixed(precision: 1)) events/sec")
            parent.onEditingChanged?(false)
        }

        /// Update NSView playhead and notify caller — without touching the SwiftUI binding.
        /// If no `onDragValueChanged` is set, falls back to updating the binding directly.
        private func updateVisualAndNotify() {
            // Update playhead position directly in NSView
            sliderView?.fraction = fractionForValue(currentDragValue)
            sliderView?.needsDisplay = true

            // Log
            dragEventCount += 1
            let now = ContinuousClock.now
            let gap = now - lastDragEventTimestamp
            let gapSeconds = Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18
            let gapMs = Int(gapSeconds * 1000)
            lastDragEventTimestamp = now
            sliderLog.info("⏱ Drag event #\(self.dragEventCount) — \(gapMs)ms since last — value=\(self.currentDragValue, format: .fixed(precision: 2))")

            if parent.onDragValueChanged != nil {
                // Fast path: bypass binding, notify caller for direct Metal update
                parent.onDragValueChanged?(currentDragValue)
            } else {
                // Fallback: update binding directly (for sliders not tied to @Observable)
                parent.value = currentDragValue
            }
        }
    }
}

/// AppKit view that handles mouse events directly for maximum event delivery rate.
final class EditSliderNSView: NSView {
    private weak var coordinator: EditSlider.Coordinator?

    var fraction: Double = 0
    var isBipolar = false
    var centerFraction: Double = 0.5
    var gradientNSColors: [NSColor]?

    init(coordinator: EditSlider.Coordinator) {
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
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let trackY = (bounds.height - 4) / 2
        let trackRect = NSRect(x: 0, y: trackY, width: bounds.width, height: 4)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2)

        // Track background — gradient or solid
        if let colors = gradientNSColors, colors.count >= 2,
           let nsGradient = NSGradient(colors: colors)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(0.5)
            trackPath.addClip()
            nsGradient.draw(in: trackRect, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor.white.withAlphaComponent(0.15).setFill()
            trackPath.fill()
        }

        // Center mark for bipolar sliders
        if isBipolar {
            let centerX = bounds.width * CGFloat(centerFraction)
            let markRect = NSRect(x: centerX - 0.5, y: (bounds.height - 8) / 2, width: 1, height: 8)
            NSColor.white.withAlphaComponent(0.25).setFill()
            markRect.fill()
        }

        // Playhead
        let isDragging = coordinator?.isDragging ?? false
        let playheadX = max(0, min(bounds.width - 2, bounds.width * CGFloat(fraction) - 1))
        let playheadRect = NSRect(x: playheadX, y: (bounds.height - 14) / 2, width: 2, height: 14)
        NSColor.white.withAlphaComponent(isDragging ? 1.0 : 0.8).setFill()
        playheadRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseDown(at: location.x, width: bounds.width)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isOption = event.modifierFlags.contains(.option)
        coordinator?.handleMouseDragged(at: location.x, width: bounds.width, isOptionDown: isOption)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isOption = event.modifierFlags.contains(.option)
        coordinator?.handleMouseUp(at: location.x, width: bounds.width, isOptionDown: isOption)
    }
}
