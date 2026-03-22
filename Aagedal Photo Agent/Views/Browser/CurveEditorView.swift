import SwiftUI

/// Interactive tone curve editor with master + per-channel (R/G/B) curves.
/// Click to add points, click existing point to select, Delete/Backspace to remove.
/// Renders a Catmull-Rom spline through control points.
struct CurveEditorView: View {
    @Binding var toneCurve: ToneCurve?
    /// Called during drag with the modified ToneCurve for direct Metal update.
    /// The binding is NOT updated during drag to avoid SwiftUI observation overhead.
    var onDragCurveChanged: ((ToneCurve?) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    @State private var selectedChannel: CurveChannel = .master
    @State private var dragIndex: Int?
    @State private var selectedPointIndex: Int?
    @State private var didDragAfterMouseDown = false
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickIndex: Int?
    /// Local copy of tone curve used during drag to avoid writing to binding.
    @State private var dragToneCurve: ToneCurve?
    @State private var isDraggingCurve = false

    enum CurveChannel: String, CaseIterable {
        case master, red, green, blue

        var label: String {
            switch self {
            case .master: "RGB"
            case .red: "R"
            case .green: "G"
            case .blue: "B"
            }
        }

        var color: Color {
            switch self {
            case .master: .white
            case .red: Color(red: 1.0, green: 0.3, blue: 0.3)
            case .green: Color(red: 0.3, green: 1.0, blue: 0.3)
            case .blue: Color(red: 0.4, green: 0.5, blue: 1.0)
            }
        }
    }

    private let defaultPoints: [ToneCurvePoint] = [
        ToneCurvePoint(x: 0, y: 0),
        ToneCurvePoint(x: 1, y: 1),
    ]

    /// Active tone curve: local copy during drag, binding otherwise.
    private var activeToneCurve: ToneCurve? {
        isDraggingCurve ? dragToneCurve : toneCurve
    }

    private func pointsForChannel(_ channel: CurveChannel) -> [ToneCurvePoint] {
        let curve = activeToneCurve
        switch channel {
        case .master: return curve?.master ?? defaultPoints
        case .red: return curve?.red ?? defaultPoints
        case .green: return curve?.green ?? defaultPoints
        case .blue: return curve?.blue ?? defaultPoints
        }
    }

    private func setPointsForChannel(_ channel: CurveChannel, _ points: [ToneCurvePoint]) {
        if isDraggingCurve {
            setPointsOnLocalCopy(channel, points)
        } else {
            setPointsOnBinding(channel, points)
        }
    }

    private func setPointsOnLocalCopy(_ channel: CurveChannel, _ points: [ToneCurvePoint]) {
        if dragToneCurve == nil {
            dragToneCurve = ToneCurve()
        }
        let sorted = points.sorted { $0.x < $1.x }
        switch channel {
        case .master: dragToneCurve?.master = sorted
        case .red: dragToneCurve?.red = sorted.count <= 2 ? nil : sorted
        case .green: dragToneCurve?.green = sorted.count <= 2 ? nil : sorted
        case .blue: dragToneCurve?.blue = sorted.count <= 2 ? nil : sorted
        }
        if let curve = dragToneCurve,
           (curve.master ?? defaultPoints).count <= 2,
           curve.red == nil, curve.green == nil, curve.blue == nil {
            dragToneCurve = nil
        }
        // Notify for direct Metal update
        onDragCurveChanged?(dragToneCurve)
    }

    private func setPointsOnBinding(_ channel: CurveChannel, _ points: [ToneCurvePoint]) {
        if toneCurve == nil {
            toneCurve = ToneCurve()
        }
        let sorted = points.sorted { $0.x < $1.x }
        switch channel {
        case .master: toneCurve?.master = sorted
        case .red: toneCurve?.red = sorted.count <= 2 ? nil : sorted
        case .green: toneCurve?.green = sorted.count <= 2 ? nil : sorted
        case .blue: toneCurve?.blue = sorted.count <= 2 ? nil : sorted
        }
        if let curve = toneCurve,
           (curve.master ?? defaultPoints).count <= 2,
           curve.red == nil, curve.green == nil, curve.blue == nil {
            toneCurve = nil
        }
    }

    private let pointRadius: CGFloat = 5
    private let hitRadius: CGFloat = 12

    private var canDeleteSelectedPoint: Bool {
        guard let index = selectedPointIndex else { return false }
        let points = pointsForChannel(selectedChannel)
        return index > 0 && index < points.count - 1
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("Tone Curve")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if toneCurve != nil {
                    Button {
                        toneCurve = nil
                        selectedPointIndex = nil
                        onDragCurveChanged?(nil)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset tone curve")
                }
            }

            Divider()

            // Channel selector + delete button
            HStack(spacing: 2) {
                ForEach(CurveChannel.allCases, id: \.self) { channel in
                    Button {
                        selectedChannel = channel
                        selectedPointIndex = nil
                    } label: {
                        Text(channel.label)
                            .font(.system(size: 10, weight: selectedChannel == channel ? .bold : .regular))
                            .foregroundStyle(selectedChannel == channel ? channel.color : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(selectedChannel == channel ? Color.white.opacity(0.08) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }

                if canDeleteSelectedPoint {
                    Button {
                        deleteSelectedPoint()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete selected point")
                }
            }

            // Curve canvas
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    // Background
                    Color(nsColor: NSColor(white: 0.08, alpha: 1))

                    // Grid lines
                    gridLines(in: size)

                    // Inactive channel curves (dimmed)
                    ForEach(CurveChannel.allCases.filter { $0 != selectedChannel }, id: \.self) { channel in
                        let pts = pointsForChannel(channel)
                        if pts.count > 2 || channel == .master {
                            curvePath(points: pts, in: size)
                                .stroke(channel.color.opacity(0.2), lineWidth: 1)
                        }
                    }

                    // Active channel curve
                    let activePoints = pointsForChannel(selectedChannel)
                    curvePath(points: activePoints, in: size)
                        .stroke(selectedChannel.color, lineWidth: 1.5)

                    // Control points for active channel
                    ForEach(Array(activePoints.enumerated()), id: \.offset) { index, point in
                        let pos = pointToScreen(point, in: size)
                        let isSelected = selectedPointIndex == index
                        ZStack {
                            if isSelected {
                                Circle()
                                    .stroke(selectedChannel.color, lineWidth: 1.5)
                                    .frame(width: pointRadius * 4, height: pointRadius * 4)
                            }
                            Circle()
                                .fill(selectedChannel.color)
                                .frame(width: pointRadius * 2, height: pointRadius * 2)
                        }
                        .position(pos)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDraggingCurve {
                                // Start drag: snapshot binding to local copy
                                dragToneCurve = toneCurve
                                isDraggingCurve = true
                            }
                            handleDrag(drag, in: size)
                        }
                        .onEnded { _ in
                            if dragIndex != nil {
                                // If we only clicked without dragging, just select the point
                                if !didDragAfterMouseDown {
                                    selectedPointIndex = dragIndex
                                }
                                dragIndex = nil
                                // Commit local copy to binding (one SwiftUI update)
                                toneCurve = dragToneCurve
                                isDraggingCurve = false
                                onEditingChanged?(false)
                            } else {
                                // Click-to-add: commit immediately
                                toneCurve = dragToneCurve
                                isDraggingCurve = false
                            }
                            didDragAfterMouseDown = false
                        }
                )
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    // MARK: - Grid

    private func gridLines(in size: CGSize) -> some View {
        Canvas { context, _ in
            let gridColor = Color.white.opacity(0.08)
            for i in 1...3 {
                let frac = CGFloat(i) / 4.0
                let x = frac * size.width
                let y = (1.0 - frac) * size.height
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(gridColor)
                )
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(gridColor)
                )
            }
            // Diagonal identity line
            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                with: .color(Color.white.opacity(0.06))
            )
        }
    }

    // MARK: - Curve Path

    private func curvePath(points: [ToneCurvePoint], in size: CGSize) -> Path {
        Path { path in
            let steps = max(Int(size.width), 100)
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let y = ToneCurveGenerator.evaluateCatmullRom(points, at: x)
                let screenPoint = CGPoint(
                    x: x * size.width,
                    y: (1.0 - max(0, min(1, y))) * size.height
                )
                if i == 0 {
                    path.move(to: screenPoint)
                } else {
                    path.addLine(to: screenPoint)
                }
            }
        }
    }

    // MARK: - Coordinate Conversion

    private func pointToScreen(_ point: ToneCurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1.0 - point.y) * size.height)
    }

    private func screenToPoint(_ location: CGPoint, in size: CGSize) -> ToneCurvePoint {
        ToneCurvePoint(
            x: max(0, min(1, location.x / size.width)),
            y: max(0, min(1, 1.0 - location.y / size.height))
        )
    }

    // MARK: - Interaction

    private func handleDrag(_ drag: DragGesture.Value, in size: CGSize) {
        let points = pointsForChannel(selectedChannel)

        if dragIndex == nil {
            didDragAfterMouseDown = false
            // Find nearest point within hit radius
            var hitIndex: Int?
            for (i, point) in points.enumerated() {
                let screenPos = pointToScreen(point, in: size)
                let dist = hypot(drag.startLocation.x - screenPos.x, drag.startLocation.y - screenPos.y)
                if dist < hitRadius {
                    hitIndex = i
                    break
                }
            }

            // Double-click detection: same point clicked twice within 0.3s
            if let hit = hitIndex {
                let now = Date()
                if hit == lastClickIndex && now.timeIntervalSince(lastClickTime) < 0.3 {
                    // Double-click on a point — delete it (if not an endpoint)
                    if hit > 0 && hit < points.count - 1 {
                        var newPoints = points
                        newPoints.remove(at: hit)
                        selectedPointIndex = nil
                        lastClickIndex = nil
                        lastClickTime = .distantPast
                        setPointsForChannel(selectedChannel, newPoints)
                        return
                    }
                }
                lastClickTime = now
                lastClickIndex = hit
                dragIndex = hit
                selectedPointIndex = hit
                onEditingChanged?(true)
            }

            // If no point hit, add a new point
            if hitIndex == nil {
                selectedPointIndex = nil
                let newPoint = screenToPoint(drag.startLocation, in: size)
                var newPoints = points
                newPoints.append(newPoint)
                newPoints.sort { $0.x < $1.x }
                setPointsForChannel(selectedChannel, newPoints)
                // Find the index of the newly added point
                let updatedPoints = pointsForChannel(selectedChannel)
                for (i, p) in updatedPoints.enumerated() {
                    if abs(p.x - newPoint.x) < 0.001 && abs(p.y - newPoint.y) < 0.001 {
                        dragIndex = i
                        selectedPointIndex = i
                        onEditingChanged?(true)
                        break
                    }
                }
                return
            }
        }

        // Detect actual dragging (moved more than a few pixels from start)
        let dragDist = hypot(drag.location.x - drag.startLocation.x, drag.location.y - drag.startLocation.y)
        if dragDist > 3 {
            didDragAfterMouseDown = true
        }

        guard let index = dragIndex, didDragAfterMouseDown else { return }
        var currentPoints = pointsForChannel(selectedChannel)
        guard index < currentPoints.count else { return }

        let newPoint = screenToPoint(drag.location, in: size)

        // Endpoints can move vertically only
        if index == 0 {
            currentPoints[0] = ToneCurvePoint(x: 0, y: max(0, min(1, newPoint.y)))
        } else if index == currentPoints.count - 1 {
            currentPoints[index] = ToneCurvePoint(x: 1, y: max(0, min(1, newPoint.y)))
        } else {
            // Interior points: clamp x between neighbors
            let minX = currentPoints[index - 1].x + 0.005
            let maxX = currentPoints[index + 1].x - 0.005
            currentPoints[index] = ToneCurvePoint(
                x: max(minX, min(maxX, newPoint.x)),
                y: max(0, min(1, newPoint.y))
            )
        }

        setPointsForChannel(selectedChannel, currentPoints)
    }

    private func deleteSelectedPoint() {
        guard let index = selectedPointIndex else { return }
        var points = pointsForChannel(selectedChannel)
        // Don't allow removing endpoints
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
        selectedPointIndex = nil
        setPointsForChannel(selectedChannel, points)
    }
}
