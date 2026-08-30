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

    // MARK: - Number claims: confirm-before-write + auto-confirm

    /// A two-team match: home #9 Haaland (red), away #9 Smith (white).
    private func twoTeamMatch() -> MatchRoster {
        let home = Team(name: "City", primaryColor: TeamKitColor(r: 0.5, g: 0.7, b: 0.95),
                        roster: [RosterPlayer(number: 9, playerName: "Erling Haaland")])
        let away = Team(name: "United", primaryColor: TeamKitColor(r: 0.95, g: 0.95, b: 0.95),
                        roster: [RosterPlayer(number: 9, playerName: "Kelly Smith")])
        return MatchRoster(folderURL: URL(fileURLWithPath: "/tmp"),
                           homeTeamID: home.id, awayTeamID: away.id,
                           homeTeamSnapshot: home, awayTeamSnapshot: away)
    }

    private func standaloneNumber(_ n: Int, url: String, side: TeamSide?, state: NumberClaimState? = nil) -> NumberDetection {
        NumberDetection(imageURL: URL(fileURLWithPath: url), number: n, numberConfidence: 0.9,
                        boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.08),
                        teamSide: side, claimState: state)
    }

    @MainActor
    @Test("A number with no corroborating face stays suggested — never auto-written")
    func numberOnlyStaysSuggested() {
        let match = twoTeamMatch()
        let det = standaloneNumber(9, url: "/tmp/a.jpg", side: .home)
        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [], groups: [], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        let claim = try! #require(result.numbers.first)
        #expect(claim.resolvedPlayerName == "Erling Haaland")
        #expect(claim.effectiveClaimState == .suggested)
    }

    @MainActor
    @Test("A number auto-confirms when an independently named face in the same photo agrees")
    func autoConfirmOnAgreement() {
        let match = twoTeamMatch()
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        // A face already identified (by face recognition / user) as Haaland in the same image.
        let groupID = UUID()
        var face = numberedFace(number: nil, color: nil)
        face = DetectedFace(id: face.id, imageURL: url, faceRect: face.faceRect,
                            featurePrintData: Data([1]), groupID: groupID, detectedAt: Date())
        let group = FaceGroup(id: groupID, name: "Erling Haaland", representativeFaceID: face.id, faceIDs: [face.id])
        let det = NumberDetection(imageURL: url, number: 9, numberConfidence: 0.9,
                                  boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.08), teamSide: .home)

        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [face], groups: [group], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        #expect(result.numbers.first?.effectiveClaimState == .confirmed)
    }

    @MainActor
    @Test("A disagreeing face does not auto-confirm a number — both can be in frame")
    func disagreeingFaceDoesNotConfirm() {
        let match = twoTeamMatch()
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        // The recognised face is Haaland, but the loose number reads as the away #9 (Smith).
        let groupID = UUID()
        let face = DetectedFace(id: UUID(), imageURL: url, faceRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                                featurePrintData: Data([1]), groupID: groupID, detectedAt: Date())
        let group = FaceGroup(id: groupID, name: "Erling Haaland", representativeFaceID: face.id, faceIDs: [face.id])
        let det = standaloneNumber(9, url: "/tmp/a.jpg", side: .away)

        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [face], groups: [group], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        let claim = try! #require(result.numbers.first)
        #expect(claim.resolvedPlayerName == "Kelly Smith")
        #expect(claim.effectiveClaimState == .suggested)
    }

    @MainActor
    @Test("Rejected claims stay rejected across re-resolution")
    func rejectedIsSticky() {
        let match = twoTeamMatch()
        let det = standaloneNumber(9, url: "/tmp/a.jpg", side: .home, state: .rejected)
        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [], groups: [], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        #expect(result.numbers.first?.effectiveClaimState == .rejected)
    }

    @MainActor
    @Test("Confirmed claim drops back to suggested when its resolved name changes (side flip)")
    func confirmedResetsOnNameChange() {
        let match = twoTeamMatch()
        // Previously confirmed as the home #9 (Haaland) — now the side flips to away (Smith).
        var det = standaloneNumber(9, url: "/tmp/a.jpg", side: .away, state: .confirmed)
        det.resolvedPlayerName = "Erling Haaland"
        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [], groups: [], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        let claim = try! #require(result.numbers.first)
        #expect(claim.resolvedPlayerName == "Kelly Smith")
        #expect(claim.effectiveClaimState == .suggested)
    }

    @MainActor
    @Test("Face-attached numbers are promoted to first-class claims")
    func faceAttachedNumbersBecomeClaims() {
        let match = twoTeamMatch()
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        var face = DetectedFace(id: UUID(), imageURL: url, faceRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                                featurePrintData: Data([1]), detectedAt: Date())
        face.jerseyNumber = 9
        face.numberConfidence = 0.8
        face.jerseyColorRGB = ColorRGB(r: 0.5, g: 0.7, b: 0.95)
        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [face], groups: [], existing: [],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in .home }, displayName: { $0.playerName }
        )
        #expect(result.numbers.count == 1)
        #expect(result.numbers.first?.associatedFaceID == face.id)
        #expect(result.numbers.first?.resolvedPlayerName == "Erling Haaland")
    }

    // MARK: - Bib / event mode

    @MainActor
    @Test("Event mode resolves a bib directly from the single startlist, never ambiguous")
    func eventModeResolvesBib() {
        let startlist = Team(name: "Oslo Marathon", primaryColor: TeamKitColor(r: 0, g: 0, b: 0),
                             roster: [RosterPlayer(number: 21, playerName: "Jakob Ingebrigtsen")])
        let match = MatchRoster(folderURL: URL(fileURLWithPath: "/tmp"),
                                homeTeamID: startlist.id, homeTeamSnapshot: startlist,
                                mode: .event, clusterMappingConfirmed: true)
        #expect(match.isReady)
        #expect(match.effectiveMode == .event)

        // No side, no colour — bib mode resolves by number alone.
        let det = standaloneNumber(21, url: "/tmp/a.jpg", side: nil)
        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [], groups: [], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        let claim = try! #require(result.numbers.first)
        #expect(claim.resolvedPlayerName == "Jakob Ingebrigtsen")
        #expect(claim.effectiveClaimState == .suggested)
        #expect(result.ambiguous.isEmpty)
    }

    @MainActor
    @Test("One team configured (no away) still resolves its own numbers; isReady is true")
    func singleTeamResolves() {
        let home = Team(name: "Landslaget", primaryColor: TeamKitColor(r: 0.85, g: 0.84, b: 0.87),
                        roster: [RosterPlayer(number: 10, playerName: "Martin Ødegaard")])
        let match = MatchRoster(folderURL: URL(fileURLWithPath: "/tmp"),
                                homeTeamID: home.id, homeTeamSnapshot: home)
        #expect(match.isReady)
        #expect(!match.hasBothTeams)

        // No side, no colour (single-team path) — resolves the number on the only team.
        let det = standaloneNumber(10, url: "/tmp/a.jpg", side: nil)
        let result = FaceRecognitionViewModel.reconcileNumberClaims(
            faces: [], groups: [], existing: [det],
            resolver: PlayerResolver(), match: match,
            sideForColor: { _ in nil }, displayName: { $0.playerName }
        )
        let claim = try! #require(result.numbers.first)
        #expect(claim.resolvedPlayerName == "Martin Ødegaard")
        #expect(claim.effectiveClaimState == .suggested)   // still needs confirmation
    }

    @Test("Legacy match roster (no mode) decodes as a team match")
    func legacyMatchRosterDefaultsToTeam() throws {
        let team = Team(name: "A", primaryColor: TeamKitColor(r: 1, g: 0, b: 0))
        let roster = MatchRoster(folderURL: URL(fileURLWithPath: "/tmp"),
                                 homeTeamSnapshot: team, awayTeamSnapshot: team)
        let encoded = try JSONEncoder().encode(roster)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["mode"] == nil)
        let decoded = try JSONDecoder().decode(MatchRoster.self, from: encoded)
        #expect(decoded.effectiveMode == .team)
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
            secondaryColor: TeamKitColor(r: 0.95, g: 0.95, b: 0.95),
            goalkeeperColor: TeamKitColor(r: 0.1, g: 0.8, b: 0.2),
            sport: .football,
            roster: [RosterPlayer(number: 9, playerName: "Riise", knownPersonID: UUID())]
        )
        let data = try JSONEncoder().encode(team)
        let decoded = try JSONDecoder().decode(Team.self, from: data)
        #expect(decoded.name == "Brann")
        #expect(decoded.roster.count == 1)
        #expect(decoded.roster[0].knownPersonID != nil)
        #expect(decoded.secondaryColor != nil)
        #expect(decoded.goalkeeperColor != nil)
        #expect(decoded.effectiveSport == .football)
        #expect(decoded.kitColors.count == 3)
        #expect(decoded.player(forNumber: 9)?.playerName == "Riise")
    }

    @Test("Roster paste accepts sheet formats, ignores headers, and preserves known-person links")
    func rosterPasteImport() {
        let personID = UUID()
        let existing = [
            RosterPlayer(number: 9, playerName: "Old Name", knownPersonID: personID),
            RosterPlayer(number: 11, playerName: "Existing")
        ]
        let imported = RosterTextImporter.merge(
            "No. Player\n9, Ada Updated\n7\tGrace Hopper\n12 Alan Turing\ninvalid\n",
            into: existing
        )

        #expect(imported.map(\.number) == [7, 9, 11, 12])
        #expect(imported.first { $0.number == 9 }?.playerName == "Ada Updated")
        #expect(imported.first { $0.number == 9 }?.knownPersonID == personID)
    }

    @Test("Sports caption number uses only confirmed or identity-backed values")
    func sportsCaptionNumberTrustBoundary() {
        let imageURL = URL(fileURLWithPath: "/tmp/sports-caption.jpg")
        let personID = UUID()
        let face = DetectedFace(
            id: UUID(), imageURL: imageURL,
            faceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            featurePrintData: Data([1]), groupID: nil, detectedAt: Date()
        )
        var identifiedGroup = FaceGroup(
            id: UUID(), name: "Roster Alias", representativeFaceID: face.id, faceIDs: [face.id]
        )
        identifiedGroup.knownPersonID = personID
        var groupedFace = face
        groupedFace.groupID = identifiedGroup.id
        let confirmed = NumberDetection(
            imageURL: imageURL, number: 9, numberConfidence: 0.9,
            boundingBox: .zero, claimState: .confirmed
        )
        let suggestion = NumberDetection(
            imageURL: imageURL, number: 88, numberConfidence: 0.9,
            boundingBox: .zero, claimState: .suggested
        )
        let data = FolderFaceData(
            folderURL: imageURL.deletingLastPathComponent(), faces: [groupedFace],
            groups: [identifiedGroup], lastScanDate: Date(), scanComplete: true,
            numberDetections: [confirmed, suggestion]
        )
        let team = Team(
            name: "Team", primaryColor: TeamKitColor(r: 1, g: 0, b: 0),
            roster: [RosterPlayer(number: 7, playerName: "Different Display", knownPersonID: personID)]
        )
        let match = MatchRoster(
            folderURL: data.folderURL, homeTeamID: team.id, homeTeamSnapshot: team
        )

        #expect(SportsCaptionNumberResolver.value(for: imageURL, faceData: data, match: match) == "7, 9")

        identifiedGroup.excludedFromPersonShown = true
        var excludedData = data
        excludedData.groups = [identifiedGroup]
        #expect(SportsCaptionNumberResolver.value(for: imageURL, faceData: excludedData, match: match) == "9")
    }

    @Test("Known-person and referee exclusion group fields are migration-safe")
    func sportsGroupBridgeRoundTrip() throws {
        let id = UUID()
        var group = FaceGroup(id: UUID(), name: "Player", representativeFaceID: UUID(), faceIDs: [])
        group.knownPersonID = id
        group.excludedFromPersonShown = true
        let decoded = try JSONDecoder().decode(FaceGroup.self, from: JSONEncoder().encode(group))
        #expect(decoded.knownPersonID == id)
        #expect(decoded.isExcludedFromPersonShown)

        let legacyJSON = "{\"id\":\"\(UUID().uuidString)\",\"representativeFaceID\":\"\(UUID().uuidString)\",\"faceIDs\":[]}"
        let legacy = try JSONDecoder().decode(FaceGroup.self, from: Data(legacyJSON.utf8))
        #expect(legacy.knownPersonID == nil)
        #expect(!legacy.isExcludedFromPersonShown)
    }

    @Test("Excluded non-player groups cannot corroborate a Sports number claim")
    func excludedGroupDoesNotConfirmClaim() {
        let imageURL = URL(fileURLWithPath: "/tmp/referee.jpg")
        var face = numberedFace(number: 4, color: nil)
        face.imageURL = imageURL
        var referee = group(of: [face], name: "Player Four")
        referee.excludedFromPersonShown = true
        face.groupID = referee.id
        let names = FaceRecognitionViewModel.independentFaceNamesByURL(
            faces: [face], groups: [referee]
        )
        #expect(names[imageURL] == nil)
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

@Suite("Match roster filesystem boundary")
struct MatchRosterServiceTests {
    @Test("load returns an immutable snapshot away from the main actor")
    @MainActor
    func loadRunsOffMainActor() async throws {
        let folderURL = URL(fileURLWithPath: "/virtual/match")
        let teamID = UUID()
        let roster = MatchRoster(folderURL: folderURL, homeTeamID: teamID)
        let encoded = try JSONEncoder().encode(roster)
        let probe = MatchRosterFileIOProbe(readData: encoded)
        let service = MatchRosterService(fileIO: probe.fileIO)
        let requestID = UUID()

        let result = await Task {
            await service.load(for: folderURL, requestID: requestID)
        }.value

        guard case .loaded(let snapshot) = result else {
            Issue.record("Expected a loaded roster snapshot")
            return
        }
        #expect(snapshot.requestID == requestID)
        #expect(snapshot.folderURL == folderURL)
        #expect(snapshot.roster?.homeTeamID == teamID)
        #expect(snapshot.sourceByteCount == encoded.count)
        #expect(!probe.ranOnMainThread)
    }

    @Test("pre-cancellation avoids every filesystem mutation")
    func preCancelledSave() async throws {
        let folderURL = URL(fileURLWithPath: "/virtual/match")
        let roster = MatchRoster(folderURL: folderURL)
        let probe = MatchRosterFileIOProbe()
        let service = MatchRosterService(fileIO: probe.fileIO)
        let requestID = UUID()
        let task = Task {
            await Task.yield()
            return try await service.save(roster, requestID: requestID)
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeCommit(requestID: requestID, folderURL: folderURL))
        #expect(probe.directoryCreationCount == 0)
        #expect(probe.writeCount == 0)
    }

    @Test("overlapping roster reads are serialized")
    func overlappingReadsSerialize() async throws {
        let folderURL = URL(fileURLWithPath: "/virtual/match")
        let encoded = try JSONEncoder().encode(MatchRoster(folderURL: folderURL))
        let probe = MatchRosterFileIOProbe(readData: encoded, readDelay: 0.03)
        let service = MatchRosterService(fileIO: probe.fileIO)

        async let first = service.load(for: folderURL, requestID: UUID())
        async let second = service.load(for: folderURL, requestID: UUID())
        _ = await (first, second)

        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("cancellation during a synchronous write preserves commit evidence")
    func cancellationAfterCommit() async throws {
        let folderURL = URL(fileURLWithPath: "/virtual/match")
        let roster = MatchRoster(folderURL: folderURL)
        let probe = MatchRosterFileIOProbe(cancelDuringWrite: true)
        let service = MatchRosterService(fileIO: probe.fileIO)
        let requestID = UUID()

        let result = try await Task {
            try await service.save(roster, requestID: requestID)
        }.value

        guard case .committed(let commit) = result else {
            Issue.record("Expected an immutable save commit")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.folderURL == folderURL)
        #expect(commit.byteCount > 0)
        #expect(commit.cancellationRequestedAfterCommit)
        #expect(probe.directoryCreationCount == 1)
        #expect(probe.writeCount == 1)
    }

    @Test("callers await roster IO and reject stale UI loads")
    func callerSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let faceViewModel = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/FaceRecognitionViewModel.swift"
            ),
            encoding: .utf8
        )
        let metadataViewModel = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/MetadataViewModel.swift"
            ),
            encoding: .utf8
        )

        #expect(faceViewModel.contains("await matchRosterService.load(for: folderURL, requestID: requestID)"))
        #expect(faceViewModel.contains("matchRosterLoadRequestID == requestID"))
        #expect(faceViewModel.contains("await matchRosterService.save(roster, requestID: UUID())"))
        #expect(metadataViewModel.contains("await MatchRosterService.shared.load("))
        #expect(!metadataViewModel.contains("MatchRosterService().load(for:"))
    }
}

private nonisolated final class MatchRosterFileIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let suppliedReadData: Data
    private let cancelDuringWrite: Bool
    private let readDelay: TimeInterval
    private var observedMainThread = false
    private var createdDirectories = 0
    private var writes = 0
    private var activeReads = 0
    private var maximumActiveReads = 0

    init(
        readData: Data = Data(),
        cancelDuringWrite: Bool = false,
        readDelay: TimeInterval = 0
    ) {
        self.suppliedReadData = readData
        self.cancelDuringWrite = cancelDuringWrite
        self.readDelay = readDelay
    }

    var fileIO: MatchRosterFileIO {
        MatchRosterFileIO(
            fileExists: { [self] _ in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return !suppliedReadData.isEmpty
            },
            readData: { [self] _ in
                lock.withLock {
                    activeReads += 1
                    maximumActiveReads = max(maximumActiveReads, activeReads)
                }
                if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
                lock.withLock { activeReads -= 1 }
                return suppliedReadData
            },
            createDirectory: { [self] _ in
                lock.withLock {
                    createdDirectories += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            },
            writeData: { [self] _, _, _ in
                lock.withLock {
                    writes += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                if cancelDuringWrite {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
    }

    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var directoryCreationCount: Int { lock.withLock { createdDirectories } }
    var writeCount: Int { lock.withLock { writes } }
    var maximumConcurrentReads: Int { lock.withLock { maximumActiveReads } }
}
