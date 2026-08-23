import AppKit
import SwiftUI
@preconcurrency import CoreLocation
@preconcurrency import MapKit

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
    let isReadOnly: Bool
    let onSetStyle: (AnalysisMapStyle) -> Void
    let onSetTrafficVisible: (Bool) -> Void
    let onSet3DContentVisible: (Bool) -> Void
    let onSetViewport: (AnalysisMapViewport) -> Void
    let onSetInvestigationLocation: (AnalysisLocationEvidence?) -> Void
    let timestampEvidence: [AnalysisTimestampEvidence]
    let onSetSolarOverlay: (AnalysisSolarOverlayState) -> Void
    let onClearSolarOverlay: () -> Void
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
    @State private var isSolarControlsPresented = false
    @State private var addsFieldOfViewCone: Bool
    @State private var fieldOfViewBearing: Double
    @State private var fieldOfViewAngle: Double
    @State private var fieldOfViewRangeMeters: Double
    @State private var solarDay: AnalysisSolarDay?
    @State private var solarPreview: AnalysisSolarMapPreview?
    @State private var mapAvailability = AnalysisMapAvailabilityMonitor()
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
        isReadOnly: Bool,
        onSetStyle: @escaping (AnalysisMapStyle) -> Void,
        onSetTrafficVisible: @escaping (Bool) -> Void,
        onSet3DContentVisible: @escaping (Bool) -> Void,
        onSetViewport: @escaping (AnalysisMapViewport) -> Void,
        onSetInvestigationLocation: @escaping (AnalysisLocationEvidence?) -> Void,
        timestampEvidence: [AnalysisTimestampEvidence],
        onSetSolarOverlay: @escaping (AnalysisSolarOverlayState) -> Void,
        onClearSolarOverlay: @escaping () -> Void,
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
        self.isReadOnly = isReadOnly
        self.onSetStyle = onSetStyle
        self.onSetTrafficVisible = onSetTrafficVisible
        self.onSet3DContentVisible = onSet3DContentVisible
        self.onSetViewport = onSetViewport
        self.onSetInvestigationLocation = onSetInvestigationLocation
        self.timestampEvidence = timestampEvidence
        self.onSetSolarOverlay = onSetSolarOverlay
        self.onClearSolarOverlay = onClearSolarOverlay
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
        _solarDay = State(initialValue: Self.calculateSolarDay(
            overlay: mapState.solarOverlay,
            location: mapState.investigationLocation
        ))
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
        .onChange(of: mapState.solarOverlay) { _, overlay in
            solarDay = Self.calculateSolarDay(
                overlay: overlay,
                location: mapState.investigationLocation
            )
        }
        .onChange(of: mapState.investigationLocation) { _, location in
            solarDay = Self.calculateSolarDay(
                overlay: mapState.solarOverlay,
                location: location
            )
        }
        .onChange(of: isSolarControlsPresented) { _, isPresented in
            if !isPresented {
                solarPreview = nil
            }
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
            Text("The label is stored in the working folder's shared map.")
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
                .frame(width: 170)
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

                Toggle(isOn: Binding(
                    get: { mapState.shows3DContent },
                    set: { onSet3DContentVisible($0) }
                )) {
                    Label("3D", systemImage: "cube.transparent")
                }
                .toggleStyle(.button)
                .disabled(isReadOnly || mapState.style == .openStreetMap)
                .help(
                    mapState.style == .openStreetMap
                        ? "3D buildings and terrain are available on Apple map styles"
                        : "Show 3D buildings and terrain"
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
                    if let solarRenderModel {
                        solarLegend(solarRenderModel)
                    }
                    Spacer()
                    Button(action: openMapCenterInAppleLookAround) {
                        Label("Open in Apple Maps Look Around", systemImage: "binoculars")
                            .labelStyle(.iconOnly)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(mapAvailability.isOffline)
                    .help("Open an interactive Look Around view for the map center in Apple Maps")

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

                    Button {
                        isSolarControlsPresented.toggle()
                    } label: {
                        Image(systemName: mapState.solarOverlay == nil ? "sun.max" : "sun.max.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Configure a reproducible solar-position calculation")
                    .accessibilityLabel("Solar Position")
                    .accessibilityValue(mapState.solarOverlay == nil ? "Not configured" : "Configured")
                    .popover(isPresented: $isSolarControlsPresented, arrowEdge: .bottom) {
                        AnalysisSolarControls(
                            location: solarControlsLocation,
                            isUsingMapCenterPreview: mapState.investigationLocation == nil,
                            timestampEvidence: timestampEvidence,
                            overlay: mapState.solarOverlay,
                            isReadOnly: isReadOnly,
                            onApply: onSetSolarOverlay,
                            onClear: onClearSolarOverlay,
                            onPreview: { solarPreview = $0 }
                        )
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
            solarRenderModel: solarRenderModel,
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
                elevation: mapElevation,
                showsTraffic: mapState.showsTraffic
            ))
        case .muted:
            baseMap.mapStyle(.standard(
                elevation: mapElevation,
                emphasis: .muted,
                showsTraffic: mapState.showsTraffic
            ))
        case .hybrid:
            baseMap.mapStyle(.hybrid(
                elevation: mapElevation,
                showsTraffic: mapState.showsTraffic
            ))
        case .satellite:
            baseMap.mapStyle(.imagery(elevation: mapElevation))
        }
    }

    private var mapElevation: MapStyle.Elevation {
        mapState.shows3DContent ? .realistic : .flat
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

            if let solarRenderModel {
                ForEach(solarRenderModel.rays) { ray in
                    MapPolyline(coordinates: [
                        ray.origin.clLocationCoordinate,
                        ray.destination.clLocationCoordinate,
                    ])
                    .stroke(ray.kind.swiftUIColor, style: ray.kind.strokeStyle)
                }
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
        globalAnnotations.map(\.annotation)
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
        if isFieldOfViewSettingsPresented, addsFieldOfViewCone {
            let origin = mapState.investigationLocation?.coordinate ?? mapCenterCoordinate
            guard origin.isValid else { return nil }
            return fieldOfViewCoordinates(at: origin)
        }
        guard let annotation = fieldOfViewAnnotation,
              annotation.isVisible,
              case .polygon(let coordinates) = annotation.geometry else { return nil }
        return coordinates
    }

    private var solarRenderModel: AnalysisSolarMapRenderModel? {
        if let solarPreview {
            return AnalysisSolarMapRenderModel(
                overlay: solarPreview.overlay,
                origin: solarPreview.origin,
                latitudeDelta: visibleRegion.span.latitudeDelta,
                longitudeDelta: visibleRegion.span.longitudeDelta,
                day: solarPreview.day
            )
        }
        guard let overlay = mapState.solarOverlay,
              let origin = mapState.investigationLocation?.coordinate,
              let solarDay else { return nil }
        return AnalysisSolarMapRenderModel(
            overlay: overlay,
            origin: origin,
            latitudeDelta: visibleRegion.span.latitudeDelta,
            longitudeDelta: visibleRegion.span.longitudeDelta,
            day: solarDay
        )
    }

    private var solarControlsLocation: AnalysisLocationEvidence {
        mapState.investigationLocation ?? AnalysisLocationEvidence(
            coordinate: mapCenterCoordinate,
            source: .mapCenter,
            sourceDetail: "Live preview at the current map center"
        )
    }

    private func fieldOfViewCoordinates(
        at origin: AnalysisGeoCoordinate
    ) -> [AnalysisGeoCoordinate] {
        let bearing = fieldOfViewBearing.truncatingRemainder(dividingBy: 360)
        let normalizedBearing = bearing < 0 ? bearing + 360 : bearing
        let angle = min(170, max(5, fieldOfViewAngle))
        let range = min(100_000, max(1, fieldOfViewRangeMeters))
        let arcCoordinates = (0...8).map { step in
            AnalysisMapGeometry.destinationCoordinate(
                from: origin,
                bearingDegrees: normalizedBearing - angle / 2 + angle * Double(step) / 8,
                distanceMeters: range
            )
        }
        return [origin] + arcCoordinates
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

    private func openMapCenterInAppleLookAround() {
        guard let url = AnalysisExternalMapLinks.appleLookAroundURL(
            for: mapCenterCoordinate
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
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

    private func solarLegend(_ model: AnalysisSolarMapRenderModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Solar directions")
                .font(.caption.weight(.semibold))
            ForEach(model.rays) { ray in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(ray.kind.swiftUIColor)
                        .frame(width: 22, height: 3)
                    Text(ray.kind.displayName)
                        .font(.caption2)
                }
            }
            if model.isBelowHorizon {
                Text("Sun below horizon · current rays hidden")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let condition = model.polarCondition {
                Text(condition == .polarDay ? "Polar day" : "Polar night")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let shadowLength = model.shadowLengthMeters,
               let objectHeight = model.shadowObjectHeightMeters {
                Text(
                    "Shadow " + formattedDistance(shadowLength) + " for "
                        + formattedDistance(objectHeight) + " object"
                )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Direction rays are illustrative · length follows zoom")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(solarLegendAccessibilityLabel(model))
    }

    private func solarLegendAccessibilityLabel(_ model: AnalysisSolarMapRenderModel) -> String {
        let directions = model.rays.map { $0.kind.displayName }.joined(separator: ", ")
        let shadow = model.shadowLengthMeters.map {
            " Expected shadow length " + formattedDistance($0) + "."
        } ?? ""
        return "Solar directions. " + directions + "." + shadow
            + " Direction-ray length follows map zoom."
    }

    private func formattedDistance(_ meters: Double) -> String {
        if meters >= 1_000 {
            return (meters / 1_000).formatted(
                .number.precision(.fractionLength(0...2))
            ) + " km"
        }
        return meters.formatted(.number.precision(.fractionLength(0...2))) + " m"
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
            AnalysisMapGeometry.greatCircleDistanceMeters(from: origin, to: $0)
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

    private static func calculateSolarDay(
        overlay: AnalysisSolarOverlayState?,
        location: AnalysisLocationEvidence?
    ) -> AnalysisSolarDay? {
        guard let overlay,
              overlay.isVisible,
              overlay.validate(),
              let coordinate = location?.coordinate,
              let instant = overlay.timestamp.resolvedInstant else { return nil }
        switch overlay.calculationMethod {
        case .meeusNOAAV1:
            return try? AnalysisSolarPositionCalculator.calculate(
                input: AnalysisSolarInput(instant: instant, coordinate: coordinate),
                civilDayOffsetMinutes: overlay.timestamp.utcOffsetMinutes ?? 0
            )
        }
    }
}

private extension AnalysisSolarMapRayKind {
    var swiftUIColor: Color {
        switch self {
        case .sun: .yellow
        case .shadow: .purple
        case .sunrise: .orange
        case .sunset: .red
        }
    }

    var strokeStyle: StrokeStyle {
        switch self {
        case .sun:
            StrokeStyle(lineWidth: 4, lineCap: .round)
        case .shadow:
            StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 5])
        case .sunrise, .sunset:
            StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 4])
        }
    }
}

nonisolated private struct AnalysisSolarDayRequest: Equatable, Sendable {
    let coordinate: AnalysisGeoCoordinate
    let civilDayRepresentativeInstant: Date
    let utcOffsetMinutes: Int
}

nonisolated private struct AnalysisSolarMapPreview: Equatable, Sendable {
    let overlay: AnalysisSolarOverlayState
    let origin: AnalysisGeoCoordinate
    let day: AnalysisSolarDay
}

nonisolated private struct AnalysisSolarPreviewConfiguration: Equatable, Sendable {
    let coordinate: AnalysisGeoCoordinate
    let timestamp: AnalysisTimestampValue
    let isVisible: Bool
    let showsSunDirection: Bool
    let showsShadowDirection: Bool
    let showsSunriseDirection: Bool
    let showsSunsetDirection: Bool
    let shadowObjectHeightMeters: Double?
}

nonisolated private struct AnalysisSolarPreviewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct AnalysisSolarControls: View {
    let location: AnalysisLocationEvidence?
    let isUsingMapCenterPreview: Bool
    let timestampEvidence: [AnalysisTimestampEvidence]
    let overlay: AnalysisSolarOverlayState?
    let isReadOnly: Bool
    let onApply: (AnalysisSolarOverlayState) -> Void
    let onClear: () -> Void
    let onPreview: (AnalysisSolarMapPreview?) -> Void

    @State private var civilDateTime: Date
    @State private var utcOffsetMinutes: Int
    @State private var selectedEvidenceID: UUID?
    @State private var isVisible: Bool
    @State private var showsSunDirection: Bool
    @State private var showsShadowDirection: Bool
    @State private var showsSunriseDirection: Bool
    @State private var showsSunsetDirection: Bool
    @State private var shadowObjectHeightMeters: Double
    @State private var calculatedDay: AnalysisSolarDay?
    @State private var calculatedDayRequest: AnalysisSolarDayRequest?
    @State private var calculationErrorMessage: String?

    private static let utc = TimeZone(secondsFromGMT: 0)!

    init(
        location: AnalysisLocationEvidence?,
        isUsingMapCenterPreview: Bool,
        timestampEvidence: [AnalysisTimestampEvidence],
        overlay: AnalysisSolarOverlayState?,
        isReadOnly: Bool,
        onApply: @escaping (AnalysisSolarOverlayState) -> Void,
        onClear: @escaping () -> Void,
        onPreview: @escaping (AnalysisSolarMapPreview?) -> Void
    ) {
        self.location = location
        self.isUsingMapCenterPreview = isUsingMapCenterPreview
        self.timestampEvidence = timestampEvidence
        self.overlay = overlay
        self.isReadOnly = isReadOnly
        self.onApply = onApply
        self.onClear = onClear
        self.onPreview = onPreview

        let initialTimestamp = overlay?.timestamp ?? AnalysisTimestampValue(
            date: Date(),
            precision: .minute,
            timeZone: Self.utc
        )
        _civilDateTime = State(
            initialValue: initialTimestamp.wallClockSortDate ?? Date()
        )
        _utcOffsetMinutes = State(initialValue: initialTimestamp.utcOffsetMinutes ?? 0)
        let eligibleEvidenceIDs = Set(
            timestampEvidence.filter(\.isEligibleForSolarPosition).map(\.id)
        )
        _selectedEvidenceID = State(initialValue: overlay?.linkedTimestampEvidenceID.flatMap {
            eligibleEvidenceIDs.contains($0) ? $0 : nil
        })
        _isVisible = State(initialValue: overlay?.isVisible ?? true)
        _showsSunDirection = State(initialValue: overlay?.showsSunDirection ?? true)
        _showsShadowDirection = State(initialValue: overlay?.showsShadowDirection ?? true)
        _showsSunriseDirection = State(initialValue: overlay?.showsSunriseDirection ?? true)
        _showsSunsetDirection = State(initialValue: overlay?.showsSunsetDirection ?? true)
        _shadowObjectHeightMeters = State(
            initialValue: overlay?.shadowObjectHeightMeters ?? 1
        )
        let request = Self.dayRequest(location: location, timestamp: initialTimestamp)
        _calculatedDayRequest = State(initialValue: request)
        _calculatedDay = State(initialValue: request.flatMap(Self.calculateDay))
        _calculationErrorMessage = State(initialValue: nil)
    }

    private var eligibleEvidence: [AnalysisTimestampEvidence] {
        timestampEvidence.filter(\.isEligibleForSolarPosition)
    }

    private var selectedEvidence: AnalysisTimestampEvidence? {
        guard let selectedEvidenceID else { return nil }
        return eligibleEvidence.first { $0.id == selectedEvidenceID }
    }

    private var captureEvidence: AnalysisTimestampEvidence? {
        eligibleEvidence.first { $0.kind == .capture }
    }

    private var manualTimestamp: AnalysisTimestampValue {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: civilDateTime
        )
        return AnalysisTimestampValue(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            precision: .minute,
            utcOffsetMinutes: utcOffsetMinutes
        )
    }

    private var effectiveTimestamp: AnalysisTimestampValue {
        selectedEvidence?.value ?? manualTimestamp
    }

    private var calculation: Result<AnalysisSolarDay, Error>? {
        guard let coordinate = location?.coordinate,
              let instant = effectiveTimestamp.resolvedInstant,
              let request = solarDayRequest else { return nil }
        if let calculationErrorMessage {
            return .failure(AnalysisSolarPreviewError(message: calculationErrorMessage))
        }
        guard calculatedDayRequest == request,
              let calculatedDay else { return nil }
        return Result {
            let position = try AnalysisSolarPositionCalculator.position(
                at: instant,
                coordinate: coordinate
            )
            return AnalysisSolarDay(
                position: position,
                sunrise: calculatedDay.sunrise,
                solarNoon: calculatedDay.solarNoon,
                sunset: calculatedDay.sunset,
                polarCondition: calculatedDay.polarCondition,
                method: calculatedDay.method
            )
        }
    }

    private var solarDayRequest: AnalysisSolarDayRequest? {
        Self.dayRequest(location: location, timestamp: effectiveTimestamp)
    }

    private var canApply: Bool {
        guard !isUsingMapCenterPreview,
              location != nil,
              effectiveTimestamp.validate(),
              effectiveTimestamp.timezoneKnown,
              effectiveTimestamp.precision != .day,
              draftOverlay.validate(),
              case .success = calculation else { return false }
        return true
    }

    private var draftOverlay: AnalysisSolarOverlayState {
        AnalysisSolarOverlayState(
            isVisible: isVisible,
            timestamp: effectiveTimestamp,
            linkedTimestampEvidenceID: selectedEvidence?.id,
            showsSunDirection: showsSunDirection,
            showsShadowDirection: showsShadowDirection,
            showsSunriseDirection: showsSunriseDirection,
            showsSunsetDirection: showsSunsetDirection,
            shadowObjectHeightMeters: shadowObjectHeightMeters
        )
    }

    private var previewConfiguration: AnalysisSolarPreviewConfiguration? {
        guard let coordinate = location?.coordinate else { return nil }
        return AnalysisSolarPreviewConfiguration(
            coordinate: coordinate,
            timestamp: effectiveTimestamp,
            isVisible: isVisible,
            showsSunDirection: showsSunDirection,
            showsShadowDirection: showsShadowDirection,
            showsSunriseDirection: showsSunriseDirection,
            showsSunsetDirection: showsSunsetDirection,
            shadowObjectHeightMeters: shadowObjectHeightMeters
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Solar Position")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                locationSection
                Divider()
                timeSection
                Divider()
                calculationSection
                Divider()
                visibilitySection

                Text(
                    "Directions assume a flat, unobstructed horizon and standard atmospheric "
                        + "refraction. They do not model terrain, buildings, weather, photographed "
                        + "shadows, or camera orientation."
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if overlay != nil {
                        Button("Remove", role: .destructive) {
                            onClear()
                        }
                        .disabled(isReadOnly)
                        .help("Remove the saved solar-position calculation from this case")
                    }
                    Spacer()
                    Button(overlay == nil ? "Add Overlay" : "Update Overlay") {
                        onApply(draftOverlay)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isReadOnly || !canApply)
                    .help("Save these calculation inputs and overlay visibility choices")
                }
            }
            .padding(16)
        }
        .frame(width: 500, height: 620)
        .environment(\.timeZone, Self.utc)
        .task(id: solarDayRequest) {
            refreshCalculatedDay()
        }
        .task(id: previewConfiguration) {
            publishPreview()
        }
        .onChange(of: selectedEvidenceID) { _, identifier in
            guard let identifier,
                  let evidence = eligibleEvidence.first(where: { $0.id == identifier }) else {
                return
            }
            load(evidence.value)
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isUsingMapCenterPreview ? "Preview Location" : "Photo Location")
                .font(.subheadline.weight(.semibold))
            if let location {
                Text(CoordinateParser.format(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    format: .decimalDegrees
                ))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                Text(location.placeName.map { "\($0) · \(location.source.displayName)" }
                    ?? location.source.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(location.sourceDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if isUsingMapCenterPreview {
                    Label(
                        "Preview only — move the map to test possible locations, then use Set Photo Location when ready.",
                        systemImage: "scope"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label(
                    "Set a Photo Location on the map before calculating solar position.",
                    systemImage: "location.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Time Input")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let captureEvidence {
                    Button("Use Capture Time") {
                        selectedEvidenceID = captureEvidence.id
                    }
                    .controlSize(.small)
                    .disabled(isReadOnly)
                    .help("Use the timezone-qualified capture timestamp from the timeline")
                }
            }

            Picker("Timeline source", selection: $selectedEvidenceID) {
                Text("Manual date and time").tag(UUID?.none)
                ForEach(eligibleEvidence) { evidence in
                    Text("\(evidence.title) — \(evidence.value.formatted)")
                        .tag(Optional(evidence.id))
                }
            }
            .disabled(isReadOnly)
            .help("Only timezone-qualified timeline rows with minute-or-better precision are listed")

            if overlay?.linkedTimestampEvidenceID != nil,
               selectedEvidence == nil {
                Label(
                    "The original timeline row is unavailable; the saved timestamp remains reproducible.",
                    systemImage: "link.badge.plus"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Date")
                    DatePicker(
                        "Civil date",
                        selection: manualDateBinding,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .accessibilityLabel("Solar calculation civil date")
                }
                GridRow {
                    Text("Time")
                    DatePicker(
                        "Civil time",
                        selection: manualDateBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .accessibilityLabel("Solar calculation civil time")
                }
                GridRow {
                    Text("UTC offset")
                    Stepper(
                        formattedUTCOffset,
                        value: manualOffsetBinding,
                        in: (-14 * 60)...(14 * 60),
                        step: 15
                    )
                    .accessibilityLabel("Solar calculation UTC offset")
                    .accessibilityValue(formattedUTCOffset)
                }
            }
            .disabled(isReadOnly || selectedEvidence != nil)

            HStack(spacing: 10) {
                Text("Time of day")
                Slider(value: timeOfDayBinding, in: 0...1_439, step: 1)
                    .accessibilityLabel("Solar calculation time of day")
                    .accessibilityValue(formattedCivilTime)
                Text(formattedCivilTime)
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(isReadOnly)
            .help("Adjust the case-only time within the selected civil day")

            Text("The controls use the displayed fixed UTC offset; they never substitute the Mac's current timezone.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var calculationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Calculated Values")
                .font(.subheadline.weight(.semibold))
            switch calculation {
            case .success(let day):
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    solarValueRow("Sun azimuth", value: degrees(day.position.azimuthDegrees))
                    solarValueRow(
                        "Expected shadow direction",
                        value: degrees(day.position.expectedShadowAzimuthDegrees)
                    )
                    solarValueRow(
                        "Expected shadow length",
                        value: formattedShadowLength(day.position)
                    )
                    solarValueRow(
                        "Geometric elevation",
                        value: signedDegrees(day.position.geometricElevationDegrees)
                    )
                    solarValueRow(
                        "Apparent elevation",
                        value: signedDegrees(day.position.apparentElevationDegrees)
                    )
                    solarValueRow("Sunrise", value: event(day.sunrise))
                    solarValueRow("Solar noon", value: event(day.solarNoon))
                    solarValueRow("Sunset", value: event(day.sunset))
                }
                if let polarCondition = day.polarCondition {
                    Label(
                        polarCondition == .polarDay ? "Polar day" : "Polar night",
                        systemImage: polarCondition == .polarDay ? "sun.max.fill" : "moon.stars.fill"
                    )
                    .font(.caption.weight(.medium))
                } else if day.position.isBelowHorizon {
                    Label("The Sun is below the apparent horizon at this time.", systemImage: "sun.horizon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Method: Meeus/NOAA v1")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    Text("Object height")
                        .foregroundStyle(.secondary)
                    TextField(
                        "Meters",
                        value: $shadowObjectHeightMeters,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .frame(width: 80)
                    Text("m")
                        .foregroundStyle(.secondary)
                }
                .disabled(isReadOnly)
                Text("Level-ground estimate for a vertical object; terrain and tilt are not modelled.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                Text(
                    solarDayRequest == nil
                        ? "A Photo Location and an absolute time are required."
                        : "Calculating civil-day solar events…"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Visibility")
                .font(.subheadline.weight(.semibold))
            Toggle("Show solar overlay", isOn: $isVisible)
            Toggle("Direction toward the Sun", isOn: $showsSunDirection)
            Toggle("Expected shadow direction", isOn: $showsShadowDirection)
            Toggle("Sunrise direction", isOn: $showsSunriseDirection)
            Toggle("Sunset direction", isOn: $showsSunsetDirection)
        }
        .disabled(isReadOnly)
    }

    private var manualDateBinding: Binding<Date> {
        Binding(
            get: { civilDateTime },
            set: {
                selectedEvidenceID = nil
                civilDateTime = $0
            }
        )
    }

    private var manualOffsetBinding: Binding<Int> {
        Binding(
            get: { utcOffsetMinutes },
            set: {
                selectedEvidenceID = nil
                utcOffsetMinutes = $0
            }
        )
    }

    private var timeOfDayBinding: Binding<Double> {
        Binding(
            get: {
                Double(effectiveTimestamp.hour * 60 + effectiveTimestamp.minute)
            },
            set: { minutes in
                selectedEvidenceID = nil
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = Self.utc
                let totalMinutes = Int(minutes.rounded())
                civilDateTime = calendar.date(
                    bySettingHour: totalMinutes / 60,
                    minute: totalMinutes % 60,
                    second: 0,
                    of: civilDateTime
                ) ?? civilDateTime
            }
        )
    }

    private var formattedUTCOffset: String {
        let sign = utcOffsetMinutes < 0 ? "−" : "+"
        let magnitude = abs(utcOffsetMinutes)
        return String(format: "UTC%@%02d:%02d", sign, magnitude / 60, magnitude % 60)
    }

    private var formattedCivilTime: String {
        String(format: "%02d:%02d", effectiveTimestamp.hour, effectiveTimestamp.minute)
    }

    private func load(_ timestamp: AnalysisTimestampValue) {
        guard let date = timestamp.wallClockSortDate else { return }
        civilDateTime = date
        utcOffsetMinutes = timestamp.utcOffsetMinutes ?? 0
    }

    private func refreshCalculatedDay() {
        guard let request = solarDayRequest else {
            calculatedDay = nil
            calculatedDayRequest = nil
            calculationErrorMessage = nil
            return
        }
        guard calculatedDayRequest != request || calculatedDay == nil else { return }
        do {
            calculatedDay = try Self.calculateDayThrowing(request)
            calculatedDayRequest = request
            calculationErrorMessage = nil
        } catch {
            calculatedDay = nil
            calculatedDayRequest = request
            calculationErrorMessage = error.localizedDescription
        }
    }

    private func publishPreview() {
        guard let coordinate = location?.coordinate,
              let instant = effectiveTimestamp.resolvedInstant,
              let utcOffsetMinutes = effectiveTimestamp.utcOffsetMinutes,
              draftOverlay.validate() else {
            onPreview(nil)
            return
        }
        do {
            let calculatedDay = try AnalysisSolarPositionCalculator.calculate(
                input: AnalysisSolarInput(instant: instant, coordinate: coordinate),
                civilDayOffsetMinutes: utcOffsetMinutes
            )
            onPreview(AnalysisSolarMapPreview(
                overlay: draftOverlay,
                origin: coordinate,
                day: calculatedDay
            ))
        } catch {
            onPreview(nil)
        }
    }

    private static func dayRequest(
        location: AnalysisLocationEvidence?,
        timestamp: AnalysisTimestampValue
    ) -> AnalysisSolarDayRequest? {
        guard let coordinate = location?.coordinate,
              coordinate.isValid,
              timestamp.validate(),
              timestamp.timezoneKnown,
              timestamp.precision != .day else { return nil }
        var representative = timestamp
        representative.hour = 12
        representative.minute = 0
        representative.second = 0
        representative.nanosecond = 0
        representative.precision = .minute
        guard let instant = representative.resolvedInstant,
              let utcOffsetMinutes = representative.utcOffsetMinutes else { return nil }
        return AnalysisSolarDayRequest(
            coordinate: coordinate,
            civilDayRepresentativeInstant: instant,
            utcOffsetMinutes: utcOffsetMinutes
        )
    }

    private static func calculateDay(_ request: AnalysisSolarDayRequest) -> AnalysisSolarDay? {
        try? calculateDayThrowing(request)
    }

    private static func calculateDayThrowing(
        _ request: AnalysisSolarDayRequest
    ) throws -> AnalysisSolarDay {
        try AnalysisSolarPositionCalculator.calculate(
            input: AnalysisSolarInput(
                instant: request.civilDayRepresentativeInstant,
                coordinate: request.coordinate
            ),
            civilDayOffsetMinutes: request.utcOffsetMinutes
        )
    }

    private func event(_ event: AnalysisSolarEvent?) -> String {
        guard let event else { return "Does not occur" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(
            secondsFromGMT: (effectiveTimestamp.utcOffsetMinutes ?? 0) * 60
        ) ?? Self.utc
        let values = calendar.dateComponents([.hour, .minute], from: event.instant)
        return String(
            format: "%02d:%02d · %@",
            values.hour ?? 0,
            values.minute ?? 0,
            degrees(event.azimuthDegrees)
        )
    }

    private func degrees(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "°"
    }

    private func signedDegrees(_ value: Double) -> String {
        value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + "°"
    }

    private func formattedShadowLength(_ position: AnalysisSolarPosition) -> String {
        guard let meters = position.expectedShadowLengthMeters(
            objectHeightMeters: shadowObjectHeightMeters
        ) else { return "Unavailable" }
        if meters >= 1_000 {
            return (meters / 1_000).formatted(
                .number.precision(.fractionLength(0...2))
            ) + " km"
        }
        return meters.formatted(.number.precision(.fractionLength(0...2))) + " m"
    }

    private func solarValueRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
        }
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
