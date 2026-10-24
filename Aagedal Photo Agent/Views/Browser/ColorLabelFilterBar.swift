import SwiftUI

struct ColorLabelFilterBar: View {
    @Binding var selectedLabels: Set<ColorLabel>

    @State private var isDragging = false
    @State private var dragSetMode = true
    @State private var visitedDuringDrag: Set<ColorLabel> = []

    private let circleSize: CGFloat = 15
    private let circleSpacing: CGFloat = 4
    private let allLabels = ColorLabel.allCases

    var body: some View {
        HStack(spacing: circleSpacing) {
            ForEach(allLabels, id: \.self) { label in
                accessibilityChip(for: label)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color label filter")
        .contentShape(Rectangle())
        .coordinateSpace(name: "colorBar")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("colorBar"))
                .onChanged { value in
                    guard let label = labelAt(x: value.location.x) else { return }

                    if !isDragging {
                        isDragging = true
                        dragSetMode = !selectedLabels.contains(label)
                        visitedDuringDrag = []
                    }

                    if !visitedDuringDrag.contains(label) {
                        visitedDuringDrag.insert(label)
                        if dragSetMode {
                            selectedLabels.insert(label)
                        } else {
                            selectedLabels.remove(label)
                        }
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    visitedDuringDrag = []
                }
        )
    }

    @ViewBuilder
    private func colorCircle(for label: ColorLabel) -> some View {
        let isActive = selectedLabels.contains(label)

        if let color = label.color {
            Circle()
                .fill(color.opacity(isActive ? 1.0 : 0.35))
                .frame(width: circleSize, height: circleSize)
                .overlay(
                    Circle()
                        .strokeBorder(.white, lineWidth: isActive ? 0 : 0)
                )
                .help(label.displayName)
        } else {
            // "None" label — hollow circle. Semantic colour so it shows in light mode too.
            Circle()
                .fill(isActive ? Color.primary : Color.clear)
                .frame(width: circleSize, height: circleSize)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isActive ? Color.primary : Color.primary.opacity(0.4),
                            lineWidth: isActive ? 0 : 1
                        )
                )
                .help("None")
        }
    }

    /// The drag gesture is pointer-only; expose each chip as a toggle for VoiceOver.
    private func accessibilityChip(for label: ColorLabel) -> some View {
        colorCircle(for: label)
            .accessibilityElement()
            .accessibilityLabel("\(label.displayName) label filter")
            .accessibilityAddTraits(selectedLabels.contains(label) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                if selectedLabels.contains(label) {
                    selectedLabels.remove(label)
                } else {
                    selectedLabels.insert(label)
                }
            }
    }

    private func labelAt(x: CGFloat) -> ColorLabel? {
        let itemWidth = circleSize + circleSpacing
        let index = Int(x / itemWidth)
        guard index >= 0, index < allLabels.count else { return nil }
        return allLabels[index]
    }
}
