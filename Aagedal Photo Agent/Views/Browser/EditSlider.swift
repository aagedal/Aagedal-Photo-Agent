import AppKit
import os
import SwiftUI

nonisolated private let sliderLog = Logger(
    subsystem: "com.aagedal.photo-agent", category: "EditSlider"
)

/// Marks the `onReset` call of an `EditSlider` double-click whose first click already committed
/// a jumped-to value. Develop folds that reset into the first click's Undo entry, so one Undo
/// returns to the value from before the double-click.
enum EditSliderDoubleClickReset {
    private(set) static var isActive = false

    static func perform(_ reset: () -> Void) {
        isActive = true
        defer { isActive = false }
        reset()
    }
}

/// The Undo/Redo title for the Develop mutation a control commits synchronously ("Undo
/// Exposure"). Sliders set their label around the binding write; `updateCameraRaw` reads it
/// when no explicit action name is passed.
enum DevelopUndoActionName {
    private(set) static var current: String?

    static func perform(_ name: String?, _ body: () -> Void) {
        let previous = current
        current = name ?? previous
        defer { current = previous }
        body()
    }
}

/// A keyboard / VoiceOver stepping session. Steps (incl. key repeats) only preview; the value is
/// committed once — one Develop commit, one Undo entry — when the key is released or after a
/// short pause without another step.
final class EditSliderKeyStepper {
    static let settleDelay: Duration = .milliseconds(300)

    private(set) var pendingValue: Double?
    private var commitTask: Task<Void, Never>?
    private let settleDelay: Duration
    var onBegin: () -> Void = {}
    var onPreview: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void = { _ in }

    init(settleDelay: Duration = EditSliderKeyStepper.settleDelay) {
        self.settleDelay = settleDelay
    }

    var isStepping: Bool { pendingValue != nil }

    func step(from committedValue: Double, range: ClosedRange<Double>, step: Double, direction: Int, large: Bool) {
        let base = pendingValue ?? committedValue
        let newValue = EditSliderStepping.steppedValue(
            from: base, range: range, step: step, direction: direction, large: large
        )
        if newValue != base {
            if pendingValue == nil { onBegin() }
            pendingValue = newValue
            onPreview(newValue)
        }
        guard pendingValue != nil else { return }
        commitTask?.cancel()
        let delay = settleDelay
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.commitNow()
        }
    }

    /// Commits a pending step value now (key-up, mouse-down, or the settle timer).
    func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        guard let value = pendingValue else { return }
        pendingValue = nil
        onCommit(value)
    }
}

/// Keyboard / VoiceOver stepping shared by the horizontal and vertical Develop sliders.
nonisolated enum EditSliderStepping {
    /// One arrow-key step: the slider's own step, but at least 1/200 of the range so fine-step
    /// sliders (Exposure 0.01) still move visibly. Shift (`large`) steps 10x.
    static func steppedValue(
        from value: Double,
        range: ClosedRange<Double>,
        step: Double,
        direction: Int,
        large: Bool
    ) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, direction != 0 else { return value }
        let unit = max(step, span / 200) * (large ? 10 : 1)
        let raw = value + Double(direction.signum()) * unit
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        guard step > 0 else { return clamped }
        let snapped = (clamped / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    /// Up/Right arrow (+1), Down/Left arrow (-1), else nil. Left/Right stay reserved for photo
    /// navigation in Develop (the workspace key monitor consumes them first), so in practice
    /// Up/Down step a focused slider.
    static func direction(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 126, 124: return 1
        case 125, 123: return -1
        default: return nil
        }
    }
}

/// A custom slider using AppKit mouse event handling for high-frequency updates.
/// Delivers drag events at the full hardware mouse rate (~60-120 Hz) instead of
/// SwiftUI DragGesture's throttled ~10 Hz.
///
/// During drag, the binding is NOT updated to avoid triggering SwiftUI observation
/// cascades. Instead, `onDragValueChanged` is called with the raw value for direct
/// Metal pipeline updates. The binding is committed once on drag end.
///
/// Thin track with a vertical playhead line instead of the default circle knob.
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
    /// Spoken name (VoiceOver) and Undo/Redo action title for commits from this slider.
    var label: String?
    /// Formats the value for VoiceOver; nil reads the raw number.
    var valueText: ((Double) -> String)?

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
        // Don't override visual state during drag or key stepping — coordinator controls it
        if !context.coordinator.isDragging, !context.coordinator.keyStepper.isStepping {
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
        /// The last click committed a jumped-to value without dragging; a double-click reset
        /// replaces that value rather than adding a second edit.
        var lastClickCommittedWithoutDrag = false
        var didDragSinceMouseDown = false
        var lastBindingUpdateTime: ContinuousClock.Instant = .now
        private let bindingThrottleInterval: Duration = .milliseconds(32) // ~30 Hz

        // Logging
        var dragEventCount: Int = 0
        var dragStartTimestamp: ContinuousClock.Instant = .now
        var lastDragEventTimestamp: ContinuousClock.Instant = .now

        private let precisionFactor: Double = 10.0

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

        func handleMouseDown(at locationX: CGFloat, width: CGFloat, clickCount: Int) {
            keyStepper.commitNow()
            // AppKit's click count honors the user's double-click speed setting.
            if clickCount >= 2, let onReset = parent.onReset {
                DevelopUndoActionName.perform(parent.label) {
                    if lastClickCommittedWithoutDrag {
                        EditSliderDoubleClickReset.perform(onReset)
                    } else {
                        onReset()
                    }
                }
                lastClickCommittedWithoutDrag = false
                return
            }
            lastClickCommittedWithoutDrag = false
            didDragSinceMouseDown = false
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
            didDragSinceMouseDown = true

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
            DevelopUndoActionName.perform(parent.label) {
                parent.value = currentDragValue
            }

            let elapsed = ContinuousClock.now - dragStartTimestamp
            let totalSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let totalMs = Int(totalSeconds * 1000)
            let rate = totalSeconds > 0 ? Double(dragEventCount) / totalSeconds : 0
            sliderLog.info("⏱ Drag ended: \(self.dragEventCount) events over \(totalMs)ms = \(rate, format: .fixed(precision: 1)) events/sec")
            parent.onEditingChanged?(false)
            lastClickCommittedWithoutDrag = !didDragSinceMouseDown
        }

        /// Keyboard / VoiceOver stepping: previews each step like a drag, commits once.
        lazy var keyStepper: EditSliderKeyStepper = {
            let stepper = EditSliderKeyStepper()
            stepper.onBegin = { [unowned self] in
                lastClickCommittedWithoutDrag = false
                parent.onEditingChanged?(true)
            }
            stepper.onPreview = { [unowned self] value in
                currentDragValue = value
                sliderView?.fraction = fractionForValue(value)
                sliderView?.needsDisplay = true
                if let preview = parent.onDragValueChanged { preview(value) } else { parent.value = value }
            }
            stepper.onCommit = { [unowned self] value in
                DevelopUndoActionName.perform(parent.label) {
                    parent.value = value
                }
                parent.onEditingChanged?(false)
                sliderView?.fraction = fractionForValue(value)
                sliderView?.needsDisplay = true
            }
            return stepper
        }()

        func step(direction: Int, large: Bool) {
            guard !isDragging else { return }
            keyStepper.step(from: parent.value, range: parent.range, step: parent.step,
                            direction: direction, large: large)
        }

        var accessibilityValueText: String {
            let value = isDragging ? currentDragValue : (keyStepper.pendingValue ?? parent.value)
            return parent.valueText?(value) ?? value.formatted(.number.precision(.fractionLength(0...2)))
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
        NSSize(width: NSView.noIntrinsicMetric, height: 16)
    }

    // MARK: Accessibility — an adjustable slider element

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { coordinator?.parent.label }
    override func accessibilityValue() -> Any? { coordinator?.accessibilityValueText }
    override func accessibilityMinValue() -> Any? { coordinator?.parent.range.lowerBound }
    override func accessibilityMaxValue() -> Any? { coordinator?.parent.range.upperBound }

    override func accessibilityPerformIncrement() -> Bool {
        coordinator?.step(direction: 1, large: false)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        coordinator?.step(direction: -1, large: false)
        return true
    }

    /// Arrow keys step a focused slider (Shift = 10x). Left/Right are consumed by the Develop
    /// workspace's photo navigation before they reach here, so Up/Down are the working keys.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty,
              let direction = EditSliderStepping.direction(forKeyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        coordinator?.step(direction: direction, large: event.modifierFlags.contains(.shift))
    }

    override func keyUp(with event: NSEvent) {
        if EditSliderStepping.direction(forKeyCode: event.keyCode) != nil {
            coordinator?.keyStepper.commitNow()
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.keyStepper.commitNow()
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let trackHeight: CGFloat = 3
        let trackY = (bounds.height - trackHeight) / 2
        let trackRect = NSRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)

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
            let markHeight: CGFloat = 7
            let markRect = NSRect(x: centerX - 0.5, y: (bounds.height - markHeight) / 2, width: 1, height: markHeight)
            NSColor.white.withAlphaComponent(0.25).setFill()
            markRect.fill()
        }

        // Playhead
        let isDragging = coordinator?.isDragging ?? false
        let playheadHeight: CGFloat = 12
        let playheadX = max(0, min(bounds.width - 2, bounds.width * CGFloat(fraction) - 1))
        let playheadRect = NSRect(x: playheadX, y: (bounds.height - playheadHeight) / 2, width: 2, height: playheadHeight)
        NSColor.white.withAlphaComponent(isDragging ? 1.0 : 0.8).setFill()
        playheadRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        coordinator?.handleMouseDown(at: location.x, width: bounds.width, clickCount: event.clickCount)
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
