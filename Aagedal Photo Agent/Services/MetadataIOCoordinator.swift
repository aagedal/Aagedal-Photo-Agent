import Foundation

/// Serializes metadata file I/O on a per-photo basis so that operations touching the
/// *same* file never overlap, while operations on *different* files still run concurrently.
///
/// Why this exists: the metadata write engine (`SwiftExifWriteEngine`) and the single-file
/// reader (`SwiftExifReadService.readDict`) are `nonisolated` and run their work off the main
/// actor. Without coordination, two off-main operations on the same image file can interleave
/// — a write-while-write loses an update or leaves a torn file, and a read-while-write sees a
/// half-written file. Swift 6's data-race checking can't catch this because the shared resource
/// is the file on disk, not in-memory state.
///
/// Operations are keyed by photo (see `MetadataIOKey`), so an image file and its `.xmp`/`.json`
/// sidecars share one lock. Different photos acquire different keys and proceed in parallel,
/// preserving the parallelism of batch folder reads.
actor MetadataIOCoordinator {
    static let shared = MetadataIOCoordinator()

    /// Tail of the operation chain for each key. Each new op awaits the current tail before
    /// running, then becomes the tail. The wrapper task is `Task<Void, Never>` because errors
    /// and cancellation are funneled to the caller via the continuation, never out of the chain
    /// itself — so a failing op never breaks serialization for later ops on the same key.
    private var tails: [String: Task<Void, Never>] = [:]
    private var folderTails: [String: Task<Void, Never>] = [:]

    /// Run `body` with exclusive access to `key`. Ops with the same key run one at a time in the
    /// order they call `withLock`; ops with different keys run concurrently. `body`'s result,
    /// thrown errors, and cancellation all surface to the caller.
    func withLock<T: Sendable>(
        _ key: String,
        _ body: @Sendable @escaping () async throws -> T
    ) async rethrows -> T {
        let previous = tails[key]
        let folderBarrier = folderTails[Self.folderKey(forPhotoKey: key)]

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let op = Task {
                    // Wait for the previous op on this key. Its result/error is irrelevant here;
                    // we only need it to have finished touching the file.
                    await previous?.value
                    await folderBarrier?.value
                    do {
                        continuation.resume(returning: try await body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                tails[key] = op

                // Drop the entry once this op finishes, but only if it's still the tail, so the
                // dictionary doesn't grow without bound. Re-enters the actor to mutate `tails`.
                Task { [weak self] in
                    await op.value
                    await self?.releaseIfTail(key, op)
                }
            }
        } onCancel: {
            // Intentionally a no-op: a single file read/write must run to completion once started —
            // interrupting a write mid-flight could leave a torn file. Callers cancel at a coarser
            // granularity (e.g. the engine checks `Task.isCancelled` between files, before taking
            // the lock). Wrapping in `withTaskCancellationHandler` (which is `rethrows`) also lets
            // this function stay `rethrows`, so non-throwing call sites need no `try`.
        }
    }

    /// A folder barrier waits for all admitted photo operations in that folder. Later
    /// photo operations wait for this barrier, preserving directory-wide delete ownership.
    /// Like photo locks, admitted barriers run to completion despite caller cancellation.
    func withFolderLock<T: Sendable>(
        _ folderKey: String,
        _ body: @Sendable @escaping () async throws -> T
    ) async rethrows -> T {
        let previous = tails.filter { Self.folderKey(forPhotoKey: $0.key) == folderKey }.map(\.value)
        let previousBarrier = folderTails[folderKey]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let op = Task {
                    await previousBarrier?.value
                    for task in previous { await task.value }
                    do {
                        continuation.resume(returning: try await body())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                folderTails[folderKey] = op
                Task { [weak self] in
                    await op.value
                    await self?.releaseFolderIfTail(folderKey, op)
                }
            }
        } onCancel: {}
    }

    private static func folderKey(forPhotoKey key: String) -> String {
        URL(fileURLWithPath: key).deletingLastPathComponent().path
    }

    private func releaseFolderIfTail(_ key: String, _ op: Task<Void, Never>) {
        if folderTails[key] == op { folderTails[key] = nil }
    }

    private func releaseIfTail(_ key: String, _ op: Task<Void, Never>) {
        if tails[key] == op { tails[key] = nil }
    }
}

/// Derives the serialization key for a photo. Keying by the extension-less, symlink-resolved,
/// lowercased path means an image and its `.xmp` sidecar (`IMG.cr2` / `IMG.xmp`) — and any
/// RAW/non-RAW siblings that intentionally share one sidecar — map to the same lock.
enum MetadataIOKey {
    static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath()
            .deletingPathExtension()
            .path
            .lowercased()
    }
}
