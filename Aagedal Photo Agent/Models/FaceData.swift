import Foundation
import CoreGraphics

struct DetectedFace: Codable, Identifiable {
    let id: UUID
    let imageURL: URL
    let faceRect: CGRect
    let featurePrintData: Data
    var groupID: UUID?
    let detectedAt: Date

    // Quality metrics (optional for backwards compatibility)
    let qualityScore: Float?
    let confidence: Float?
    let faceSize: Int?
    let blurScore: Float?

    init(
        id: UUID,
        imageURL: URL,
        faceRect: CGRect,
        featurePrintData: Data,
        groupID: UUID? = nil,
        detectedAt: Date,
        qualityScore: Float? = nil,
        confidence: Float? = nil,
        faceSize: Int? = nil,
        blurScore: Float? = nil
    ) {
        self.id = id
        self.imageURL = imageURL
        self.faceRect = faceRect
        self.featurePrintData = featurePrintData
        self.groupID = groupID
        self.detectedAt = detectedAt
        self.qualityScore = qualityScore
        self.confidence = confidence
        self.faceSize = faceSize
        self.blurScore = blurScore
    }
}

struct FaceGroup: Codable, Identifiable {
    let id: UUID
    var name: String?
    var representativeFaceID: UUID
    var faceIDs: [UUID]
}

/// Tracks a file's identity for incremental scanning
struct FileSignature: Codable, Equatable {
    let modificationDate: Date
    let fileSize: Int64
}

/// Represents a suggestion to merge two similar face groups
struct MergeSuggestion: Identifiable {
    let id = UUID()
    let group1ID: UUID
    let group2ID: UUID
    let similarity: Float  // 0.0-1.0, higher = more similar
}

struct FolderFaceData: Codable {
    var folderURL: URL
    var faces: [DetectedFace]
    var groups: [FaceGroup]
    var lastScanDate: Date
    var scanComplete: Bool

    /// File signatures for incremental scanning (URL string -> signature)
    var scannedFiles: [String: FileSignature]

    init(
        folderURL: URL,
        faces: [DetectedFace],
        groups: [FaceGroup],
        lastScanDate: Date,
        scanComplete: Bool,
        scannedFiles: [String: FileSignature] = [:]
    ) {
        self.folderURL = folderURL
        self.faces = faces
        self.groups = groups
        self.lastScanDate = lastScanDate
        self.scanComplete = scanComplete
        self.scannedFiles = scannedFiles
    }
}
