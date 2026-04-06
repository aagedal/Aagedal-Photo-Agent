import SwiftUI

/// Per-color Hue/Saturation/Density panel with 7 channels matching the vectorscope targets.
/// Each channel has two vertical sliders (Saturation, Density) and one horizontal slider (Hue).
///
/// During drag, `onDragChanged` receives a modified copy of the adjustments with the drag value
/// applied — the binding is NOT updated until drag ends (two-phase pattern matching EditSlider).
struct HSLAdjustmentView: View {
    @Binding var adjustments: HSLAdjustments
    var onEditingChanged: ((Bool) -> Void)?
    var onDragChanged: ((HSLAdjustments) -> Void)?
    var onDragEnded: (() -> Void)?

    private static let channels: [(label: String, color: Color, keyPath: WritableKeyPath<HSLAdjustments, HSLColorAdjustment?>)] = [
        ("R", Color(red: 0.85, green: 0.20, blue: 0.20), \.red),
        ("Y", Color(red: 0.85, green: 0.85, blue: 0.20), \.yellow),
        ("G", Color(red: 0.20, green: 0.85, blue: 0.20), \.green),
        ("C", Color(red: 0.20, green: 0.85, blue: 0.85), \.cyan),
        ("B", Color(red: 0.20, green: 0.20, blue: 0.85), \.blue),
        ("M", Color(red: 0.85, green: 0.20, blue: 0.85), \.magenta),
        ("Sk", Color(red: 0.50, green: 0.42, blue: 0.34), \.skinTone),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.channels.enumerated()), id: \.offset) { _, channel in
                let keyPath = channel.keyPath
                HSLChannelColumn(
                    label: channel.label,
                    color: channel.color,
                    adjustment: channelBinding(keyPath),
                    onEditingChanged: { editing in
                        onEditingChanged?(editing)
                    },
                    onDragAdjustment: { modified in
                        var copy = adjustments
                        copy[keyPath: keyPath] = modified.isEmpty ? nil : modified
                        onDragChanged?(copy)
                    },
                    onDragEnded: {
                        onDragEnded?()
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func channelBinding(_ keyPath: WritableKeyPath<HSLAdjustments, HSLColorAdjustment?>) -> Binding<HSLColorAdjustment> {
        Binding(
            get: { adjustments[keyPath: keyPath] ?? HSLColorAdjustment() },
            set: { newValue in
                adjustments[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }
}

/// Single channel column: colored dot, two vertical sliders (Sat/Dens), horizontal Hue slider.
private struct HSLChannelColumn: View {
    let label: String
    let color: Color
    @Binding var adjustment: HSLColorAdjustment
    var onEditingChanged: ((Bool) -> Void)?
    /// Called during drag with a modified copy of the adjustment containing the drag value.
    var onDragAdjustment: ((HSLColorAdjustment) -> Void)?
    var onDragEnded: (() -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            HStack(spacing: 2) {
                EditVerticalSlider(
                    value: satBinding,
                    range: -100...100,
                    step: 1,
                    onEditingChanged: { editing in
                        onEditingChanged?(editing)
                        if !editing { onDragEnded?() }
                    },
                    onDragValueChanged: { dragValue in
                        var modified = adjustment
                        let intVal = Int(dragValue.rounded())
                        modified.saturation = intVal == 0 ? nil : intVal
                        onDragAdjustment?(modified)
                    },
                    onReset: {
                        satBinding.wrappedValue = 0
                        onDragEnded?()
                    }
                )
                .frame(width: 16)

                EditVerticalSlider(
                    value: densBinding,
                    range: -100...100,
                    step: 1,
                    onEditingChanged: { editing in
                        onEditingChanged?(editing)
                        if !editing { onDragEnded?() }
                    },
                    onDragValueChanged: { dragValue in
                        var modified = adjustment
                        let intVal = Int(dragValue.rounded())
                        modified.luminance = intVal == 0 ? nil : intVal
                        onDragAdjustment?(modified)
                    },
                    onReset: {
                        densBinding.wrappedValue = 0
                        onDragEnded?()
                    }
                )
                .frame(width: 16)
            }
            .frame(height: 100)

            HStack(spacing: 2) {
                Text("S").font(.system(size: 7))
                    .frame(width: 16)
                Text("D").font(.system(size: 7))
                    .frame(width: 16)
            }
            .foregroundStyle(.secondary)

            EditSlider(
                value: hueBinding,
                range: -100...100,
                step: 1,
                onEditingChanged: { editing in
                    if !editing { onDragEnded?() }
                },
                onDragValueChanged: { dragValue in
                    var modified = adjustment
                    let intVal = Int(dragValue.rounded())
                    modified.hueShift = intVal == 0 ? nil : intVal
                    onDragAdjustment?(modified)
                },
                onReset: {
                    hueBinding.wrappedValue = 0
                    onDragEnded?()
                }
            )
            .frame(height: 16)
            .padding(.horizontal, 2)

            Text("H").font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
    }

    private var satBinding: Binding<Double> {
        Binding(
            get: { Double(adjustment.saturation ?? 0) },
            set: { adjustment.saturation = Int($0.rounded()) == 0 ? nil : Int($0.rounded()) }
        )
    }

    private var densBinding: Binding<Double> {
        Binding(
            get: { Double(adjustment.luminance ?? 0) },
            set: { adjustment.luminance = Int($0.rounded()) == 0 ? nil : Int($0.rounded()) }
        )
    }

    private var hueBinding: Binding<Double> {
        Binding(
            get: { Double(adjustment.hueShift ?? 0) },
            set: { adjustment.hueShift = Int($0.rounded()) == 0 ? nil : Int($0.rounded()) }
        )
    }
}
