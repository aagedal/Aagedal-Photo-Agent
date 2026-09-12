import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("RAW archive voice memo transaction", .serialized)
struct RAWArchiveTransactionServiceTests {
    @Test("A rendered archive installs independent image, XMP, memo, and relationship bytes")
    func installsCompleteBundle() async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }
        let signed = LockedFlag()

        let receipt = try await RAWArchiveTransactionService().archive(request(
            fixture,
            render: standardRender(fixture),
            sign: { archive, parent in
                #expect(archive.deletingLastPathComponent().lastPathComponent.hasPrefix(".raw-archive-"))
                #expect(parent == fixture.image)
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: archive.deletingLastPathComponent().path
                )
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                signed.set()
            }
        ))

        let destination = fixture.destination.appendingPathComponent("DSC00001.tiff")
        let memo = fixture.destination.appendingPathComponent("DSC00001.WAV")
        let sidecar = fixture.destination.appendingPathComponent("DSC00001.xmp")
        let record = VoiceMemoCompanionRepository().recordURL(for: destination)
        #expect(receipt.archiveURL == destination)
        #expect(Set(receipt.artifactURLs) == Set([destination, sidecar, memo, record]))
        #expect(receipt.cleanupResidualURLs.isEmpty)
        #expect(signed.value)
        #expect(try Data(contentsOf: destination) == Data("rendered".utf8))
        #expect(try Data(contentsOf: sidecar) == Data("source-xmp".utf8))
        #expect(try Data(contentsOf: memo) == Data("memo".utf8))
        #expect(try VoiceMemoCompanionRepository().lookup(for: destination) == .available(
            VoiceMemoAssociation(profileIdentifier: fixture.profile, imageURL: destination, memoURL: memo)
        ))
        #expect(try Data(contentsOf: fixture.image) == Data("source-raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo".utf8))
        #expect(try Data(contentsOf: fixture.xmp) == Data("source-xmp".utf8))
        #expect(try !FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)
            .contains(where: { $0.hasPrefix(".raw-archive-") }))
    }

    @Test("Complete carrier collisions choose one coherent suffix and unrelated WAVs are not adopted",
          arguments: [true, false])
    func coherentCollisionReservation(associated: Bool) async throws {
        let fixture = try Fixture(associated: associated, withXMP: false)
        defer { fixture.remove() }
        let occupiedSidecar = fixture.destination.appendingPathComponent("DSC00001.xmp")
        try Data("foreign".utf8).write(to: occupiedSidecar)

        let receipt = try await RAWArchiveTransactionService().archive(request(
            fixture,
            render: standardRender(fixture),
            sign: { archive, _ in
                #expect(archive.lastPathComponent == "DSC00001 2.tiff")
            }
        ))

        #expect(receipt.archiveURL.lastPathComponent == "DSC00001 2.tiff")
        #expect(try Data(contentsOf: occupiedSidecar) == Data("foreign".utf8))
        let destinationRecord = VoiceMemoCompanionRepository().recordURL(for: receipt.archiveURL)
        if associated {
            let memo = fixture.destination.appendingPathComponent("DSC00001 2.WAV")
            #expect(try Data(contentsOf: memo) == Data("memo".utf8))
            #expect(try VoiceMemoCompanionRepository().lookup(for: receipt.archiveURL) == .available(
                VoiceMemoAssociation(profileIdentifier: fixture.profile, imageURL: receipt.archiveURL, memoURL: memo)
            ))
        } else {
            #expect(!FileManager.default.fileExists(atPath: destinationRecord.path))
            #expect(!FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("DSC00001 2.WAV").path
            ))
        }
    }

    @Test("Source image, XMP, memo, and relationship changes during rendering fail before commit",
          arguments: ["image", "xmp", "memo", "record"])
    func sourceChangesFailClosed(kind: String) async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }

        await #expect(throws: VoiceMemoCompanionRepository.RepositoryError.copySourceChanged) {
            try await RAWArchiveTransactionService().archive(request(
                fixture,
                render: { source, staging in
                    let output = try await standardRender(fixture)(source, staging)
                    switch kind {
                    case "image": try Data("changed-raw".utf8).write(to: fixture.image)
                    case "xmp": try Data("changed-xmp".utf8).write(to: fixture.xmp)
                    case "memo": try Data("changed-memo".utf8).write(to: fixture.memo)
                    default:
                        let record = VoiceMemoCompanionRepository().recordURL(for: fixture.image)
                        var bytes = try Data(contentsOf: record)
                        bytes.append(10)
                        try bytes.write(to: record)
                    }
                    return output
                }
            ))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test("Signing failure and cancellation leave no visible archive artifacts", arguments: [false, true])
    func precommitStopsCleanly(cancel: Bool) async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }

        do {
            _ = try await RAWArchiveTransactionService().archive(request(
                fixture,
                render: standardRender(fixture),
                sign: { _, _ in
                    if cancel {
                        withUnsafeCurrentTask { $0?.cancel() }
                    } else {
                        throw InjectedFailure.signing
                    }
                }
            ))
            Issue.record("Expected archive failure")
        } catch is CancellationError {
            #expect(cancel)
        } catch InjectedFailure.signing {
            #expect(!cancel)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try Data(contentsOf: fixture.image) == Data("source-raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo".utf8))
    }

    @Test("A later install failure removes only transaction-owned destinations")
    func installationRollback() async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }
        let moves = LockedCounter()
        var io = RAWArchiveTransactionIO.system
        io = RAWArchiveTransactionIO(
            fileExists: io.fileExists,
            createDirectory: io.createDirectory,
            moveItem: { source, destination in
                if moves.increment() == 2 { throw InjectedFailure.install }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: io.removeItem,
            isRegularFile: io.isRegularFile
        )

        await #expect(throws: InjectedFailure.install) {
            try await RAWArchiveTransactionService(io: io).archive(
                request(fixture, render: standardRender(fixture))
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try Data(contentsOf: fixture.image) == Data("source-raw".utf8))
        #expect(try Data(contentsOf: fixture.memo) == Data("memo".utf8))
    }

    @Test("A signer-created unsafe sidecar is rejected and its target is preserved")
    func unsafeSidecarAfterSigning() async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }

        do {
            _ = try await RAWArchiveTransactionService().archive(request(
                fixture,
                render: { _, staging in
                    let output = staging.appendingPathComponent("DSC00001.tiff")
                    try Data("rendered".utf8).write(to: output)
                    return output
                },
                sign: { archive, _ in
                    let sidecar = XMPSidecarService().sidecarURL(for: archive)
                    try FileManager.default.createSymbolicLink(
                        at: sidecar,
                        withDestinationURL: fixture.xmp
                    )
                }
            ))
            Issue.record("Expected unsafe signer sidecar failure")
        } catch RAWArchiveTransactionFailure.invalidRenderedArtifact(let path) {
            #expect(path.hasSuffix("DSC00001.xmp"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }

        #expect(try Data(contentsOf: fixture.xmp) == Data("source-xmp".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test("A relationship pointing through a memo symbolic link is rejected before rendering")
    func rejectsMemoSymbolicLink() async throws {
        let fixture = try Fixture(associated: true, withXMP: false)
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("real.WAV")
        try FileManager.default.moveItem(at: fixture.memo, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.memo, withDestinationURL: target)
        let renderCalled = LockedFlag()

        await #expect(throws: VoiceMemoCompanionRepository.RepositoryError.unsafeMemoFile(
            "DSC00001.WAV"
        )) {
            try await RAWArchiveTransactionService().archive(request(
                fixture,
                render: { _, staging in
                    renderCalled.set()
                    return staging.appendingPathComponent("DSC00001.tiff")
                }
            ))
        }

        #expect(!renderCalled.value)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try Data(contentsOf: target) == Data("memo".utf8))
    }

    @Test("Cancellation observed during commit finishes the complete bundle")
    func cancellationDuringCommit() async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }
        let cancelled = LockedFlag()
        let system = RAWArchiveTransactionIO.system
        let io = RAWArchiveTransactionIO(
            fileExists: system.fileExists,
            createDirectory: system.createDirectory,
            moveItem: { source, destination in
                if !cancelled.value {
                    cancelled.set()
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: system.removeItem,
            isRegularFile: system.isRegularFile
        )

        let operation = Task {
            try await RAWArchiveTransactionService(io: io).archive(
                request(fixture, render: standardRender(fixture))
            )
        }
        let receipt = try await operation.value

        #expect(receipt.cancellationObservedAfterCommit)
        #expect(receipt.artifactURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(try VoiceMemoCompanionRepository().lookup(for: receipt.archiveURL) != .none)
    }

    @Test("A post-commit cleanup failure returns the exact private residual")
    func cleanupResidualReceipt() async throws {
        let fixture = try Fixture(associated: true, withXMP: false)
        defer { fixture.remove() }
        let system = RAWArchiveTransactionIO.system
        let io = RAWArchiveTransactionIO(
            fileExists: system.fileExists,
            createDirectory: system.createDirectory,
            moveItem: system.moveItem,
            removeItem: { url in
                if url.lastPathComponent.hasPrefix(".raw-archive-") {
                    throw InjectedFailure.cleanup
                }
                try FileManager.default.removeItem(at: url)
            },
            isRegularFile: system.isRegularFile
        )

        let receipt = try await RAWArchiveTransactionService(io: io).archive(
            request(fixture, render: standardRender(fixture))
        )

        #expect(receipt.cleanupResidualURLs.count == 1)
        #expect(receipt.cleanupResidualURLs[0].lastPathComponent.hasPrefix(".raw-archive-"))
        #expect(FileManager.default.fileExists(atPath: receipt.archiveURL.path))
    }

    @Test("A relationship arriving during installation is preserved and owned files roll back")
    func lateRelationshipCollision() async throws {
        let fixture = try Fixture(associated: true, withXMP: true)
        defer { fixture.remove() }
        let installedForeignRecord = LockedFlag()
        let record = VoiceMemoCompanionRepository().recordURL(
            for: fixture.destination.appendingPathComponent("DSC00001.tiff")
        )
        let system = RAWArchiveTransactionIO.system
        let io = RAWArchiveTransactionIO(
            fileExists: system.fileExists,
            createDirectory: system.createDirectory,
            moveItem: { source, destination in
                if !installedForeignRecord.value {
                    try Data("foreign-record".utf8).write(to: record)
                    installedForeignRecord.set()
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            removeItem: system.removeItem,
            isRegularFile: system.isRegularFile
        )

        await #expect(throws: (any Error).self) {
            try await RAWArchiveTransactionService(io: io).archive(
                request(fixture, render: standardRender(fixture))
            )
        }

        #expect(try Data(contentsOf: record) == Data("foreign-record".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path) == [
            record.lastPathComponent
        ])
    }

    @Test("Rendered bytes changed during companion preparation are rejected before commit")
    func renderedMutationDuringCompanionPreparation() async throws {
        let fixture = try Fixture(associated: true, withXMP: false)
        defer { fixture.remove() }
        let copyIO = VoiceMemoCompanionCopyIO(
            copy: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                try Data("mutated-render".utf8).write(
                    to: destination.deletingLastPathComponent()
                        .appendingPathComponent("DSC00001.tiff")
                )
            },
            install: { try FileManager.default.moveItem(at: $0, to: $1) },
            remove: { try FileManager.default.removeItem(at: $0) }
        )
        let repository = VoiceMemoCompanionRepository(copyIO: copyIO)

        do {
            _ = try await RAWArchiveTransactionService(repository: repository).archive(
                request(fixture, render: standardRender(fixture))
            )
            Issue.record("Expected rendered-artifact mutation failure")
        } catch RAWArchiveTransactionFailure.invalidRenderedArtifact(let path) {
            #expect(path.hasSuffix("DSC00001.tiff"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test("A staged memo symbolic link is rejected before installation")
    func rejectsStagedMemoSymbolicLink() async throws {
        let fixture = try Fixture(associated: true, withXMP: false)
        defer { fixture.remove() }
        let copyIO = VoiceMemoCompanionCopyIO(
            copy: { source, destination in
                try FileManager.default.createSymbolicLink(
                    at: destination,
                    withDestinationURL: source
                )
            },
            install: { try FileManager.default.moveItem(at: $0, to: $1) },
            remove: { try FileManager.default.removeItem(at: $0) }
        )
        let repository = VoiceMemoCompanionRepository(copyIO: copyIO)

        do {
            _ = try await RAWArchiveTransactionService(repository: repository).archive(
                request(fixture, render: standardRender(fixture))
            )
            Issue.record("Expected staged memo safety failure")
        } catch RAWArchiveTransactionFailure.invalidStagedCompanion(let path) {
            #expect(path.hasSuffix("archive-memo.WAV"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        #expect(try Data(contentsOf: fixture.memo) == Data("memo".utf8))
    }

    private func request(
        _ fixture: Fixture,
        render: @escaping RAWArchiveTransactionRequest.Render,
        sign: RAWArchiveTransactionRequest.Sign? = nil
    ) -> RAWArchiveTransactionRequest {
        RAWArchiveTransactionRequest(
            sourceURL: fixture.image,
            destinationFolder: fixture.destination,
            fileExtension: "tiff",
            render: render,
            sign: sign
        )
    }

    private func standardRender(_ fixture: Fixture) -> RAWArchiveTransactionRequest.Render {
        { _, staging in
            let output = staging.appendingPathComponent("DSC00001.tiff")
            try Data("rendered".utf8).write(to: output)
            if FileManager.default.fileExists(atPath: fixture.xmp.path) {
                try Data(contentsOf: fixture.xmp).write(
                    to: staging.appendingPathComponent("DSC00001.xmp")
                )
            }
            return output
        }
    }

    private enum InjectedFailure: Error, Equatable {
        case signing
        case install
        case cleanup
    }

    nonisolated private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }

    nonisolated private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int { lock.withLock { count += 1; return count } }
    }

    private struct Fixture: Sendable {
        let root: URL
        let image: URL
        let memo: URL
        let xmp: URL
        let destination: URL
        let profile = "sony-ilce-1-v4"

        init(associated: Bool, withXMP: Bool) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RAWArchiveTransactionServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
            destination = root.appendingPathComponent("Archive", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            image = root.appendingPathComponent("DSC00001.ARW")
            memo = root.appendingPathComponent("DSC00001.WAV")
            xmp = root.appendingPathComponent("DSC00001.xmp")
            try Data("source-raw".utf8).write(to: image)
            try Data("memo".utf8).write(to: memo)
            if withXMP { try Data("source-xmp".utf8).write(to: xmp) }
            if associated {
                try VoiceMemoCompanionRepository().save(VoiceMemoAssociation(
                    profileIdentifier: profile,
                    imageURL: image,
                    memoURL: memo
                ))
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
