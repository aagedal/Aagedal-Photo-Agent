import Foundation

/// Decides, when an image has both embedded metadata and an `.xmp` sidecar that disagree,
/// which one is the master for descriptive metadata.
///
/// Policy (chosen by the user, 2026-06-08): the sidecar is master by default — matching
/// Photo Mechanic, which writes edits only to the sidecar. But Adobe Bridge writes
/// metadata *into the image file* instead, so a previously-written sidecar can go stale.
/// When the image file was modified more recently than the sidecar AND their descriptive
/// metadata actually differs, that is the signature of an out-of-band embedded edit: the
/// file wins and the caller surfaces a warning rather than silently overwriting the newer
/// embedded values with the stale sidecar.
///
/// The content diff is what makes the timestamp check safe: cloud sync (iCloud/Dropbox),
/// copies, and backup restores routinely rewrite modification dates without changing
/// content, so a newer mtime alone is not trusted — the two must also actually differ.
nonisolated enum SidecarReconciliation {
    enum Verdict: Equatable, Sendable {
        /// Trust the sidecar (default): apply its values, including clears.
        case sidecarMaster
        /// The image file is newer than the sidecar and they disagree — the sidecar looks
        /// stale (e.g. an external tool edited the embedded file), so the caller should
        /// prefer the embedded file values and warn.
        case fileNewerConflict
    }

    static func verdict(
        imageURL: URL,
        sidecarURL: URL,
        embedded: IPTCMetadata?,
        sidecar: IPTCMetadata
    ) -> Verdict {
        // A develop-settings-only sidecar (no descriptive content, e.g. written by
        // saveCameraRawOnly) is not an IPTC record — there is nothing to reconcile
        // and it must never be flagged stale against embedded descriptive values.
        guard sidecar.hasDescriptiveContent else {
            return .sidecarMaster
        }
        // No embedded baseline, or the two agree → nothing to reconcile; sidecar stands.
        guard let embedded, descriptiveFieldsDiffer(embedded, sidecar) else {
            return .sidecarMaster
        }
        // Without both timestamps we can't tell which is newer; default to the sidecar.
        guard let fileDate = modificationDate(of: imageURL),
              let sidecarDate = modificationDate(of: sidecarURL) else {
            return .sidecarMaster
        }
        return fileDate > sidecarDate ? .fileNewerConflict : .sidecarMaster
    }

    /// True when any descriptive (editor-managed) field differs. Keywords and people are
    /// compared order-insensitively. GPS and technical EXIF are excluded — they aren't part
    /// of the sidecar's descriptive domain and the overlay never force-clears them.
    static func descriptiveFieldsDiffer(_ embedded: IPTCMetadata, _ sidecar: IPTCMetadata) -> Bool {
        if embedded.title != sidecar.title { return true }
        // Legacy sidecars predate the localized Title carrier. `nil` means the sidecar has no
        // opinion and must not turn preserved embedded alternatives into a stale-sidecar conflict.
        // A modeled sidecar value, including explicit `[]`, remains authoritative and comparable.
        if let localizedTitles = sidecar.localizedTitles,
           embedded.localizedTitles != localizedTitles { return true }
        if embedded.description != sidecar.description { return true }
        if embedded.extendedDescription != sidecar.extendedDescription { return true }
        if Set(embedded.keywords) != Set(sidecar.keywords) { return true }
        if Set(embedded.personShown) != Set(sidecar.personShown) { return true }
        if Set(embedded.organisationsShownNames) != Set(sidecar.organisationsShownNames) { return true }
        if Set(embedded.organisationsShownCodes) != Set(sidecar.organisationsShownCodes) { return true }
        if embedded.digitalSourceType != sidecar.digitalSourceType { return true }
        if embedded.urgency != sidecar.urgency { return true }
        if Set(embedded.sceneCodes) != Set(sidecar.sceneCodes) { return true }
        if Set(embedded.subjectCodes) != Set(sidecar.subjectCodes) { return true }
        if Set(embedded.mediaTopics) != Set(sidecar.mediaTopics) { return true }
        if Set(embedded.genres) != Set(sidecar.genres) { return true }
        if embedded.creators != sidecar.creators { return true }
        if embedded.creatorJobTitle != sidecar.creatorJobTitle { return true }
        if embedded.descriptionWriter != sidecar.descriptionWriter { return true }
        if embedded.credit != sidecar.credit { return true }
        if embedded.copyright != sidecar.copyright { return true }
        if embedded.rightsUsageTerms != sidecar.rightsUsageTerms { return true }
        if embedded.webStatementOfRights != sidecar.webStatementOfRights { return true }
        if embedded.digitalImageGUID != sidecar.digitalImageGUID { return true }
        if embedded.imageSupplierImageID != sidecar.imageSupplierImageID { return true }
        if embedded.imageSuppliers != sidecar.imageSuppliers { return true }
        if embedded.jobId != sidecar.jobId { return true }
        if embedded.dateCreated != sidecar.dateCreated { return true }
        if embedded.city != sidecar.city { return true }
        if embedded.sublocation != sidecar.sublocation { return true }
        if embedded.provinceState != sidecar.provinceState { return true }
        if embedded.country != sidecar.country { return true }
        if embedded.countryCode != sidecar.countryCode { return true }
        if embedded.event != sidecar.event { return true }
        if embedded.instructions != sidecar.instructions { return true }
        if embedded.source != sidecar.source { return true }
        if embedded.creatorContactInfo != sidecar.creatorContactInfo { return true }
        if Set(embedded.locationsCreated) != Set(sidecar.locationsCreated) { return true }
        if Set(embedded.locationsShown) != Set(sidecar.locationsShown) { return true }
        return false
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
