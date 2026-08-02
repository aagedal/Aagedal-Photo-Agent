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

    @State private var mapPosition: MapCameraPosition
    @State private var visibleRegion: MKCoordinateRegion
    @State private var coordinateInput = ""
    @State private var coordinateError: String?
    @State private var searchText = ""
    @State private var searchCompleter = LocationSearchCompleter()
    @State private var searchError: String?
    @State private var isReverseGeocoding = false
    @State private var geocodingError: String?

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
        onSetInvestigationLocation: @escaping (AnalysisLocationEvidence?) -> Void
    ) {
        self.mapState = mapState
        self.embeddedLocation = embeddedLocation
        self.isReadOnly = isReadOnly
        self.onSetStyle = onSetStyle
        self.onSetViewport = onSetViewport
        self.onSetInvestigationLocation = onSetInvestigationLocation

        let region = Self.initialRegion(mapState: mapState, embeddedLocation: embeddedLocation)
        _mapPosition = State(initialValue: .region(region))
        _visibleRegion = State(initialValue: region)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

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

            if let error = coordinateError ?? searchError ?? geocodingError {
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
                    set: onSetStyle
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

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField("Search for an address or place", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _, query in
                        searchError = nil
                        searchCompleter.search(query: query)
                    }
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
            .disabled(isReadOnly)

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
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
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

    private func moveMap(to coordinate: AnalysisGeoCoordinate) {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
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
