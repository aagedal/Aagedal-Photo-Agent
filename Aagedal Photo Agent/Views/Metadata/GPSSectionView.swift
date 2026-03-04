import SwiftUI
@preconcurrency import MapKit

struct GPSSectionView: View {
    @Binding var latitude: Double?
    @Binding var longitude: Double?
    var onChanged: () -> Void
    var focusKey: String? = nil
    var focusedField: FocusState<String?>.Binding? = nil

    // Reverse geocoding parameters
    var isBatchMode: Bool = false
    var isReverseGeocoding: Bool = false
    var geocodingError: String? = nil
    var geocodingProgress: String = ""
    var onReverseGeocode: (() -> Void)? = nil

    @State private var coordinateInput = ""
    @State private var parseError: String?
    @State private var displayFormat: CoordinateFormat = .decimalDegrees
    @State private var mapPosition: MapCameraPosition = .automatic
    @AppStorage("gpsLocationCollapsed") private var isCollapsed = false

    // Search state
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchCompleter = LocationSearchCompleter()

    private var hasGPS: Bool {
        latitude != nil && longitude != nil
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50, longitude: 10),
        span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header row: chevron + title + search button
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Text("GPS Location")
                            .font(.headline)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    isSearching.toggle()
                    if !isSearching {
                        searchText = ""
                        searchCompleter.results = []
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Search for a location")
            }

            // Search field (always visible when searching, regardless of collapse)
            if isSearching {
                searchView
            }

            if !isCollapsed {
                mapView

                if coordinate != nil {
                    coordinateDisplay
                }

                coordinateInputField

                if let error = parseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let error = geocodingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: latitude) { updateMapPosition() }
        .onChange(of: longitude) { updateMapPosition() }
        .onAppear { updateMapPosition() }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchView: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Search location...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onChange(of: searchText) { _, newValue in
                    searchCompleter.search(query: newValue)
                }

            if !searchCompleter.results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(searchCompleter.results, id: \.self) { result in
                            Button {
                                selectSearchResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    if !result.subtitle.isEmpty {
                                        Text(result.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapView: some View {
        GeometryReader { geometry in
            MapReader { proxy in
                Map(position: $mapPosition) {
                    if let coord = coordinate {
                        Marker("", coordinate: coord)
                    }
                }
                .mapStyle(.standard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    // Crosshair in center (always visible)
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)

                    // Set location button in bottom left
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                if let coord = proxy.convert(center, from: .local) {
                                    latitude = coord.latitude
                                    longitude = coord.longitude
                                    onChanged()
                                }
                            } label: {
                                Label("Set location", systemImage: "mappin.and.ellipse")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(8)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    // MARK: - Coordinate Display

    @ViewBuilder
    private var coordinateDisplay: some View {
        if let lat = latitude, let lon = longitude {
            HStack(spacing: 4) {
                Picker("Format", selection: $displayFormat) {
                    ForEach(CoordinateFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 160)
                .controlSize(.small)

                Text(CoordinateParser.format(latitude: lat, longitude: lon, format: displayFormat))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                Spacer()

                Button {
                    let text = CoordinateParser.format(latitude: lat, longitude: lon, format: displayFormat)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy coordinates")
            }
        }
    }

    // MARK: - Input

    private var coordinateInputField: some View {
        HStack(spacing: 4) {
            if let focusedField, let focusKey {
                TextField("e.g. 59.9139, 10.7522", text: $coordinateInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused(focusedField, equals: focusKey)
                    .onSubmit { setCoordinates() }
            } else {
                TextField("e.g. 59.9139, 10.7522", text: $coordinateInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { setCoordinates() }
            }

            Button { setCoordinates() } label: {
                Image(systemName: "checkmark")
            }
            .disabled(coordinateInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Set coordinates")

            if let onReverseGeocode {
                Button { onReverseGeocode() } label: {
                    if isReverseGeocoding {
                        if !geocodingProgress.isEmpty {
                            Text(geocodingProgress)
                                .font(.caption2)
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    } else {
                        Image(systemName: "location.fill")
                    }
                }
                .disabled((!hasGPS && !isBatchMode) || isReverseGeocoding)
                .help(isBatchMode ? "Auto-fill City/Country for all selected images" : "Auto-fill City and Country from GPS")
            }

            if hasGPS {
                Button(role: .destructive) {
                    latitude = nil
                    longitude = nil
                    coordinateInput = ""
                    parseError = nil
                    mapPosition = .region(Self.defaultRegion)
                    onChanged()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove GPS")
            }
        }
    }

    // MARK: - Helpers

    private func setCoordinates() {
        parseError = nil
        guard let result = CoordinateParser.parse(coordinateInput) else {
            parseError = "Invalid coordinates. Use DD (59.9139, 10.7522), DMS (59°54'50.0\"N 10°45'7.9\"E), or DDM (59°54.833'N 10°45.132'E)."
            return
        }
        latitude = result.latitude
        longitude = result.longitude
        parseError = nil
        onChanged()
    }

    private func updateMapPosition() {
        if let coord = coordinate {
            mapPosition = .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        } else {
            mapPosition = .region(Self.defaultRegion)
        }
    }

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: result)
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            guard let item = response?.mapItems.first else { return }
            let coord = item.placemark.coordinate
            latitude = coord.latitude
            longitude = coord.longitude
            onChanged()
            isSearching = false
            searchText = ""
            searchCompleter.results = []
        }
    }
}

// MARK: - Location Search Completer

@Observable
class LocationSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(query: String) {
        if query.isEmpty {
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let completionResults = completer.results
        Task { @MainActor in
            self.results = completionResults
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Silently handle search errors
    }
}
