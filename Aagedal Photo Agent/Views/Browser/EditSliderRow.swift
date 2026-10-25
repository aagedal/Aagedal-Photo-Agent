import SwiftUI

/// A slider row with a label, optional reset button, and a formatted value display.
/// Extracted as a standalone View so that `@State` changes (live drag value display)
/// only re-evaluate this tiny body — not the parent's 2700-line body.
struct EditSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var gradientColors: [Color]?
    let formatter: (Double) -> String
    /// Transforms the raw slider value before passing it to `formatter` for display.
    /// Use for sliders where the binding operates on a different scale than the display
    /// (e.g., normalized log-scale 0...1 → Kelvin 2000...50000).
    var displayValueTransform: ((Double) -> Double)?
    /// Maps a typed display value back to the binding's scale. Required for typing into a row
    /// with `displayValueTransform`; rows without a transform type in their own units.
    var displayValueInverse: ((Double) -> Double)?
    var onEditingChanged: ((Bool) -> Void)?
    var onDragValueChanged: ((Double) -> Void)?
    var onReset: (() -> Void)?
    /// Override reset button visibility. When nil, shows reset when `abs(value) > 0.001`.
    var showReset: Bool?
    var resetHelp: String = "Reset to default"

    @State private var dragDisplayValue: Double?
    @State private var typedText: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                if let onReset, shouldShowReset {
                    Button {
                        DevelopUndoActionName.perform(label, onReset)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(resetHelp)
                    .accessibilityLabel("Reset \(label)")
                }
                Spacer()
                if typedText != nil {
                    TextField(label, text: Binding(get: { typedText ?? "" }, set: { typedText = $0 }))
                        .textFieldStyle(.plain)
                        .font(.caption.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .focused($isTyping)
                        .onSubmit(commitTypedValue)
                        .onExitCommand { typedText = nil }
                        .onChange(of: isTyping) { _, focused in
                            if !focused { typedText = nil }
                        }
                        .accessibilityLabel("\(label) value")
                } else {
                    Text(formattedDisplayValue)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { beginTyping() }
                        .help(canType ? "Click to type a value" : "")
                        // The slider element below speaks the label and value.
                        .accessibilityHidden(true)
                }
            }
            EditSlider(
                value: $value,
                range: range,
                step: step,
                gradientColors: gradientColors,
                onEditingChanged: { editing in
                    if !editing {
                        dragDisplayValue = nil
                    }
                    onEditingChanged?(editing)
                },
                onDragValueChanged: { dragValue in
                    dragDisplayValue = dragValue
                    onDragValueChanged?(dragValue)
                },
                onReset: onReset,
                label: label,
                valueText: { formatter(displayValueTransform?($0) ?? $0) }
            )
            .frame(height: 16)
        }
    }

    private var shouldShowReset: Bool {
        if let showReset { return showReset }
        return abs(value) > 0.001
    }

    private var canType: Bool { displayValueTransform == nil || displayValueInverse != nil }

    private func beginTyping() {
        guard canType else { return }
        let displayed = displayValueTransform?(value) ?? value
        typedText = EditSliderTypedValue.editableText(for: displayed, step: displayValueTransform == nil ? step : 1)
        isTyping = true
    }

    /// A typed value commits like one slider release: one Develop commit and one Undo step.
    private func commitTypedValue() {
        defer { typedText = nil }
        guard let text = typedText, let typed = EditSliderTypedValue.parse(text) else { return }
        let raw = displayValueInverse?(typed) ?? typed
        let newValue = EditSliderTypedValue.clamped(raw, to: range, step: step)
        guard newValue != value else { return }
        onEditingChanged?(true)
        DevelopUndoActionName.perform(label) { value = newValue }
        onEditingChanged?(false)
    }

    private var formattedDisplayValue: String {
        let raw = dragDisplayValue ?? value
        let transformed = displayValueTransform?(raw) ?? raw
        return formatter(transformed)
    }
}

/// Parsing for values typed into a Develop slider's value field.
nonisolated enum EditSliderTypedValue {
    /// Accepts "+25", "-0,5", "−12", "5200K", "40%" or "12px": the first number wins and any
    /// unit or sign decoration around it is ignored.
    static func parse(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        guard let match = normalized.firstMatch(of: /[-+]?\d*\.?\d+/) else { return nil }
        return Double(match.output)
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>, step: Double) -> Double {
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        guard step > 0 else { return bounded }
        let snapped = (bounded / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    static func editableText(for value: Double, step: Double) -> String {
        let decimals = step > 0 && step < 1 ? min(4, Int(ceil(-log10(step)))) : 0
        return value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }
}
