import SwiftUI
import Combine

/// Shared, persisted toggle for the full-screen viewer and edit preview's magnification /
/// minification filter: nearest-neighbor (crisp pixels) vs linear (bilinear smoothing).
/// Surfaced both in the View menu and via the Option+S shortcut inside the full-screen viewer,
/// so the state has to be observable and shared rather than local `@State`.
@MainActor
final class ImageScalingController: ObservableObject {
    static let shared = ImageScalingController()

    @Published var useNearestNeighbor: Bool {
        didSet {
            UserDefaults.standard.set(
                useNearestNeighbor,
                forKey: UserDefaultsKeys.imageScalingNearestNeighbor
            )
        }
    }

    private init() {
        useNearestNeighbor = UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.imageScalingNearestNeighbor
        )
    }

    func toggle() {
        useNearestNeighbor.toggle()
    }
}
