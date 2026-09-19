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
        // Keep passive/develop-only reads free of unnecessary filesystem probes.
        guard sidecar.hasDescriptiveContent,
              let embedded, descriptiveFieldsDiffer(embedded, sidecar) else {
            return .sidecarMaster
        }
        return verdict(imageModificationDate: modificationDate(of: imageURL),
                sidecarModificationDate: modificationDate(of: sidecarURL),
                embedded: embedded, sidecar: sidecar)
    }

    /// Reconciles captured carriers without observing a later filesystem generation.
    static func verdict(
        imageModificationDate: Date?,
        sidecarModificationDate: Date?,
        embedded: IPTCMetadata?,
        sidecar: IPTCMetadata
    ) -> Verdict {
        guard sidecar.hasDescriptiveContent,
              let embedded, descriptiveFieldsDiffer(embedded, sidecar),
              let fileDate = imageModificationDate,
              let sidecarDate = sidecarModificationDate else {
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

nonisolated enum MetadataReferenceSource: String, CaseIterable, Identifiable, Sendable {
    case embedded
    case xmp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .embedded:
            return "Embedded"
        case .xmp:
            return "XMP Sidecar"
        }
    }
}

/// Pure carrier selection shared by interactive reads and explicit-photo automation.
/// Callers own byte capture, parsing, authorization and revision validation; this resolver
/// never reopens a path or grants mutation authority.
nonisolated enum EffectiveMetadataResolver {
    enum Carrier: String, Sendable {
        case embedded, xmp, pendingAppSidecar
    }

    struct Resolution: Sendable {
        let metadata: IPTCMetadata
        let descriptiveCarrier: Carrier
        /// Carrier whose selection rule supplied each persisted editorial field, including clears.
        let fieldCarriers: [String: Carrier]
        let hasPendingChanges: Bool
        let hasXMPConflict: Bool
    }

    enum ReadError: LocalizedError {
        case incompleteXMP
        var errorDescription: String? {
            "The XMP sidecar could not be read consistently. Reload before copying metadata."
        }
    }

    static func resolve(embedded: IPTCMetadata, xmpMetadata: IPTCMetadata?,
                        appSidecar: MetadataSidecar?, reconciliationVerdict: SidecarReconciliation.Verdict?,
                        xmpReadFailure: String? = nil, isRaw: Bool) throws -> Resolution {
        guard xmpReadFailure == nil else { throw ReadError.incompleteXMP }
        let conflict = reconciliationVerdict == .fileNewerConflict
        let reference: MetadataReferenceSource = xmpMetadata != nil && !conflict ? .xmp : .embedded
        let physical = physicalMetadata(for: reference, embedded: embedded,
            xmp: xmpMetadata, isRaw: isRaw) ?? embedded
        let pending = appSidecar?.pendingChanges == true
        let metadata = appSidecar.map { applyingPendingDraft($0, to: physical) } ?? physical
        let descriptiveCarrier: Carrier = pending ? .pendingAppSidecar
            : (reference == .xmp && xmpMetadata?.hasDescriptiveContent == true ? .xmp : .embedded)
        var fieldCarriers = Dictionary(uniqueKeysWithValues:
            IPTCMetadata.persistedJSONFieldNames.map { ($0, descriptiveCarrier) })
        if !pending {
            // These fields are inherited even when XMP replaces the descriptive record.
            // The legacy creator alias follows the creators array selected above.
            for key in ["localizedTitles", "captureDate", "latitude", "longitude", "rating", "label"] {
                fieldCarriers[key] = .embedded
            }
            if reference == .xmp, let xmp = xmpMetadata {
                if xmp.localizedTitles != nil { fieldCarriers["localizedTitles"] = .xmp }
                if let value = xmp.captureDate, !value.isEmpty { fieldCarriers["captureDate"] = .xmp }
                if xmp.latitude != nil { fieldCarriers["latitude"] = .xmp }
                if xmp.longitude != nil { fieldCarriers["longitude"] = .xmp }
                if xmp.rating != nil { fieldCarriers["rating"] = .xmp }
                if xmp.label != nil { fieldCarriers["label"] = .xmp }
            }
        }
        return Resolution(metadata: metadata,
            descriptiveCarrier: descriptiveCarrier, fieldCarriers: fieldCarriers,
            hasPendingChanges: pending, hasXMPConflict: conflict)
    }

    static func applyingPendingDraft(_ sidecar: MetadataSidecar, to physical: IPTCMetadata) -> IPTCMetadata {
        guard sidecar.pendingChanges else { return physical }
        var metadata = sidecar.metadata
        metadata.cameraRaw = physical.cameraRaw ?? sidecar.metadata.cameraRaw
        metadata.exifOrientation = physical.exifOrientation
        return metadata
    }

    static func physicalMetadata(for source: MetadataReferenceSource,
                                 embedded: IPTCMetadata?, xmp: IPTCMetadata?,
                                 isRaw: Bool) -> IPTCMetadata? {
        switch source {
        case .embedded:
            // Develop (CRS) edits made in this app always persist to the XMP
            // sidecar — the image file itself is never rewritten by the editor
            // (mandatory for RAW/C2PA, and the default for non-RAW too). So even
            // when the user prefers embedded IPTC, the sidecar is authoritative
            // for develop settings: override embedded CRS with non-empty XMP CRS
            // for ALL file types. This mirrors the grid loader
            // (BrowserViewModel.applyBatchMetadataResults); previously this was
            // gated to RAW only, which dropped develop edits for JPEG/JXL on
            // reload and left the develop view showing the unedited original.
            if let embedded,
               let xmpCRS = xmp?.cameraRaw, !xmpCRS.isEmpty {
                var result = embedded
                var finalCRS = xmpCRS
                if (xmpCRS.localAdjustments?.isEmpty ?? true),
                   let masks = embedded.cameraRaw?.localAdjustments, !masks.isEmpty {
                    finalCRS.localAdjustments = masks
                }
                result.cameraRaw = finalCRS
                return result
            }
            return embedded
        case .xmp:
            if let embedded, let xmp {
                // Photo Mechanic semantics: a sidecar with descriptive content IS the
                // IPTC record — take its descriptive fields wholesale so clears stick
                // instead of resurrecting embedded values through empty fields. A
                // develop-only sidecar (no descriptive content) is not a record;
                // overlay it additively so embedded descriptive values show through.
                var merged = xmp.hasDescriptiveContent
                    ? embedded.replacingDescriptiveFields(from: xmp)
                    : embedded.merged(preferring: xmp)
                // RAW: XMP sidecar is authoritative for CRS — replace, don't merge,
                // to avoid stale embedded values leaking through nil sidecar fields
                // (e.g. Adobe omitting Temperature even with WhiteBalance="Custom").
                if isRaw,
                   let xmpCRS = xmp.cameraRaw {
                    var finalCRS = xmpCRS
                    // Preserve localAdjustments from embedded (written to image directly, not to XMP sidecar)
                    if (xmpCRS.localAdjustments?.isEmpty ?? true),
                       let masks = embedded.cameraRaw?.localAdjustments, !masks.isEmpty {
                        finalCRS.localAdjustments = masks
                    }
                    merged.cameraRaw = finalCRS
                }
                return merged
            }
            return xmp ?? embedded
        }
    }
}
