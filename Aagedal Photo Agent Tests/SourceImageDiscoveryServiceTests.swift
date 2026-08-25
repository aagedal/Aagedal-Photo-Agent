import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Source image discovery")
struct SourceImageDiscoveryServiceTests {
    @Test("the recorded path is preferred after its hash is verified")
    func locatesCurrentPath() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("source.raw", contents: "same bytes")
        let source = try await SourceImageRevision.capture(at: sourceURL)

        let result = try await SourceImageDiscoveryService().discover(source, among: [])

        guard case .located(let located, let method) = result else {
            Issue.record("Expected the source at its current path")
            return
        }
        #expect(located.canonicalURL == sourceURL.standardizedFileURL)
        #expect(method == .currentPath)
    }

    @Test("a moved source is found by resource ID only after its hash matches")
    func locatesMovedSourceByResourceIdentifier() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("original.raw", contents: "move me")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let movedURL = fixture.directoryURL.appendingPathComponent("moved.raw")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [movedURL]
        )

        guard case .located(let located, let method) = result else {
            Issue.record("Expected the moved source")
            return
        }
        #expect(located.canonicalURL == movedURL.standardizedFileURL)
        #expect(located.sha256 == source.sha256)
        #expect(method == .fileResourceIdentifier)
    }

    @Test("a unique byte-for-byte copy can be reassociated by hash")
    func locatesUniqueCopyByHash() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("original.raw", contents: "copy me")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let copyURL = try fixture.write("copy.raw", contents: "copy me")
        try FileManager.default.removeItem(at: originalURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [copyURL]
        )

        guard case .located(let located, let method) = result else {
            Issue.record("Expected the unique hash match")
            return
        }
        #expect(located.canonicalURL == copyURL.standardizedFileURL)
        #expect(method == .contentHash)
    }

    @Test("multiple hash-only copies require an explicit user choice")
    func reportsAmbiguousCopies() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("original.raw", contents: "duplicate")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let firstCopy = try fixture.write("a.raw", contents: "duplicate")
        let secondCopy = try fixture.write("b.raw", contents: "duplicate")
        try FileManager.default.removeItem(at: originalURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [secondCopy, firstCopy]
        )

        guard case .ambiguous(let matches) = result else {
            Issue.record("Expected ambiguous exact matches")
            return
        }
        #expect(matches.map(\.canonicalURL) == [
            firstCopy.standardizedFileURL,
            secondCopy.standardizedFileURL
        ])
    }

    @Test("changed bytes at the recorded location are never silently reassociated")
    func reportsChangedSource() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("source.raw", contents: "before")
        let source = try await SourceImageRevision.capture(at: sourceURL)
        try Data("after!".utf8).write(to: sourceURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [sourceURL]
        )

        guard case .sourceChanged(let changed) = result else {
            Issue.record("Expected changed source state")
            return
        }
        #expect(changed.canonicalURL == sourceURL.standardizedFileURL)
        #expect(changed.sha256 != source.sha256)
    }

    @Test("different-size candidates are rejected and no match is reported")
    func reportsNotFound() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.write("source.raw", contents: "source")
        let source = try await SourceImageRevision.capture(at: originalURL)
        let unrelatedURL = try fixture.write("other.raw", contents: "a different size")
        try FileManager.default.removeItem(at: originalURL)

        let result = try await SourceImageDiscoveryService().discover(
            source,
            among: [unrelatedURL]
        )

        #expect(result == .notFound)
    }

    @Test("a pre-cancelled discovery exits before inspecting candidates")
    func honorsCancellation() async throws {
        let fixture = try SourceDiscoveryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("source.raw", contents: "cancel")
        let source = try await SourceImageRevision.capture(at: sourceURL)

        let task = Task {
            await Task.yield()
            return try await SourceImageDiscoveryService().discover(source, among: [sourceURL])
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

@Suite("Voice memo companion association")
struct VoiceMemoAssociationServiceTests {
    private let service = VoiceMemoAssociationService()
    private let profile = VoiceMemoAssociationProfile(
        identifier: "synthetic-validated-layout",
        imageFilenameExtensions: ["arw", "jpg"],
        filenameCaseSensitive: false
    )

    @Test("an explicit profile associates one image and one memo deterministically")
    func associatesUniquePair() throws {
        let root = URL(fileURLWithPath: "/card/DCIM/100MSDCF", isDirectory: true)
        let image = root.appendingPathComponent("DSC01234.ARW")
        let memo = root.appendingPathComponent("dsc01234.WAV")

        let report = try service.associate(
            files: [memo, image, memo],
            profile: profile
        )

        #expect(report.associations == [VoiceMemoAssociation(
            profileIdentifier: profile.identifier,
            imageURL: image,
            memoURL: memo
        )])
        #expect(report.imagesWithoutMemo.isEmpty)
        #expect(report.ambiguous.isEmpty)
        #expect(report.orphanMemoURLs.isEmpty)
        #expect(report.association(for: image)?.renameArtifact.sourceURL == memo)
        #expect(report.association(for: image)?.renameArtifact.filenamePattern.suffix == ".WAV")
    }

    @Test("RAW plus JPEG and duplicate audio fail closed instead of guessing")
    func reportsAmbiguousGroups() throws {
        let root = URL(fileURLWithPath: "/card/DCIM/100MSDCF", isDirectory: true)
        let raw = root.appendingPathComponent("DSC00001.ARW")
        let jpeg = root.appendingPathComponent("DSC00001.JPG")
        let upperMemo = root.appendingPathComponent("DSC00001.WAV")
        let lowerMemo = root.appendingPathComponent("dsc00001.wav")

        let report = try service.associate(
            files: [raw, jpeg, upperMemo, lowerMemo],
            profile: profile
        )

        #expect(report.associations.isEmpty)
        #expect(report.ambiguous == [VoiceMemoAssociationAmbiguity(
            imageURLs: [raw, jpeg],
            memoURLs: [lowerMemo, upperMemo]
        )])
        #expect(report.orphanMemoURLs.isEmpty)
    }

    @Test("missing images and orphan memos stay visible")
    func reportsMissingAndOrphan() throws {
        let root = URL(fileURLWithPath: "/card/DCIM/100MSDCF", isDirectory: true)
        let image = root.appendingPathComponent("DSC00002.ARW")
        let orphan = root.appendingPathComponent("DSC99999.WAV")

        let report = try service.associate(files: [image, orphan], profile: profile)

        #expect(report.imagesWithoutMemo == [image])
        #expect(report.orphanMemoURLs == [orphan])
        #expect(report.associations.isEmpty)
    }

    @Test("a validated relative memo directory is honored")
    func supportsRelativeMemoDirectory() throws {
        let imageRoot = URL(fileURLWithPath: "/card/DCIM/100MSDCF", isDirectory: true)
        let image = imageRoot.appendingPathComponent("DSC00003.ARW")
        let memo = imageRoot.appendingPathComponent("VOICE", isDirectory: true)
            .appendingPathComponent("DSC00003.WAV")
        let nestedProfile = VoiceMemoAssociationProfile(
            identifier: "synthetic-nested-layout",
            imageFilenameExtensions: ["arw"],
            memoDirectoryComponents: ["VOICE"],
            filenameCaseSensitive: true
        )

        let report = try service.associate(files: [memo, image], profile: nestedProfile)

        #expect(report.associations.first?.imageURL == image)
        #expect(report.associations.first?.memoURL == memo)
    }

    @Test("unsafe or empty profiles are rejected")
    func rejectsInvalidProfile() {
        let invalid = VoiceMemoAssociationProfile(
            identifier: "",
            imageFilenameExtensions: ["arw"],
            memoDirectoryComponents: [".."],
            filenameCaseSensitive: false
        )

        #expect(throws: VoiceMemoAssociationService.AssociationError.invalidProfile) {
            _ = try service.associate(files: [], profile: invalid)
        }
    }
}

@Suite("Sony dual-card voice memo association")
struct SonyDualCardVoiceMemoAssociationServiceTests {
    private let service = SonyDualCardVoiceMemoAssociationService()
    private let cardOne = URL(fileURLWithPath: "/card-1/DCIM/100MSDCF", isDirectory: true)
    private let cardTwo = URL(fileURLWithPath: "/card-2/DCIM/100MSDCF", isDirectory: true)
    private let capturedAt = Date(timeIntervalSince1970: 1_787_605_206.544)

    @Test("matching RAW and JPEG variants associate a WAV recorded at any later time")
    func associatesAcrossCardsWithoutAnUpperTimeLimit() {
        let raw = evidence(cardOne.appendingPathComponent("TRA08908.ARW"))
        let jpeg = evidence(cardTwo.appendingPathComponent("TRA08908.JPG"))
        let wav = cardTwo.appendingPathComponent("TRA08908.WAV")

        let report = service.associate(
            primaryImages: [raw],
            companionImages: [jpeg],
            memoFileDates: [wav: capturedAt.addingTimeInterval(30 * 24 * 3600)]
        )

        #expect(report.associations == [
            VoiceMemoAssociation(
                profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                imageURL: raw.url,
                memoURL: wav
            ),
            VoiceMemoAssociation(
                profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                imageURL: jpeg.url,
                memoURL: wav
            ),
        ])
        #expect(report.ambiguous.isEmpty)
        #expect(report.orphanMemoURLs.isEmpty)
    }

    @Test("a RAW and WAV on one card associate without a JPEG")
    func associatesSingleCardRawAndMemo() {
        let raw = evidence(cardOne.appendingPathComponent("TRA08910.ARW"))
        let wav = cardOne.appendingPathComponent("TRA08910.WAV")

        let report = service.associate(
            primaryImages: [raw],
            companionImages: [],
            primaryMemoFileDates: [wav: capturedAt.addingTimeInterval(120)],
            companionMemoFileDates: [:]
        )

        #expect(report.associations == [VoiceMemoAssociation(
            profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
            imageURL: raw.url,
            memoURL: wav
        )])
        #expect(report.ambiguous.isEmpty)
    }

    @Test("a WAV on another source requires an image anchor on that source")
    func rejectsCrossSourceMemoWithoutImageAnchor() {
        let raw = evidence(cardOne.appendingPathComponent("TRA08911.ARW"))
        let wav = cardTwo.appendingPathComponent("TRA08911.WAV")

        let report = service.associate(
            primaryImages: [raw],
            companionImages: [],
            primaryMemoFileDates: [:],
            companionMemoFileDates: [wav: capturedAt.addingTimeInterval(120)]
        )

        #expect(report.associations.isEmpty)
        #expect(report.ambiguous.count == 1)
    }

    @Test("a WAV timestamp before image capture fails closed")
    func rejectsMemoCreatedBeforeImage() {
        let raw = evidence(cardOne.appendingPathComponent("TRA08907.ARW"))
        let jpeg = evidence(cardTwo.appendingPathComponent("TRA08907.JPG"))
        let wav = cardTwo.appendingPathComponent("TRA08907.WAV")

        let report = service.associate(
            primaryImages: [raw],
            companionImages: [jpeg],
            memoFileDates: [wav: capturedAt.addingTimeInterval(-0.001)]
        )

        #expect(report.associations.isEmpty)
        #expect(report.ambiguous == [VoiceMemoAssociationAmbiguity(
            imageURLs: [raw.url, jpeg.url],
            memoURLs: [wav]
        )])
    }

    @Test("a matching stem with different capture evidence fails closed")
    func rejectsSequenceRolloverCollision() {
        let raw = evidence(cardOne.appendingPathComponent("TRA00001.ARW"))
        let jpegURL = cardTwo.appendingPathComponent("TRA00001.JPG")
        let jpeg = SonyVoiceMemoImageEvidence(
            url: jpegURL,
            captureSignature: "ILCE-1|v4.00|2027:01:01 00:00:00|000|+02:00",
            capturedAt: capturedAt.addingTimeInterval(10_000)
        )
        let wav = cardTwo.appendingPathComponent("TRA00001.WAV")

        let report = service.associate(
            primaryImages: [raw],
            companionImages: [jpeg],
            memoFileDates: [wav: capturedAt.addingTimeInterval(20_000)]
        )

        #expect(report.associations.isEmpty)
        #expect(report.ambiguous.count == 1)
    }

    @Test("a same-source image anchor and unique files are required")
    func rejectsMissingWitnessAndDuplicateMemo() {
        let raw = evidence(cardOne.appendingPathComponent("TRA08909.ARW"))
        let wav = cardTwo.appendingPathComponent("TRA08909.WAV")
        let duplicate = cardTwo.appendingPathComponent("backup/TRA08909.WAV")

        let report = service.associate(
            primaryImages: [raw],
            companionImages: [],
            memoFileDates: [
                wav: capturedAt.addingTimeInterval(10),
                duplicate: capturedAt.addingTimeInterval(20),
            ]
        )

        #expect(report.associations.isEmpty)
        #expect(report.ambiguous.first?.memoURLs == [duplicate, wav])
    }

    private func evidence(_ url: URL) -> SonyVoiceMemoImageEvidence {
        SonyVoiceMemoImageEvidence(
            url: url,
            captureSignature: "ILCE-1|v4.00|2026:08:24 22:41:06|544|+02:00",
            capturedAt: capturedAt
        )
    }

}

private struct SourceDiscoveryFixture {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apa-source-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
    }

    func write(_ filename: String, contents: String) throws -> URL {
        let url = directoryURL.appendingPathComponent(filename)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
