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
    var onEditingChanged: ((Bool) -> Void)?
    var onDragValueChanged: ((Double) -> Void)?
    var onReset: (() -> Void)?
    /// Override reset button visibility. When nil, shows reset when `abs(value) > 0.001`.
    var showReset: Bool?
    var resetHelp: String = "Reset to default"

    @State private var dragDisplayValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let onReset, shouldShowReset {
                    Button {
                        onReset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(resetHelp)
                }
                Spacer()
                Text(formattedDisplayValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                onReset: onReset
            )
            .frame(height: 20)
        }
    }

    private var shouldShowReset: Bool {
        if let showReset { return showReset }
        return abs(value) > 0.001
    }

    private var formattedDisplayValue: String {
        let raw = dragDisplayValue ?? value
        let transformed = displayValueTransform?(raw) ?? raw
        return formatter(transformed)
    }
}
