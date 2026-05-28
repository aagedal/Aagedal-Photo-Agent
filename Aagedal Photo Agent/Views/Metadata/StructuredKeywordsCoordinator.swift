import Foundation
import Observation

/// Mediates between the standalone Structured Keywords window and the currently
/// active metadata panel. The panel registers an "add" closure on appear; when the
/// user double-clicks a keyword in the window, the coordinator forwards it.
///
/// Only one closure is active at a time — last registration wins, matching the
/// expectation that the most recently focused metadata panel is the user's target.
@Observable
final class StructuredKeywordsCoordinator {
    static let shared = StructuredKeywordsCoordinator()

    private(set) var hasActiveTarget: Bool = false

    @ObservationIgnored private var addHandler: (([String]) -> Void)?
    @ObservationIgnored private var ownerToken: ObjectIdentifier?

    /// Register `handler` as the active target. `owner` lets a later unregister call
    /// guard against clobbering a different panel's registration when this panel
    /// disappears after another has taken over.
    func register(owner: AnyObject, handler: @escaping ([String]) -> Void) {
        addHandler = handler
        ownerToken = ObjectIdentifier(owner)
        hasActiveTarget = true
    }

    /// Clear the registration if `owner` is still the current owner. Safe to call
    /// from `onDisappear` even if another panel has already taken over.
    func unregister(owner: AnyObject) {
        guard ownerToken == ObjectIdentifier(owner) else { return }
        addHandler = nil
        ownerToken = nil
        hasActiveTarget = false
    }

    /// Apply `keywords` to the active panel. Returns true if a target was registered.
    @discardableResult
    func apply(_ keywords: [String]) -> Bool {
        guard let addHandler else { return false }
        addHandler(keywords)
        return true
    }
}
