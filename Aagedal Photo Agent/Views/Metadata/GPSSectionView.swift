import SwiftUI
import MapKit

struct GPSSectionView: View {
    @Binding var latitude: Double?
    @Binding var longitude: Double?
    var onChanged: () -> Void

    @State private var coordinateInput = ""
    @State private var parseError: String?
    @State private var displayFormat: CoordinateFormat = .decimalDegrees
    @State private var isExpanded = true

    private var hasGPS: Bool {
        latitude != nil && longitude != nil
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        DisclosureGroup("GPS Location", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let coord = coordinate {
                    mapView(coordinate: coord)
                    coordinateDisplay
                }

                coordinateInputField

                if let error = parseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if hasGPS {
                    Button("Remove GPS", role: .destructive) {
                        latitude = nil
                        longitude = nil
                        coordinateInput = ""
                        parseError = nil
                        onChanged()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Map

    @ViewBuilder
    private func mapView(coordinate: CLLocationCoordinate2D) -> some View {
        Map {
            Marker("", coordinate: coordinate)
        }
        .mapStyle(.standard)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Coordinate Display

    @ViewBuilder
    private var coordinateDisplay: some View {
        if let lat = latitude, let lon = longitude {
            HStack {
                Picker("Format", selection: $displayFormat) {
                    ForEach(CoordinateFormat.allCases, id: \.self) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

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
        HStack {
            TextField("e.g. 59.9139, 10.7522", text: $coordinateInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { setCoordinates() }

            Button("Set") { setCoordinates() }
                .disabled(coordinateInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

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
}
