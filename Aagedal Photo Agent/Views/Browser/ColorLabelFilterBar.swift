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
                colorCircle(for: label)
            }
        }
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
            // "None" label — hollow circle
            Circle()
                .fill(isActive ? Color.white : Color.clear)
                .frame(width: circleSize, height: circleSize)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isActive ? Color.white : Color.white.opacity(0.4),
                            lineWidth: isActive ? 0 : 1
                        )
                )
                .help("None")
        }
    }

    private func labelAt(x: CGFloat) -> ColorLabel? {
        let itemWidth = circleSize + circleSpacing
        let index = Int(x / itemWidth)
        guard index >= 0, index < allLabels.count else { return nil }
        return allLabels[index]
    }
}
