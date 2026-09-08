import CoreGraphics
import Foundation

/// Keeps the Core Foundation image inside a Swift value across NotificationCenter's
/// untyped boundary, so receivers never need to force a CGImage bridge.
nonisolated struct ScopeSourceImageUpdate: Sendable {
    let image: CGImage?
    let isHDR: Bool

    var userInfo: [String: Any] { ["scopeSource": self] }

    init(image: CGImage?, isHDR: Bool) {
        self.image = image
        self.isHDR = isHDR
    }

    init?(notification: Notification) {
        guard let update = notification.userInfo?["scopeSource"] as? Self else { return nil }
        self = update
    }
}
