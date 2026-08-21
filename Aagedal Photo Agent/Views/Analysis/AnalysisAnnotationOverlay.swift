import AppKit
import SwiftUI

enum AnalysisAnnotationTool: String, CaseIterable, Identifiable {
    case select
    case hand
    case marker
    case line
    case arrow
    case distance
    case rectangle
    case ellipse
    case shape
    case label

    var id: Self { self }

    var displayName: String {
        switch self {
        case .select: "Select"
        case .hand: "Hand"
        case .marker: "Marker"
        case .line: "Line"
        case .arrow: "Arrow"
        case .distance: "Distance"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .shape: "Polygon"
        case .label: "Label"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.draw"
        case .marker: "mappin"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .distance: "ruler"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .shape: "pentagon"
        case .label: "character.cursor.ibeam"
        }
    }

    var annotationKind: AnalysisAnnotationKind? {
        switch self {
        case .select, .hand, .marker: nil
        case .line: .line
        case .arrow: .arrow
        case .distance: .distance
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .shape: .polygon
        case .label: .label
        }
    }

    var photoShortcutKey: String? {
        switch self {
        case .select: "V"
        case .hand: "H"
        case .line: "L"
        case .arrow: "A"
        case .distance: "D"
        case .rectangle: "R"
        case .ellipse: "E"
        case .shape: "P"
        case .label: "T"
        case .marker: nil
        }
    }

    static func photoTool(forShortcut key: String) -> Self? {
        switch key.lowercased() {
        case "v": .select
        case "h": .hand
        case "l": .line
        case "a": .arrow
        case "d": .distance
        case "r": .rectangle
        case "e": .ellipse
        case "p": .shape
        case "t": .label
        default: nil
        }
    }

    static let photoTools: [Self] = [
        .select, .hand, .line, .arrow, .distance, .rectangle, .ellipse, .shape, .label,
    ]

    static let mapTools: [Self] = [
        .select, .marker, .line, .distance, .shape, .label,
    ]

}

struct AnalysisAnnotationGestureDraft {
    let kind: AnalysisAnnotationKind
    let start: AnalysisNormalizedPoint
    let current: AnalysisNormalizedPoint
}

struct AnalysisAnnotationToolbar: View {
    @Binding var tool: AnalysisAnnotationTool
    @Binding var style: AnalysisAnnotationStyle
    let selectedAnnotationID: UUID?
    let isReadOnly: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undoActionName: String?
    let redoActionName: String?
    let onUndo: () -> Void
    let onRedo: () -> Void
    let canCalibrate: Bool
    let selectedIsCalibration: Bool
    let onCalibrate: () -> Void
    let onDelete: () -> Void
    var tools: [AnalysisAnnotationTool] = AnalysisAnnotationTool.photoTools
    var contextLabel: String = "Photo"
    var secondaryTool: Binding<AnalysisAnnotationTool>?
    var secondaryTools: [AnalysisAnnotationTool] = []
    var secondaryContextLabel = "Map"
    var canEditLabel = false
    var selectedHasLabel = false
    var showsLabelActionTitle = false
    var photoFinishActionTitle: String?
    var photoDraftIsActive = false
    var onPhotoFinishAction: () -> Void = {}
    var onCancelPhotoDraft: () -> Void = {}
    var mapActionTitle: String?
    var mapFinishActionTitle: String?
    var mapDraftIsActive = false
    var onMapAction: () -> Void = {}
    var onMapFinishAction: () -> Void = {}
    var onCancelMapDraft: () -> Void = {}
    var onEditLabel: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text("MARKUP")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let secondaryTool {
                toolGroup(
                    contextLabel,
                    selection: $tool,
                    tools: tools
                )

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 2)

                toolGroup(
                    secondaryContextLabel,
                    selection: secondaryTool,
                    tools: secondaryTools
                )

                if let mapActionTitle {
                    Button(mapActionTitle, action: onMapAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isReadOnly)
                }

                if let mapFinishActionTitle {
                    Button(mapFinishActionTitle, action: onMapFinishAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isReadOnly)
                }

                if mapDraftIsActive {
                    Button(action: onCancelMapDraft) {
                        Label("Cancel Map Markup", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly)
                    .help("Cancel the in-progress map markup")
                }
            } else {
                toolPicker(selection: $tool, tools: tools)
            }

            if let photoFinishActionTitle {
                Button(photoFinishActionTitle, action: onPhotoFinishAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isReadOnly)
            }

            if photoDraftIsActive {
                Button(action: onCancelPhotoDraft) {
                    Label("Cancel Photo Polygon", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(isReadOnly)
                .help("Cancel the in-progress photo polygon")
            }

            HStack(spacing: 5) {
                ForEach(AnalysisAnnotationPaletteColor.allCases, id: \.self) { color in
                    Button {
                        style.color = .palette(color)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AnalysisAnnotationColor.palette(color).swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(
                                        style.color == .palette(color)
                                            ? Color.accentColor
                                            : Color.primary.opacity(0.35),
                                        lineWidth: style.color == .palette(color) ? 3 : 1
                                    )
                            }
                            .overlay {
                                if style.color == .palette(color) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(
                                            AnalysisAnnotationColor.palette(color).contrastColor
                                        )
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(color.displayName)
                    .accessibilityLabel("\(color.displayName) annotation color")
                    .accessibilityAddTraits(
                        style.color == .palette(color) ? .isSelected : []
                    )
                }

                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 6)

                ColorPicker(
                    "Custom Color",
                    selection: Binding(
                        get: { style.color.swiftUIColor },
                        set: { style.color = .customColor(from: $0) }
                    ),
                    supportsOpacity: true
                )
                .labelsHidden()
                .frame(width: 22)
                .help("Custom annotation color")
            }
            .fixedSize()
            .disabled(isReadOnly)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Annotation colors")

            Spacer(minLength: 0)

            Button(action: onUndo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(isReadOnly || !canUndo)
            .help(undoActionName.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)")

            Button(action: onRedo) {
                Label("Redo", systemImage: "arrow.uturn.forward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(isReadOnly || !canRedo)
            .help(redoActionName.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)")

            Button(action: onCalibrate) {
                Label(
                    selectedIsCalibration ? "Edit Measurement Calibration" : "Calibrate Distance",
                    systemImage: selectedIsCalibration ? "ruler.fill" : "ruler"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly || !canCalibrate)
            .help(
                selectedIsCalibration
                    ? "Edit the known real-world length for the selected distance"
                    : "Use the selected distance as a real-world measurement calibration"
            )

            Button(action: onEditLabel) {
                HStack(spacing: 5) {
                    Image(systemName: selectedHasLabel ? "note.text" : "note.text.badge.plus")
                    if showsLabelActionTitle {
                        Text(selectedHasLabel ? "Edit Details" : "Label / Note")
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly || !canEditLabel)
            .help(selectedHasLabel ? "Edit the selected annotation details" : "Add a label or note")

            Button(role: .destructive, action: onDelete) {
                Label("Delete Annotation", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly || selectedAnnotationID == nil)
            .help("Delete the selected annotation")

            if isReadOnly {
                Label("Read-only: source changed", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(contextLabel) markup tools")
    }

    private func toolGroup(
        _ title: String,
        selection: Binding<AnalysisAnnotationTool>,
        tools: [AnalysisAnnotationTool]
    ) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            toolPicker(selection: selection, tools: tools)
        }
        .fixedSize()
    }

    private func toolPicker(
        selection: Binding<AnalysisAnnotationTool>,
        tools: [AnalysisAnnotationTool]
    ) -> some View {
        Picker("\(contextLabel) Markup Tool", selection: selection) {
            ForEach(tools) { tool in
                let shortcutKey = tools == AnalysisAnnotationTool.photoTools
                    ? tool.photoShortcutKey
                    : nil
                Label(tool.displayName, systemImage: tool.systemImage)
                    .labelStyle(.iconOnly)
                    .tag(tool)
                    .help(
                        shortcutKey.map { "\(tool.displayName) (\($0))" }
                            ?? tool.displayName
                    )
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(isReadOnly)
    }
}

struct AnalysisAnnotationOverlay: View {
    let annotations: [AnalysisAnnotation]
    let draft: AnalysisAnnotation?
    let selectedAnnotationID: UUID?
    let geometry: ImageInspectionGeometry
    let coordinateMapper: AnalysisAnnotationCoordinateMapper
    let measurementScale: AnalysisMeasurementScale?

    var body: some View {
        Canvas { context, _ in
            for annotation in annotations where annotation.id != draft?.id {
                draw(
                    annotation,
                    selected: annotation.id == selectedAnnotationID,
                    context: &context
                )
            }
            if let draft {
                draw(
                    draft,
                    selected: draft.id == selectedAnnotationID,
                    isDraft: draft.id != selectedAnnotationID,
                    context: &context
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Photo annotations")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let measurements = annotations.compactMap {
            AnalysisSourcePixelMeasurement(
                annotation: $0,
                annotationTransform: coordinateMapper.annotationTransform
            )?.formattedLength(calibratedBy: measurementScale)
                .replacingOccurrences(of: " px", with: " pixels")
        }
        guard !measurements.isEmpty else { return "\(annotations.count) visible" }
        return "\(annotations.count) visible; source-pixel distances: "
            + measurements.joined(separator: ", ")
    }

    private func draw(
        _ annotation: AnalysisAnnotation,
        selected: Bool,
        isDraft: Bool = false,
        context: inout GraphicsContext
    ) {
        let path = AnalysisAnnotationViewGeometry.path(
            for: annotation,
            geometry: geometry,
            coordinateMapper: coordinateMapper
        )
        let color = annotation.style.color.swiftUIColor.opacity(isDraft ? 0.72 : 1)
        let contrast = annotation.style.color.contrastColor.opacity(isDraft ? 0.55 : 0.82)
        let width = CGFloat(annotation.style.lineWidthPoints)

        if annotation.geometry.supportsFill, annotation.style.fillOpacity > 0 {
            context.fill(
                path,
                with: .color(color.opacity(annotation.style.fillOpacity))
            )
        }

        context.stroke(
            path,
            with: .color(contrast),
            style: StrokeStyle(
                lineWidth: width + 2,
                lineCap: .round,
                lineJoin: .round
            )
        )
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: width,
                lineCap: .round,
                lineJoin: .round
            )
        )

        if let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let placement = AnalysisAnnotationViewGeometry.annotationLabelPlacement(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            let label = Text(text).font(.caption.weight(.semibold))
            context.draw(
                label.foregroundColor(contrast),
                at: CGPoint(x: placement.point.x + 1, y: placement.point.y + 1),
                anchor: placement.anchor
            )
            context.draw(
                label.foregroundColor(color),
                at: placement.point,
                anchor: placement.anchor
            )
        }

        if let measurement = AnalysisSourcePixelMeasurement(
            annotation: annotation,
            annotationTransform: coordinateMapper.annotationTransform
        ), case .segment(let start, let end) = annotation.geometry {
            let first = AnalysisAnnotationViewGeometry.viewPoint(
                start,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            let last = AnalysisAnnotationViewGeometry.viewPoint(
                end,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            let labelPoint = AnalysisAnnotationViewGeometry.measurementLabelPoint(
                start: first,
                end: last,
                imageRect: geometry.imageRectInView
            )
            let label = Text(measurement.formattedLength(calibratedBy: measurementScale))
                .font(.caption2.monospacedDigit().weight(.semibold))
            context.draw(
                label.foregroundColor(contrast),
                at: CGPoint(x: labelPoint.x + 1, y: labelPoint.y + 1),
                anchor: .center
            )
            context.draw(
                label.foregroundColor(color),
                at: labelPoint,
                anchor: .center
            )
        }

        if isDraft, case .polygon = annotation.geometry {
            let vertices = AnalysisAnnotationViewGeometry.controlPoints(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            for (_, point) in vertices {
                let halo = Path(ellipseIn: CGRect(
                    x: point.x - 5,
                    y: point.y - 5,
                    width: 10,
                    height: 10
                ))
                let center = Path(ellipseIn: CGRect(
                    x: point.x - 2.5,
                    y: point.y - 2.5,
                    width: 5,
                    height: 5
                ))
                context.fill(halo, with: .color(.white.opacity(0.95)))
                context.stroke(halo, with: .color(color), lineWidth: 2)
                context.fill(center, with: .color(color))
            }
        }

        if selected {
            let handles = AnalysisAnnotationViewGeometry.controlPoints(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            for (_, point) in handles {
                let handle = Path(ellipseIn: CGRect(
                    x: point.x - 4,
                    y: point.y - 4,
                    width: 8,
                    height: 8
                ))
                context.fill(handle, with: .color(.white))
                context.stroke(handle, with: .color(.accentColor), lineWidth: 2)
            }
        }
    }
}

private extension AnalysisAnnotationGeometry {
    var supportsFill: Bool {
        switch self {
        case .bounds, .polygon: true
        case .segment, .anchor: false
        }
    }
}

enum AnalysisAnnotationHitTester {
    static func editTarget(
        at point: CGPoint,
        selectedAnnotationID: UUID?,
        annotations: [AnalysisAnnotation],
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> AnalysisAnnotationEditTarget? {
        if let selectedAnnotationID,
           let selected = annotations.first(where: { $0.id == selectedAnnotationID }) {
            let handles = AnalysisAnnotationViewGeometry.controlPoints(
                for: selected,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            if let handle = handles.min(by: {
                hypot(point.x - $0.point.x, point.y - $0.point.y)
                    < hypot(point.x - $1.point.x, point.y - $1.point.y)
            }), hypot(point.x - handle.point.x, point.y - handle.point.y) <= 10 {
                if let controlPoint = handle.controlPoint {
                    return .resize(annotationID: selected.id, controlPoint: controlPoint)
                }
                return .move(annotationID: selected.id)
            }
        }

        guard let annotation = annotations.reversed().first(where: {
            contains(
                point,
                annotation: $0,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
        }) else { return nil }
        return .move(annotationID: annotation.id)
    }

    static func annotationID(
        at point: CGPoint,
        annotations: [AnalysisAnnotation],
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> UUID? {
        annotations.reversed().first {
            contains(
                point,
                annotation: $0,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
        }?.id
    }

    private static func contains(
        _ point: CGPoint,
        annotation: AnalysisAnnotation,
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> Bool {
        let tolerance = max(7, CGFloat(annotation.style.lineWidthPoints) + 4)
        switch annotation.geometry {
        case .segment(let start, let end):
            let first = AnalysisAnnotationViewGeometry.viewPoint(
                start,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            let last = AnalysisAnnotationViewGeometry.viewPoint(
                end,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            return point.distance(toSegmentFrom: first, to: last) <= tolerance

        case .bounds:
            let path = AnalysisAnnotationViewGeometry.path(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            if path.contains(point) { return true }
            let points = AnalysisAnnotationViewGeometry.outlinePoints(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            return zip(points, points.dropFirst() + points.prefix(1)).contains {
                point.distance(toSegmentFrom: $0.0, to: $0.1) <= tolerance
            }

        case .polygon:
            let path = AnalysisAnnotationViewGeometry.path(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            if path.contains(point) { return true }
            let points = AnalysisAnnotationViewGeometry.outlinePoints(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            return zip(points, points.dropFirst() + points.prefix(1)).contains {
                point.distance(toSegmentFrom: $0.0, to: $0.1) <= tolerance
            }

        case .anchor(let anchor):
            let location = AnalysisAnnotationViewGeometry.viewPoint(
                anchor,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            return hypot(point.x - location.x, point.y - location.y) <= 22
        }
    }
}

enum AnalysisAnnotationEditTarget: Equatable {
    case move(annotationID: UUID)
    case resize(annotationID: UUID, controlPoint: AnalysisAnnotationControlPoint)

    var annotationID: UUID {
        switch self {
        case .move(let annotationID), .resize(let annotationID, _): annotationID
        }
    }
}

private enum AnalysisAnnotationViewGeometry {
    static func annotationLabelPlacement(
        for annotation: AnalysisAnnotation,
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> (point: CGPoint, anchor: UnitPoint) {
        switch annotation.geometry {
        case .anchor(let anchor):
            let point = viewPoint(anchor, geometry: geometry, coordinateMapper: coordinateMapper)
            return (CGPoint(x: point.x + 7, y: point.y - 7), .bottomLeading)
        case .segment(let start, let end):
            let first = viewPoint(start, geometry: geometry, coordinateMapper: coordinateMapper)
            let last = viewPoint(end, geometry: geometry, coordinateMapper: coordinateMapper)
            return (
                CGPoint(x: (first.x + last.x) / 2, y: min(first.y, last.y) - 7),
                .bottom
            )
        case .bounds(let bounds):
            let point = viewPoint(
                bounds.minimum,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            return (CGPoint(x: point.x + 4, y: point.y - 5), .bottomLeading)
        case .polygon(let points):
            guard let first = points.first else { return (.zero, .center) }
            let point = viewPoint(first, geometry: geometry, coordinateMapper: coordinateMapper)
            return (CGPoint(x: point.x + 4, y: point.y - 5), .bottomLeading)
        }
    }

    static func path(
        for annotation: AnalysisAnnotation,
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> Path {
        switch annotation.geometry {
        case .segment(let start, let end):
            let first = viewPoint(start, geometry: geometry, coordinateMapper: coordinateMapper)
            let last = viewPoint(end, geometry: geometry, coordinateMapper: coordinateMapper)
            var path = Path()
            path.move(to: first)
            path.addLine(to: last)
            if annotation.kind == .arrow {
                addArrowHead(to: &path, start: first, end: last)
            } else if annotation.kind == .distance {
                addDistanceCaps(to: &path, start: first, end: last)
            }
            return path

        case .bounds, .polygon:
            let points = outlinePoints(
                for: annotation,
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            return path

        case .anchor(let anchor):
            let point = viewPoint(anchor, geometry: geometry, coordinateMapper: coordinateMapper)
            return Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
        }
    }

    static func outlinePoints(
        for annotation: AnalysisAnnotation,
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> [CGPoint] {
        if case .polygon(let points) = annotation.geometry {
            return points.map {
                viewPoint($0, geometry: geometry, coordinateMapper: coordinateMapper)
            }
        }
        guard case .bounds(let bounds) = annotation.geometry else { return [] }
        if annotation.kind == .rectangle {
            return [
                AnalysisNormalizedPoint(x: bounds.minimum.x, y: bounds.minimum.y),
                AnalysisNormalizedPoint(x: bounds.maximum.x, y: bounds.minimum.y),
                AnalysisNormalizedPoint(x: bounds.maximum.x, y: bounds.maximum.y),
                AnalysisNormalizedPoint(x: bounds.minimum.x, y: bounds.maximum.y),
            ].map { viewPoint($0, geometry: geometry, coordinateMapper: coordinateMapper) }
        }

        let centerX = (bounds.minimum.x + bounds.maximum.x) / 2
        let centerY = (bounds.minimum.y + bounds.maximum.y) / 2
        let radiusX = (bounds.maximum.x - bounds.minimum.x) / 2
        let radiusY = (bounds.maximum.y - bounds.minimum.y) / 2
        return (0..<48).map { index in
            let angle = Double(index) * 2 * .pi / 48
            return viewPoint(
                AnalysisNormalizedPoint(
                    x: centerX + cos(angle) * radiusX,
                    y: centerY + sin(angle) * radiusY
                ),
                geometry: geometry,
                coordinateMapper: coordinateMapper
            )
        }
    }

    static func controlPoints(
        for annotation: AnalysisAnnotation,
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> [(controlPoint: AnalysisAnnotationControlPoint?, point: CGPoint)] {
        switch annotation.geometry {
        case .segment(let start, let end):
            return [
                (
                    .segmentStart,
                    viewPoint(start, geometry: geometry, coordinateMapper: coordinateMapper)
                ),
                (
                    .segmentEnd,
                    viewPoint(end, geometry: geometry, coordinateMapper: coordinateMapper)
                ),
            ]
        case .bounds(let bounds):
            let maximumXMinimumY = AnalysisNormalizedPoint(
                x: bounds.maximum.x,
                y: bounds.minimum.y
            )
            let minimumXMaximumY = AnalysisNormalizedPoint(
                x: bounds.minimum.x,
                y: bounds.maximum.y
            )
            return [
                (
                    .boundsMinimum,
                    viewPoint(
                        bounds.minimum,
                        geometry: geometry,
                        coordinateMapper: coordinateMapper
                    )
                ),
                (
                    .boundsMaximumXMinimumY,
                    viewPoint(
                        maximumXMinimumY,
                        geometry: geometry,
                        coordinateMapper: coordinateMapper
                    )
                ),
                (
                    .boundsMaximum,
                    viewPoint(
                        bounds.maximum,
                        geometry: geometry,
                        coordinateMapper: coordinateMapper
                    )
                ),
                (
                    .boundsMinimumXMaximumY,
                    viewPoint(
                        minimumXMaximumY,
                        geometry: geometry,
                        coordinateMapper: coordinateMapper
                    )
                ),
            ]
        case .polygon(let points):
            return points.enumerated().map { index, point in
                (
                    .polygonVertex(index),
                    viewPoint(point, geometry: geometry, coordinateMapper: coordinateMapper)
                )
            }
        case .anchor(let point):
            return [(
                nil,
                viewPoint(point, geometry: geometry, coordinateMapper: coordinateMapper)
            )]
        }
    }

    static func viewPoint(
        _ point: AnalysisNormalizedPoint,
        geometry: ImageInspectionGeometry,
        coordinateMapper: AnalysisAnnotationCoordinateMapper
    ) -> CGPoint {
        geometry.viewPoint(fromNormalizedDisplay: coordinateMapper.displayPoint(from: point))
    }

    static func measurementLabelPoint(
        start: CGPoint,
        end: CGPoint,
        imageRect: CGRect
    ) -> CGPoint {
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return midpoint }
        let offset: CGFloat = 13
        let candidate = CGPoint(
            x: midpoint.x - (end.y - start.y) / length * offset,
            y: midpoint.y + (end.x - start.x) / length * offset
        )
        return CGPoint(
            x: min(max(candidate.x, imageRect.minX + 28), imageRect.maxX - 28),
            y: min(max(candidate.y, imageRect.minY + 9), imageRect.maxY - 9)
        )
    }

    private static func addArrowHead(to path: inout Path, start: CGPoint, end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 12
        for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - cos(angle + offset) * length,
                y: end.y - sin(angle + offset) * length
            ))
        }
    }

    private static func addDistanceCaps(to path: inout Path, start: CGPoint, end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x) + .pi / 2
        let radius: CGFloat = 5
        for point in [start, end] {
            path.move(to: CGPoint(
                x: point.x - cos(angle) * radius,
                y: point.y - sin(angle) * radius
            ))
            path.addLine(to: CGPoint(
                x: point.x + cos(angle) * radius,
                y: point.y + sin(angle) * radius
            ))
        }
    }
}

private extension CGPoint {
    func distance(toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return hypot(x - start.x, y - start.y) }
        let projection = min(
            1,
            max(0, ((x - start.x) * deltaX + (y - start.y) * deltaY) / lengthSquared)
        )
        return hypot(
            x - (start.x + projection * deltaX),
            y - (start.y + projection * deltaY)
        )
    }
}

private extension AnalysisAnnotationPaletteColor {
    var displayName: String { rawValue.capitalized }
}

extension AnalysisAnnotationColor {
    var swiftUIColor: Color {
        switch self {
        case .palette(let color):
            switch color {
            case .yellow: Color(red: 1, green: 0.83, blue: 0.08)
            case .red: Color(red: 1, green: 0.20, blue: 0.18)
            case .green: Color(red: 0.20, green: 0.84, blue: 0.38)
            case .cyan: Color(red: 0.18, green: 0.88, blue: 1)
            case .blue: Color(red: 0.20, green: 0.68, blue: 1)
            case .orange: Color(red: 1, green: 0.43, blue: 0.12)
            case .purple: Color(red: 0.74, green: 0.48, blue: 1)
            case .white: .white
            case .black: .black
            }
        case .custom(let color):
            Color(
                red: color.red,
                green: color.green,
                blue: color.blue,
                opacity: color.opacity
            )
        }
    }

    var contrastColor: Color {
        switch self {
        case .palette(.black): .white
        case .custom(let color)
            where 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue < 0.25:
            .white
        default:
            .black
        }
    }

    static func customColor(from color: Color) -> AnalysisAnnotationColor {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .systemYellow
        return .custom(AnalysisAnnotationCustomColor(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            opacity: Double(converted.alphaComponent)
        ))
    }
}
