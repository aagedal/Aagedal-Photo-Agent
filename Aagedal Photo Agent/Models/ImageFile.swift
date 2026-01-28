import Foundation
import UniformTypeIdentifiers

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
    var hasPendingMetadataChanges: Bool
    var metadata: IPTCMetadata?

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
        self.hasPendingMetadataChanges = false
        self.metadata = nil
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.url == rhs.url
            && lhs.starRating == rhs.starRating
            && lhs.colorLabel == rhs.colorLabel
            && lhs.hasC2PA == rhs.hasC2PA
            && lhs.hasPendingMetadataChanges == rhs.hasPendingMetadataChanges
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
