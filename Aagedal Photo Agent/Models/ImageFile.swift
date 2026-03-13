import Foundation
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
    var metadata: IPTCMetadata?
    var personShown: [String]
    var keywords: [String]

    var isImageFile: Bool { SupportedImageFormats.isSupported(url: url) }

    init(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent
        self.filenameLowercased = url.lastPathComponent.lowercased()
        self.fileType = UTType(filenameExtension: url.pathExtension)

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date.distantPast
        self.dateAdded = values?.addedToDirectoryDate ?? Date.distantPast

        self.starRating = .none
        self.colorLabel = .none
        self.hasC2PA = false
        self.hasDevelopEdits = false
        self.hasCropEdits = false
        self.cropRegion = nil
        self.cameraRawSettings = nil
        self.exifOrientation = 1
        self.hasPendingMetadataChanges = false
        self.metadata = nil
        self.personShown = []
        self.keywords = []
    }

    init(url: URL, copyingFrom source: ImageFile) {
        self.url = url
        self.filename = url.lastPathComponent
        self.filenameLowercased = url.lastPathComponent.lowercased()
        self.fileType = UTType(filenameExtension: url.pathExtension)

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date.distantPast
        self.dateAdded = values?.addedToDirectoryDate ?? Date.distantPast

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
        self.metadata = source.metadata
        self.personShown = source.personShown
        self.keywords = source.keywords
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
            && lhs.cameraRawSettings == rhs.cameraRawSettings
            && lhs.exifOrientation == rhs.exifOrientation
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
