import Foundation

/// Synchronous native-editor admission for automation draft writes. Selected photos are
/// refused even when the editor appears clean: captured caption saves and unpersisted UI
/// state are not part of the on-disk patch snapshot. There is no MainActor hop under the
/// metadata filesystem lock (the Caption flush barrier can synchronously wait on that lock).
nonisolated final class AutomationDraftEditorAdmission: @unchecked Sendable {
    static let shared = AutomationDraftEditorAdmission()

    enum Failure: LocalizedError, Equatable {
        case selectedInEditor

        var errorDescription: String? {
            "Deselect this photo in every Photo Agent window before applying an automation draft or publishing XMP. Finish or discard editor changes first."
        }
    }

    // All access to selectionKeys is protected by lock. The registry retains identities,
    // not view models; a model removes its entry on deinitialization.
    private let lock = NSLock()
    private var selectionKeys: [UUID: Set<String>] = [:]

    func update(owner: UUID, selectedURLs: [URL]) {
        // Resolve each selection once outside the lock, using exactly the same alias and
        // RAW/XMP sibling identity as metadata I/O. Admission never calls into an editor.
        let keys = Set(selectedURLs.map(MetadataIOKey.key(for:)))
        lock.lock()
        defer { lock.unlock() }
        if keys.isEmpty { selectionKeys.removeValue(forKey: owner) }
        else { selectionKeys[owner] = keys }
    }

    func remove(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        selectionKeys.removeValue(forKey: owner)
    }

    /// Call at the executor's final synchronous admission while holding its photo I/O
    /// lock. A selection registered after this check reads through that same I/O lock
    /// and therefore cannot load the pre-write draft while the transaction is in flight.
    func requireUnselected(_ photo: URL) throws {
        let key = MetadataIOKey.key(for: photo)
        lock.lock()
        defer { lock.unlock() }
        guard !selectionKeys.values.contains(where: { $0.contains(key) }) else {
            throw Failure.selectedInEditor
        }
    }
}
