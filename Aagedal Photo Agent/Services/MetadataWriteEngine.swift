import Foundation

/// The authoritative structured editorial portion of a descriptive write. Keeping this wrapper
/// optional on `StructuredWriteData` distinguishes "leave these properties untouched" from an
/// explicit record whose nil/empty values clear them.
nonisolated struct EditorialStructuredWriteData: Sendable {
    /// Ordered Dublin Core Title alternatives. nil leaves the carrier untouched; an empty
    /// collection explicitly clears it.
    var localizedTitles: [LocalizedMetadataText]?
    var creatorContactInfo: CreatorContactInfo?
    var locationsCreated: [EditorialLocation]
    var locationsShown: [EditorialLocation]
    var mediaTopics: [IPTCControlledVocabularyTerm]
    var genres: [IPTCControlledVocabularyTerm]
    var imageSuppliers: [EditorialImageSupplier]

    nonisolated init(metadata: IPTCMetadata) {
        localizedTitles = metadata.localizedTitles
        creatorContactInfo = metadata.creatorContactInfo
        locationsCreated = metadata.locationsCreated
        locationsShown = metadata.locationsShown
        mediaTopics = metadata.mediaTopics
        genres = metadata.genres
        imageSuppliers = metadata.imageSuppliers
    }
}

/// Structured data for writes that go beyond simple key-value pairs (tone curves, masks).
nonisolated struct StructuredWriteData: Sendable {
    var toneCurve: ToneCurve?
    var masks: [MaskAdjustment]?
    /// Watermark layers — app-private, carried alongside `masks` through the same
    /// `layerOrder` chain. nil ⇒ "don't touch" for a merge-style write.
    var watermarkLayers: [WatermarkLayer]?
    var hslAdjustments: HSLAdjustments?
    /// The reorderable layer chain (incl. the global node's position). nil ⇒ canonical
    /// global-first. Carried so the embedded-XMP writer can persist `aaphoto:GlobalLayerIndex`
    /// and write masks in render-stack order, matching the .xmp sidecar.
    var layerOrder: [LayerRef]?
    /// The global Anonymizer redaction settings (app-private, not an ACR concept). nil means
    /// "don't touch" for a merge-style write; see `replaceCameraRawBlock` for full-replace writes.
    var anonymizer: AnonymizerSettings?

    /// Camera Raw mask corrections this app can't model (erase-brush blobs, unknown mask types),
    /// carried through so a full-replace develop write re-emits them verbatim instead of dropping
    /// them. See `PreservedMaskCorrection`.
    var unparsedMaskCorrections: [PreservedMaskCorrection]?

    /// Creator Contact Info and Location Created/Shown. nil means "do not touch"; a present
    /// wrapper with empty values means clear the corresponding XMP properties.
    var editorial: EditorialStructuredWriteData?

    /// Replace the file's ENTIRE Camera Raw (crs) namespace block with this
    /// write's content — Adobe-faithful semantics: ACR drops settings it isn't
    /// carrying (Texture, vignette, HSL, …) when it saves, so stale baked
    /// globals from a previous export can't be re-applied on top of our render.
    /// Opt in ONLY when the write carries the complete live develop state
    /// (the edit-view save / develop reset); partial crs writes like the
    /// develop-settings paste must leave fields they don't carry untouched.
    var replaceCameraRawBlock: Bool = false

    var isEmpty: Bool {
        (toneCurve == nil || (toneCurve?.isEmpty ?? true))
            && (masks == nil || (masks?.isEmpty ?? true))
            && (watermarkLayers == nil || (watermarkLayers?.isEmpty ?? true))
            && (hslAdjustments == nil || (hslAdjustments?.isEmpty ?? true))
            && (anonymizer == nil || (anonymizer?.isEmpty ?? true))
            && (unparsedMaskCorrections?.isEmpty ?? true)
            && editorial == nil
    }

    nonisolated static let empty = StructuredWriteData()
}

/// Abstraction over metadata write backends.
/// Both implementations must handle XMP/IPTC mirroring and file creation date preservation internally.
protocol MetadataWriteEngine: AnyObject, Sendable {
    /// Write key-value metadata fields to one or more files.
    func writeFields(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws

    /// Write fields to files created by the render pipeline.
    ///
    /// Rendered TIFFs can legitimately retain a Sony camera Make tag. SwiftExif's
    /// conservative RAW guard then classifies the TIFF bytes as ARW even though the
    /// pipeline created a normal raster TIFF. Implementations may use this explicit
    /// trust boundary to permit that otherwise-refused metadata rewrite.
    func writeFieldsToRenderedFiles(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws

    /// Add and/or remove individual list values (keywords, persons) with deduplication.
    func addRemoveListValues(
        add: [MetadataFieldKey: [String]],
        remove: [MetadataFieldKey: [String]],
        to urls: [URL]
    ) async throws

    /// Write star rating.
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws

    /// Write color label.
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws

    /// Write EXIF orientation.
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws

    /// Strip all IPTC and XMP metadata.
    func stripIPTCAndXMP(from urls: [URL]) async throws

    /// Copy all metadata from source to rendered destination with standard exclusions.
    ///
    /// `bakedCameraRaw` are the develop settings that were applied into the rendered
    /// pixels. When provided, they're re-emitted into the destination's crs block marked
    /// `AlreadyApplied="True"` — documenting how the image was edited without letting any
    /// reader re-apply them on top of the baked render. When nil (no edits), the crs block
    /// is left empty.
    func copyMetadataToRenderedFile(
        from source: URL,
        to destination: URL,
        bakedCameraRaw: CameraRawSettings?
    ) async throws
}

extension MetadataWriteEngine {
    func copyMetadataToRenderedFile(from source: URL, to destination: URL) async throws {
        try await copyMetadataToRenderedFile(from: source, to: destination, bakedCameraRaw: nil)
    }
}

extension MetadataWriteEngine {
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL]) async throws {
        try await writeFields(fields, to: urls, structuredData: .empty)
    }

    func writeFieldsToRenderedFiles(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL]
    ) async throws {
        try await writeFieldsToRenderedFiles(fields, to: urls, structuredData: .empty)
    }
}

// MARK: - Shared Helpers

/// Capture file creation dates before a write operation so they can be restored after.
/// Direct file writes may reset the creation date.
nonisolated func captureCreationDates(for urls: [URL]) -> [URL: Date] {
    var result: [URL: Date] = [:]
    for url in urls {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let creationDate = attrs[.creationDate] as? Date else {
            continue
        }
        result[url] = creationDate
    }
    return result
}

/// Restore file creation dates after a write operation.
nonisolated func restoreCreationDates(_ creationDates: [URL: Date]) {
    for (url, creationDate) in creationDates {
        try? FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
    }
}

/// Format a number in ACR's style: integers for whole numbers, minimal trailing decimals otherwise.
nonisolated func acrNum(_ value: Double) -> String {
    if value == value.rounded(.toNearestOrEven) && abs(value) < 1_000_000 {
        return String(Int(value))
    }
    var s = String(format: "%.6f", value)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
