import Foundation
@preconcurrency import MapKit
@preconcurrency import Network
import Observation

nonisolated enum AnalysisMapImageryAvailability: Equatable, Sendable {
    case checking
    case available
    case offline
    case networkFailure(String)
    case unavailable(String)
    /// OpenStreetMap answered tile requests with an error (rate limit, block, captive portal).
    case tileServerFailure(String)

    var title: String? {
        switch self {
        case .checking, .available:
            nil
        case .offline:
            "Map is offline"
        case .networkFailure:
            "Map network request failed"
        case .unavailable:
            "Map content unavailable"
        case .tileServerFailure:
            "OpenStreetMap tiles are not loading"
        }
    }

    var message: String? {
        switch self {
        case .checking, .available:
            nil
        case .offline:
            "MapKit imagery and place search require a network connection. Coordinates and saved map annotations remain available."
        case .networkFailure(let detail):
            "The network is connected, but MapKit could not complete the imagery request. \(detail)"
        case .unavailable(let detail):
            "MapKit did not return content for this view. Try a different scale, style, or location. \(detail)"
        case .tileServerFailure(let detail):
            "The network is connected, but OpenStreetMap did not return map tiles (\(detail)). Its servers may be limiting requests; try again later or choose an Apple map style. Coordinates and saved annotations are unaffected."
        }
    }

    var systemImage: String {
        switch self {
        case .checking:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .available:
            "checkmark.circle"
        case .offline:
            "wifi.slash"
        case .networkFailure:
            "network.slash"
        case .unavailable:
            "map"
        case .tileServerFailure:
            "exclamationmark.icloud"
        }
    }

    static func failure(for error: Error, networkAvailable: Bool) -> Self {
        guard networkAvailable else { return .offline }
        let detail = error.localizedDescription.isEmpty
            ? "No additional error detail was provided."
            : error.localizedDescription

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .internationalRoamingOff,
                 .dataNotAllowed:
                return .networkFailure(detail)
            default:
                break
            }
        }
        return .unavailable(detail)
    }
}

/// Reports connectivity immediately and verifies that MapKit can render the current imagery view.
/// The small snapshot is never persisted or exported; it is only a health check for explicit UI.
@Observable
final class AnalysisMapAvailabilityMonitor {
    private(set) var imageryAvailability: AnalysisMapImageryAvailability = .checking
    private(set) var isNetworkAvailable: Bool?

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(
        label: "com.aagedal.photoagent.analysis-map-network",
        qos: .utility
    )
    private var hasStarted = false
    private var probeTask: Task<Void, Never>?
    private var lastRegion: MKCoordinateRegion?
    private var lastStyle: AnalysisMapStyle?
    @ObservationIgnored private var tileFailureObserver: AnalysisNotificationObservation?

    var isOffline: Bool {
        isNetworkAvailable == false
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.receiveNetworkAvailability(isAvailable)
            }
        }
        pathMonitor.start(queue: monitorQueue)
        tileFailureObserver = AnalysisNotificationObservation(NotificationCenter.default.addObserver(
            forName: Self.openStreetMapTileFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let detail = notification.userInfo?["detail"] as? String ?? "unknown error"
            Task { @MainActor [weak self] in
                self?.receiveOpenStreetMapTileFailure(detail)
            }
        })
    }

    /// Posted (from any thread) by the OSM tile overlay when a tile request fails.
    nonisolated static let openStreetMapTileFailed = Notification.Name(
        "AnalysisMapAvailabilityMonitor.openStreetMapTileFailed"
    )

    private func receiveOpenStreetMapTileFailure(_ detail: String) {
        guard lastStyle == .openStreetMap, isNetworkAvailable != false else { return }
        imageryAvailability = .tileServerFailure(detail)
    }

    func checkImagery(
        region: MKCoordinateRegion,
        style: AnalysisMapStyle,
        force: Bool = false
    ) {
        lastRegion = region
        lastStyle = style

        guard isNetworkAvailable != false else {
            probeTask?.cancel()
            imageryAvailability = .offline
            return
        }
        if style == .openStreetMap {
            probeTask?.cancel()
            imageryAvailability = .available
            return
        }
        guard force || imageryAvailability != .checking else { return }

        probeTask?.cancel()
        imageryAvailability = .checking
        let assumedNetworkAvailable = isNetworkAvailable != false
        probeTask = Task { [weak self] in
            let options = MKMapSnapshotter.Options()
            options.region = region
            options.size = CGSize(width: 64, height: 64)
            switch style {
            case .standard:
                options.mapType = .standard
            case .muted:
                options.mapType = .mutedStandard
            case .hybrid:
                options.mapType = .hybrid
            case .satellite:
                options.mapType = .satellite
            case .openStreetMap:
                return
            }
            let snapshotter = MKMapSnapshotter(options: options)

            do {
                _ = try await withTaskCancellationHandler {
                    try await snapshotter.start()
                } onCancel: {
                    snapshotter.cancel()
                }
                try Task.checkCancellation()
                self?.imageryAvailability = .available
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.imageryAvailability = .failure(
                    for: error,
                    networkAvailable: self?.isNetworkAvailable ?? assumedNetworkAvailable
                )
            }
        }
    }

    func retry() {
        guard let lastRegion, let lastStyle else { return }
        checkImagery(region: lastRegion, style: lastStyle, force: true)
    }

    func cancelCurrentCheck() {
        probeTask?.cancel()
        probeTask = nil
    }

    private func receiveNetworkAvailability(_ isAvailable: Bool) {
        let previous = isNetworkAvailable
        isNetworkAvailable = isAvailable
        guard isAvailable else {
            probeTask?.cancel()
            imageryAvailability = .offline
            return
        }
        if previous != true, let lastRegion, let lastStyle {
            checkImagery(region: lastRegion, style: lastStyle, force: true)
        }
    }

    deinit {
        pathMonitor.cancel()
    }
}

/// Removes a block-based NotificationCenter observer when its owner goes away.
nonisolated private final class AnalysisNotificationObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
