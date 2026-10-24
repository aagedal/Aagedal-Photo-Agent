import Foundation
import os

/// A multi-image Develop paste where some files failed or were refused; the rest were written
/// and the failed files keep their previous settings.
nonisolated struct DevelopPasteFailedError: LocalizedError, Sendable {
    let failures: [URL: String]
    let total: Int

    var errorDescription: String? {
        let details = failures.sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }
            .map { "\($0.key.lastPathComponent): \($0.value)" }
        return "Pasted to \(total - failures.count) of \(total) images; \(failures.count) failed and keep "
            + "their previous settings.\n" + details.joined(separator: "\n")
    }
}

extension CameraRawSettings {
    /// The Develop record a multi-image paste leaves on one target. Scalar sliders come from the
    /// copied source; collections the source doesn't carry (HSL, anonymizer, tone curve) and the
    /// crop when it isn't pasted are kept from the target. Layers are never replaced: the
    /// source's masks and watermark layers are appended to the target's own (see
    /// `appendingLayers(from:maskIdentity:watermarkIdentity:)`), so a paste can't delete the
    /// target's Anonymizer face masks or watermarks.
    nonisolated static func pasted(
        _ source: CameraRawSettings,
        onto existing: CameraRawSettings?,
        includeCrop: Bool
    ) -> CameraRawSettings {
        pastedResult(source, onto: existing, includeCrop: includeCrop,
                     maskIdentity: .keepUnlessTaken, watermarkIdentity: .keepUnlessTaken).settings
    }

    /// The Develop record a single-image (live editor) paste leaves on the active image. Same
    /// merge as `pasted(_:onto:includeCrop:)` so single and multi-image paste agree, except that
    /// pasted masks get fresh IDs — they become independent of the source's masks — with the
    /// pasted layer order remapped to follow them.
    nonisolated static func pastedIntoEditor(
        _ source: CameraRawSettings,
        onto existing: CameraRawSettings?,
        includeCrop: Bool
    ) -> CameraRawSettings {
        pastedIntoEditorResult(source, onto: existing, includeCrop: includeCrop).settings
    }

    /// `pastedIntoEditor` plus the count of layers skipped for the layer limit.
    nonisolated static func pastedIntoEditorResult(
        _ source: CameraRawSettings,
        onto existing: CameraRawSettings?,
        includeCrop: Bool
    ) -> DevelopLayerAppendResult {
        pastedResult(source, onto: existing, includeCrop: includeCrop,
                     maskIdentity: .fresh, watermarkIdentity: .keepUnlessTaken)
    }
}

extension XMPSidecarService {
    /// Applies a Develop paste to the sidecar's current crs inside the per-URL transaction, so the
    /// merge base is the revision actually being replaced. Descriptive fields are untouched.
    /// Returns how many copied layers were skipped for the layer limit.
    @MetadataSidecarFilesystemActor
    @discardableResult
    func pasteCameraRawSerialized(
        _ source: CameraRawSettings,
        includeCrop: Bool,
        for imageURL: URL
    ) async throws -> Int {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            let skipped = OSAllocatedUnfairLock(initialState: 0)
            try await self.updateCameraRawTransaction(for: imageURL) { existing in
                let result = CameraRawSettings.pastedResult(
                    source, onto: existing, includeCrop: includeCrop,
                    maskIdentity: .keepUnlessTaken, watermarkIdentity: .keepUnlessTaken
                )
                skipped.withLock { $0 = result.skippedLayerCount }
                return result.settings
            }
            return skipped.withLock { $0 }
        }
    }
}
