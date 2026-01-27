import SwiftUI
import MapKit

struct GPSSectionView: View {
    @Binding var latitude: Double?
    @Binding var longitude: Double?
    var onChanged: () -> Void

    @State private var coordinateInput = ""
    @State private var parseError: String?
    @State private var displayFormat: CoordinateFormat = .decimalDegrees
    @State private var mapPosition: MapCameraPosition = .automatic

    private var hasGPS: Bool {
        latitude != nil && longitude != nil
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GPS Location")
                .font(.headline)

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
        }
        .onChange(of: latitude) { updateMapPosition() }
        .onChange(of: longitude) { updateMapPosition() }
        .onAppear { updateMapPosition() }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $mapPosition) {
                if let coord = coordinate {
                    Marker("", coordinate: coord)
                }
            }
            .mapStyle(.standard)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if !hasGPS {
                    Text("Click to set location")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .onTapGesture { point in
                if let tapped = proxy.convert(point, from: .local) {
                    latitude = tapped.latitude
                    longitude = tapped.longitude
                    onChanged()
                }
            }
        }
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
            TextField("e.g. 59.9139, 10.7522", text: $coordinateInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { setCoordinates() }

            Button { setCoordinates() } label: {
                Image(systemName: "checkmark")
            }
            .disabled(coordinateInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Set coordinates")

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
}
