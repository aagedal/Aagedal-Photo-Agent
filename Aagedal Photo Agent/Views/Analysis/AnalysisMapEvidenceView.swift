import AppKit
import SwiftUI
@preconcurrency import CoreLocation
@preconcurrency import MapKit

enum AnalysisMapLayerScope: String, CaseIterable {
    case currentPhoto
    case workingFolder

    var displayName: String {
        switch self {
        case .currentPhoto: "This Photo"
        case .workingFolder: "Working Folder"
        }
    }
}

private enum AppleMapStyleVariant {
    case standard
    case muted
    case hybrid
    case satellite
}

struct AnalysisMapEvidenceView: View {
    let mapState: AnalysisMapState
    let embeddedLocation: AnalysisGeoCoordinate?
    let photoAnnotationToLocate: AnalysisAnnotation?
    let currentSourceURL: URL?
    let folderAnnotations: [AnalysisImageMapAnnotation]
    let globalAnnotations: [AnalysisGlobalMapAnnotation]
    let usesFolderOwnedAnnotations: Bool
    let isReadOnly: Bool
    let onSetStyle: (AnalysisMapStyle) -> Void
    let onSetTrafficVisible: (Bool) -> Void
    let onSetViewport: (AnalysisMapViewport) -> Void
    let onSetInvestigationLocation: (AnalysisLocationEvidence?) -> Void
    let onSetAnnotation: (AnalysisMapAnnotation) -> Void
    let onSetLocalAnnotation: (AnalysisMapAnnotation) -> Void
    let onDeleteAnnotation: (UUID) -> Void

    @Binding var annotationTool: AnalysisAnnotationTool
    @Binding var sharedAnnotationStyle: AnalysisAnnotationStyle
    @Binding var selectedAnnotationID: UUID?
    let primaryActionRequestID: Int
    let finishShapeRequestID: Int
    let cancelDraftRequestID: Int
    let onDraftCountChanged: (Int) -> Void

    @State private var mapPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion
    @State private var coordinateInput = ""
    @State private var coordinateError: String?
    @State private var searchText = ""
    @State private var searchCompleter = LocationSearchCompleter()
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var isReverseGeocoding = false
    @State private var geocodingError: String?
    @State private var annotationDraftCoordinates: [AnalysisGeoCoordinate] = []
    @State private var labelInput = ""
    @State private var isLabelPromptPresented = false
    @State private var isFieldOfViewSettingsPresented = false
    @State private var addsFieldOfViewCone: Bool
    @State private var fieldOfViewBearing: Double
    @State private var fieldOfViewAngle: Double
    @State private var fieldOfViewRangeMeters: Double
    @State private var mapAvailability = AnalysisMapAvailabilityMonitor()
    @Environment(\.openWindow) private var openWindow

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50, longitude: 10),
        span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)
    )

    init(
        mapState: AnalysisMapState,
        embeddedLocation: AnalysisGeoCoordinate?,
        photoAnnotationToLocate: AnalysisAnnotation?,
        currentSourceURL: URL?,
        folderAnnotations: [AnalysisImageMapAnnotation],
        globalAnnotations: [AnalysisGlobalMapAnnotation],
        usesFolderOwnedAnnotations: Bool,
        isReadOnly: Bool,
        onSetStyle: @escaping (AnalysisMapStyle) -> Void,
        onSetTrafficVisible: @escaping (Bool) -> Void,
        onSetViewport: @escaping (AnalysisMapViewport) -> Void,
        onSetInvestigationLocation: @escaping (AnalysisLocationEvidence?) -> Void,
        onSetAnnotation: @escaping (AnalysisMapAnnotation) -> Void,
        onSetLocalAnnotation: @escaping (AnalysisMapAnnotation) -> Void,
        onDeleteAnnotation: @escaping (UUID) -> Void,
        annotationTool: Binding<AnalysisAnnotationTool>,
        sharedAnnotationStyle: Binding<AnalysisAnnotationStyle>,
        selectedAnnotationID: Binding<UUID?>,
        primaryActionRequestID: Int,
        finishShapeRequestID: Int,
        cancelDraftRequestID: Int,
        onDraftCountChanged: @escaping (Int) -> Void
    ) {
        self.mapState = mapState
        self.embeddedLocation = embeddedLocation
        self.photoAnnotationToLocate = photoAnnotationToLocate
        self.currentSourceURL = currentSourceURL
        self.folderAnnotations = folderAnnotations
        self.globalAnnotations = globalAnnotations
        self.usesFolderOwnedAnnotations = usesFolderOwnedAnnotations
        self.isReadOnly = isReadOnly
        self.onSetStyle = onSetStyle
        self.onSetTrafficVisible = onSetTrafficVisible
        self.onSetViewport = onSetViewport
        self.onSetInvestigationLocation = onSetInvestigationLocation
        self.onSetAnnotation = onSetAnnotation
        self.onSetLocalAnnotation = onSetLocalAnnotation
        self.onDeleteAnnotation = onDeleteAnnotation
        _annotationTool = annotationTool
        _sharedAnnotationStyle = sharedAnnotationStyle
        _selectedAnnotationID = selectedAnnotationID
        self.primaryActionRequestID = primaryActionRequestID
        self.finishShapeRequestID = finishShapeRequestID
        self.cancelDraftRequestID = cancelDraftRequestID
        self.onDraftCountChanged = onDraftCountChanged

        let region = Self.initialRegion(mapState: mapState, embeddedLocation: embeddedLocation)
        _mapPosition = State(initialValue: Self.initialPosition(
            mapState: mapState,
            fallbackRegion: region
        ))
        _visibleRegion = State(initialValue: region)
        let fieldOfView = Self.existingFieldOfViewSettings(in: mapState)
        _addsFieldOfViewCone = State(initialValue: fieldOfView != nil)
        _fieldOfViewBearing = State(initialValue: fieldOfView?.bearing ?? 0)
        _fieldOfViewAngle = State(initialValue: fieldOfView?.angle ?? 60)
        _fieldOfViewRangeMeters = State(initialValue: fieldOfView?.rangeMeters ?? 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchControls

            map
                .frame(minHeight: 360)
                .layoutPriority(1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }

            coordinateControls
            evidenceSummary

            if let error = coordinateError
                ?? searchError
                ?? searchCompleter.errorMessage
                ?? geocodingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Map locations are analysis-only evidence. They never change embedded or sidecar GPS metadata.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location evidence map")
        .onChange(of: embeddedLocation) { _, newLocation in
            guard mapState.viewport == nil,
                  mapState.investigationLocation == nil,
                  let newLocation else { return }
            moveMap(to: newLocation)
        }
        .onChange(of: annotationTool) {
            annotationDraftCoordinates.removeAll()
        }
        .onChange(of: primaryActionRequestID) {
            performAnnotationPrimaryAction()
        }
        .onChange(of: finishShapeRequestID) {
            finishShape()
        }
        .onChange(of: cancelDraftRequestID) {
            annotationDraftCoordinates.removeAll()
        }
        .onChange(of: annotationDraftCoordinates.count) { _, count in
            onDraftCountChanged(count)
        }
        .onChange(of: activeMapAnnotations.map(\.id)) {
            if let selectedAnnotationID,
               !activeMapAnnotations.contains(where: { $0.id == selectedAnnotationID }) {
                self.selectedAnnotationID = nil
            }
        }
        .onChange(of: selectedAnnotationID) { _, selection in
            guard let selection,
                  let annotation = activeMapAnnotations.first(where: { $0.id == selection }) else {
                return
            }
            sharedAnnotationStyle = AnalysisAnnotationStyle(
                color: annotation.style.color,
                lineWidthPoints: annotation.style.lineWidthPoints,
                fillOpacity: annotation.style.fillOpacity
            )
            moveMap(to: annotation.representativeCoordinate, preservingSpan: true)
        }
        .task {
            onDraftCountChanged(annotationDraftCoordinates.count)
            mapAvailability.start()
            mapAvailability.checkImagery(
                region: visibleRegion,
                style: mapState.style,
                force: true
            )
        }
        .onDisappear(perform: mapAvailability.cancelCurrentCheck)
        .onChange(of: mapState.style) { _, style in
            mapAvailability.checkImagery(region: visibleRegion, style: style, force: true)
        }
        .alert("Map Label", isPresented: $isLabelPromptPresented) {
            TextField("Label text", text: $labelInput)
            Button("Cancel", role: .cancel) {
                labelInput = ""
            }
            Button("Add") {
                addLabelAtMapCenter()
            }
            .disabled(labelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(
                usesFolderOwnedAnnotations
                    ? "The label is stored in the working folder's shared map."
                    : "The label is stored only in this image's analysis case."
            )
        }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField("Find the photo location", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(searchForPlace)
                    .onChange(of: searchText) { _, query in
                        searchError = nil
                        searchCompleter.search(query: query)
                    }
                    .disabled(isReadOnly || mapAvailability.isOffline)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchCompleter.results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear place search")
                }

                Button(action: searchForPlace) {
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(
                    isReadOnly
                        || mapAvailability.isOffline
                        || isSearching
                        || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Search for this place")
                .accessibilityLabel("Search for place")

                Menu {
                    ForEach(AnalysisMapStyle.allCases, id: \.self) { style in
                        Button {
                            setMapStylePreservingCamera(style)
                        } label: {
                            if mapState.style == style {
                                Label(style.displayName, systemImage: "checkmark")
                            } else {
                                Text(style.displayName)
                            }
                        }
                    }
                } label: {
                    Label(mapState.style.displayName, systemImage: mapState.style.systemImage)
                }
                .frame(width: 140)
                .disabled(isReadOnly)

                Toggle(isOn: Binding(
                    get: { mapState.showsTraffic },
                    set: { onSetTrafficVisible($0) }
                )) {
                    Label("Traffic", systemImage: "car.2")
                }
                .toggleStyle(.button)
                .disabled(
                    isReadOnly
                        || mapState.style == .satellite
                        || mapState.style == .openStreetMap
                )
                .help(
                    mapState.style == .satellite || mapState.style == .openStreetMap
                        ? "Traffic is available on Standard, Muted, and Hybrid maps"
                        : "Show live traffic on the map"
                )
            }

            if mapAvailability.isOffline {
                Text("Place search is unavailable offline. Coordinate entry and saved evidence still work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !searchCompleter.results.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(searchCompleter.results, id: \.self) { result in
                            Button {
                                selectSearchResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .lineLimit(1)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                }
            }
        }
    }

    private var map: some View {
        ZStack {
            styledMap
            if mapState.style == .openStreetMap {
                openStreetMapContent
            }

            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .allowsHitTesting(false)

            VStack {
                if let title = mapAvailability.imageryAvailability.title,
                   let message = mapAvailability.imageryAvailability.message {
                    mapAvailabilityBanner(title: title, message: message)
                        .padding(8)
                }

                HStack(spacing: 6) {
                    Spacer()
                    Button(action: openLookAroundAtMapCenter) {
                        Label("Look Around", systemImage: "binoculars")
                            .labelStyle(.iconOnly)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(mapAvailability.isOffline)
                    .help("Open Look Around for the map center in a separate window")

                    Button(action: openMapCenterInGoogleMaps) {
                        Label("Open in Google Maps", systemImage: "arrow.up.right.square")
                            .labelStyle(.iconOnly)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Open the map center in Google Maps in your default browser")
                }
                .padding(.horizontal, 8)

                Spacer()
                HStack {
                    Button {
                        setPhotoLocationAtMapCenter()
                    } label: {
                        Label("Set Photo Location", systemImage: "camera.fill")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReadOnly)

                    if let location = mapState.investigationLocation {
                        Button {
                            moveMap(to: location.coordinate, preservingSpan: true)
                        } label: {
                            Label("Photo Location", systemImage: "location.viewfinder")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Move the map back to the set photo location")
                    }

                    Button {
                        isFieldOfViewSettingsPresented.toggle()
                    } label: {
                        Image(systemName: addsFieldOfViewCone ? "camera.aperture" : "ellipsis.circle")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReadOnly)
                    .help("Photo-location and field-of-view options")
                    .popover(isPresented: $isFieldOfViewSettingsPresented, arrowEdge: .bottom) {
                        fieldOfViewSettings
                    }

                    if let photoAnnotationToLocate {
                        Button {
                            addLinkedPhotoMarker(photoAnnotationToLocate)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(photoAnnotationToLocate.style.color.swiftUIColor)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                                Text(photoLocationActionTitle(photoAnnotationToLocate))
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(isReadOnly)
                        .help("Place the selected photo object at the map center with its matching color")
                    }
                    Spacer()
                }
                .padding(8)

                if mapState.style == .openStreetMap {
                    HStack {
                        Spacer()
                        Link(
                            "© OpenStreetMap contributors",
                            destination: URL(string: "https://www.openstreetmap.org/copyright")!
                        )
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var fieldOfViewSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Add field-of-view cone", isOn: $addsFieldOfViewCone)
                .font(.headline)

            Text(
                mapState.investigationLocation == nil
                    ? "Set a photo location before adding a field-of-view cone."
                    : "Adjust the cone here, then apply it without changing the saved photo location."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Text("Bearing")
                    .frame(width: 88, alignment: .leading)
                AnalysisBearingDial(bearing: $fieldOfViewBearing)
            }
            .disabled(!addsFieldOfViewCone)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Field of view")
                    Slider(value: $fieldOfViewAngle, in: 5...170, step: 1)
                        .frame(width: 130)
                    TextField("Degrees", value: $fieldOfViewAngle, format: .number)
                        .frame(width: 64)
                    Text("°")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Range")
                    Slider(value: fieldOfViewRangeSliderBinding, in: 0...5)
                        .frame(width: 130)
                    TextField("Meters", value: $fieldOfViewRangeMeters, format: .number)
                        .frame(width: 64)
                    Text("m")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!addsFieldOfViewCone)

            Text("Drag the bearing control left or right. 0° is north; values increase clockwise.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button(fieldOfViewAnnotation == nil ? "Add Cone" : "Update Cone") {
                    guard let origin = mapState.investigationLocation?.coordinate else { return }
                    addFieldOfViewCone(at: origin)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isReadOnly
                        || !addsFieldOfViewCone
                        || mapState.investigationLocation == nil
                        || !fieldOfViewValuesAreValid
                )
            }
        }
        .padding(16)
        .frame(width: 470)
    }

    private var fieldOfViewRangeSliderBinding: Binding<Double> {
        Binding(
            get: { log10(min(100_000, max(1, fieldOfViewRangeMeters))) },
            set: { fieldOfViewRangeMeters = pow(10, $0) }
        )
    }

    private var fieldOfViewValuesAreValid: Bool {
        fieldOfViewBearing.isFinite
            && fieldOfViewAngle.isFinite
            && (5...170).contains(fieldOfViewAngle)
            && fieldOfViewRangeMeters.isFinite
            && (1...100_000).contains(fieldOfViewRangeMeters)
    }

    private func mapAvailabilityBanner(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: mapAvailability.imageryAvailability.systemImage)
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button("Retry") {
                mapAvailability.retry()
            }
            .font(.caption)
            .disabled(mapAvailability.isOffline)
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }

    @ViewBuilder
    private var openStreetMapContent: some View {
        AnalysisOpenStreetMapView(
            region: visibleRegion,
            embeddedLocation: embeddedLocation,
            investigationLocation: mapState.investigationLocation,
            annotations: activeMapAnnotations,
            folderAnnotations: folderContextAnnotations,
            fieldOfViewPreview: fieldOfViewPreviewCoordinates,
            selectedAnnotationID: selectedAnnotationID,
            onCameraChanged: { region, camera in
                visibleRegion = region
                mapPosition = .region(region)
                persistViewport(
                    region: region,
                    cameraDistance: camera.altitude,
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            },
            onSelectAnnotation: { annotationID in
                selectedAnnotationID = annotationID
                annotationTool = .select
            }
        )
    }

    @ViewBuilder
    private var styledMap: some View {
        switch appleMapStyle {
        case .standard:
            baseMap.mapStyle(.standard(
                elevation: .realistic,
                showsTraffic: mapState.showsTraffic
            ))
        case .muted:
            baseMap.mapStyle(.standard(
                elevation: .realistic,
                emphasis: .muted,
                showsTraffic: mapState.showsTraffic
            ))
        case .hybrid:
            baseMap.mapStyle(.hybrid(
                elevation: .realistic,
                showsTraffic: mapState.showsTraffic
            ))
        case .satellite:
            baseMap.mapStyle(.imagery(elevation: .realistic))
        }
    }

    private var appleMapStyle: AppleMapStyleVariant {
        switch mapState.style {
        case .standard, .openStreetMap: .standard
        case .muted: .muted
        case .hybrid: .hybrid
        case .satellite: .satellite
        }
    }

    private var baseMap: some View {
        Map(position: $mapPosition) {
            if let embeddedLocation {
                Marker(
                    "Embedded GPS",
                    coordinate: CLLocationCoordinate2D(
                        latitude: embeddedLocation.latitude,
                        longitude: embeddedLocation.longitude
                    )
                )
                .tint(.blue)
            }

            if let location = mapState.investigationLocation {
                Marker(
                    location.placeName ?? "Photo location",
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                )
                .tint(.orange)
            }

            if let coordinates = fieldOfViewPreviewCoordinates {
                MapPolygon(coordinates: coordinates.map(\.clLocationCoordinate))
                    .foregroundStyle(Color.cyan.opacity(0.22))
                MapPolyline(coordinates: (
                    coordinates + (coordinates.first.map { [$0] } ?? [])
                ).map(\.clLocationCoordinate))
                .stroke(
                    Color.cyan,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            }

            ForEach(activeMapAnnotations.filter(\.isVisible)) { annotation in
                switch annotation.geometry {
                case .point(let coordinate):
                    Annotation(
                        annotation.text ?? annotation.kind.displayName,
                        coordinate: coordinate.clLocationCoordinate
                    ) {
                        mapAnnotationButton(annotation)
                    }

                case .segment(let start, let end):
                    MapPolyline(coordinates: [
                        start.clLocationCoordinate,
                        end.clLocationCoordinate,
                    ])
                    .stroke(
                        annotation.style.color.swiftUIColor,
                        lineWidth: annotation.style.lineWidthPoints
                    )
                    Annotation(
                        annotation.text ?? annotation.kind.displayName,
                        coordinate: annotation.representativeCoordinate.clLocationCoordinate
                    ) {
                        mapAnnotationButton(annotation)
                    }

                case .polygon(let coordinates):
                    MapPolygon(coordinates: coordinates.map(\.clLocationCoordinate))
                        .foregroundStyle(
                            annotation.style.color.swiftUIColor.opacity(
                                annotation.style.fillOpacity
                            )
                        )
                    MapPolyline(coordinates: (
                        coordinates + (coordinates.first.map { [$0] } ?? [])
                    ).map(\.clLocationCoordinate))
                    .stroke(
                        annotation.style.color.swiftUIColor,
                        lineWidth: annotation.style.lineWidthPoints
                    )
                    if !Self.isFieldOfView(annotation) {
                        Annotation(
                            annotation.text ?? annotation.kind.displayName,
                            coordinate: annotation.representativeCoordinate.clLocationCoordinate
                        ) {
                            mapAnnotationButton(annotation)
                        }
                    }
                }
            }

            ForEach(folderContextAnnotations) { item in
                let annotation = item.annotation
                switch annotation.geometry {
                case .point(let coordinate):
                    Annotation(
                        annotation.text ?? item.sourceName,
                        coordinate: coordinate.clLocationCoordinate
                    ) {
                        folderMapAnnotationLabel(item)
                    }

                case .segment(let start, let end):
                    MapPolyline(coordinates: [
                        start.clLocationCoordinate,
                        end.clLocationCoordinate,
                    ])
                    .stroke(
                        annotation.style.color.swiftUIColor.opacity(0.75),
                        lineWidth: annotation.style.lineWidthPoints
                    )
                    Annotation(
                        annotation.text ?? item.sourceName,
                        coordinate: annotation.representativeCoordinate.clLocationCoordinate
                    ) {
                        folderMapAnnotationLabel(item)
                    }

                case .polygon(let coordinates):
                    MapPolygon(coordinates: coordinates.map(\.clLocationCoordinate))
                        .foregroundStyle(
                            annotation.style.color.swiftUIColor.opacity(
                                annotation.style.fillOpacity
                            )
                        )
                    MapPolyline(coordinates: (
                        coordinates + (coordinates.first.map { [$0] } ?? [])
                    ).map(\.clLocationCoordinate))
                    .stroke(
                        annotation.style.color.swiftUIColor.opacity(0.75),
                        lineWidth: annotation.style.lineWidthPoints
                    )
                    Annotation(
                        annotation.text ?? item.sourceName,
                        coordinate: annotation.representativeCoordinate.clLocationCoordinate
                    ) {
                        folderMapAnnotationLabel(item)
                    }
                }
            }

            if annotationDraftCoordinates.count == 1,
               let coordinate = annotationDraftCoordinates.first {
                Annotation("Draft start", coordinate: coordinate.clLocationCoordinate) {
                    Circle()
                        .fill(sharedAnnotationStyle.color.swiftUIColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .accessibilityLabel("Map annotation draft start")
                }
            } else if annotationDraftCoordinates.count > 1 {
                MapPolyline(coordinates: annotationDraftCoordinates.map(\.clLocationCoordinate))
                    .stroke(
                        sharedAnnotationStyle.color.swiftUIColor.opacity(0.8),
                        style: StrokeStyle(
                            lineWidth: sharedAnnotationStyle.lineWidthPoints,
                            dash: [6, 4]
                        )
                    )
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
            MapZoomStepper()
            MapPitchToggle()
            MapPitchSlider()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            mapAvailability.checkImagery(region: context.region, style: mapState.style, force: true)
            persistViewport(
                region: context.region,
                cameraDistance: context.camera.distance,
                heading: context.camera.heading,
                pitch: context.camera.pitch
            )
        }
    }

    private func persistViewport(
        region: MKCoordinateRegion,
        cameraDistance: Double?,
        heading: Double,
        pitch: Double
    ) {
        let viewport = AnalysisMapViewport(
            center: AnalysisGeoCoordinate(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            ),
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta,
            cameraDistance: cameraDistance,
            heading: normalizedHeading(heading),
            pitch: min(90, max(0, pitch))
        )
        guard !isReadOnly, viewport.isValid else { return }
        onSetViewport(viewport)
    }

    private func setMapStylePreservingCamera(_ style: AnalysisMapStyle) {
        guard style != mapState.style else { return }
        mapPosition = .region(visibleRegion)
        onSetStyle(style)
    }

    private var coordinateControls: some View {
        HStack(spacing: 6) {
            TextField("Coordinates: 59.9139, 10.7522", text: $coordinateInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(setCoordinates)
                .disabled(isReadOnly)

            Button("Set", action: setCoordinates)
                .disabled(
                    isReadOnly
                        || coordinateInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

            if mapState.investigationLocation != nil {
                Button {
                    reverseGeocodeInvestigationLocation()
                } label: {
                    if isReverseGeocoding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Name Place", systemImage: "location.fill")
                    }
                }
                .disabled(isReadOnly || isReverseGeocoding)
                .help("Resolve a city and country with the configured online or offline geocoder")

                Button("Remove", role: .destructive) {
                    onSetInvestigationLocation(nil)
                    geocodingError = nil
                }
                .disabled(isReadOnly)
            }
        }
    }

    @ViewBuilder
    private var evidenceSummary: some View {
        if embeddedLocation == nil && mapState.investigationLocation == nil {
            Label(
                "No photo location set — search, enter coordinates, or set the map center.",
                systemImage: "location.slash"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        } else {
            HStack(alignment: .top, spacing: 12) {
                if let embeddedLocation {
                    locationCard(
                        title: "Embedded GPS",
                        coordinate: embeddedLocation,
                        source: "Source metadata",
                        detail: "Read from the analyzed source; unchanged by this workspace",
                        color: .blue,
                        canSetAsPhotoLocation: true
                    )
                }
                if let location = mapState.investigationLocation {
                    locationCard(
                        title: location.placeName ?? "Photo location",
                        coordinate: location.coordinate,
                        source: location.source == .mapCenter
                            ? nil
                            : location.source.displayName,
                        detail: location.source == .mapCenter
                            ? nil
                            : location.placeNameSource.map {
                                "\(location.sourceDetail) · \($0.displayName)"
                            } ?? location.sourceDetail,
                        color: .orange
                    )
                }
            }
        }
    }

    private func locationCard(
        title: String,
        coordinate: AnalysisGeoCoordinate,
        source: String?,
        detail: String?,
        color: Color,
        canSetAsPhotoLocation: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "mappin.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(CoordinateParser.format(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                format: .decimalDegrees
            ))
            .font(.caption.monospaced())
            .textSelection(.enabled)
            if let source {
                Text(source)
                    .font(.caption.weight(.medium))
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if canSetAsPhotoLocation {
                Button {
                    setPhotoLocationFromEmbeddedGPS(coordinate)
                } label: {
                    Label(
                        isEmbeddedGPSPhotoLocation(coordinate)
                            ? "Photo Location Set"
                            : "Set as Photo Location",
                        systemImage: "camera.fill"
                    )
                }
                .controlSize(.small)
                .disabled(
                    isReadOnly
                        || isEmbeddedGPSPhotoLocation(coordinate)
                )
                .help("Use the source file's embedded GPS as the case photo location")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: canSetAsPhotoLocation ? .contain : .combine)
    }

    private func isEmbeddedGPSPhotoLocation(_ coordinate: AnalysisGeoCoordinate) -> Bool {
        mapState.investigationLocation?.coordinate == coordinate
            && mapState.investigationLocation?.source == .embeddedGPS
    }

    private func mapAnnotationButton(_ annotation: AnalysisMapAnnotation) -> some View {
        Button {
            selectedAnnotationID = annotation.id
            sharedAnnotationStyle = AnalysisAnnotationStyle(
                color: annotation.style.color,
                lineWidthPoints: annotation.style.lineWidthPoints,
                fillOpacity: annotation.style.fillOpacity
            )
            annotationTool = .select
        } label: {
            VStack(spacing: 1) {
                Image(systemName: annotation.kind == .marker ? "mappin.circle.fill" : "circle.fill")
                    .font(annotation.kind == .marker ? .title3 : .caption2)
                    .foregroundStyle(annotation.style.color.swiftUIColor)
                    .padding(3)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        if selectedAnnotationID == annotation.id {
                            Circle().stroke(Color.accentColor, lineWidth: 2)
                        }
                    }
                if let text = annotation.text {
                    Text(text)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                if let measurement = AnalysisMapDistanceMeasurement(annotation: annotation) {
                    Text(measurement.formatted)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mapAnnotationTitle(annotation))
        .accessibilityAddTraits(selectedAnnotationID == annotation.id ? .isSelected : [])
        .contextMenu {
            Button("Delete Map Annotation", role: .destructive) {
                onDeleteAnnotation(annotation.id)
                if selectedAnnotationID == annotation.id {
                    selectedAnnotationID = nil
                }
            }
            .disabled(isReadOnly)
        }
    }

    private var folderContextAnnotations: [AnalysisImageMapAnnotation] {
        let currentIDs = Set(activeMapAnnotations.map(\.id))
        return folderAnnotations.filter {
            $0.annotation.isVisible
                && $0.sourceURL.standardizedFileURL != currentSourceURL?.standardizedFileURL
                && !currentIDs.contains($0.annotation.id)
        }
    }

    private var activeMapAnnotations: [AnalysisMapAnnotation] {
        usesFolderOwnedAnnotations
            ? globalAnnotations.map(\.annotation)
            : mapState.annotations
    }

    private func folderMapAnnotationLabel(_ item: AnalysisImageMapAnnotation) -> some View {
        VStack(spacing: 1) {
            Image(systemName: item.annotation.kind == .marker ? "mappin.circle.fill" : "circle.fill")
                .font(item.annotation.kind == .marker ? .title3 : .caption2)
                .foregroundStyle(item.annotation.style.color.swiftUIColor)
                .padding(3)
                .background(.ultraThinMaterial, in: Circle())
            Text(item.annotation.text ?? item.sourceName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .help(item.sourceName)
        .accessibilityLabel("\(item.sourceName), \(mapAnnotationTitle(item.annotation))")
    }

    private func performAnnotationPrimaryAction() {
        let coordinate = AnalysisGeoCoordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude
        )
        guard coordinate.isValid else { return }

        switch annotationTool {
        case .select, .hand:
            return
        case .arrow, .rectangle, .ellipse:
            return
        case .marker:
            addMapAnnotation(kind: .marker, geometry: .point(coordinate))
        case .label:
            annotationDraftCoordinates = [coordinate]
            labelInput = ""
            isLabelPromptPresented = true
        case .line, .distance:
            guard let start = annotationDraftCoordinates.first else {
                annotationDraftCoordinates = [coordinate]
                return
            }
            guard start != coordinate else { return }
            addMapAnnotation(
                kind: annotationTool == .line ? .line : .distance,
                geometry: .segment(start: start, end: coordinate)
            )
            annotationDraftCoordinates.removeAll()
        case .shape:
            guard annotationDraftCoordinates.last != coordinate else { return }
            annotationDraftCoordinates.append(coordinate)
        }
    }

    private func finishShape() {
        guard annotationDraftCoordinates.count >= 3 else { return }
        addMapAnnotation(kind: .shape, geometry: .polygon(annotationDraftCoordinates))
        annotationDraftCoordinates.removeAll()
    }

    private func addLabelAtMapCenter() {
        guard let coordinate = annotationDraftCoordinates.first else { return }
        let text = labelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addMapAnnotation(kind: .label, geometry: .point(coordinate), text: text)
        labelInput = ""
        annotationDraftCoordinates.removeAll()
    }

    private func addMapAnnotation(
        kind: AnalysisMapAnnotationKind,
        geometry: AnalysisMapAnnotationGeometry,
        text: String? = nil
    ) {
        let annotation = AnalysisMapAnnotation(
            kind: kind,
            geometry: geometry,
            text: text,
            style: mapAnnotationStyle
        )
        guard (try? annotation.validate()) != nil else { return }
        onSetAnnotation(annotation)
        selectedAnnotationID = annotation.id
    }

    private func addLinkedPhotoMarker(_ photoAnnotation: AnalysisAnnotation) {
        let coordinate = AnalysisGeoCoordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude
        )
        guard coordinate.isValid else { return }
        let trimmedLabel = photoAnnotation.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotation = AnalysisMapAnnotation(
            kind: .marker,
            geometry: .point(coordinate),
            text: trimmedLabel?.isEmpty == false ? trimmedLabel : nil,
            style: AnalysisMapAnnotationStyle(
                color: photoAnnotation.style.color,
                lineWidthPoints: photoAnnotation.style.lineWidthPoints,
                fillOpacity: photoAnnotation.style.fillOpacity
            ),
            linkedPhotoLabelID: photoAnnotation.id
        )
        guard (try? annotation.validate()) != nil else { return }
        onSetAnnotation(annotation)
        selectedAnnotationID = annotation.id
        annotationTool = .select
    }

    private func photoLocationActionTitle(_ annotation: AnalysisAnnotation) -> String {
        if let label = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return "Place \(label)"
        }
        return "Place Selected Object"
    }

    private func mapAnnotationTitle(_ annotation: AnalysisMapAnnotation) -> String {
        if let text = annotation.text {
            return "\(annotation.kind.displayName): \(text)"
        }
        if let measurement = AnalysisMapDistanceMeasurement(annotation: annotation) {
            return "Distance: \(measurement.formatted)"
        }
        return annotation.kind.displayName
    }

    private var mapAnnotationStyle: AnalysisMapAnnotationStyle {
        AnalysisMapAnnotationStyle(
            color: sharedAnnotationStyle.color,
            lineWidthPoints: sharedAnnotationStyle.lineWidthPoints,
            fillOpacity: sharedAnnotationStyle.fillOpacity
        )
    }

    private func setCoordinates() {
        coordinateError = nil
        guard let parsed = CoordinateParser.parse(coordinateInput) else {
            coordinateError = "Invalid coordinates. Use decimal degrees, DMS, or DDM."
            return
        }
        let coordinate = AnalysisGeoCoordinate(
            latitude: parsed.latitude,
            longitude: parsed.longitude
        )
        setInvestigationLocation(
            coordinate: coordinate,
            source: .manualCoordinates,
            detail: "Entered with the analysis coordinate field"
        )
        coordinateInput = ""
    }

    private func setPhotoLocationAtMapCenter() {
        let coordinate = AnalysisGeoCoordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude
        )
        setInvestigationLocation(
            coordinate: coordinate,
            source: .mapCenter,
            detail: "Selected from the center of the analysis map"
        )
        guard addsFieldOfViewCone else { return }
        addFieldOfViewCone(at: coordinate)
    }

    private func setPhotoLocationFromEmbeddedGPS(_ coordinate: AnalysisGeoCoordinate) {
        setInvestigationLocation(
            coordinate: coordinate,
            source: .embeddedGPS,
            detail: "Promoted from the analyzed source's embedded GPS metadata"
        )
        guard addsFieldOfViewCone else { return }
        addFieldOfViewCone(at: coordinate)
    }

    private func addFieldOfViewCone(at origin: AnalysisGeoCoordinate) {
        let geometry = AnalysisMapAnnotationGeometry.polygon(
            fieldOfViewCoordinates(at: origin)
        )
        let style = AnalysisMapAnnotationStyle(
            color: .palette(.cyan),
            lineWidthPoints: 2,
            fillOpacity: 0.18
        )
        let annotation: AnalysisMapAnnotation
        if var existing = fieldOfViewAnnotation {
            existing.geometry = geometry
            existing.style = style
            existing.isVisible = true
            existing.markUpdated()
            annotation = existing
        } else {
            annotation = AnalysisMapAnnotation(
                kind: .shape,
                geometry: geometry,
                text: "Field of view",
                style: style
            )
        }
        guard (try? annotation.validate()) != nil else { return }
        onSetLocalAnnotation(annotation)
    }

    private var fieldOfViewAnnotation: AnalysisMapAnnotation? {
        mapState.annotations.first {
            Self.isFieldOfView($0)
        }
    }

    private static func isFieldOfView(_ annotation: AnalysisMapAnnotation) -> Bool {
        annotation.kind == .shape && annotation.text == "Field of view"
    }

    private var fieldOfViewPreviewCoordinates: [AnalysisGeoCoordinate]? {
        guard isFieldOfViewSettingsPresented, addsFieldOfViewCone else { return nil }
        let origin = mapState.investigationLocation?.coordinate ?? AnalysisGeoCoordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude
        )
        guard origin.isValid else { return nil }
        return fieldOfViewCoordinates(at: origin)
    }

    private func fieldOfViewCoordinates(
        at origin: AnalysisGeoCoordinate
    ) -> [AnalysisGeoCoordinate] {
        let bearing = fieldOfViewBearing.truncatingRemainder(dividingBy: 360)
        let normalizedBearing = bearing < 0 ? bearing + 360 : bearing
        let angle = min(170, max(5, fieldOfViewAngle))
        let range = min(100_000, max(1, fieldOfViewRangeMeters))
        let arcCoordinates = (0...8).map { step in
            destinationCoordinate(
                from: origin,
                bearingDegrees: normalizedBearing - angle / 2 + angle * Double(step) / 8,
                distanceMeters: range
            )
        }
        return [origin] + arcCoordinates
    }

    private func destinationCoordinate(
        from origin: AnalysisGeoCoordinate,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> AnalysisGeoCoordinate {
        let earthRadiusMeters = 6_371_000.0
        let angularDistance = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180
        let destinationLatitude = asin(
            sin(latitude) * cos(angularDistance)
                + cos(latitude) * sin(angularDistance) * cos(bearing)
        )
        let destinationLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude)
        )
        var longitudeDegrees = destinationLongitude * 180 / .pi
        longitudeDegrees = (longitudeDegrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return AnalysisGeoCoordinate(
            latitude: destinationLatitude * 180 / .pi,
            longitude: longitudeDegrees
        )
    }

    private func setInvestigationLocation(
        coordinate: AnalysisGeoCoordinate,
        source: AnalysisLocationEvidenceSource,
        detail: String,
        placeName: String? = nil,
        placeNameSource: AnalysisPlaceNameSource? = nil
    ) {
        guard coordinate.isValid else {
            coordinateError = "The selected map coordinate is invalid."
            return
        }
        geocodingError = nil
        onSetInvestigationLocation(AnalysisLocationEvidence(
            coordinate: coordinate,
            source: source,
            sourceDetail: detail,
            placeName: placeName,
            placeNameSource: placeNameSource
        ))
        if source != .mapCenter {
            moveMap(to: coordinate)
        }
    }

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchError = nil
        let title = result.title
        let subtitle = result.subtitle
        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, error in
            Task { @MainActor in
                guard let item = response?.mapItems.first else {
                    searchError = error?.localizedDescription ?? "No location was found for that place."
                    return
                }
                let coordinate = AnalysisGeoCoordinate(
                    latitude: item.location.coordinate.latitude,
                    longitude: item.location.coordinate.longitude
                )
                let detail = subtitle.isEmpty ? title : "\(title), \(subtitle)"
                setInvestigationLocation(
                    coordinate: coordinate,
                    source: .placeSearch,
                    detail: detail,
                    placeName: title,
                    placeNameSource: .placeSearch
                )
                searchText = ""
                searchCompleter.results = []
            }
        }
    }

    private func searchForPlace() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }

        searchError = nil
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = visibleRegion
        MKLocalSearch(request: request).start { response, error in
            Task { @MainActor in
                isSearching = false
                guard let item = response?.mapItems.first else {
                    searchError = error?.localizedDescription
                        ?? "No location was found for \(query)."
                    return
                }
                let coordinate = AnalysisGeoCoordinate(
                    latitude: item.location.coordinate.latitude,
                    longitude: item.location.coordinate.longitude
                )
                setInvestigationLocation(
                    coordinate: coordinate,
                    source: .placeSearch,
                    detail: query,
                    placeName: item.name ?? query,
                    placeNameSource: .placeSearch
                )
                searchText = ""
                searchCompleter.results = []
            }
        }
    }

    private func reverseGeocodeInvestigationLocation() {
        guard var location = mapState.investigationLocation else { return }
        isReverseGeocoding = true
        geocodingError = nil
        let coordinate = location.coordinate
        Task {
            do {
                let result = try await GeocodingService().reverseGeocode(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                guard mapState.investigationLocation?.coordinate == coordinate else { return }
                let components = [result.city, result.country].compactMap { $0 }
                guard !components.isEmpty else {
                    geocodingError = "The geocoder returned no city or country for this coordinate."
                    isReverseGeocoding = false
                    return
                }
                location.placeName = components.joined(separator: ", ")
                location.placeNameSource = .reverseGeocoded
                onSetInvestigationLocation(location)
                isReverseGeocoding = false
            } catch {
                geocodingError = error.localizedDescription
                isReverseGeocoding = false
            }
        }
    }

    private func moveMap(
        to coordinate: AnalysisGeoCoordinate,
        preservingSpan: Bool = false
    ) {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            span: preservingSpan
                ? visibleRegion.span
                : MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        visibleRegion = region
        mapPosition = .region(region)
    }

    private func openLookAroundAtMapCenter() {
        let coordinate = mapCenterCoordinate
        guard coordinate.isValid else { return }
        openWindow(value: AnalysisLookAroundLocation(
            coordinate: coordinate,
            title: mapState.investigationLocation?.placeName ?? "Map Center"
        ))
    }

    private func openMapCenterInGoogleMaps() {
        guard let url = AnalysisExternalMapLinks.googleMapsURL(for: mapCenterCoordinate) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var mapCenterCoordinate: AnalysisGeoCoordinate {
        AnalysisGeoCoordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude
        )
    }

    private func normalizedHeading(_ heading: Double) -> Double {
        guard heading.isFinite else { return 0 }
        let value = heading.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private static func initialRegion(
        mapState: AnalysisMapState,
        embeddedLocation: AnalysisGeoCoordinate?
    ) -> MKCoordinateRegion {
        if let viewport = mapState.viewport, viewport.isValid {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: viewport.center.latitude,
                    longitude: viewport.center.longitude
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: viewport.latitudeDelta,
                    longitudeDelta: viewport.longitudeDelta
                )
            )
        }
        if let coordinate = mapState.investigationLocation?.coordinate ?? embeddedLocation {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        return defaultRegion
    }

    private static func existingFieldOfViewSettings(
        in mapState: AnalysisMapState
    ) -> (bearing: Double, angle: Double, rangeMeters: Double)? {
        guard let annotation = mapState.annotations.first(where: {
            $0.kind == .shape && $0.text == "Field of view"
        }), case .polygon(let coordinates) = annotation.geometry,
        coordinates.count >= 4,
        let origin = coordinates.first,
        let firstArcPoint = coordinates.dropFirst().first,
        let lastArcPoint = coordinates.last else { return nil }

        let startBearing = bearing(from: origin, to: firstArcPoint)
        let endBearing = bearing(from: origin, to: lastArcPoint)
        var signedAngle = (endBearing - startBearing).truncatingRemainder(dividingBy: 360)
        if signedAngle < -180 { signedAngle += 360 }
        if signedAngle > 180 { signedAngle -= 360 }
        let angle = min(170, max(5, abs(signedAngle)))
        let centerBearing = normalizedBearing(startBearing + signedAngle / 2)
        let range = coordinates.dropFirst().map {
            distanceMeters(from: origin, to: $0)
        }.reduce(0, +) / Double(coordinates.count - 1)
        guard centerBearing.isFinite, angle.isFinite, range.isFinite else { return nil }
        return (centerBearing, angle, min(100_000, max(1, range)))
    }

    private static func bearing(
        from origin: AnalysisGeoCoordinate,
        to destination: AnalysisGeoCoordinate
    ) -> Double {
        let latitude1 = origin.latitude * .pi / 180
        let latitude2 = destination.latitude * .pi / 180
        let longitudeDelta = (destination.longitude - origin.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2)
            - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        return normalizedBearing(atan2(y, x) * 180 / .pi)
    }

    private static func distanceMeters(
        from origin: AnalysisGeoCoordinate,
        to destination: AnalysisGeoCoordinate
    ) -> Double {
        let latitudeDelta = (destination.latitude - origin.latitude) * .pi / 180
        let longitudeDelta = (destination.longitude - origin.longitude) * .pi / 180
        let latitude1 = origin.latitude * .pi / 180
        let latitude2 = destination.latitude * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
                * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private static func normalizedBearing(_ bearing: Double) -> Double {
        let value = bearing.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private static func initialPosition(
        mapState: AnalysisMapState,
        fallbackRegion: MKCoordinateRegion
    ) -> MapCameraPosition {
        guard let viewport = mapState.viewport,
              viewport.isValid,
              let distance = viewport.cameraDistance else {
            return .region(fallbackRegion)
        }
        return .camera(MapCamera(
            centerCoordinate: viewport.center.clLocationCoordinate,
            distance: distance,
            heading: viewport.heading,
            pitch: viewport.pitch
        ))
    }
}

private struct AnalysisBearingDial: View {
    @Binding var bearing: Double
    @State private var dragStartBearing: Double?
    @Environment(\.isEnabled) private var isEnabled

    private var normalizedBearing: Double {
        Self.normalized(bearing)
    }

    private var displayedBearing: Int {
        Int(normalizedBearing.rounded()).isMultiple(of: 360)
            ? 0
            : Int(normalizedBearing.rounded())
    }

    private var cardinalDirection: String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((normalizedBearing + 22.5) / 45).isMultiple(of: 8)
            ? 0
            : Int((normalizedBearing + 22.5) / 45)
        return directions[index]
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.10))
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)

                ForEach(0..<12, id: \.self) { tick in
                    Capsule()
                        .fill(Color.secondary.opacity(tick.isMultiple(of: 3) ? 0.75 : 0.4))
                        .frame(width: tick.isMultiple(of: 3) ? 2 : 1, height: 5)
                        .offset(y: -24)
                        .rotationEffect(.degrees(Double(tick) * 30))
                }

                Image(systemName: "location.north.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .rotationEffect(.degrees(normalizedBearing))
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let start: Double
                        if let dragStartBearing {
                            start = dragStartBearing
                        } else {
                            start = normalizedBearing
                            dragStartBearing = start
                        }
                        bearing = Self.normalized(start + Double(value.translation.width))
                    }
                    .onEnded { _ in
                        dragStartBearing = nil
                    }
            )
            .help("Drag left or right to change the bearing")
            .accessibilityElement()
            .accessibilityLabel("Bearing")
            .accessibilityValue("\(displayedBearing) degrees \(cardinalDirection)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    bearing = Self.normalized(normalizedBearing + 1)
                case .decrement:
                    bearing = Self.normalized(normalizedBearing - 1)
                @unknown default:
                    break
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(displayedBearing)°")
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(cardinalDirection)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }
}

private extension AnalysisGeoCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
