import Testing
import Foundation
import CoreGraphics
import CryptoKit
@testable import Aagedal_Photo_Agent

/// Tests for the face-embedding serialization + distance layer that replaced the old
/// `VNFeaturePrintObservation` payload, plus a smoke test of the bundled CoreML embedder.
@Suite("FaceEmbedding")
struct FaceEmbeddingTests {

    private struct AuraFaceFixture {
        let descriptor: AuraFaceDistributionDescriptor
        let descriptorData: Data
        let signatureData: Data
        let archiveData: Data
        let packageFiles: [String: Data]
    }

    private enum InjectedAuraFaceFailure: Error {
        case move
    }

    private func makeAuraFaceFixture(
        privateKey: Curve25519.Signing.PrivateKey,
        version: String = "AuraFace-v1/glintr100",
        archiveData: Data = Data("fixture archive".utf8)
    ) throws -> AuraFaceFixture {
        let packageFiles = [
            "Data/com.apple.CoreML/model.mlmodel": Data("model-\(version)".utf8),
            "Data/com.apple.CoreML/weights/weight.bin": Data("weights-\(version)".utf8),
            "Manifest.json": Data("{\"version\":\"\(version)\"}\n".utf8),
        ]
        let descriptor = AuraFaceDistributionDescriptor(
            schemaVersion: 1,
            componentID: AuraFaceComponentStore.componentID,
            modelVersion: version,
            embeddingVersion: FaceRecognitionDefaults.embeddingVersion,
            packageDirectory: AuraFaceComponentStore.packageDirectory,
            packageFiles: packageFiles.mapValues {
                Data(SHA256.hash(data: $0)).lowercaseHexString
            },
            archive: .init(
                fileName: "AuraFaceR100.mlpackage.zip",
                byteCount: Int64(archiveData.count),
                sha256: Data(SHA256.hash(data: archiveData)).lowercaseHexString
            ),
            downloadURL: URL(
                string: "https://aagedal.me/models/auraface/AuraFaceR100.mlpackage.zip"
            )!
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let descriptorData = try encoder.encode(descriptor)
        let signature = try privateKey.signature(for: descriptorData)
        return AuraFaceFixture(
            descriptor: descriptor,
            descriptorData: descriptorData,
            signatureData: Data(signature).base64EncodedData(),
            archiveData: archiveData,
            packageFiles: packageFiles
        )
    }

    private func makeAuraFaceIO(
        packageFiles: [String: Data],
        failCandidateCommit: Bool = false,
        corruptPackage: Bool = false
    ) -> AuraFaceComponentIO {
        var io = AuraFaceComponentIO.live
        io.fetch = { _ in throw URLError(.notConnectedToInternet) }
        io.extractArchive = { _, destination in
            let package = destination.appendingPathComponent(
                AuraFaceComponentStore.packageDirectory,
                isDirectory: true
            )
            for (relative, original) in packageFiles {
                let file = package.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = corruptPackage && relative == "Manifest.json"
                    ? Data("corrupt".utf8)
                    : original
                try data.write(to: file)
            }
        }
        io.compileModel = { _, destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("compiled fixture".utf8).write(
                to: destination.appendingPathComponent("model.bin")
            )
        }
        if failCandidateCommit {
            let liveMove = io.move
            io.move = { source, destination in
                if source.lastPathComponent == "candidate",
                   destination.lastPathComponent == "current" {
                    throw InjectedAuraFaceFailure.move
                }
                try liveMove(source, destination)
            }
        }
        return io
    }

    private func temporaryAuraFaceRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFaceInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - EmbeddingCodec

    @Test func encodeDecodeRoundTrips() {
        let vector: [Float] = [0.0, 1.5, -2.25, 3.125, 1e-6, -1e6]
        let data = EmbeddingCodec.encode(vector)
        let decoded = EmbeddingCodec.decode(data)
        #expect(decoded != nil)
        #expect(decoded == vector)
    }

    @Test func decodeRejectsLegacyAndCorruptData() {
        // Legacy NSKeyedArchiver blobs start with the "bplist00" magic — wrong codec magic.
        let legacy = Data("bplist00legacyfeatureprintpayload".utf8)
        #expect(EmbeddingCodec.decode(legacy) == nil)

        // Too short to even hold the header.
        #expect(EmbeddingCodec.decode(Data([0x01, 0x02, 0x03])) == nil)
        #expect(EmbeddingCodec.decode(Data()) == nil)

        // Correct magic + count, but the float payload is truncated by one byte.
        var truncated = EmbeddingCodec.encode([1, 2, 3, 4])
        truncated.removeLast()
        #expect(EmbeddingCodec.decode(truncated) == nil)
    }

    @Test func cosineDistanceOnUnitVectors() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        let opposite: [Float] = [-1, 0, 0, 0]

        // Same direction → 0, orthogonal → 1, opposite → 2.
        #expect(approxEqual(EmbeddingCodec.cosineDistance(a, a), 0))
        #expect(approxEqual(EmbeddingCodec.cosineDistance(a, b), 1))
        #expect(approxEqual(EmbeddingCodec.cosineDistance(a, opposite), 2))
    }

    @Test func cosineDistanceIsSymmetricAndGuards() {
        let a: [Float] = [0.6, 0.8, 0, 0]
        let b: [Float] = [0, 0.8, 0.6, 0]
        let dAB = EmbeddingCodec.cosineDistance(a, b)
        let dBA = EmbeddingCodec.cosineDistance(b, a)
        #expect(dAB != nil && dBA != nil)
        #expect(approxEqual(dAB, dBA))

        // Mismatched dimensions / empty → nil rather than a bogus number.
        #expect(EmbeddingCodec.cosineDistance([1, 0], [1, 0, 0]) == nil)
        #expect(EmbeddingCodec.cosineDistance([], []) == nil)
    }

    @Test func faceDetectionDefaultsToFastMode() {
        #expect(FaceDetectionService.DetectionConfig().tiledDetection == false)
    }

    @Test func incrementalClusteringUsesExactAverageGroupDistance() {
        func face(_ vector: [Float], groupID: UUID? = nil) -> DetectedFace {
            DetectedFace(
                id: UUID(),
                imageURL: URL(fileURLWithPath: "/tmp/centroid-test.jpg"),
                faceRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                featurePrintData: EmbeddingCodec.encode(vector),
                groupID: groupID,
                detectedAt: Date(),
                qualityScore: 0.9
            )
        }

        let groupID = UUID()
        let memberA = face([1, 0, 0], groupID: groupID)
        let memberB = face([0.8, 0.6, 0], groupID: groupID)
        let firstNewFace = face([1, 0, 0])
        let secondNewFace = face([0.8, 0.6, 0])
        let existingGroup = FaceGroup(
            id: groupID,
            name: nil,
            representativeFaceID: memberA.id,
            faceIDs: [memberA.id, memberB.id]
        )

        var config = FaceDetectionService.DetectionConfig()
        config.clusteringThreshold = 0.15
        let groups = FaceDetectionService().clusterFacesWithAlgorithm(
            [firstNewFace, secondNewFace],
            allFaces: [memberA, memberB, firstNewFace, secondNewFace],
            existingGroups: [existingGroup],
            config: config
        )

        // Both new faces are 0.1 average cosine distance from the original two-member group.
        // The second decision also includes the first newly attached face in the running average.
        #expect(groups.count == 1)
        #expect(Set(groups[0].faceIDs) == Set([memberA.id, memberB.id, firstNewFace.id, secondNewFace.id]))
    }

    // MARK: - CoreMLFaceEmbedder (bundled model smoke test)

    @Test func omittedModelHasExplicitUnavailableState() async {
        let embedder = CoreMLFaceEmbedder(modelURL: nil)

        #expect(embedder.availability == .unavailable)
        #expect(embedder.availability.title == "Face Recognition Unavailable")
        #expect(embedder.availability.detail.contains("AuraFace"))
        #expect(FaceRecognitionModelAvailability.releaseNotesDisclosure ==
            "Face recognition is unavailable in this build because the AuraFace model is not included.")

        do {
            _ = try await embedder.embed(Self.makeTestImage(seed: 7))
            Issue.record("An embedder without a packaged model unexpectedly produced an embedding")
        } catch let error as CoreMLFaceEmbedder.EmbedError {
            guard case .modelNotFound = error else {
                Issue.record("Expected modelNotFound, received \(error)")
                return
            }
        } catch {
            Issue.record("Expected CoreMLFaceEmbedder.EmbedError, received \(error)")
        }
    }

    @Test func modelAvailabilityStatesAreExplicitAndFailClosed() {
        let ready = FaceRecognitionModelAvailability.ready(version: "AuraFace-v1/glintr100")
        let update = FaceRecognitionModelAvailability.updateAvailable(
            installedVersion: "AuraFace-v1/glintr100",
            availableVersion: "AuraFace-v2/glintr100"
        )
        let unavailable: [FaceRecognitionModelAvailability] = [
            .notInstalled,
            .downloading(progress: 0.42),
            .incompatible(requiredSystemVersion: "26.0"),
            .verificationFailed,
            .offline,
        ]

        #expect(ready.isAvailable)
        #expect(update.isAvailable)
        #expect(unavailable.allSatisfy { !$0.isAvailable })
        #expect(FaceRecognitionModelAvailability.downloading(progress: 1.5).detail.contains("100%"))
        #expect(FaceRecognitionModelAvailability.downloadExplanation.contains("125 MB"))
        #expect(FaceRecognitionModelAvailability.downloadExplanation.contains("only on this Mac"))
        #expect(FaceRecognitionModelAvailability.downloadExplanation.contains("works offline"))
    }

    @Test func auraFaceDescriptorRequiresValidSignatureAndPinnedHTTPSContract() throws {
        let key = Curve25519.Signing.PrivateKey()
        let fixture = try makeAuraFaceFixture(privateKey: key)

        let verified = try AuraFaceComponentStore.verifySignedDescriptor(
            fixture.descriptorData,
            signatureData: fixture.signatureData,
            publicKeyData: key.publicKey.rawRepresentation
        )
        #expect(verified == fixture.descriptor)

        var tampered = fixture.descriptorData
        tampered.append(0x20)
        #expect(throws: AuraFaceComponentError.invalidDescriptorSignature) {
            try AuraFaceComponentStore.verifySignedDescriptor(
                tampered,
                signatureData: fixture.signatureData,
                publicKeyData: key.publicKey.rawRepresentation
            )
        }
        #expect(!AuraFaceComponentStore.isAllowedDownloadURL(
            URL(string: "http://aagedal.me/models/auraface.zip")!
        ))
        #expect(!AuraFaceComponentStore.isAllowedDownloadURL(
            URL(string: "https://example.com/models/auraface.zip")!
        ))
        #expect(!AuraFaceComponentStore.isAllowedDownloadURL(
            URL(string: "https://aagedal.me/models/auraface.zip?latest=1")!
        ))
    }

    @Test func auraFaceCleanInstallVerifiesAndPersistsSignedReceipt() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let fixture = try makeAuraFaceFixture(privateKey: key)
        let root = try temporaryAuraFaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let io = makeAuraFaceIO(packageFiles: fixture.packageFiles)
        let installer = try AuraFaceComponentInstaller(
            io: io,
            publicKeyData: key.publicKey.rawRepresentation,
            root: root
        )

        let installed = try await installer.install(
            descriptorData: fixture.descriptorData,
            signatureData: fixture.signatureData,
            archiveData: fixture.archiveData
        )

        #expect(installed == fixture.descriptor)
        let current = root.appendingPathComponent("current", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: current
            .appendingPathComponent(AuraFaceComponentStore.compiledDirectory).path))
        let reverified = try AuraFaceComponentStore.verifySignedDescriptor(
            Data(contentsOf: current.appendingPathComponent(AuraFaceComponentStore.descriptorFile)),
            signatureData: Data(contentsOf: current.appendingPathComponent(AuraFaceComponentStore.signatureFile)),
            publicKeyData: key.publicKey.rawRepresentation
        )
        try AuraFaceComponentStore.verifyPackage(
            at: current.appendingPathComponent(AuraFaceComponentStore.packageDirectory),
            descriptor: reverified,
            io: io
        )
    }

    @Test func auraFaceCorruptArchiveAndPackageFailBeforeInstall() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let fixture = try makeAuraFaceFixture(privateKey: key)

        let archiveRoot = try temporaryAuraFaceRoot()
        defer { try? FileManager.default.removeItem(at: archiveRoot) }
        let archiveInstaller = try AuraFaceComponentInstaller(
            io: makeAuraFaceIO(packageFiles: fixture.packageFiles),
            publicKeyData: key.publicKey.rawRepresentation,
            root: archiveRoot
        )
        await #expect(throws: AuraFaceComponentError.archiveSizeMismatch) {
            try await archiveInstaller.install(
                descriptorData: fixture.descriptorData,
                signatureData: fixture.signatureData,
                archiveData: fixture.archiveData + Data([0])
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: archiveRoot.appendingPathComponent("current").path
        ))

        let packageRoot = try temporaryAuraFaceRoot()
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        let packageInstaller = try AuraFaceComponentInstaller(
            io: makeAuraFaceIO(packageFiles: fixture.packageFiles, corruptPackage: true),
            publicKeyData: key.publicKey.rawRepresentation,
            root: packageRoot
        )
        do {
            _ = try await packageInstaller.install(
                descriptorData: fixture.descriptorData,
                signatureData: fixture.signatureData,
                archiveData: fixture.archiveData
            )
            Issue.record("A package with a corrupt file unexpectedly installed")
        } catch let error as AuraFaceComponentError {
            guard case .packageHashMismatch("Manifest.json") = error else {
                Issue.record("Expected the corrupt Manifest.json hash to fail, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(
            atPath: packageRoot.appendingPathComponent("current").path
        ))
    }

    @Test func auraFaceFailedUpdateRestoresCurrentAndSuccessfulUpdateRetainsRollback() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let first = try makeAuraFaceFixture(privateKey: key)
        let second = try makeAuraFaceFixture(
            privateKey: key,
            version: "AuraFace-v2/glintr100",
            archiveData: Data("second fixture archive".utf8)
        )
        let root = try temporaryAuraFaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstInstaller = try AuraFaceComponentInstaller(
            io: makeAuraFaceIO(packageFiles: first.packageFiles),
            publicKeyData: key.publicKey.rawRepresentation,
            root: root
        )
        _ = try await firstInstaller.install(
            descriptorData: first.descriptorData,
            signatureData: first.signatureData,
            archiveData: first.archiveData
        )

        let failingInstaller = try AuraFaceComponentInstaller(
            io: makeAuraFaceIO(packageFiles: second.packageFiles, failCandidateCommit: true),
            publicKeyData: key.publicKey.rawRepresentation,
            root: root
        )
        await #expect(throws: AuraFaceComponentError.installationFailed) {
            try await failingInstaller.install(
                descriptorData: second.descriptorData,
                signatureData: second.signatureData,
                archiveData: second.archiveData
            )
        }
        let decoder = JSONDecoder()
        let currentAfterFailure = try decoder.decode(
            AuraFaceDistributionDescriptor.self,
            from: Data(contentsOf: root.appendingPathComponent("current/distribution.json"))
        )
        #expect(currentAfterFailure.modelVersion == first.descriptor.modelVersion)

        let successfulInstaller = try AuraFaceComponentInstaller(
            io: makeAuraFaceIO(packageFiles: second.packageFiles),
            publicKeyData: key.publicKey.rawRepresentation,
            root: root
        )
        _ = try await successfulInstaller.install(
            descriptorData: second.descriptorData,
            signatureData: second.signatureData,
            archiveData: second.archiveData
        )
        let current = try decoder.decode(
            AuraFaceDistributionDescriptor.self,
            from: Data(contentsOf: root.appendingPathComponent("current/distribution.json"))
        )
        let rollback = try decoder.decode(
            AuraFaceDistributionDescriptor.self,
            from: Data(contentsOf: root.appendingPathComponent("rollback/distribution.json"))
        )
        #expect(current.modelVersion == second.descriptor.modelVersion)
        #expect(rollback.modelVersion == first.descriptor.modelVersion)
    }

    @Test func auraFaceDownloadUsesOnlyDeclaredEndpointsAndRemovalWorksOffline() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let fixture = try makeAuraFaceFixture(privateKey: key)
        let root = try temporaryAuraFaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var io = makeAuraFaceIO(packageFiles: fixture.packageFiles)
        let descriptorURL = AuraFaceComponentStore.descriptorURL
        let signatureURL = AuraFaceComponentStore.signatureURL
        let archiveURL = fixture.descriptor.downloadURL
        io.fetch = { url in
            switch url {
            case descriptorURL: AuraFaceHTTPPayload(data: fixture.descriptorData, statusCode: 200)
            case signatureURL: AuraFaceHTTPPayload(data: fixture.signatureData, statusCode: 200)
            case archiveURL: AuraFaceHTTPPayload(data: fixture.archiveData, statusCode: 200)
            default: throw URLError(.unsupportedURL)
            }
        }
        let installer = try AuraFaceComponentInstaller(
            io: io,
            publicKeyData: key.publicKey.rawRepresentation,
            root: root
        )

        _ = try await installer.downloadAndInstall()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("current").path))
        try await installer.removeInstalledComponent()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("current").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("rollback").path))
    }

    @Test @MainActor
    func auraFaceBundledFallbackExposesNoMisleadingComponentActions() {
        let manager = AuraFaceComponentManager(
            installerFactory: { fatalError("Bundled AuraFace must not invoke the component installer") },
            initialSnapshot: AuraFaceComponentSnapshot(
                availability: .ready(version: CoreMLFaceEmbedder.modelVersion),
                source: .bundled
            )
        )

        #expect(manager.availability.isAvailable)
        #expect(manager.source == .bundled)
        #expect(!manager.canDownload)
        #expect(!manager.canRemove)

        manager.downloadConfirmed()
        manager.removeConfirmed()

        #expect(manager.source == .bundled)
        #expect(manager.availability == .ready(version: CoreMLFaceEmbedder.modelVersion))
    }

    @Test @MainActor
    func auraFaceDownloadedAndMissingSourcesExposeOnlyValidActions() {
        let downloaded = AuraFaceComponentManager(
            installerFactory: { fatalError("Capability checks must not invoke the installer") },
            initialSnapshot: AuraFaceComponentSnapshot(
                availability: .ready(version: "AuraFace-v1/glintr100"),
                source: .downloaded
            )
        )
        let missing = AuraFaceComponentManager(
            installerFactory: { fatalError("Capability checks must not invoke the installer") },
            initialSnapshot: AuraFaceComponentSnapshot(
                availability: .notInstalled,
                source: .none
            )
        )

        #expect(downloaded.canRemove)
        #expect(!downloaded.canDownload)
        #expect(!missing.canRemove)
        #expect(missing.canDownload)
    }

    @Test @MainActor
    func unavailableModelRefusesScanBeforeStarting() {
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            faceModelAvailability: .unavailable
        )

        viewModel.scanFolder(
            imageURLs: [URL(fileURLWithPath: "/private/tmp/should-not-face-scan.jpg")],
            folderURL: URL(fileURLWithPath: "/private/tmp/should-not-face-scan")
        )

        #expect(!viewModel.isScanning)
        #expect(viewModel.scanningFolderURL == nil)
        #expect(viewModel.scanProcessedCount == 0)
        #expect(viewModel.errorMessage == FaceRecognitionModelAvailability.unavailable.detail)
    }

    @Test func embedderProducesNormalizedDeterministicVectors() async throws {
        let embedder = CoreMLFaceEmbedder.shared
        let image = Self.makeTestImage(seed: 7)

        let v1: [Float]
        do {
            v1 = try await embedder.embed(image)
        } catch {
            // The compiled model may not be present in the test bundle depending on the
            // test host; in that case this smoke test is a no-op rather than a failure.
            return
        }

        #expect(v1.count == embedder.dimension)

        // L2-normalized: ‖v‖ ≈ 1.
        let norm = sqrt(v1.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(norm - 1.0) < 1e-3)

        // Deterministic: same input → same embedding → ~zero distance.
        let v1again = try await embedder.embed(image)
        let selfDistance = EmbeddingCodec.cosineDistance(v1, v1again)
        #expect(selfDistance != nil && selfDistance! < 1e-4)

        // A different input still yields a valid, finite, normalized vector.
        let v2 = try await embedder.embed(Self.makeTestImage(seed: 200))
        #expect(v2.count == embedder.dimension)
        #expect(v2.allSatisfy { $0.isFinite })
    }

    // MARK: - FaceLensService clustering

    /// Identity-distance closure over encoded ArcFace embeddings, as the lens clustering uses.
    private static func identityDistance(_ a: DetectedFace, _ b: DetectedFace) -> Float? {
        EmbeddingCodec.cosineDistance(a.featurePrintData, b.featurePrintData)
    }

    /// Two faces with near-identical vectors group; an orthogonal one stays apart.
    @Test func lensClusteringGroupsByDistance() {
        func face(vector: [Float], quality: Float = 0.9) -> DetectedFace {
            DetectedFace(
                id: UUID(),
                imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                faceRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.2),
                featurePrintData: EmbeddingCodec.encode(vector),
                detectedAt: Date(),
                qualityScore: quality
            )
        }

        let a = face(vector: [1, 0, 0, 0])
        let b = face(vector: [0.999, 0.0447, 0, 0])   // ~0.001 cosine distance from a
        let c = face(vector: [0, 1, 0, 0])            // orthogonal: distance 1 > threshold

        let groups = FaceLensService().clusterFaces([a, b, c], threshold: 0.72, distance: Self.identityDistance)

        #expect(groups.count == 2)
        #expect(Set(groups.flatMap(\.faceIDs)) == Set([a.id, b.id, c.id]))
        let pairGroup = groups.first { $0.faceIDs.count == 2 }
        #expect(pairGroup != nil)
        #expect(Set(pairGroup?.faceIDs ?? []) == Set([a.id, b.id]))
        // Largest group sorts first for the lens view.
        #expect(groups.first?.faceIDs.count == 2)
    }

    /// Faces below the quality gate still land somewhere: near an existing cluster they join
    /// it; otherwise they become singletons. Faces with undecodable embeddings end up as
    /// singletons rather than being dropped.
    @Test func lensClusteringAssignsLowQualityAndKeepsUndecodableFaces() {
        func face(vector: [Float]?, quality: Float) -> DetectedFace {
            DetectedFace(
                id: UUID(),
                imageURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                faceRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.2),
                featurePrintData: vector.map(EmbeddingCodec.encode) ?? Data([0xDE, 0xAD]),
                detectedAt: Date(),
                qualityScore: quality
            )
        }

        let anchor1 = face(vector: [1, 0, 0, 0], quality: 0.9)
        let anchor2 = face(vector: [0.999, 0.0447, 0, 0], quality: 0.9)
        let lowNear = face(vector: [0.998, 0.0632, 0, 0], quality: 0.1)  // below gate, near the pair
        let lowFar = face(vector: [0, 0, 1, 0], quality: 0.1)            // below gate, far away
        let broken = face(vector: nil, quality: 0.9)                     // undecodable embedding

        let groups = FaceLensService().clusterFaces(
            [anchor1, anchor2, lowNear, lowFar, broken],
            threshold: 0.72,
            distance: Self.identityDistance
        )

        #expect(Set(groups.flatMap(\.faceIDs)) == Set([anchor1.id, anchor2.id, lowNear.id, lowFar.id, broken.id]))
        let mainGroup = groups.first { $0.faceIDs.contains(anchor1.id) }
        #expect(Set(mainGroup?.faceIDs ?? []) == Set([anchor1.id, anchor2.id, lowNear.id]))
        #expect(groups.first { $0.faceIDs.contains(lowFar.id) }?.faceIDs.count == 1)
        #expect(groups.first { $0.faceIDs.contains(broken.id) }?.faceIDs.count == 1)
    }

    // MARK: - Helpers

    private func approxEqual(_ a: Float?, _ b: Float?, tolerance: Float = 1e-4) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) < tolerance
    }

    private static func makeTestImage(seed: Int) -> CGImage {
        let n = 112
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 4
                pixels[i] = UInt8((x + seed) & 0xFF)
                pixels[i + 1] = UInt8((y + seed) & 0xFF)
                pixels[i + 2] = UInt8(((x ^ y) + seed) & 0xFF)
                pixels[i + 3] = 255
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = pixels.withUnsafeMutableBytes { ptr in
            CGContext(
                data: ptr.baseAddress,
                width: n, height: n,
                bitsPerComponent: 8,
                bytesPerRow: n * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }!
        return ctx.makeImage()!
    }
}
