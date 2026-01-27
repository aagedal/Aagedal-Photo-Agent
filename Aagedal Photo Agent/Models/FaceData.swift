import Foundation
import CoreGraphics

struct DetectedFace: Codable, Identifiable {
    let id: UUID
    let imageURL: URL
    let faceRect: CGRect
    let featurePrintData: Data
    var groupID: UUID?
    let detectedAt: Date
}

struct FaceGroup: Codable, Identifiable {
    let id: UUID
    var name: String?
    var representativeFaceID: UUID
    var faceIDs: [UUID]
}

struct FolderFaceData: Codable {
    var folderURL: URL
    var faces: [DetectedFace]
    var groups: [FaceGroup]
    var lastScanDate: Date
    var scanComplete: Bool
}
