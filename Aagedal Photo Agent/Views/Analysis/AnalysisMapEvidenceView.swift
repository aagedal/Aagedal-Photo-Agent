import SwiftUI
@preconcurrency import CoreLocation
@preconcurrency import MapKit

struct AnalysisMapEvidenceView: View {
    let mapState: AnalysisMapState
    let embeddedLocation: AnalysisGeoCoordinate?
    let isReadOnly: Bool
    let onSetStyle: (AnalysisMapStyle) -> Void
    let onSetViewport: (AnalysisMapViewport) -> Void
    let onSetInvestigationLocation: (AnalysisLocationEvidence?) -> Void
    let onSetAnnotation: (AnalysisMapAnnotation) -> Void

    @Binding var annotationTool: AnalysisAnnotationTool
    @Binding var sharedAnnotationStyle: AnalysisAnnotationStyle
    @Binding var selectedAnnotationID: UUID?

    @State private var mapPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion
    @State private var coordinateInput = ""
    @State private var coordinateError: String?
    @State private var searchText = ""
    @State private var searchCompleter = LocationSearchCompleter()
    @State private var searchError: String?
    @State private var isReverseGeocoding = false
    @State private var geocodingError: String?
    @State private var annotationDraftCoordinates: [AnalysisGeoCoordinate] = []
    @State private var labelInput = ""
    @State private var isLabelPromptPresented = false
    @State private var mapAvailability = AnalysisMapAvailabilityMonitor()

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50, longitude: 10),
        span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)
    )

    init(
        mapState: AnalysisMapState,
        embeddedLocation: AnalysisGeoCoordinate?,
        isReadOnly: Bool,
        onSetStyle: @escaping (AnalysisMapStyle) -> Void,
        onSetViewport: @escaping (AnalysisMapViewport) -> Void,
        onSetInvestigationLocation: @escaping (AnalysisLocationEvidence?) -> Void,
        onSetAnnotation: @escaping (AnalysisMapAnnotation) -> Void,
        annotationTool: Binding<AnalysisAnnotationTool>,
        sharedAnnotationStyle: Binding<AnalysisAnnotationStyle>,
        selectedAnnotationID: Binding<UUID?>
    ) {
        self.mapState = mapState
        self.embeddedLocation = embeddedLocation
        self.isReadOnly = isReadOnly
        self.onSetStyle = onSetStyle
        self.onSetViewport = onSetViewport
        self.onSetInvestigationLocation = onSetInvestigationLocation
        self.onSetAnnotation = onSetAnnotation
        _annotationTool = annotationTool
        _sharedAnnotationStyle = sharedAnnotationStyle
        _selectedAnnotationID = selectedAnnotationID

        let region = Self.initialRegion(mapState: mapState, embeddedLocation: embeddedLocation)
        _mapPosition = State(initialValue: .region(region))
        _visibleRegion = State(initialValue: region)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            annotationAuthoringControls

            searchControls

            map
                .frame(minHeight: 230)
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

            Text("Map locations are case-only evidence. They never change embedded or sidecar GPS metadata.")
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
        .onChange(of: mapState.annotations.map(\.id)) {
            if let selectedAnnotationID,
               !mapState.annotations.contains(where: { $0.id == selectedAnnotationID }) {
                self.selectedAnnotationID = nil
            }
        }
        .onChange(of: selectedAnnotationID) { _, selection in
            guard let selection,
                  let annotation = mapState.annotations.first(where: { $0.id == selection }) else {
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
            Text("The label is stored only in this analysis case.")
        }
    }

    private var header: some View {
        HStack {
            Label("Location Evidence", systemImage: "map")
                .font(.headline)
            Spacer()
            Picker(
                "Map Style",
                selection: Binding(
                    get: { mapState.style },
                    set: { style in onSetStyle(style) }
                )
            ) {
                ForEach(AnalysisMapStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .disabled(isReadOnly)
        }
    }

    private var annotationAuthoringControls: some View {
        HStack(spacing: 8) {
            if annotationTool.supportsMap {
                if annotationTool != .select {
                    Button(annotationPrimaryActionTitle, action: performAnnotationPrimaryAction)
                        .disabled(isReadOnly)
                } else {
                    Text("Select markup on the map or in Map Layers below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(annotationTool.displayName) is available on the photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if annotationTool == .shape, annotationDraftCoordinates.count >= 3 {
                Button("Finish Shape", action: finishShape)
                    .disabled(isReadOnly)
            }

            if !annotationDraftCoordinates.isEmpty {
                Text(annotationDraftSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { annotationDraftCoordinates.removeAll() }
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map markup action")
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField("Search for an address or place", text: $searchText)
                    .textFieldStyle(.roundedBorder)
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
            }
            .disabled(isReadOnly || mapAvailability.isOffline)

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

                Spacer()
                HStack {
                    Button {
                        setInvestigationLocation(
                            coordinate: AnalysisGeoCoordinate(
                                latitude: visibleRegion.center.latitude,
                                longitude: visibleRegion.center.longitude
                            ),
                            source: .mapCenter,
                            detail: "Selected from the center of the analysis map"
                        )
                    } label: {
                        Label("Pin Center", systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(isReadOnly)
                    Spacer()
                }
                .padding(8)
            }
        }
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
    private var styledMap: some View {
        if mapState.style == .hybrid {
            baseMap.mapStyle(.hybrid(elevation: .realistic))
        } else {
            baseMap.mapStyle(.imagery(elevation: .realistic))
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
                    location.placeName ?? "Case location",
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                )
                .tint(.orange)
            }

            ForEach(mapState.annotations.filter(\.isVisible)) { annotation in
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
                    Annotation(
                        annotation.text ?? annotation.kind.displayName,
                        coordinate: annotation.representativeCoordinate.clLocationCoordinate
                    ) {
                        mapAnnotationButton(annotation)
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
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            mapAvailability.checkImagery(region: context.region, style: mapState.style, force: true)
            let viewport = AnalysisMapViewport(
                center: AnalysisGeoCoordinate(
                    latitude: context.region.center.latitude,
                    longitude: context.region.center.longitude
                ),
                latitudeDelta: context.region.span.latitudeDelta,
                longitudeDelta: context.region.span.longitudeDelta
            )
            guard !isReadOnly, viewport.isValid else { return }
            onSetViewport(viewport)
        }
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
            ContentUnavailableView(
                "No Location Evidence",
                systemImage: "location.slash",
                description: Text("Search, enter coordinates, or move the map and pin its center.")
            )
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 12) {
                if let embeddedLocation {
                    locationCard(
                        title: "Embedded GPS",
                        coordinate: embeddedLocation,
                        source: "Source metadata",
                        detail: "Read from the analyzed source; unchanged by this workspace",
                        color: .blue
                    )
                }
                if let location = mapState.investigationLocation {
                    locationCard(
                        title: location.placeName ?? "Case location",
                        coordinate: location.coordinate,
                        source: location.source.displayName,
                        detail: location.placeNameSource.map {
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
        source: String,
        detail: String,
        color: Color
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
            Text(source)
                .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
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
    }

    private var annotationPrimaryActionTitle: String {
        switch annotationTool {
        case .select: "Select"
        case .marker: "Add Marker at Center"
        case .line:
            annotationDraftCoordinates.isEmpty ? "Set Line Start" : "Set Line End"
        case .shape: "Add Shape Vertex"
        case .distance:
            annotationDraftCoordinates.isEmpty ? "Set Distance Start" : "Set Distance End"
        case .label: "Add Label at Center"
        case .arrow, .rectangle, .ellipse: "Use on Photo"
        }
    }

    private var annotationDraftSummary: String {
        switch annotationTool {
        case .line, .distance: "Start selected — move map to the endpoint"
        case .shape: "\(annotationDraftCoordinates.count) vertices"
        default: "Draft"
        }
    }

    private func performAnnotationPrimaryAction() {
        let coordinate = AnalysisGeoCoordinate(
            latitude: visibleRegion.center.latitude,
            longitude: visibleRegion.center.longitude
        )
        guard coordinate.isValid else { return }

        switch annotationTool {
        case .select:
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
        moveMap(to: coordinate)
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
}

private extension AnalysisGeoCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
