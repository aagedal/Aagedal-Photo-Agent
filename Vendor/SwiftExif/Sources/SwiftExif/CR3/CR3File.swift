import Foundation

/// Parsed Canon CR3 file structure.
/// CR3 is ISOBMFF-based with Canon-specific uuid boxes for metadata.
public struct CR3File: Sendable, Equatable {
    /// All top-level boxes (ftyp, moov, uuid, mdat, etc.).
    public var boxes: [ISOBMFFBox]

    /// JPEG thumbnail data from THMB box (160x120 or 320x214).
    public var thumbnailData: Data?

    /// JPEG preview data from PRVW box (1620x1080).
    public var previewData: Data?

    /// Original file data (needed for round-trip writing since mdat is skipped during parse).
    public var originalData: Data?

    public init(boxes: [ISOBMFFBox] = [], thumbnailData: Data? = nil, previewData: Data? = nil, originalData: Data? = nil) {
        self.boxes = boxes
        self.thumbnailData = thumbnailData
        self.previewData = previewData
        self.originalData = originalData
    }
}
