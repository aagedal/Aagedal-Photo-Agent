import Foundation

extension CameraRawSettings {
    /// The Develop record a multi-image paste leaves on one target. Scalar sliders come from the
    /// copied source; collections the source doesn't carry (masks, watermark layers, HSL,
    /// anonymizer, preserved ACR masks) and the crop when it isn't pasted are kept from the
    /// target, mirroring the merge-style embedded write.
    nonisolated static func pasted(
        _ source: CameraRawSettings,
        onto existing: CameraRawSettings?,
        includeCrop: Bool
    ) -> CameraRawSettings {
        var result = source
        result.hasSettings = true
        if !includeCrop || source.crop?.isEmpty != false {
            result.crop = existing?.crop
        }
        if source.toneCurve == nil { result.toneCurve = existing?.toneCurve }
        if source.localAdjustments?.isEmpty != false { result.localAdjustments = existing?.localAdjustments }
        if source.watermarkLayers?.isEmpty != false { result.watermarkLayers = existing?.watermarkLayers }
        if source.hslAdjustments?.isEmpty != false { result.hslAdjustments = existing?.hslAdjustments }
        if source.anonymizer?.isEmpty != false { result.anonymizer = existing?.anonymizer }
        if source.unparsedMaskCorrections?.isEmpty != false {
            result.unparsedMaskCorrections = existing?.unparsedMaskCorrections
        }
        return result
    }
}

extension XMPSidecarService {
    /// Applies a Develop paste to the sidecar's current crs inside the per-URL transaction, so the
    /// merge base is the revision actually being replaced. Descriptive fields are untouched.
    @MetadataSidecarFilesystemActor
    func pasteCameraRawSerialized(
        _ source: CameraRawSettings,
        includeCrop: Bool,
        for imageURL: URL
    ) async throws {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            try await self.updateCameraRawTransaction(for: imageURL) { existing in
                CameraRawSettings.pasted(source, onto: existing, includeCrop: includeCrop)
            }
        }
    }
}
