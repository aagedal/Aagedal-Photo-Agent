import CryptoKit
import Foundation
import Testing
import Observation
import os
@testable import Aagedal_Photo_Agent

@Suite("Caption existing-folder voice memo association")
struct CaptionVoiceMemoAssociationServiceTests {
    private func fixture() throws -> (URL, URL, URL) {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("TRA08907.JPG")
        let memo = folder.appendingPathComponent("TRA08907.WAV")
        try Data("photo".utf8).write(to: image)
        try Data("audio".utf8).write(to: memo)
        return (folder, image, memo)
    }

    private func service(capture: SourceImageRevisionCaptureService = .shared) -> CaptionVoiceMemoAssociationService {
        CaptionVoiceMemoAssociationService(scanner: ImportVoiceMemoAssociationScanService(
            imageEvidenceReader: { .init(url: $0, captureSignature: "SONY|fixture", capturedAt: Date(timeIntervalSince1970: 100)) },
            memoDateReader: { _ in Date(timeIntervalSince1970: 200) }), revisionCapture: capture)
    }

    @MainActor @Test("Opening Caption automatically links a unique adjacent WAV without confirmation")
    func automaticAssociation() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originals = try [Data(contentsOf: image), Data(contentsOf: memo)]
        let service = service()
        let model = CaptionVoiceMemoAssociationModel(service: service)
        #expect(await model.associateAutomatically(imageURL: image))
        #expect(model.pendingAssociation == nil)
        #expect(!model.isWorking)
        #expect(model.errorMessage == nil)
        guard case .available(let pair) = try VoiceMemoCompanionRepository().lookup(for: image) else {
            Issue.record("Expected an automatically installed relationship"); return
        }
        #expect(pair.memoURL == memo)
        #expect(try [Data(contentsOf: image), Data(contentsOf: memo)] == originals)
        let record = VoiceMemoCompanionRepository().recordURL(for: image)
        let bytes = try Data(contentsOf: record)
        #expect(try await service.associateAutomatically(imageURL: image) == false)
        #expect(try Data(contentsOf: record) == bytes)
    }

    @MainActor @Test("Automatic detection leaves missing or ambiguous matches unlinked", arguments: [false, true])
    func automaticNoMatch(ambiguous: Bool) async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        if ambiguous { try Data("duplicate".utf8).write(to: folder.appendingPathComponent("TRA08907.jpeg")) }
        else { try FileManager.default.removeItem(at: memo) }
        let model = CaptionVoiceMemoAssociationModel(service: service())
        #expect(await model.associateAutomatically(imageURL: image) == false)
        #expect(model.errorMessage == nil)
        #expect(model.pendingAssociation == nil)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("An unlinked adjacent voice memo has a waiting badge without a relationship write")
    func unlinkedBadge() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let associationService = service()
        let badges = CaptionVoiceMemoStatusService(discoverAssociation: {
            _ = try await associationService.discover(imageURL: $0)
            return true
        })
        #expect(await badges.status(for: image) == .needsTranscription)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("An unlinked memo badge reads no file content and is cached per folder revision")
    func unlinkedBadgeDoesNotHash() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hashes = CountingRevisionIO()
        let associationService = service(capture: SourceImageRevisionCaptureService(io: hashes.io))
        #expect(try await associationService.hasUnlinkedMatch(imageURL: image))
        #expect(hashes.hashedURLs.isEmpty)

        // An old folder date lets the status service reuse its listing and probe result.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: folder.path)
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let badges = CaptionVoiceMemoStatusService(discoverAssociation: {
            probes.withLock { $0 += 1 }
            return try await associationService.hasUnlinkedMatch(imageURL: $0)
        })
        #expect(await badges.status(for: image) == .needsTranscription)
        #expect(await badges.status(for: image) == .needsTranscription)
        #expect(probes.withLock { $0 } == 1)
        #expect(hashes.hashedURLs.isEmpty)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)

        // A changed same-stem file changes the probe's key and is probed again.
        try Data("longer audio".utf8).write(to: memo)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: folder.path)
        #expect(await badges.status(for: image) == .needsTranscription)
        #expect(probes.withLock { $0 } == 2)
    }

    @Test("Ambiguous groups end discovery before any content hash")
    func ambiguousDiscoveryDoesNotHash() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("duplicate".utf8).write(to: folder.appendingPathComponent("TRA08907.jpeg"))
        let hashes = CountingRevisionIO()
        let service = service(capture: SourceImageRevisionCaptureService(io: hashes.io))
        await #expect(throws: CaptionVoiceMemoAssociationService.Failure.self) {
            try await service.discover(imageURL: image)
        }
        #expect(try await service.hasUnlinkedMatch(imageURL: image) == false)
        #expect(hashes.hashedURLs.isEmpty)
    }

    @Test("Linking hashes each source once; repeated revalidation answers from the digest cache")
    func confirmationUsesDigestCache() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hashes = CountingRevisionIO()
        let service = service(capture: SourceImageRevisionCaptureService(io: hashes.io))
        let preview = try await service.discover(imageURL: image)
        #expect(Set(hashes.hashedURLs) == [image, memo])
        #expect(hashes.hashedURLs.count == 2)
        try await service.confirm(preview)
        // Discovery revalidation, confirmation, the three installation checks and the identity
        // record all reuse the two verified digests.
        #expect(hashes.hashedURLs.count == 2)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .available(preview.association))
        let record = try JSONDecoder().decode(VoiceMemoCompanionRecord.self,
            from: Data(contentsOf: VoiceMemoCompanionRepository().recordURL(for: image)))
        #expect(record.memoIdentity?.sha256 == SHA256.hash(data: Data("audio".utf8))
            .map { String(format: "%02x", $0) }.joined())
    }

    @Test("A cached digest never hides a changed memo when linking")
    func cachedDigestStillDetectsChangedMemo() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hashes = CountingRevisionIO()
        let service = service(capture: SourceImageRevisionCaptureService(io: hashes.io))
        let preview = try await service.discover(imageURL: image)
        // Same size, different bytes: the stat identity changes, so the bytes are re-read.
        try Data("AUDIO".utf8).write(to: memo)
        await #expect(throws: (any Error).self) { try await service.confirm(preview) }
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("Badges skip lookup and discovery when the folder has neither a record nor a same-stem WAV")
    func badgeShortCircuitsWithoutCandidates() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("TRA08908.JPG")
        try Data("other photo".utf8).write(to: other)
        // An old folder date lets the service reuse its listing across cells.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: folder.path)
        let calls = OSAllocatedUnfairLock(initialState: [URL]())
        let badges = CaptionVoiceMemoStatusService(lookup: { url in
            calls.withLock { $0.append(url) }
            return try VoiceMemoCompanionRepository().lookup(for: url)
        }, discoverAssociation: { _ in true })

        #expect(await badges.status(for: other) == CaptionVoiceMemoTranscriptionStatus.none)
        #expect(await badges.status(for: other) == CaptionVoiceMemoTranscriptionStatus.none)
        #expect(calls.withLock { $0 }.isEmpty)
        #expect(await badges.status(for: image) == .needsTranscription)
        #expect(calls.withLock { $0 } == [image])

        // A newly added same-stem WAV changes the folder date and is seen immediately.
        try Data("audio".utf8).write(to: folder.appendingPathComponent("TRA08908.wav"))
        #expect(await badges.status(for: other) == .needsTranscription)
        // A relationship record alone (memo gone) still reaches lookup and reports missing.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("TRA08908.wav"))
        let record = VoiceMemoCompanionRecord(profileIdentifier: "test", imageFilename: "TRA08908.JPG",
                                              memoFilename: "TRA08908.wav")
        try JSONEncoder().encode(record).write(to: VoiceMemoCompanionRepository().recordURL(for: other))
        #expect(await badges.status(for: other) == .missing)
    }

    @Test("Discovery is read-only; reviewed confirmation installs identities and preserves originals")
    func explicitConfirmation() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try [Data(contentsOf: image), Data(contentsOf: memo)]
        let service = service()
        let preview = try await service.discover(imageURL: image)
        #expect(preview.association.memoURL == memo.standardizedFileURL.resolvingSymlinksInPath())
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
        try await service.confirm(preview)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .available(preview.association))
        #expect(try [Data(contentsOf: image), Data(contentsOf: memo)] == original)
        let record = try JSONDecoder().decode(VoiceMemoCompanionRecord.self,
            from: Data(contentsOf: VoiceMemoCompanionRepository().recordURL(for: image)))
        #expect(record.imageIdentity != nil)
        #expect(record.memoIdentity != nil)
        await #expect(throws: (any Error).self) { try await service.confirm(preview) }
    }

    @Test("Added same-stem image invalidates a reviewed preview")
    func inventoryDrift() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        let preview = try await service.discover(imageURL: image)
        try Data("second JPEG".utf8).write(to: folder.appendingPathComponent("TRA08907.jpeg"))
        await #expect(throws: (any Error).self) { try await service.confirm(preview) }
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("A memo for a different photo is not a candidate")
    func otherStemMemoIsNoMatch() async throws {
        let (folder, _, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("TRA08908.JPG")
        try Data("other photo".utf8).write(to: other)
        await #expect(throws: CaptionVoiceMemoAssociationService.Failure.self) {
            try await service().discover(imageURL: other)
        }
        #expect(FileManager.default.fileExists(atPath: memo.path))
    }

    @Test("Unrelated files in the folder neither block nor invalidate a pairing")
    func unrelatedFolderChangesAreIgnored() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        let preview = try await service.discover(imageURL: image)
        try Data("later shot".utf8).write(to: folder.appendingPathComponent("TRA08999.JPG"))
        try await service.confirm(preview)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) != .none)
        #expect(preview.association.memoURL.lastPathComponent == memo.lastPathComponent)
    }

    @Test("Changed source bytes invalidate a reviewed preview")
    func sourceDrift() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        let preview = try await service.discover(imageURL: image)
        try Data("other audio".utf8).write(to: memo)
        await #expect(throws: (any Error).self) { try await service.confirm(preview) }
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("A concurrent relationship is preserved byte-for-byte")
    func occupiedRecord() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        let preview = try await service.discover(imageURL: image)
        let record = VoiceMemoCompanionRepository().recordURL(for: image)
        let unrelated = Data("newer opaque relationship".utf8)
        try unrelated.write(to: record)
        await #expect(throws: (any Error).self) { try await service.confirm(preview) }
        #expect(try Data(contentsOf: record) == unrelated)
    }

    @Test("Duplicate JPEG variants and linked WAVs fail closed")
    func ambiguityAndSymlink() async throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let duplicate = folder.appendingPathComponent("TRA08907.jpeg")
        try Data("duplicate".utf8).write(to: duplicate)
        let service = service()
        await #expect(throws: (any Error).self) { try await service.discover(imageURL: image) }
        try FileManager.default.removeItem(at: duplicate)
        let external = folder.appendingPathComponent("opaque.bin")
        try FileManager.default.moveItem(at: memo, to: external)
        try FileManager.default.createSymbolicLink(at: memo, withDestinationURL: external)
        await #expect(throws: (any Error).self) { try await service.discover(imageURL: image) }
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @MainActor @Test("Cancelling review clears its authority and confirmation cannot proceed")
    func modelCancellation() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = CaptionVoiceMemoAssociationModel(service: service())
        await model.discover(imageURL: image)
        #expect(model.pendingAssociation != nil)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = model.pendingAssociation } onChange: {
            changed.withLock { $0 = true }
        }
        model.cancel()
        #expect(changed.withLock { $0 })
        #expect(model.pendingAssociation == nil)
        #expect(await model.confirm() == false)
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("An active GUI photo mutation prevents association confirmation")
    func reservationConflict() async throws {
        let (folder, image, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        let preview = try await service.discover(imageURL: image)
        let lease = try MCPProcessReservation.acquirePhoto(image)
        defer { lease.release() }
        await #expect(throws: (any Error).self) { try await service.confirm(preview) }
        #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .none)
    }

    @Test("Exclusive installation preserves a relationship arriving after preflight")
    func exclusiveInstallRace() throws {
        let (folder, image, memo) = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = VoiceMemoCompanionRepository()
        let destination = repository.recordURL(for: image)
        let existing = Data("concurrent relationship".utf8)
        var checks = 0
        #expect(throws: (any Error).self) {
            try repository.saveNewReviewedAssociation(.init(profileIdentifier: "fixture", imageURL: image, memoURL: memo)) {
                checks += 1
                if checks == 2 { try existing.write(to: destination) }
            }
        }
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test("Opt-in production Sony fixture discovers and links all adjacent pairs without altering sources",
          .enabled(if: ProcessInfo.processInfo.environment["APA_SONY_EXISTING_FOLDER_FIXTURE"] != nil))
    func productionSonyFixture() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["APA_SONY_EXISTING_FOLDER_FIXTURE"])
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "wav" }
        #expect(files.count == 6)
        let originals = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
        let service = CaptionVoiceMemoAssociationService()
        for image in files.filter({ $0.pathExtension.lowercased() == "jpg" }).sorted(by: { $0.path < $1.path }) {
            let preview = try await service.discover(imageURL: image)
            try await service.confirm(preview)
            #expect(try VoiceMemoCompanionRepository().lookup(for: image) == .available(preview.association))
        }
        for (file, bytes) in originals { #expect(try Data(contentsOf: file) == bytes) }
    }
}

/// Real filesystem primitives with counted content hashes. The clock runs a minute ahead so
/// freshly written fixtures count as settled and their digests may be cached.
nonisolated private final class CountingRevisionIO: Sendable {
    private let hashes = OSAllocatedUnfairLock(initialState: [URL]())

    var hashedURLs: [URL] { hashes.withLock { $0 } }

    var io: SourceImageRevisionCaptureIO {
        let system = SourceImageRevisionCaptureIO.system
        return SourceImageRevisionCaptureIO(
            canonicalURL: system.canonicalURL,
            snapshot: system.snapshot,
            hash: { [hashes] url in
                hashes.withLock { $0.append(url.standardizedFileURL) }
                return try system.hash(url)
            },
            now: { Date().addingTimeInterval(60) }
        )
    }
}
