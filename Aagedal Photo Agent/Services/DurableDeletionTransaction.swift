import Foundation

/// File operations used by ``DurableDeletionTransaction``. Keeping these operations in
/// one value gives the three synced libraries the same transaction semantics and gives
/// tests a narrow failure-injection seam.
nonisolated struct DurableDeletionIO: @unchecked Sendable {
    let writeData: (Data, URL) throws -> Void
    let readData: (URL) throws -> Data
    let removeItem: (URL) throws -> Void

    static let live = DurableDeletionIO(
        writeData: { try CloudCoordinatedIO.writeData($0, to: $1) },
        readData: { try CloudCoordinatedIO.readData(at: $0) },
        removeItem: { try CloudCoordinatedIO.removeItem(at: $0) }
    )
}

/// A recoverable failure from a synced record deletion.
///
/// The descriptions deliberately tell the UI whether the original was preserved. A
/// caller can safely present `localizedDescription` and leave the item selected for Retry.
nonisolated enum DurableDeletionError: Error, LocalizedError, Equatable {
    case markerEncodingFailed(reason: String)
    case markerWriteFailed(reason: String)
    case markerReadBackFailed(reason: String)
    case markerVerificationFailed
    case markerRollbackFailed(operation: String, reason: String)
    case recordRemovalFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .markerEncodingFailed:
            "The deletion marker could not be prepared. The original item was kept. Retry the deletion."
        case .markerWriteFailed:
            "The deletion marker could not be saved. The original item was kept. Check storage access and retry."
        case .markerReadBackFailed:
            "The saved deletion marker could not be verified. The original item was kept and the unverified marker was removed. Retry the deletion."
        case .markerVerificationFailed:
            "The saved deletion marker did not match this item. The original item was kept and the invalid marker was removed. Retry the deletion."
        case .markerRollbackFailed:
            "The deletion was interrupted and its marker could not be rolled back. The original record remains on disk; retry the deletion to finish recovery."
        case .recordRemovalFailed:
            "The original item could not be removed, so its deletion marker was rolled back and the item was kept. Retry the deletion."
        }
    }
}

/// Installs and read-back-verifies a synced deletion marker before removing a record.
///
/// There is no portable atomic rename covering two iCloud items. This transaction uses
/// the safe recoverable order instead:
///
/// 1. encode, durably write, read back, and decode the marker;
/// 2. verify that the decoded marker identifies the intended record;
/// 3. remove the source record;
/// 4. if step 2 or 3 fails, remove the marker so the still-present source stays usable.
///
/// Callers must update in-memory state and delete derived caches only after this method
/// returns. A marker rollback failure leaves a documented retryable state: the source is
/// still on disk and a repeated deletion can replace the marker and finish the removal.
nonisolated enum DurableDeletionTransaction {
    static func execute<Marker: Codable>(
        marker: Marker,
        markerURL: URL,
        recordURL: URL,
        markerMatches: (Marker) -> Bool,
        io: DurableDeletionIO = .live
    ) throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(marker)
        } catch {
            throw DurableDeletionError.markerEncodingFailed(reason: error.localizedDescription)
        }

        do {
            try io.writeData(encoded, markerURL)
        } catch {
            throw DurableDeletionError.markerWriteFailed(reason: error.localizedDescription)
        }

        let installed: Marker
        do {
            let installedData = try io.readData(markerURL)
            installed = try JSONDecoder().decode(Marker.self, from: installedData)
        } catch {
            try rollbackMarker(
                at: markerURL,
                operation: "verifying the saved marker",
                originalError: DurableDeletionError.markerReadBackFailed(reason: error.localizedDescription),
                io: io
            )
        }

        guard markerMatches(installed) else {
            try rollbackMarker(
                at: markerURL,
                operation: "verifying the saved marker",
                originalError: DurableDeletionError.markerVerificationFailed,
                io: io
            )
        }

        do {
            try io.removeItem(recordURL)
        } catch {
            try rollbackMarker(
                at: markerURL,
                operation: "removing the original record",
                originalError: DurableDeletionError.recordRemovalFailed(reason: error.localizedDescription),
                io: io
            )
        }
    }

    private static func rollbackMarker(
        at markerURL: URL,
        operation: String,
        originalError: DurableDeletionError,
        io: DurableDeletionIO
    ) throws -> Never {
        do {
            try io.removeItem(markerURL)
        } catch {
            throw DurableDeletionError.markerRollbackFailed(
                operation: operation,
                reason: error.localizedDescription
            )
        }
        throw originalError
    }
}
