import Foundation
import UniformTypeIdentifiers

struct ThumbnailCropRegion: Sendable, Equatable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double

    var clamped: ThumbnailCropRegion {
        ThumbnailCropRegion(
            top: min(max(top, 0), 1),
            left: min(max(left, 0), 1),
            bottom: min(max(bottom, 0), 1),
            right: min(max(right, 0), 1)
        )
    }
}

struct ImageFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let filename: String
    let fileType: UTType?
    let fileSize: Int64
    let dateModified: Date

    var starRating: StarRating
    var colorLabel: ColorLabel
    var hasC2PA: Bool
    var hasDevelopEdits: Bool
    var hasCropEdits: Bool
    var cropRegion: ThumbnailCropRegion?
    var hasPendingMetadataChanges: Bool
    var pendingFieldNames: [String] = []
    var metadata: IPTCMetadata?
    var personShown: [String]

    init(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent
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
        self.hasPendingMetadataChanges = false
        self.metadata = nil
        self.personShown = []
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
