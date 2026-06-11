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
        #expect(object["activeLens"] == nil)
        #expect(object["lensStates"] == nil)
        let faceObjects = try #require(object["faces"] as? [[String: Any]])
        #expect(faceObjects.first?["jerseyNumber"] == nil)

        let decoded = try JSONDecoder().decode(FolderFaceData.self, from: encoded)
        #expect(decoded.faces.count == 1)
        #expect(decoded.numberDetections == nil)
        #expect(decoded.faces[0].jerseyNumber == nil)
        #expect(decoded.faces[0].teamSide == nil)
        #expect(decoded.currentLens == .face)

        // Files written before the lens rework carried a top-level `recognitionMode` key;
        // the current model (which dropped that field) must still decode them.
        var legacyObject = object
        legacyObject["recognitionMode"] = "vision"
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(FolderFaceData.self, from: legacyData)
        #expect(legacyDecoded.faces.count == 1)
    }

    // MARK: - Jersey merge plan (Sports lens assist)

    private func numberedFace(number: Int?, color: ColorRGB?) -> DetectedFace {
        DetectedFace(
            id: UUID(),
            imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            faceRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.2),
            featurePrintData: Data([1]),
            detectedAt: Date(),
            jerseyNumber: number,
            jerseyColorRGB: color
        )
    }

    private func group(of faces: [DetectedFace], name: String? = nil) -> FaceGroup {
        FaceGroup(id: UUID(), name: name, representativeFaceID: faces[0].id, faceIDs: faces.map(\.id))
    }

    @MainActor
    @Test("Same number with agreeing colours merges toward the named group; conflicts never merge")
    func jerseyMergePlanRules() {
        let red = ColorRGB(r: 0.8, g: 0.1, b: 0.1)
        let alsoRed = ColorRGB(r: 0.75, g: 0.15, b: 0.12)
        let white = ColorRGB(r: 0.95, g: 0.95, b: 0.95)

        // Two groups of the same red #9 player — one named. Should merge into the named one.
        let named9 = [numberedFace(number: 9, color: red), numberedFace(number: nil, color: nil)]
        let unnamed9 = [numberedFace(number: 9, color: alsoRed)]
        // A white #9 on the other team must NOT merge with the red #9.
        let otherTeam9 = [numberedFace(number: 9, color: white)]
        // A group with conflicting member numbers never participates.
        let mixed = [numberedFace(number: 4, color: red), numberedFace(number: 7, color: red)]
        // Same number but no sampled colour on either side: too risky, no merge.
        let colorless9a = [numberedFace(number: 19, color: nil)]
        let colorless9b = [numberedFace(number: 19, color: nil)]

        let groups = [
            group(of: named9, name: "Erling Braut Haaland"),
            group(of: unnamed9),
            group(of: otherTeam9),
            group(of: mixed),
            group(of: colorless9a),
            group(of: colorless9b)
        ]
        let faces = (named9 + unnamed9 + otherTeam9 + mixed + colorless9a + colorless9b)

        let plan = FaceRecognitionViewModel.jerseyMergePlan(groups: groups, faces: faces)

        #expect(plan.count == 1)
        #expect(plan.first?.source == groups[1].id)
        #expect(plan.first?.target == groups[0].id)
    }

    @MainActor
    @Test("Differently named groups sharing a number never merge")
    func jerseyMergePlanRespectsNames() {
        let red = ColorRGB(r: 0.8, g: 0.1, b: 0.1)
        let faces1 = [numberedFace(number: 7, color: red)]
        let faces2 = [numberedFace(number: 7, color: red)]
        let groups = [
            group(of: faces1, name: "Player A"),
            group(of: faces2, name: "Player B")
        ]
        let plan = FaceRecognitionViewModel.jerseyMergePlan(groups: groups, faces: faces1 + faces2)
        #expect(plan.isEmpty)
    }

    // MARK: - Jersey OCR parsing & dedup

    @Test("Jersey OCR parsing tolerates one junk character, rejects boards and dates")
    func jerseyNumberParsing() {
        #expect(JerseyDetectionService.parseJerseyNumber("14") == 14)
        #expect(JerseyDetectionService.parseJerseyNumber(" 7 ") == 7)
        // Stylised kit fonts often read with one junk character: "c17", "d7".
        #expect(JerseyDetectionService.parseJerseyNumber("c17") == 17)
        #expect(JerseyDetectionService.parseJerseyNumber("d7") == 7)
        #expect(JerseyDetectionService.parseJerseyNumber("#9") == 9)
        // Sponsor boards, dates, scoreboards must not become numbers.
        #expect(JerseyDetectionService.parseJerseyNumber("TO26") == nil)
        #expect(JerseyDetectionService.parseJerseyNumber("07.06.2026") == nil)
        #expect(JerseyDetectionService.parseJerseyNumber("026") == nil)
        #expect(JerseyDetectionService.parseJerseyNumber("100") == nil)
        #expect(JerseyDetectionService.parseJerseyNumber("ROAD") == nil)
        #expect(JerseyDetectionService.parseJerseyNumber("") == nil)
    }

    @Test("Coinciding reads collapse to the two-digit number; separate numbers survive")
    func dedupPartialReads() {
        // "4" read inside the same printed "14" (overlapping tile passes).
        let full = JerseyDetectionService.RawNumber(
            value: 14, confidence: 1.0,
            box: CGRect(x: 0.30, y: 0.36, width: 0.025, height: 0.035), color: nil
        )
        let partial = JerseyDetectionService.RawNumber(
            value: 4, confidence: 1.0,
            box: CGRect(x: 0.312, y: 0.36, width: 0.012, height: 0.035), color: nil
        )
        // A genuine #7 on a different player elsewhere in the frame.
        let other = JerseyDetectionService.RawNumber(
            value: 7, confidence: 1.0,
            box: CGRect(x: 0.53, y: 0.54, width: 0.02, height: 0.03), color: nil
        )
        // The same #7 seen again by an overlapping tile, slightly shifted.
        let duplicate = JerseyDetectionService.RawNumber(
            value: 7, confidence: 0.5,
            box: CGRect(x: 0.532, y: 0.541, width: 0.02, height: 0.03), color: nil
        )

        let merged = JerseyDetectionService.deduplicate([partial, duplicate, full, other])
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.value)) == Set([14, 7]))
        // The higher-confidence read of the #7 wins.
        #expect(merged.first { $0.value == 7 }?.confidence == 1.0)
    }

    @Test("Lens state and active lens round-trip; Face lens derives from canonical groups")
    func lensStateRoundTrip() throws {
        let face = DetectedFace(
            id: UUID(),
            imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            faceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            featurePrintData: Data([1, 2, 3]),
            detectedAt: Date()
        )
        let faceGroup = FaceGroup(id: UUID(), name: nil, representativeFaceID: face.id, faceIDs: [face.id])
        var folder = FolderFaceData(
            folderURL: URL(fileURLWithPath: "/tmp"),
            faces: [face],
            groups: [faceGroup],
            lastScanDate: Date(),
            scanComplete: true
        )

        #expect(folder.currentLens == .face)
        #expect(folder.lensState(for: .face).status == .complete)
        #expect(folder.groups(for: .face).count == 1)
        #expect(folder.lensState(for: .expression).status == .notStarted)
        #expect(folder.groups(for: .expression).isEmpty)

        let expressionGroup = FaceGroup(id: UUID(), name: nil, representativeFaceID: face.id, faceIDs: [face.id])
        folder.setLensState(
            FaceLensState(groups: [expressionGroup], status: .complete, embeddingVersion: 1, lastUpdated: Date()),
            for: .expression
        )
        folder.activeLens = .expression

        let decoded = try JSONDecoder().decode(FolderFaceData.self, from: try JSONEncoder().encode(folder))
        #expect(decoded.currentLens == .expression)
        #expect(decoded.lensState(for: .expression).status == .complete)
        #expect(decoded.groups(for: .expression).map(\.id) == [expressionGroup.id])
        #expect(decoded.groups(for: .face).map(\.id) == [faceGroup.id])
        #expect(decoded.lensState(for: .redCarpet).status == .notStarted)
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
