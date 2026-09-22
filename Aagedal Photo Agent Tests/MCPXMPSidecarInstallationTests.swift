import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Rooted XMP publication installation")
struct MCPXMPSidecarInstallationTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let folder: URL
        let photo: URL
        let xmp: URL
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let snapshot: MCPPhotoCarrierSnapshot
        let reservation: MCPProcessReservationLease
        let candidate = Data("<xmp>candidate</xmp>".utf8)

        init(existing: Bool = false) throws {
            let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(path) }
            root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("xmp-install-\(UUID().uuidString)")
            folder = root.appendingPathComponent("photos")
            photo = folder.appendingPathComponent("frame.jpg")
            xmp = folder.appendingPathComponent("frame.xmp")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("unchanged-photo".utf8).write(to: photo)
            if existing { try Data("<xmp>original</xmp>".utf8).write(to: xmp) }
            let box = MCPServerCoreTests.DataBox()
            authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
            try authority.addRoot(root)
            try authority.setEnabled(true)
            facade = MCPAutomationFacade(authorizationStore: authority)
            snapshot = try facade.capturePhotoSnapshot(path: photo.path)
            reservation = try MCPProcessReservation.acquirePhoto(photo)
        }
        deinit { reservation.release(); try? FileManager.default.removeItem(at: root) }
        func install(before: @Sendable () throws -> Void = {}) throws -> URL {
            try facade.installXMPSidecar(data: candidate, expected: snapshot,
                reservation: reservation, beforeInstall: before)
        }
        func assertNoStaging(in directory: URL? = nil) throws {
            #expect(try FileManager.default.contentsOfDirectory(atPath: (directory ?? folder).path)
                .allSatisfy { !$0.hasPrefix(".automation-xmp-") })
        }
    }

    @Test(arguments: [false, true]) func installsWithoutChangingPhotoOrDraft(existing: Bool) throws {
        let fixture = try Fixture(existing: existing)
        let installed = try fixture.install()
        #expect(installed.path == fixture.snapshot.target.url.deletingPathExtension().appendingPathExtension("xmp").path)
        let after = try fixture.facade.withPhotoSnapshot(path: fixture.photo.path, reservation: fixture.reservation) { $0 }
        #expect(after.xmpBytes == fixture.candidate)
        #expect(after.sourceRevision == fixture.snapshot.sourceRevision)
        #expect(after.appSidecarRevision == fixture.snapshot.appSidecarRevision)
        #expect(after.sourceBytes == fixture.snapshot.sourceBytes)
        try fixture.assertNoStaging()
    }

    @Test("Installed receipt callback identifies the exact installed generation")
    func installedReceiptIdentity() throws {
        let fixture = try Fixture(existing: true)
        try fixture.facade.installXMPSidecar(data: fixture.candidate, expected: fixture.snapshot,
            reservation: fixture.reservation, afterInstall: { snapshot in
                var identity = stat()
                #expect(Darwin.lstat(fixture.xmp.path, &identity) == 0)
                let identityPart = "\(identity.st_dev):\(identity.st_ino):\(identity.st_size):\(identity.st_mtimespec.tv_sec):\(identity.st_mtimespec.tv_nsec):\(identity.st_ctimespec.tv_sec):\(identity.st_ctimespec.tv_nsec):"
                var bytes = Data("apa-mcp-revision-v1:xmp:\(identityPart)".utf8)
                bytes.append(fixture.candidate)
                let token = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(snapshot.xmpSidecarRevision == token)
                #expect(snapshot.xmpBytes == fixture.candidate)
            })
        try fixture.assertNoStaging()
    }

    @Test func refusesExternalCarrierChangeAndCleansStage() throws {
        let fixture = try Fixture(existing: true)
        let changed = Data("external-editor".utf8)
        #expect(throws: (any Error).self) {
            try fixture.install { try changed.write(to: fixture.xmp) }
        }
        #expect(try Data(contentsOf: fixture.xmp) == changed)
        try fixture.assertNoStaging()
    }

    @Test func refusesRevokedAuthorityAndReleasedReservation() throws {
        for revoke in [false, true] {
            let fixture = try Fixture()
            #expect(throws: (any Error).self) {
                try fixture.install {
                    if revoke { try fixture.authority.setEnabled(false) }
                    else { fixture.reservation.release() }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.xmp.path))
            try fixture.assertNoStaging()
        }
    }

    @Test func swappedAncestorCannotRedirectPublicationOrCleanup() throws {
        let fixture = try Fixture(existing: true)
        let retained = fixture.root.appendingPathComponent("retained")
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try fixture.install {
                try FileManager.default.moveItem(at: fixture.folder, to: retained)
                try FileManager.default.createSymbolicLink(at: fixture.folder, withDestinationURL: outside)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try Data(contentsOf: retained.appendingPathComponent("frame.xmp")) == fixture.snapshot.xmpBytes)
        try fixture.assertNoStaging(in: retained)
    }

    @Test func refusesSameLengthStagingCorruption() throws {
        let fixture = try Fixture()
        #expect(throws: (any Error).self) {
            try fixture.install {
                let name = try #require(FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
                    .first { $0.hasPrefix(".automation-xmp-") })
                try Data(repeating: 0x78, count: fixture.candidate.count)
                    .write(to: fixture.folder.appendingPathComponent(name))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.xmp.path))
        try fixture.assertNoStaging()
    }

    @Test func symlinkCarrierRefusesWithoutTouchingDestination() throws {
        let fixture = try Fixture()
        let outside = fixture.root.appendingPathComponent("outside.xmp")
        let original = Data("outside".utf8)
        try original.write(to: outside)
        #expect(throws: (any Error).self) {
            try fixture.install { try FileManager.default.createSymbolicLink(at: fixture.xmp, withDestinationURL: outside) }
        }
        #expect(try Data(contentsOf: outside) == original)
        try fixture.assertNoStaging()
    }
}
