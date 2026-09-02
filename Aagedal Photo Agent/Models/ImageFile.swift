import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ThumbnailCropRegion: Sendable, Equatable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double
    let angle: Double

    var clamped: ThumbnailCropRegion {
        ThumbnailCropRegion(
            top: min(max(top, 0), 1),
            left: min(max(left, 0), 1),
            bottom: min(max(bottom, 0), 1),
            right: min(max(right, 0), 1),
            angle: min(max(angle, -45), 45)
        )
    }
}

struct ImageFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let filename: String
    let filenameLowercased: String
    let fileType: UTType?
    let fileSize: Int64
    let dateModified: Date
    let dateAdded: Date
    let isICloudDownloadPending: Bool
    /// Modification date of the adjacent `.xmp` sidecar (nil when none). Tracked so the
    /// folder refresh can notice an external sidecar edit (e.g. ACR rotating a RAW) even
    /// though the image file itself is untouched. Not part of `==` — it drives the refresh
    /// diff, not cell redraw.
    let sidecarModified: Date?

    var starRating: StarRating
    var colorLabel: ColorLabel
    var hasC2PA: Bool
    var hasDevelopEdits: Bool
    var hasCropEdits: Bool
    var cropRegion: ThumbnailCropRegion?
    var cameraRawSettings: CameraRawSettings?
    var exifOrientation: Int
    var hasPendingMetadataChanges: Bool
    var pendingFieldNames: [String] = []
    var metadata: IPTCMetadata? {
        didSet { metadataSearchLowercased = Self.searchableText(from: metadata) }
    }
    /// Pre-lowercased concatenation of the searchable IPTC fields (title, description, creator,
    /// city, country, event). Built once when `metadata` is assigned so the search filter can use a
    /// single plain `.contains` instead of six `localizedCaseInsensitiveContains` calls per image
    /// per keystroke — the latter folds Unicode and allocates, which janked the MainActor rebuild on
    /// large folders. Matches the `keywordsLowercased` / `personShownLowercased` pattern.
    var metadataSearchLowercased: String = ""
    var isNativeHDR: Bool
    var personShown: [String] {
        didSet { personShownLowercased = personShown.map { $0.lowercased() } }
    }
    var personShownLowercased: [String]
    var keywords: [String] {
        didSet { keywordsLowercased = keywords.map { $0.lowercased() } }
    }
    var keywordsLowercased: [String]

    var isImageFile: Bool { SupportedImageFormats.isSupported(url: url) }

    /// Modification date of the adjacent `<name>.xmp` sidecar, or nil if there is none.
    /// Metadata-only stat — does not download/read the file, so it's cheap and safe on iCloud.
    nonisolated static func sidecarModificationDate(for url: URL) -> Date? {
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        return try? sidecar.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    nonisolated init(url: URL, isICloudDownloadPending: Bool = false) {
        self.url = url
        self.filename = url.lastPathComponent
        self.filenameLowercased = url.lastPathComponent.lowercased()
        self.fileType = UTType(filenameExtension: url.pathExtension)

        let values = isICloudDownloadPending
            ? nil
            : try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date.distantPast
        self.dateAdded = values?.addedToDirectoryDate ?? Date.distantPast
        self.isICloudDownloadPending = isICloudDownloadPending
        self.sidecarModified = isICloudDownloadPending ? nil : Self.sidecarModificationDate(for: url)

        self.starRating = .none
        self.colorLabel = .none
        self.hasC2PA = false
        self.hasDevelopEdits = false
        self.hasCropEdits = false
        self.cropRegion = nil
        self.cameraRawSettings = nil
        self.exifOrientation = 1
        self.hasPendingMetadataChanges = false
        self.isNativeHDR = false
        self.metadata = nil
        self.personShown = []
        self.personShownLowercased = []
        self.keywords = []
        self.keywordsLowercased = []
    }

    nonisolated init(url: URL, copyingFrom source: ImageFile) {
        self.url = url
        self.filename = url.lastPathComponent
        self.filenameLowercased = url.lastPathComponent.lowercased()
        self.fileType = UTType(filenameExtension: url.pathExtension)

        let values = source.isICloudDownloadPending
            ? nil
            : try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date.distantPast
        self.dateAdded = values?.addedToDirectoryDate ?? Date.distantPast
        self.isICloudDownloadPending = source.isICloudDownloadPending
        self.sidecarModified = source.isICloudDownloadPending ? nil : Self.sidecarModificationDate(for: url)

        self.starRating = source.starRating
        self.colorLabel = source.colorLabel
        self.hasC2PA = source.hasC2PA
        self.hasDevelopEdits = source.hasDevelopEdits
        self.hasCropEdits = source.hasCropEdits
        self.cropRegion = source.cropRegion
        self.cameraRawSettings = source.cameraRawSettings
        self.exifOrientation = source.exifOrientation
        self.hasPendingMetadataChanges = source.hasPendingMetadataChanges
        self.pendingFieldNames = source.pendingFieldNames
        self.isNativeHDR = source.isNativeHDR
        self.metadata = source.metadata
        self.metadataSearchLowercased = source.metadataSearchLowercased
        self.personShown = source.personShown
        self.personShownLowercased = source.personShownLowercased
        self.keywords = source.keywords
        self.keywordsLowercased = source.keywordsLowercased
    }

    /// Projects an already-known image through a path-only relocation such as a successful
    /// rename. Unlike `init(url:copyingFrom:)`, this initializer performs no filesystem reads.
    /// A rename preserves the file and sidecar facts captured by the serialized executor, so
    /// re-statting the destination from a MainActor presentation owner would only add a slow-
    /// volume blocking opportunity and could produce a partially refreshed model snapshot.
    nonisolated init(url: URL, relocating source: ImageFile) {
        self.url = url
        self.filename = url.lastPathComponent
        self.filenameLowercased = url.lastPathComponent.lowercased()
        self.fileType = UTType(filenameExtension: url.pathExtension)

        self.fileSize = source.fileSize
        self.dateModified = source.dateModified
        self.dateAdded = source.dateAdded
        self.isICloudDownloadPending = source.isICloudDownloadPending
        self.sidecarModified = source.sidecarModified

        self.starRating = source.starRating
        self.colorLabel = source.colorLabel
        self.hasC2PA = source.hasC2PA
        self.hasDevelopEdits = source.hasDevelopEdits
        self.hasCropEdits = source.hasCropEdits
        self.cropRegion = source.cropRegion
        self.cameraRawSettings = source.cameraRawSettings
        self.exifOrientation = source.exifOrientation
        self.hasPendingMetadataChanges = source.hasPendingMetadataChanges
        self.pendingFieldNames = source.pendingFieldNames
        self.isNativeHDR = source.isNativeHDR
        self.metadata = source.metadata
        self.metadataSearchLowercased = source.metadataSearchLowercased
        self.personShown = source.personShown
        self.personShownLowercased = source.personShownLowercased
        self.keywords = source.keywords
        self.keywordsLowercased = source.keywordsLowercased
    }

    /// Lowercased, newline-joined blob of the IPTC fields the browser search filters on. Built once
    /// per metadata assignment so the per-keystroke filter is a single substring scan. `nil`/empty
    /// fields are dropped; returns "" when there's nothing searchable.
    static func searchableText(from metadata: IPTCMetadata?) -> String {
        guard let metadata else { return "" }
        let fields = [metadata.title, metadata.description, metadata.creator,
                      metadata.creatorJobTitle, metadata.descriptionWriter,
                      metadata.rightsUsageTerms, metadata.webStatementOfRights, metadata.digitalImageGUID,
                      metadata.imageSupplierImageID,
                      metadata.city, metadata.country, metadata.countryCode, metadata.event,
                      metadata.urgency.map(String.init)]
        return (fields.compactMap { $0 }
            + metadata.organisationsShownNames
            + metadata.organisationsShownCodes
            + metadata.sceneCodes
            + metadata.subjectCodes
            + metadata.mediaTopics.flatMap { [$0.termIdentifier, $0.name].compactMap { $0 } }
            + metadata.genres.flatMap { [$0.termIdentifier, $0.name].compactMap { $0 } }
            + metadata.imageSuppliers.flatMap { [$0.identifier, $0.name].compactMap { $0 } })
            .joined(separator: "\n")
            .lowercased()
    }

    /// Compute next EXIF orientation after 90° CW rotation.
    static func orientationAfterClockwiseRotation(_ current: Int) -> Int {
        switch current {
        case 1: return 6
        case 6: return 3
        case 3: return 8
        case 8: return 1
        case 2: return 7
        case 7: return 4
        case 4: return 5
        case 5: return 2
        default: return 6
        }
    }

    /// Compute next EXIF orientation after 90° CCW rotation.
    static func orientationAfterCounterclockwiseRotation(_ current: Int) -> Int {
        switch current {
        case 1: return 8
        case 8: return 3
        case 3: return 6
        case 6: return 1
        case 2: return 5
        case 5: return 4
        case 4: return 7
        case 7: return 2
        default: return 8
        }
    }

    /// Number of 90° CW rotations needed to correct from `fileOrientation`
    /// (baked into pixels by the OS) to `targetOrientation` (in-memory).
    /// Returns 0 when no correction is needed.
    nonisolated static func rotationDelta(from fileOrientation: Int, to targetOrientation: Int) -> Int {
        guard fileOrientation != targetOrientation else { return 0 }
        let cwSteps: [Int: Int] = [1: 0, 6: 1, 3: 2, 8: 3]
        let fromStep = cwSteps[fileOrientation] ?? 0
        let toStep = cwSteps[targetOrientation] ?? 0
        return (toStep - fromStep + 4) % 4
    }

    /// CGImagePropertyOrientation to apply as corrective rotation from
    /// `fileOrientation` to `targetOrientation`.  Returns `.up` (no-op) when equal.
    nonisolated static func orientationCorrection(from fileOrientation: Int, to targetOrientation: Int) -> CGImagePropertyOrientation {
        switch rotationDelta(from: fileOrientation, to: targetOrientation) {
        case 1: return .right   // 90° CW
        case 2: return .down    // 180°
        case 3: return .left    // 270° CW
        default: return .up
        }
    }

    // MARK: - Hashable / Equatable
    //
    // hash(into:) uses only `url` while == checks all mutable display properties.
    // This is intentional and satisfies the Hashable contract (equal objects must have
    // equal hashes, but not vice versa). The coarse hash is fine because ImageFile is
    // never used as a Set element or Dictionary key — URL is used instead. The detailed
    // == drives diffing (e.g. NSDiffableDataSource snapshot) so that cells redraw when ratings,
    // labels, or other visual state changes on the same file.

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.url == rhs.url
            && lhs.starRating == rhs.starRating
            && lhs.colorLabel == rhs.colorLabel
            && lhs.hasC2PA == rhs.hasC2PA
            && lhs.hasDevelopEdits == rhs.hasDevelopEdits
            && lhs.hasCropEdits == rhs.hasCropEdits
            && lhs.isICloudDownloadPending == rhs.isICloudDownloadPending
            && lhs.cameraRawSettings == rhs.cameraRawSettings
            && lhs.exifOrientation == rhs.exifOrientation
            && lhs.isNativeHDR == rhs.isNativeHDR
            && lhs.hasPendingMetadataChanges == rhs.hasPendingMetadataChanges
            && lhs.pendingFieldNames == rhs.pendingFieldNames
            && lhs.cropRegion == rhs.cropRegion
            && lhs.personShown == rhs.personShown
            && lhs.keywords == rhs.keywords
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
