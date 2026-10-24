import Foundation
import os
import SwiftMediaMetadata

/// A multi-image Develop paste where some files failed or were refused; the rest were written
/// and the failed files keep their previous settings.
nonisolated struct DevelopPasteFailedError: LocalizedError, Sendable {
    /// Nothing was written; these files keep their previous settings.
    let failures: [URL: String]
    /// The XMP sidecar (which wins on load) took the paste; the embedded copy wasn't updated.
    var sidecarOnly: [URL: String] = [:]
    let total: Int

    var errorDescription: String? {
        func lines(_ entries: [URL: String]) -> [String] {
            entries.sorted { $0.key.lastPathComponent < $1.key.lastPathComponent }
                .map { "\($0.key.lastPathComponent): \($0.value)" }
        }
        var parts: [String] = []
        if !failures.isEmpty {
            parts.append("Pasted to \(total - failures.count) of \(total) images; \(failures.count) failed and keep "
                + "their previous settings.\n" + lines(failures).joined(separator: "\n"))
        }
        if !sidecarOnly.isEmpty {
            parts.append("Pasted to the XMP sidecar; the embedded copy wasn't updated:\n"
                + lines(sidecarOnly).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

extension CameraRawSettings {
    /// The Develop record a multi-image paste leaves on one target. Scalar sliders come from the
    /// copied source; collections the source doesn't carry (HSL, tone curve) and the crop when it
    /// isn't pasted are kept from the target. Lightroom-like layers (see `pastedResult` /
    /// `pastingLayers`): the source's masks replace the target's ordinary masks and its
    /// watermarks replace the target's, but the target's Anonymizer masks — and an active global
    /// Anonymizer — are never removed or weakened.
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

extension StructuredWriteData {
    /// The structured part of a multi-photo Develop paste into a file's embedded XMP: what the
    /// copied settings carry, merged per file with paste semantics (`mergesLayersForPaste`),
    /// including the source's ACR-only mask corrections so the file ends up like the in-memory
    /// `CameraRawSettings.pasted` result.
    nonisolated static func developPaste(_ cameraRaw: CameraRawSettings) -> StructuredWriteData {
        StructuredWriteData(
            toneCurve: cameraRaw.toneCurve,
            masks: (cameraRaw.localAdjustments?.isEmpty == false) ? cameraRaw.localAdjustments : nil,
            watermarkLayers: (cameraRaw.watermarkLayers?.isEmpty == false) ? cameraRaw.watermarkLayers : nil,
            hslAdjustments: (cameraRaw.hslAdjustments?.isEmpty == false) ? cameraRaw.hslAdjustments : nil,
            layerOrder: cameraRaw.layerOrder,
            anonymizer: (cameraRaw.anonymizer?.isEmpty == false) ? cameraRaw.anonymizer : nil,
            unparsedMaskCorrections: (cameraRaw.unparsedMaskCorrections?.isEmpty == false)
                ? cameraRaw.unparsedMaskCorrections : nil,
            mergesLayersForPaste: true
        )
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
            // Merge onto what the photo actually displays: an embedded develop block (with its
            // Anonymizer masks / strength) shows when the sidecar has none, and must be carried
            // into the sidecar block this paste writes instead of being hidden by it.
            let embedded: CameraRawSettings? = (try? ImageMetadata.read(from: imageURL))
                .flatMap { iptcMetadataFromDict($0.asMetadataDict(fileURL: imageURL)).cameraRaw }
            try await self.updateCameraRawTransaction(for: imageURL) { existing in
                let displayed = EffectiveMetadataResolver.reconciledDevelopSettings(
                    sidecar: existing, embedded: embedded
                )
                let result = CameraRawSettings.pastedResult(
                    source, onto: displayed, includeCrop: includeCrop,
                    maskIdentity: .keepUnlessTaken, watermarkIdentity: .keepUnlessTaken
                )
                skipped.withLock { $0 = result.skippedLayerCount }
                return result.settings
            }
            return skipped.withLock { $0 }
        }
    }
}
