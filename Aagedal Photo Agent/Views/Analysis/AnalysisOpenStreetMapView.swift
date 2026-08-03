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
    let folderAnnotations: [AnalysisFolderMapAnnotation]
    let fieldOfViewPreview: [AnalysisGeoCoordinate]?
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
        mapView.pointOfInterestFilter = .includingAll
        mapView.setRegion(region, animated: false)
        // Keep replacement tiles on the map-content layer. Investigative geometry is
        // added at .aboveLabels so opaque OSM tiles can never cover it after a redraw.
        mapView.addOverlay(AnalysisOpenStreetMapTileOverlay(), level: .aboveRoads)
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

        func rebuildEvidence(in mapView: MKMapView) {
            let evidenceOverlays = mapView.overlays.filter { !($0 is AnalysisOpenStreetMapTileOverlay) }
            mapView.removeOverlays(evidenceOverlays)
            mapView.removeAnnotations(mapView.annotations)

            if let embeddedLocation {
                mapView.addAnnotation(AnalysisOSMPointAnnotation(
                    coordinate: embeddedLocation.clLocationCoordinate,
                    title: "Embedded GPS",
                    color: .systemBlue,
                    annotationID: nil
                ))
            }
            if let investigationLocation {
                mapView.addAnnotation(AnalysisOSMPointAnnotation(
                    coordinate: investigationLocation.coordinate.clLocationCoordinate,
                    title: investigationLocation.placeName ?? "Photo location",
                    color: .systemOrange,
                    annotationID: nil
                ))
            }
            if let preview = parent.fieldOfViewPreview {
                addPolygon(
                    preview,
                    style: AnalysisMapAnnotationStyle(
                        color: .palette(.cyan),
                        lineWidthPoints: 2,
                        fillOpacity: 0.22
                    ),
                    annotationID: nil,
                    title: nil,
                    to: mapView
                )
            }
            for annotation in parent.annotations where annotation.isVisible {
                add(annotation, dimmed: false, to: mapView)
            }
            for item in parent.folderAnnotations where item.annotation.isVisible {
                add(item.annotation, dimmed: true, fallbackTitle: item.sourceName, to: mapView)
            }
            restoreSelectionAfterEvidenceUpdate(in: mapView)
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

        private func add(
            _ annotation: AnalysisMapAnnotation,
            dimmed: Bool,
            fallbackTitle: String? = nil,
            to mapView: MKMapView
        ) {
            let title = annotation.text ?? fallbackTitle ?? annotation.kind.displayName
            let color = annotation.style.color.nsColor.withAlphaComponent(dimmed ? 0.72 : 1)
            switch annotation.geometry {
            case .point(let coordinate):
                mapView.addAnnotation(AnalysisOSMPointAnnotation(
                    coordinate: coordinate.clLocationCoordinate,
                    title: title,
                    color: color,
                    annotationID: annotation.id
                ))
            case .segment(let start, let end):
                let overlay = AnalysisOSMPolyline(
                    coordinates: [start.clLocationCoordinate, end.clLocationCoordinate],
                    count: 2
                )
                overlay.style = annotation.style
                overlay.isDimmed = dimmed
                mapView.addOverlay(overlay, level: .aboveLabels)
                addSelectionAnnotation(annotation, title: title, color: color, to: mapView)
            case .polygon(let coordinates):
                addPolygon(
                    coordinates,
                    style: annotation.style,
                    annotationID: annotation.id,
                    title: title,
                    dimmed: dimmed,
                    to: mapView
                )
            }
        }

        private func addPolygon(
            _ coordinates: [AnalysisGeoCoordinate],
            style: AnalysisMapAnnotationStyle,
            annotationID: UUID?,
            title: String?,
            dimmed: Bool = false,
            to mapView: MKMapView
        ) {
            var mapCoordinates = coordinates.map(\.clLocationCoordinate)
            let polygon = AnalysisOSMPolygon(
                coordinates: &mapCoordinates,
                count: mapCoordinates.count
            )
            polygon.style = style
            polygon.isDimmed = dimmed
            mapView.addOverlay(polygon, level: .aboveLabels)
            if let annotationID, let title {
                let representative = AnalysisGeoCoordinate(
                    latitude: polygon.coordinate.latitude,
                    longitude: polygon.coordinate.longitude
                )
                mapView.addAnnotation(AnalysisOSMPointAnnotation(
                    coordinate: representative.clLocationCoordinate,
                    title: title,
                    color: style.color.nsColor.withAlphaComponent(dimmed ? 0.72 : 1),
                    annotationID: annotationID,
                    usesSmallSymbol: true
                ))
            }
        }

        private func addSelectionAnnotation(
            _ annotation: AnalysisMapAnnotation,
            title: String,
            color: NSColor,
            to mapView: MKMapView
        ) {
            mapView.addAnnotation(AnalysisOSMPointAnnotation(
                coordinate: annotation.representativeCoordinate.clLocationCoordinate,
                title: title,
                color: color,
                annotationID: annotation.id,
                usesSmallSymbol: true
            ))
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isApplyingRegion else { return }
            parent.onCameraChanged(mapView.region, mapView.camera.copy() as! MKMapCamera)
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
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "AagedalPhotoAgent/2.3 (desktop OSINT map; contact: aagedal.no)",
        ]
        configuration.requestCachePolicy = .returnCacheDataElseLoad
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
        Self.session.dataTask(with: url) { data, _, error in
            result(data, error)
        }.resume()
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

private extension AnalysisGeoCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
