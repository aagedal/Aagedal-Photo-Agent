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

    private func service() -> CaptionVoiceMemoAssociationService {
        CaptionVoiceMemoAssociationService(scanner: ImportVoiceMemoAssociationScanService(
            imageEvidenceReader: { .init(url: $0, captureSignature: "SONY|fixture", capturedAt: Date(timeIntervalSince1970: 100)) },
            memoDateReader: { _ in Date(timeIntervalSince1970: 200) }))
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
