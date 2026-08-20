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
    static func descriptiveFieldsDiffer(_ a: IPTCMetadata, _ b: IPTCMetadata) -> Bool {
        if a.title != b.title { return true }
        if a.description != b.description { return true }
        if a.extendedDescription != b.extendedDescription { return true }
        if Set(a.keywords) != Set(b.keywords) { return true }
        if Set(a.personShown) != Set(b.personShown) { return true }
        if Set(a.organisationsShownNames) != Set(b.organisationsShownNames) { return true }
        if Set(a.organisationsShownCodes) != Set(b.organisationsShownCodes) { return true }
        if a.digitalSourceType != b.digitalSourceType { return true }
        if a.urgency != b.urgency { return true }
        if a.creator != b.creator { return true }
        if a.creatorJobTitle != b.creatorJobTitle { return true }
        if a.descriptionWriter != b.descriptionWriter { return true }
        if a.credit != b.credit { return true }
        if a.copyright != b.copyright { return true }
        if a.rightsUsageTerms != b.rightsUsageTerms { return true }
        if a.webStatementOfRights != b.webStatementOfRights { return true }
        if a.jobId != b.jobId { return true }
        if a.dateCreated != b.dateCreated { return true }
        if a.city != b.city { return true }
        if a.sublocation != b.sublocation { return true }
        if a.provinceState != b.provinceState { return true }
        if a.country != b.country { return true }
        if a.countryCode != b.countryCode { return true }
        if a.event != b.event { return true }
        if a.instructions != b.instructions { return true }
        if a.source != b.source { return true }
        if a.creatorContactInfo != b.creatorContactInfo { return true }
        if Set(a.locationsCreated) != Set(b.locationsCreated) { return true }
        if Set(a.locationsShown) != Set(b.locationsShown) { return true }
        return false
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
