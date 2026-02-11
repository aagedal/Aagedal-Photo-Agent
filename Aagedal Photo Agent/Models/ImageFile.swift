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

    init(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent
        self.filenameLowercased = url.lastPathComponent.lowercased()
        self.fileType = UTType(filenameExtension: url.pathExtension)

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.dateModified = values?.contentModificationDate ?? Date.distantPast

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

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
