import Testing
import Foundation
import CoreGraphics
@testable import Aagedal_Photo_Agent

@Suite("Sports tagging models & detection")
struct SportsTaggingTests {

    // MARK: - Codable back-compat

    /// Legacy face_data.json (written before sports tagging) has no
    /// `numberDetections` and faces have no jersey fields. The extended models
    /// must still decode it, leaving the new fields nil.
    @Test("Legacy face data decodes without sports fields")
    func legacyFaceDataDecodes() throws {
        let face = DetectedFace(
            id: UUID(),
            imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            faceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            featurePrintData: Data([1, 2, 3]),
            detectedAt: Date()
        )
        let folder = FolderFaceData(
            folderURL: URL(fileURLWithPath: "/tmp"),
            faces: [face],
            groups: [],
            lastScanDate: Date(),
            scanComplete: true
        )

        // JSONEncoder omits nil optionals, so the encoded form matches a legacy file.
        let encoded = try JSONEncoder().encode(folder)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["numberDetections"] == nil)
        let faceObjects = try #require(object["faces"] as? [[String: Any]])
        #expect(faceObjects.first?["jerseyNumber"] == nil)

        let decoded = try JSONDecoder().decode(FolderFaceData.self, from: encoded)
        #expect(decoded.faces.count == 1)
        #expect(decoded.numberDetections == nil)
        #expect(decoded.faces[0].jerseyNumber == nil)
        #expect(decoded.faces[0].teamSide == nil)
    }

    @Test("Enriched face and standalone number round-trip")
    func enrichedRoundTrip() throws {
        var face = DetectedFace(
            id: UUID(),
            imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            faceRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
            featurePrintData: Data([9]),
            detectedAt: Date()
        )
        face.jerseyNumber = 9
        face.numberConfidence = 0.81
        face.jerseyColorRGB = ColorRGB(r: 0.8, g: 0.1, b: 0.1)
        face.teamSide = .away

        let number = NumberDetection(
            imageURL: URL(fileURLWithPath: "/tmp/b.jpg"),
            number: 7,
            numberConfidence: 0.6,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.15),
            jerseyColorRGB: ColorRGB(r: 0.95, g: 0.95, b: 0.95),
            teamSide: .home,
            resolvedPlayerName: "Hansen"
        )
        let folder = FolderFaceData(
            folderURL: URL(fileURLWithPath: "/tmp"),
            faces: [face],
            groups: [],
            lastScanDate: Date(),
            scanComplete: true,
            numberDetections: [number]
        )

        let data = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(FolderFaceData.self, from: data)
        #expect(decoded.faces[0].jerseyNumber == 9)
        #expect(decoded.faces[0].teamSide == .away)
        #expect(decoded.numberDetections?.first?.number == 7)
        #expect(decoded.numberDetections?.first?.resolvedPlayerName == "Hansen")
    }

    @Test("Team round-trips with roster and known-person link")
    func teamRoundTrip() throws {
        let team = Team(
            name: "Brann",
            primaryColor: TeamKitColor(r: 0.8, g: 0.1, b: 0.1),
            goalkeeperColor: TeamKitColor(r: 0.1, g: 0.8, b: 0.2),
            roster: [RosterPlayer(number: 9, playerName: "Riise", knownPersonID: UUID())]
        )
        let data = try JSONEncoder().encode(team)
        let decoded = try JSONDecoder().decode(Team.self, from: data)
        #expect(decoded.name == "Brann")
        #expect(decoded.roster.count == 1)
        #expect(decoded.roster[0].knownPersonID != nil)
        #expect(decoded.goalkeeperColor != nil)
        #expect(decoded.player(forNumber: 9)?.playerName == "Riise")
    }

    // MARK: - Colour sampling

    @Test("sampleDominantColor recovers a solid jersey colour")
    func sampleSolidColour() throws {
        let image = Self.solidImage(r: 0.82, g: 0.10, b: 0.12)
        let service = JerseyDetectionService()
        let color = try #require(service.sampleDominantColor(in: image, near: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        #expect(color.r > 0.6)
        #expect(color.g < 0.35)
        #expect(color.b < 0.35)
    }

    private static func solidImage(r: Double, g: Double, b: Double, size: Int = 64) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }
}
