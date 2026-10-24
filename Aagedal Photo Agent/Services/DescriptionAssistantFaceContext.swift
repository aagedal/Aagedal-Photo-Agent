import Foundation

/// Shared input preparation for the interactive editor and future batch requests.
/// Reads existing face data only; never scans, identifies people or mutates the face library.
nonisolated struct DescriptionAssistantFaceContext: Sendable {
    let people: [CaptionConfirmedPerson]
    let notice: String?

    /// `developSettings` is the caller's copy of the photo's Develop settings (the editor buffer);
    /// the sidecar is read as well, and a redaction in either copy keeps its faces out.
    static func load(for imageURL: URL, developSettings: CameraRawSettings? = nil) async -> Self {
        let result = await FaceDataFolderLoadService.shared.loadDocument(folderURL: imageURL.deletingLastPathComponent())
        guard !Task.isCancelled, case .complete(let evidence) = result else {
            return Self(people: [], notice: "Face context could not be loaded.")
        }
        let signature = await FaceScanFileSignatureService.shared.signature(for: imageURL)
        guard !Task.isCancelled, case .captured(_, let current) = signature else {
            return Self(people: [], notice: "Face context could not be loaded.")
        }
        // Stored boxes are in the file-tag frame; order them as the photo is displayed
        // (a culling rotation may live only in the sidecar).
        let orientation = await FaceDisplayOrientation.resolved(for: imageURL)
        guard !Task.isCancelled else { return Self(people: [], notice: "Face context could not be loaded.") }
        let redaction = await persistedRedactionInputs(for: imageURL)
        guard !Task.isCancelled else { return Self(people: [], notice: "Face context could not be loaded.") }
        return make(for: imageURL, data: evidence.faceData, currentSignature: current, orientation: orientation,
                    redactionSettings: [developSettings, redaction.sidecar].compactMap { $0 },
                    sensorAspect: redaction.sensorAspect)
    }

    /// Off-main read of the sidecar's develop settings and the stored pixel aspect (needed to
    /// place ellipse masks).
    @concurrent
    private static func persistedRedactionInputs(
        for imageURL: URL
    ) async -> (sidecar: CameraRawSettings?, sensorAspect: Double?) {
        (XMPSidecarService().loadDevelopSettings(for: imageURL), ImagePixelAspect.aspect(at: imageURL))
    }

    static func make(
        for imageURL: URL,
        data: FolderFaceData?,
        currentSignature: FileSignature?,
        orientation: FaceDisplayOrientation,
        redactionSettings: [CameraRawSettings] = [],
        sensorAspect: Double? = nil,
        aiMaskBounds: RedactedFaceFilter.AIMaskBounds = RedactedFaceFilter.decodedAIMaskBounds
    ) -> Self {
        guard var data else { return Self(people: [], notice: "No face scan is available for this photo.") }
        // Geometry from a replaced or physically rotated file must not enter the prompt. A
        // metadata-only write (Apply, Review) keeps the content fingerprint and stays current:
        // the same rule the incremental face scan uses.
        guard FileSignature.storedFacesAreCurrent(stored: data.scannedFiles[imageURL.path], current: currentSignature) else {
            return Self(people: [], notice: "Face data is missing or out of date. Scan this photo again to include names.")
        }
        data.groups.removeAll { $0.isExcludedFromPersonShown }
        let named = CaptionConfirmedPersonOrdering.people(for: imageURL, in: data, orientation: orientation)
        // Privacy: a person the photographer blurred must not be named in the caption.
        let people = RedactedFaceFilter.people(
            named,
            excludingRedactedBy: redactionSettings,
            displayOrientation: orientation.displayOrientation,
            sensorAspect: sensorAspect,
            aiMaskBounds: aiMaskBounds
        )
        let notice: String?
        if people.count < named.count {
            notice = people.isEmpty
                ? "The named faces in this photo are blurred, so their names are left out."
                : "Blurred faces are left out."
        } else {
            notice = people.isEmpty ? "No named faces are available for this photo." : nil
        }
        return Self(people: people, notice: notice)
    }
}
