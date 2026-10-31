import AppKit
import CoreLocation
import SwiftUI
@preconcurrency import MapKit

/// An interactive OpenStreetMap-backed map used by the OSINT workspace.
///
/// The tile overlay replaces Apple map content while MKMapView continues to provide native
/// panning, zooming, annotation selection, and camera behavior.
struct AnalysisOpenStreetMapView: NSViewRepresentable {
    let region: MKCoordinateRegion
    let embeddedLocation: AnalysisGeoCoordinate?
    let investigationLocation: AnalysisLocationEvidence?
    let annotations: [AnalysisMapAnnotation]
    let folderAnnotations: [AnalysisImageMapAnnotation]
    let fieldOfViewPreview: [AnalysisGeoCoordinate]?
    let solarRenderModel: AnalysisSolarMapRenderModel?
    let selectedAnnotationID: UUID?
    let onCameraChanged: (MKCoordinateRegion, MKMapCamera) -> Void
    let onSelectAnnotation: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsZoomControls = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.setRegion(region, animated: false)
        // MapKit renders its own labels above `.aboveRoads` overlays, even when a tile
        // overlay replaces the base map. Put OSM above that layer so only OSM's labels
        // remain visible. Evidence geometry is added afterward at the same level and
        // therefore stays above the replacement tiles.
        mapView.addOverlay(AnalysisOpenStreetMapTileOverlay(), level: .aboveLabels)
        context.coordinator.rebuildEvidence(in: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        if !Self.regionsAreEffectivelyEqual(mapView.region, region) {
            context.coordinator.isApplyingRegion = true
            mapView.setRegion(region, animated: false)
            context.coordinator.isApplyingRegion = false
        }
        context.coordinator.rebuildEvidence(in: mapView)
    }

    private static func regionsAreEffectivelyEqual(
        _ lhs: MKCoordinateRegion,
        _ rhs: MKCoordinateRegion
    ) -> Bool {
        abs(lhs.center.latitude - rhs.center.latitude) < 0.000_000_1
            && abs(lhs.center.longitude - rhs.center.longitude) < 0.000_000_1
            && abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.000_000_1
            && abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.000_000_1
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AnalysisOpenStreetMapView
        var isApplyingRegion = false

        init(parent: AnalysisOpenStreetMapView) {
            self.parent = parent
        }

        /// Evidence currently installed in the map, keyed by everything that affects drawing, so
        /// an update only touches what changed instead of removing and re-adding everything.
        private var installedOverlayKeys: [AnalysisOSMEvidenceKey] = []
        private var installedOverlays: [any MKOverlay] = []
        private var installedAnnotations: [AnalysisOSMEvidenceKey: [AnalysisOSMPointAnnotation]] = [:]
        private var lastSelectedAnnotationID: UUID?

        func rebuildEvidence(in mapView: MKMapView) {
            let desired = desiredEvidence()
            let overlayKeys = desired.filter(\.isOverlay)

            // Overlays at one level draw in insertion order, so a changed overlay list is
            // reinstalled in order to keep the layering the full rebuild produced.
            if overlayKeys != installedOverlayKeys {
                mapView.removeOverlays(installedOverlays)
                installedOverlays = overlayKeys.compactMap(makeOverlay)
                mapView.addOverlays(installedOverlays, level: .aboveLabels)
                installedOverlayKeys = overlayKeys
            }

            var reusable = installedAnnotations
            var installed: [AnalysisOSMEvidenceKey: [AnalysisOSMPointAnnotation]] = [:]
            var added: [AnalysisOSMPointAnnotation] = []
            for key in desired where !key.isOverlay {
                let annotation: AnalysisOSMPointAnnotation
                if var candidates = reusable[key], let existing = candidates.popLast() {
                    reusable[key] = candidates
                    annotation = existing
                } else {
                    annotation = makeAnnotation(for: key)
                    added.append(annotation)
                }
                installed[key, default: []].append(annotation)
            }
            let removed = reusable.values.flatMap { $0 }
            if !removed.isEmpty { mapView.removeAnnotations(removed) }
            if !added.isEmpty { mapView.addAnnotations(added) }
            installedAnnotations = installed

            if !added.isEmpty || parent.selectedAnnotationID != lastSelectedAnnotationID {
                restoreSelectionAfterEvidenceUpdate(in: mapView)
            }
            lastSelectedAnnotationID = parent.selectedAnnotationID
        }

        /// The evidence to draw, in the order the map has always layered it.
        private func desiredEvidence() -> [AnalysisOSMEvidenceKey] {
            var keys: [AnalysisOSMEvidenceKey] = []
            if let embeddedLocation {
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .point(color: .system(.blue), usesSmallSymbol: false),
                    coordinates: [embeddedLocation],
                    title: "Embedded GPS",
                    annotationID: nil
                ))
            }
            if let investigationLocation {
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .point(color: .system(.orange), usesSmallSymbol: false),
                    coordinates: [investigationLocation.coordinate],
                    title: investigationLocation.placeName ?? "Photo location",
                    annotationID: nil
                ))
            }
            if let preview = parent.fieldOfViewPreview {
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .polygon(style: AnalysisMapAnnotationStyle(
                        color: .palette(.cyan),
                        lineWidthPoints: 2,
                        fillOpacity: 0.22
                    )),
                    coordinates: preview,
                    title: nil,
                    annotationID: nil
                ))
            }
            if let solarRenderModel = parent.solarRenderModel {
                for ray in solarRenderModel.rays {
                    keys.append(AnalysisOSMEvidenceKey(
                        shape: .solarRay(kind: ray.kind),
                        coordinates: [ray.origin, ray.destination],
                        title: nil,
                        annotationID: nil
                    ))
                }
            }
            for annotation in parent.annotations where annotation.isVisible {
                appendKeys(for: annotation, dimmed: false, to: &keys)
            }
            for item in parent.folderAnnotations where item.annotation.isVisible {
                appendKeys(for: item.annotation, dimmed: true, fallbackTitle: item.sourceName, to: &keys)
            }
            return keys
        }

        private func restoreSelectionAfterEvidenceUpdate(in mapView: MKMapView) {
            guard let selectedAnnotationID = parent.selectedAnnotationID else { return }
            // Selecting from viewFor: opens a nested MapKit/AppKit transaction while the
            // annotation view is being committed. Defer it until MapKit finishes this pass.
            DispatchQueue.main.async { [weak mapView] in
                guard let mapView,
                      !mapView.selectedAnnotations.contains(where: {
                          ($0 as? AnalysisOSMPointAnnotation)?.annotationID == selectedAnnotationID
                      }),
                      let annotation = mapView.annotations.first(where: {
                          ($0 as? AnalysisOSMPointAnnotation)?.annotationID == selectedAnnotationID
                      }) else {
                    return
                }
                mapView.selectAnnotation(annotation, animated: false)
            }
        }

        private var embeddedLocation: AnalysisGeoCoordinate? { parent.embeddedLocation }
        private var investigationLocation: AnalysisLocationEvidence? { parent.investigationLocation }

        private func appendKeys(
            for annotation: AnalysisMapAnnotation,
            dimmed: Bool,
            fallbackTitle: String? = nil,
            to keys: inout [AnalysisOSMEvidenceKey]
        ) {
            let title = annotation.text ?? fallbackTitle ?? annotation.kind.displayName
            let color = AnalysisOSMEvidenceKey.Color.annotation(annotation.style.color)
            switch annotation.geometry {
            case .point(let coordinate):
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .point(color: color, usesSmallSymbol: false),
                    coordinates: [coordinate],
                    title: title,
                    annotationID: annotation.id,
                    isDimmed: dimmed
                ))
            case .segment(let start, let end):
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .polyline(style: annotation.style),
                    coordinates: [start, end],
                    title: nil,
                    annotationID: nil,
                    isDimmed: dimmed
                ))
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .point(color: color, usesSmallSymbol: true),
                    coordinates: [annotation.representativeCoordinate],
                    title: title,
                    annotationID: annotation.id,
                    isDimmed: dimmed
                ))
            case .polygon(let coordinates):
                keys.append(AnalysisOSMEvidenceKey(
                    shape: .polygon(style: annotation.style),
                    coordinates: coordinates,
                    title: nil,
                    annotationID: nil,
                    isDimmed: dimmed
                ))
                if !isFieldOfView(annotation) {
                    keys.append(AnalysisOSMEvidenceKey(
                        shape: .polygonHandle(color: color),
                        coordinates: coordinates,
                        title: title,
                        annotationID: annotation.id,
                        isDimmed: dimmed
                    ))
                }
            }
        }

        private func isFieldOfView(_ annotation: AnalysisMapAnnotation) -> Bool {
            annotation.kind == .shape && annotation.text == "Field of view"
        }

        private func makeOverlay(for key: AnalysisOSMEvidenceKey) -> (any MKOverlay)? {
            var mapCoordinates = key.coordinates.map(\.clLocationCoordinate)
            switch key.shape {
            case .polyline(let style):
                let overlay = AnalysisOSMPolyline(coordinates: mapCoordinates, count: mapCoordinates.count)
                overlay.style = style
                overlay.isDimmed = key.isDimmed
                return overlay
            case .solarRay(let kind):
                let overlay = AnalysisOSMSolarPolyline(
                    coordinates: mapCoordinates,
                    count: mapCoordinates.count
                )
                overlay.kind = kind
                return overlay
            case .polygon(let style):
                let polygon = AnalysisOSMPolygon(
                    coordinates: &mapCoordinates,
                    count: mapCoordinates.count
                )
                polygon.style = style
                polygon.isDimmed = key.isDimmed
                return polygon
            case .point, .polygonHandle:
                return nil
            }
        }

        private func makeAnnotation(for key: AnalysisOSMEvidenceKey) -> AnalysisOSMPointAnnotation {
            switch key.shape {
            case .point(let color, let usesSmallSymbol):
                return AnalysisOSMPointAnnotation(
                    coordinate: key.coordinates[0].clLocationCoordinate,
                    title: key.title,
                    color: color.nsColor(dimmed: key.isDimmed),
                    annotationID: key.annotationID,
                    usesSmallSymbol: usesSmallSymbol
                )
            case .polygonHandle(let color):
                // The handle sits on MapKit's representative point of the drawn polygon.
                var mapCoordinates = key.coordinates.map(\.clLocationCoordinate)
                let polygon = MKPolygon(coordinates: &mapCoordinates, count: mapCoordinates.count)
                return AnalysisOSMPointAnnotation(
                    coordinate: polygon.coordinate,
                    title: key.title,
                    color: color.nsColor(dimmed: key.isDimmed),
                    annotationID: key.annotationID,
                    usesSmallSymbol: true
                )
            case .polyline, .solarRay, .polygon:
                preconditionFailure("Overlay evidence is not an annotation")
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isApplyingRegion,
                  let camera = mapView.camera.copy() as? MKMapCamera else { return }
            parent.onCameraChanged(mapView.region, camera)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? AnalysisOSMPointAnnotation,
                  let annotationID = annotation.annotationID else { return }
            parent.onSelectAnnotation(annotationID)
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: any MKAnnotation
        ) -> MKAnnotationView? {
            guard let annotation = annotation as? AnalysisOSMPointAnnotation else { return nil }
            let identifier = "AnalysisOSMMarker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = annotation.color
            // MKMarkerAnnotationView can crash while resolving an NSImage system symbol
            // during the layer transaction created by an Apple-map → OSM switch. Use
            // MapKit's native marker glyph and a lightweight text dot for small handles.
            view.glyphImage = nil
            view.glyphText = annotation.usesSmallSymbol ? "•" : nil
            view.displayPriority = annotation.usesSmallSymbol ? .defaultLow : .required
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let solarPolyline = overlay as? AnalysisOSMSolarPolyline {
                let renderer = MKPolylineRenderer(polyline: solarPolyline)
                renderer.strokeColor = solarPolyline.kind.nsColor
                renderer.lineWidth = solarPolyline.kind.lineWidth
                renderer.lineCap = .round
                renderer.lineDashPattern = solarPolyline.kind.lineDashPattern
                return renderer
            }
            if let polyline = overlay as? AnalysisOSMPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.style.color.nsColor.withAlphaComponent(
                    polyline.isDimmed ? 0.72 : 1
                )
                renderer.lineWidth = polyline.style.lineWidthPoints
                return renderer
            }
            if let polygon = overlay as? AnalysisOSMPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let alpha = polygon.style.fillOpacity * (polygon.isDimmed ? 0.72 : 1)
                renderer.fillColor = polygon.style.color.nsColor.withAlphaComponent(alpha)
                renderer.strokeColor = polygon.style.color.nsColor.withAlphaComponent(
                    polygon.isDimmed ? 0.72 : 1
                )
                renderer.lineWidth = polygon.style.lineWidthPoints
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

nonisolated private final class AnalysisOpenStreetMapTileOverlay: MKTileOverlay {
    private static let session: URLSession = {
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "AagedalPhotoAgent/\(appVersion) (desktop OSINT map; contact: aagedal.no)",
        ]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init() {
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 19
        canReplaceMapContent = true
    }

    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) {
        let url = url(forTilePath: path)
        Self.session.dataTask(with: url) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if let error {
                if (error as? URLError)?.code != .cancelled {
                    Self.reportFailure(error.localizedDescription)
                }
                result(nil, error)
            } else if let status, status != 200 {
                // A 403/429 body is an error page, not a tile; drawing it would leave a grey
                // map with no explanation.
                Self.reportFailure("HTTP \(status)")
                result(nil, URLError(.badServerResponse))
            } else {
                result(data, nil)
            }
        }.resume()
    }

    private static func reportFailure(_ detail: String) {
        NotificationCenter.default.post(
            name: AnalysisMapAvailabilityMonitor.openStreetMapTileFailed,
            object: nil,
            userInfo: ["detail": detail]
        )
    }
}

/// Everything that determines how one piece of map evidence is drawn. Two equal keys draw
/// identically, so an installed object can be kept when its key is still wanted.
nonisolated private struct AnalysisOSMEvidenceKey: Hashable {
    enum SystemColor: Hashable {
        case blue
        case orange
    }

    enum Color: Equatable {
        case system(SystemColor)
        case annotation(AnalysisAnnotationColor)

        @MainActor func nsColor(dimmed: Bool) -> NSColor {
            switch self {
            case .system(.blue): .systemBlue
            case .system(.orange): .systemOrange
            case .annotation(let color): color.nsColor.withAlphaComponent(dimmed ? 0.72 : 1)
            }
        }
    }

    enum Shape: Equatable {
        case point(color: Color, usesSmallSymbol: Bool)
        /// The small selection handle of a titled polygon.
        case polygonHandle(color: Color)
        case polyline(style: AnalysisMapAnnotationStyle)
        case solarRay(kind: AnalysisSolarMapRayKind)
        case polygon(style: AnalysisMapAnnotationStyle)
    }

    let shape: Shape
    let coordinates: [AnalysisGeoCoordinate]
    let title: String?
    let annotationID: UUID?
    var isDimmed = false

    var isOverlay: Bool {
        switch shape {
        case .point, .polygonHandle: false
        case .polyline, .solarRay, .polygon: true
        }
    }

    // Equality compares every field; the hash uses only the Hashable subset, which equal keys
    // always share.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.shape == rhs.shape
            && lhs.coordinates == rhs.coordinates
            && lhs.title == rhs.title
            && lhs.annotationID == rhs.annotationID
            && lhs.isDimmed == rhs.isDimmed
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(annotationID)
        hasher.combine(isDimmed)
        hasher.combine(isOverlay)
        hasher.combine(coordinates.count)
        for coordinate in coordinates {
            hasher.combine(coordinate.latitude)
            hasher.combine(coordinate.longitude)
        }
    }
}

private final class AnalysisOSMPointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let color: NSColor
    let annotationID: UUID?
    let usesSmallSymbol: Bool

    init(
        coordinate: CLLocationCoordinate2D,
        title: String?,
        color: NSColor,
        annotationID: UUID?,
        usesSmallSymbol: Bool = false
    ) {
        self.coordinate = coordinate
        self.title = title
        self.color = color
        self.annotationID = annotationID
        self.usesSmallSymbol = usesSmallSymbol
    }
}

nonisolated private final class AnalysisOSMPolyline: MKPolyline {
    var style = AnalysisMapAnnotationStyle.default
    var isDimmed = false
}

nonisolated private final class AnalysisOSMSolarPolyline: MKPolyline {
    var kind = AnalysisSolarMapRayKind.sun
}

nonisolated private final class AnalysisOSMPolygon: MKPolygon {
    var style = AnalysisMapAnnotationStyle.default
    var isDimmed = false
}

private extension AnalysisAnnotationColor {
    var nsColor: NSColor {
        switch self {
        case .custom(let color):
            NSColor(
                srgbRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.opacity
            )
        case .palette(let color):
            switch color {
            case .yellow: .systemYellow
            case .red: .systemRed
            case .green: .systemGreen
            case .cyan: .systemCyan
            case .blue: .systemBlue
            case .orange: .systemOrange
            case .purple: .systemPurple
            case .white: .white
            case .black: .black
            }
        }
    }
}

private extension AnalysisSolarMapRayKind {
    var nsColor: NSColor {
        switch self {
        case .sun: .systemYellow
        case .shadow: .systemPurple
        case .sunrise: .systemOrange
        case .sunset: .systemRed
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .sun: 4
        case .shadow: 3
        case .sunrise, .sunset: 2.5
        }
    }

    var lineDashPattern: [NSNumber]? {
        switch self {
        case .sun: nil
        case .shadow: [7, 5]
        case .sunrise, .sunset: [3, 4]
        }
    }
}

private extension AnalysisGeoCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
