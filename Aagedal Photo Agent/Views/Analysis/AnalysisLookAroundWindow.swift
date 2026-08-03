import AppKit
import SwiftUI
@preconcurrency import MapKit

nonisolated struct AnalysisLookAroundLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let title: String?

    init(coordinate: AnalysisGeoCoordinate, title: String? = nil) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.title = title
    }

    var coordinate: AnalysisGeoCoordinate {
        AnalysisGeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

nonisolated enum AnalysisExternalMapLinks {
    static func googleMapsURL(for coordinate: AnalysisGeoCoordinate) -> URL? {
        guard coordinate.isValid else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/search/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(
                name: "query",
                value: String(
                    format: "%.8f,%.8f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    coordinate.latitude,
                    coordinate.longitude
                )
            ),
        ]
        return components.url
    }
}

struct AnalysisLookAroundWindowView: View {
    let location: AnalysisLookAroundLocation

    @State private var scene: MKLookAroundScene?
    @State private var sceneRequest: MKLookAroundSceneRequest?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let scene {
                InteractiveLookAroundView(scene: scene)
            } else if isLoading {
                ContentUnavailableView {
                    Label("Loading Look Around", systemImage: "binoculars")
                } description: {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                ContentUnavailableView(
                    "Look Around Unavailable",
                    systemImage: "binoculars.fill",
                    description: Text(
                        errorMessage
                            ?? "Apple Look Around does not currently cover this location."
                    )
                )
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .task(id: location) {
            await loadScene()
        }
        .onDisappear {
            sceneRequest?.cancel()
            sceneRequest = nil
        }
        .toolbar {
            ToolbarItem {
                Button(action: openInGoogleMaps) {
                    Label("Open in Google Maps", systemImage: "arrow.up.right.square")
                }
                .help("Open this location in Google Maps in your default browser")
            }
        }
    }

    private func loadScene() async {
        sceneRequest?.cancel()
        scene = nil
        errorMessage = nil
        isLoading = true

        guard location.coordinate.isValid else {
            isLoading = false
            errorMessage = "The requested coordinate is invalid."
            return
        }

        let request = MKLookAroundSceneRequest(
            coordinate: CLLocationCoordinate2D(
                latitude: location.latitude,
                longitude: location.longitude
            )
        )
        sceneRequest = request

        do {
            let loadedScene = try await request.scene
            guard sceneRequest === request, !Task.isCancelled else { return }
            scene = loadedScene
            isLoading = false
            if loadedScene == nil {
                errorMessage = "Apple Look Around does not currently cover this location."
            }
        } catch is CancellationError {
            return
        } catch {
            guard sceneRequest === request, !Task.isCancelled else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func openInGoogleMaps() {
        guard let url = AnalysisExternalMapLinks.googleMapsURL(for: location.coordinate) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct InteractiveLookAroundView: NSViewControllerRepresentable {
    let scene: MKLookAroundScene

    func makeNSViewController(context: Context) -> MKLookAroundViewController {
        let controller = MKLookAroundViewController(scene: scene)
        controller.isNavigationEnabled = true
        controller.showsRoadLabels = true
        controller.badgePosition = .topLeading
        return controller
    }

    func updateNSViewController(
        _ controller: MKLookAroundViewController,
        context: Context
    ) {
        if controller.scene !== scene {
            controller.scene = scene
        }
        controller.isNavigationEnabled = true
        controller.showsRoadLabels = true
    }
}
