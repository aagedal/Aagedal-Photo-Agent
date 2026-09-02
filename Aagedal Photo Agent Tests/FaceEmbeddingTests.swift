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
            .checking,
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
        #expect(FaceRecognitionModelAvailability.checking.detail.contains("Checking"))
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

    @Test
    func auraFaceDynamicEmbedderPublishesOnlyPreResolvedModelURLs() {
        let embedder = CoreMLFaceEmbedder(
            modelURL: nil,
            allowsDynamicResolution: true,
            isResolutionPending: true
        )
        let resolvedURL = URL(fileURLWithPath: "/private/tmp/verified-auraface.mlmodelc")

        #expect(embedder.availability == .checking)
        embedder.publishResolvedModelURL(resolvedURL)
        #expect(embedder.availability.isAvailable)
        embedder.publishResolvedModelURL(nil)
        #expect(embedder.availability == .notInstalled)
    }

    @Test @MainActor
    func auraFaceComponentProbeRunsOffMainAndRejectsSupersededResult() async {
        let staleURL = URL(fileURLWithPath: "/private/tmp/stale-auraface.mlmodelc")
        let probe = AuraFaceResolutionProbe(resolutions: [
            AuraFaceComponentResolution(
                snapshot: AuraFaceComponentSnapshot(
                    availability: .ready(version: "stale"),
                    source: .downloaded
                ),
                modelURL: staleURL
            ),
            AuraFaceComponentResolution(
                snapshot: AuraFaceComponentSnapshot(
                    availability: .notInstalled,
                    source: .none
                ),
                modelURL: nil
            ),
        ])
        let published = AuraFacePublishedURLProbe()
        let service = AuraFaceComponentProbeService(resolver: probe.resolve)
        let manager = AuraFaceComponentManager(
            installerFactory: { fatalError("A component probe must not invoke the installer") },
            probeService: service,
            modelPublisher: published.record
        )

        #expect(manager.availability == .checking)
        #expect(await probe.waitUntilCallCount(1))
        #expect(!probe.ranOnMainThread)

        manager.refresh()
        for _ in 0..<20 { await Task.yield() }
        #expect(probe.callCount == 1)

        probe.releaseFirstCall()
        #expect(await probe.waitUntilCallCount(2))
        for _ in 0..<100 where manager.availability == .checking {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(probe.maximumConcurrentCalls == 1)
        #expect(manager.availability == .notInstalled)
        #expect(manager.source == .none)
        #expect(published.urls == [nil])
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

private nonisolated final class FaceFolderLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeCount = 0
    private var storedMaximumActiveCount = 0
    private var didStart = false
    private var isReleased = false

    func block() {
        condition.lock()
        activeCount += 1
        storedMaximumActiveCount = max(storedMaximumActiveCount, activeCount)
        didStart = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
        activeCount -= 1
        condition.unlock()
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var maximumActiveCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedMaximumActiveCount
    }

    private var started: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didStart
    }
}

private nonisolated final class FaceFolderLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedThumbnailIDs: [UUID] = []
    private var storedRanOnMainThread = false

    func recordDocumentRead() {
        lock.lock()
        storedRanOnMainThread = storedRanOnMainThread || Thread.isMainThread
        lock.unlock()
    }

    func recordThumbnailRead(_ faceID: UUID) {
        lock.lock()
        storedRanOnMainThread = storedRanOnMainThread || Thread.isMainThread
        storedThumbnailIDs.append(faceID)
        lock.unlock()
    }

    var thumbnailIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return storedThumbnailIDs
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedRanOnMainThread
    }
}

private nonisolated final class FaceDataPersistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var storedRanOnMainThread = false

    func record(_ event: String) {
        lock.lock()
        storedEvents.append(event)
        storedRanOnMainThread = storedRanOnMainThread || Thread.isMainThread
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedRanOnMainThread
    }
}

private nonisolated final class FaceFileSignatureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let signatures: [URL: FileSignature]
    private var storedURLs: [URL] = []
    private var storedRanOnMainThread = false

    init(signatures: [URL: FileSignature]) {
        self.signatures = signatures
    }

    func read(_ url: URL) -> FileSignature? {
        lock.lock()
        storedURLs.append(url)
        storedRanOnMainThread = storedRanOnMainThread || Thread.isMainThread
        lock.unlock()
        return signatures[url]
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedRanOnMainThread
    }
}

private nonisolated func makeFaceFolderData(
    folder: URL,
    faceIDs: [UUID]
) -> FolderFaceData {
    let groupID = UUID()
    let faces = faceIDs.map { faceID in
        DetectedFace(
            id: faceID,
            imageURL: folder.appendingPathComponent("\(faceID.uuidString).jpg"),
            faceRect: .zero,
            featurePrintData: Data([1]),
            groupID: groupID,
            detectedAt: .distantPast
        )
    }
    let groups: [FaceGroup] = faceIDs.first.map { representativeID in
        [FaceGroup(
            id: groupID,
            name: nil,
            representativeFaceID: representativeID,
            faceIDs: faceIDs
        )]
    } ?? []
    return FolderFaceData(
        folderURL: folder,
        faces: faces,
        groups: groups,
        lastScanDate: .distantPast,
        scanComplete: true
    )
}

@Suite("Face scan file-signature boundary")
struct FaceScanFileSignatureServiceTests {
    @Test @MainActor
    func classificationReturnsOneImmutableSnapshotOffMainActor() async {
        let root = URL(fileURLWithPath: "/faces/signatures")
        let unchanged = root.appendingPathComponent("unchanged.jpg")
        let modified = root.appendingPathComponent("modified.jpg")
        let added = root.appendingPathComponent("added.jpg")
        let removed = root.appendingPathComponent("removed.jpg")
        let first = FileSignature(modificationDate: Date(timeIntervalSince1970: 1), fileSize: 10)
        let second = FileSignature(modificationDate: Date(timeIntervalSince1970: 2), fileSize: 20)
        let probe = FaceFileSignatureProbe(signatures: [
            unchanged: first,
            modified: second,
            added: first,
        ])
        let service = FaceScanFileSignatureService(readSignature: probe.read)

        let result = await service.classify(
            imageURLs: [unchanged, modified, added],
            existingSignatures: [
                unchanged.path: first,
                modified.path: first,
                removed.path: first,
            ]
        )

        guard case .complete(let classification) = result else {
            Issue.record("An uncancelled classification must complete")
            return
        }
        #expect(classification.imageURLsToScan == [modified, added])
        #expect(classification.removedOrModifiedPaths == [modified.path, removed.path])
        #expect(classification.unchangedPaths == [unchanged.path])
        #expect(probe.urls == [unchanged, modified, added])
        #expect(!probe.ranOnMainThread)
    }

    @Test
    func cancellationAfterAttributeReadReportsExactPrefix() async {
        let root = URL(fileURLWithPath: "/faces/signature-cancellation")
        let first = root.appendingPathComponent("first.jpg")
        let second = root.appendingPathComponent("second.jpg")
        let signature = FileSignature(modificationDate: .distantPast, fileSize: 1)
        let gate = FaceFolderLoadGate()
        let service = FaceScanFileSignatureService { _ in
            gate.block()
            return signature
        }
        let task = Task {
            await service.classify(imageURLs: [first, second], existingSignatures: [:])
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        task.cancel()
        gate.release()

        #expect(await task.value == .cancelled(processedFileCount: 1, requestedFileCount: 2))
    }

    @Test
    func actorSerializesClassificationAndCaptureReads() async {
        let gate = FaceFolderLoadGate()
        let url = URL(fileURLWithPath: "/faces/serialized-signature.jpg")
        let signature = FileSignature(modificationDate: .distantPast, fileSize: 1)
        let service = FaceScanFileSignatureService { _ in
            gate.block()
            return signature
        }
        let classification = Task {
            await service.classify(imageURLs: [url], existingSignatures: [:])
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        let capture = Task { await service.signature(for: url) }
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.maximumActiveCount == 1)
        gate.release()

        _ = await classification.value
        #expect(await capture.value == .captured(imageURL: url, signature: signature))
        #expect(gate.maximumActiveCount == 1)
    }

    @Test
    func viewModelRoutesBothSignaturePathsThroughService() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/FaceRecognitionViewModel.swift"
            ),
            encoding: .utf8
        )
        let scanStart = try #require(source.range(of: "func scanFolder(imageURLs:"))
        let scanEnd = try #require(source.range(
            of: "    /// Suspends until the scan",
            range: scanStart.upperBound..<source.endIndex
        ))
        let scanSource = String(source[scanStart.lowerBound..<scanEnd.lowerBound])

        #expect(scanSource.contains("await fileSignatureService.classify("))
        #expect(scanSource.contains("await fileSignatureService.signature(for:"))
        #expect(scanSource.contains("classificationWasCancelled"))
        #expect(!scanSource.contains("FileManager.default.attributesOfItem"))
        #expect(!source.contains("func getFileSignature("))
        #expect(!source.contains("func categorizeFiles("))
    }
}

@Suite("Face folder-load filesystem boundary")
struct FaceFolderLoadServiceTests {
    @Test @MainActor
    func documentOnlyLoadReturnsExistenceEvidenceOffMainActor() async {
        let folder = URL(fileURLWithPath: "/faces/document-only")
        let data = makeFaceFolderData(folder: folder, faceIDs: [UUID()])
        let probe = FaceDataPersistenceProbe()
        let service = FaceDataFolderLoadService(
            loadFaceData: { _ in
                probe.record("read")
                return data
            },
            faceDataExists: { _ in
                probe.record("exists")
                return true
            }
        )

        guard case .complete(let evidence) = await service.loadDocument(folderURL: folder) else {
            Issue.record("An uncancelled document load must complete")
            return
        }
        #expect(evidence.documentExisted)
        #expect(evidence.faceData?.folderURL == folder)
        #expect(probe.events == ["exists", "read"])
        #expect(!probe.ranOnMainThread)
    }

    @Test @MainActor
    func folderLoadReadsEveryThumbnailOffMainActor() async throws {
        let folder = URL(fileURLWithPath: "/faces/current")
        let firstID = UUID()
        let secondID = UUID()
        let data = makeFaceFolderData(folder: folder, faceIDs: [firstID, secondID])
        let probe = FaceFolderLoadProbe()
        let service = FaceDataFolderLoadService(
            loadFaceData: { _ in
                probe.recordDocumentRead()
                return data
            },
            loadThumbnail: { faceID, _ in
                probe.recordThumbnailRead(faceID)
                return Data(faceID.uuidString.utf8)
            }
        )

        let result = await service.load(folderURL: folder, cleanupPolicy: .never)
        let evidence: FaceDataFolderLoadEvidence
        switch result {
        case .complete(let complete):
            evidence = complete
        case .cancelled:
            Issue.record("An uncancelled folder load must complete")
            return
        }

        #expect(evidence.faceData?.folderURL == folder)
        #expect(evidence.requestedThumbnailCount == 2)
        #expect(evidence.processedThumbnailCount == 2)
        #expect(Set(evidence.thumbnailData.keys) == [firstID, secondID])
        #expect(probe.thumbnailIDs == [firstID, secondID])
        #expect(!probe.ranOnMainThread)
    }

    @Test
    func cancellationAfterThumbnailReadReturnsExactPrefix() async {
        let folder = URL(fileURLWithPath: "/faces/cancelled")
        let faceIDs = [UUID(), UUID()]
        let data = makeFaceFolderData(folder: folder, faceIDs: faceIDs)
        let gate = FaceFolderLoadGate()
        let service = FaceDataFolderLoadService(
            loadFaceData: { _ in data },
            loadThumbnail: { _, _ in
                gate.block()
                return Data([1])
            }
        )
        let task = Task {
            await service.load(folderURL: folder, cleanupPolicy: .never)
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        task.cancel()
        gate.release()

        switch await task.value {
        case .complete:
            Issue.record("A cancelled thumbnail scan must not return complete evidence")
        case .cancelled(let evidence):
            #expect(evidence.requestedThumbnailCount == 2)
            #expect(evidence.processedThumbnailCount == 0)
        }
    }

    @Test
    func folderLoadActorSerializesOverlappingReads() async {
        let gate = FaceFolderLoadGate()
        let folder = URL(fileURLWithPath: "/faces/serialized")
        let service = FaceDataFolderLoadService(
            loadFaceData: { folder in
                gate.block()
                return makeFaceFolderData(folder: folder, faceIDs: [])
            }
        )
        let first = Task { await service.load(folderURL: folder, cleanupPolicy: .never) }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        let second = Task {
            await service.load(
                folderURL: folder.appendingPathComponent("second"),
                cleanupPolicy: .never
            )
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.maximumActiveCount == 1)
        gate.release()

        _ = await first.value
        _ = await second.value
        #expect(gate.maximumActiveCount == 1)
    }

    @Test
    func cancellationAfterExpiredDataDeletionReportsDurableCleanup() async {
        let folder = URL(fileURLWithPath: "/faces/expired")
        let data = makeFaceFolderData(folder: folder, faceIDs: [UUID()])
        let gate = FaceFolderLoadGate()
        let service = FaceDataFolderLoadService(
            loadFaceData: { _ in data },
            deleteFaceData: { _ in gate.block() },
            currentDate: { .now }
        )
        let task = Task {
            await service.load(folderURL: folder, cleanupPolicy: .sevenDays)
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        task.cancel()
        gate.release()

        switch await task.value {
        case .cancelled:
            Issue.record("A committed cleanup must not be presented as if nothing changed")
        case .complete(let evidence):
            #expect(evidence.faceData == nil)
            #expect(evidence.thumbnailData.isEmpty)
            #expect(evidence.cleanupDisposition == .deleted(
                cancellationRequestedAfterCommit: true
            ))
        }
    }

    @Test @MainActor
    func viewModelRejectsSupersededFolderAndUsesCacheOnlyLookup() async {
        let firstFolder = URL(fileURLWithPath: "/faces/first")
        let secondFolder = URL(fileURLWithPath: "/faces/second")
        let firstID = UUID()
        let secondID = UUID()
        let gate = FaceFolderLoadGate()
        let probe = FaceFolderLoadProbe()
        let service = FaceDataFolderLoadService(
            loadFaceData: { folder in
                probe.recordDocumentRead()
                if folder == firstFolder { gate.block() }
                return makeFaceFolderData(
                    folder: folder,
                    faceIDs: [folder == firstFolder ? firstID : secondID]
                )
            },
            loadThumbnail: { faceID, _ in
                probe.recordThumbnailRead(faceID)
                return Data([0x00])
            }
        )
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            folderLoadService: service
        )

        viewModel.loadFaceData(for: firstFolder, cleanupPolicy: .never)
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        // The main actor remains available while the synchronous reader is blocked.
        viewModel.loadFaceData(for: secondFolder, cleanupPolicy: .never)
        #expect(viewModel.displayedFolderURL == secondFolder.standardizedFileURL)
        gate.release()
        await viewModel.waitForCurrentFaceDataLoad()

        #expect(viewModel.faceData?.folderURL == secondFolder)
        #expect(viewModel.faceData?.faces.map(\.id) == [secondID])
        #expect(probe.thumbnailIDs == [secondID])
        let readCount = probe.thumbnailIDs.count
        #expect(viewModel.thumbnailImage(for: secondID) == nil)
        #expect(viewModel.thumbnailImage(for: secondID) == nil)
        #expect(probe.thumbnailIDs.count == readCount)
        #expect(!probe.ranOnMainThread)
    }

    @Test
    func viewModelSourceKeepsFolderReadsBehindBoundary() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = workspace
            .appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("ViewModels", isDirectory: true)
            .appendingPathComponent("FaceRecognitionViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let loadSlice = try #require(source.range(
            of: "func loadFaceData(for folderURL: URL, cleanupPolicy: FaceCleanupPolicy)"
        )).lowerBound..<#require(source.range(
            of: "    func isScanning(folderURL: URL?) -> Bool"
        )).lowerBound
        let loadSource = String(source[loadSlice])
        let thumbnailSlice = try #require(source.range(
            of: "func thumbnailImage(for faceID: UUID) -> NSImage?"
        )).lowerBound..<source.endIndex
        let thumbnailSource = String(source[thumbnailSlice])

        #expect(loadSource.contains("await folderLoadService.load("))
        #expect(loadSource.contains("faceDataLoadRequestID == requestID"))
        #expect(!loadSource.contains("storageService.loadFaceData"))
        #expect(!loadSource.contains("storageService.applyCleanupIfNeeded"))
        #expect(!loadSource.contains("storageService.loadThumbnail"))
        #expect(thumbnailSource.contains("thumbnailCache.object(forKey:"))
        #expect(!thumbnailSource.contains("storageService.loadThumbnail"))
    }

    @Test @MainActor
    func persistenceCommitsDocumentBeforeThumbnailCleanupOffMainActor() async {
        let folder = URL(fileURLWithPath: "/faces/persisted")
        let faceID = UUID()
        let data = makeFaceFolderData(folder: folder, faceIDs: [])
        let probe = FaceDataPersistenceProbe()
        let service = FaceDataFolderLoadService(
            saveFaceData: { _ in probe.record("document") },
            deleteThumbnail: { deletedID, _ in
                probe.record("thumbnail:\(deletedID.uuidString)")
            }
        )

        let result = await service.persist(data, deletingThumbnailIDs: [faceID])
        guard case .committed(let evidence) = result else {
            Issue.record("An uncancelled persistence request must commit")
            return
        }

        #expect(evidence.documentCommitted)
        #expect(evidence.requestedThumbnailDeletionCount == 1)
        #expect(evidence.deletedThumbnailIDs == [faceID])
        #expect(evidence.thumbnailFailures.isEmpty)
        #expect(!evidence.cancellationRequestedAfterCommit)
        #expect(probe.events == ["document", "thumbnail:\(faceID.uuidString)"])
        #expect(!probe.ranOnMainThread)
    }

    @Test
    func cancellationAfterDocumentWritePreservesDurableCommitEvidence() async {
        let folder = URL(fileURLWithPath: "/faces/cancelled-persistence")
        let faceID = UUID()
        let data = makeFaceFolderData(folder: folder, faceIDs: [])
        let gate = FaceFolderLoadGate()
        let probe = FaceDataPersistenceProbe()
        let service = FaceDataFolderLoadService(
            saveFaceData: { _ in
                probe.record("document")
                gate.block()
            },
            deleteThumbnail: { _, _ in probe.record("thumbnail") }
        )
        let task = Task {
            await service.persist(data, deletingThumbnailIDs: [faceID])
        }
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        task.cancel()
        gate.release()

        guard case .committed(let evidence) = await task.value else {
            Issue.record("Cancellation after the write must retain its durable commit")
            return
        }
        #expect(evidence.documentCommitted)
        #expect(evidence.deletedThumbnailIDs.isEmpty)
        #expect(evidence.cancellationRequestedAfterCommit)
        #expect(probe.events == ["document"])
    }

    @Test @MainActor
    func viewModelMutationPublishesImmediatelyAndPersistsOffMainActor() async throws {
        let folder = URL(fileURLWithPath: "/faces/view-model-persistence")
        let faceID = UUID()
        let data = makeFaceFolderData(folder: folder, faceIDs: [faceID])
        let groupID = try #require(data.groups.first?.id)
        let gate = FaceFolderLoadGate()
        let probe = FaceDataPersistenceProbe()
        let service = FaceDataFolderLoadService(
            saveFaceData: { _ in
                probe.record("document")
                gate.block()
            }
        )
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            folderLoadService: service
        )
        viewModel.faceData = data

        viewModel.nameGroup(groupID, name: "Immediate")
        #expect(viewModel.faceData?.groups.first?.name == "Immediate")
        defer { gate.release() }
        #expect(await gate.waitUntilStarted())
        // Reaching this assertion proves the blocked Foundation writer did not occupy MainActor.
        #expect(viewModel.faceData?.groups.first?.name == "Immediate")
        gate.release()
        await viewModel.waitForCurrentFaceDataPersistence()

        #expect(probe.events == ["document"])
        #expect(!probe.ranOnMainThread)
    }

    @Test @MainActor
    func rapidViewModelMutationsPersistInVisibleRevisionOrder() async throws {
        let folder = URL(fileURLWithPath: "/faces/ordered-persistence")
        let faceID = UUID()
        let data = makeFaceFolderData(folder: folder, faceIDs: [faceID])
        let groupID = try #require(data.groups.first?.id)
        let probe = FaceDataPersistenceProbe()
        let service = FaceDataFolderLoadService(
            saveFaceData: { snapshot in
                probe.record(snapshot.groups.first?.name ?? "unnamed")
            }
        )
        let viewModel = FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            folderLoadService: service
        )
        viewModel.faceData = data

        viewModel.nameGroup(groupID, name: "First")
        viewModel.nameGroup(groupID, name: "Second")
        await viewModel.waitForCurrentFaceDataPersistence()

        #expect(viewModel.faceData?.groups.first?.name == "Second")
        #expect(probe.events == ["First", "Second"])
        #expect(!probe.ranOnMainThread)
    }

    @Test
    func viewModelSourceKeepsInteractiveMutationsBehindPersistenceBoundary() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = workspace
            .appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("ViewModels", isDirectory: true)
            .appendingPathComponent("FaceRecognitionViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("scheduleFaceDataPersistence("))
        #expect(source.contains("scheduleFaceDataDeletion(for:"))
        #expect(source.contains("await folderLoadService.persistThumbnail("))
        #expect(source.contains("await folderLoadService.persist(folderData)"))
        #expect(!source.contains("storageService.saveFaceData"))
        #expect(!source.contains("storageService.saveThumbnail"))
        #expect(!source.contains("storageService.deleteThumbnail"))
        #expect(!source.contains("storageService.deleteFaceData"))
        #expect(!source.contains("storageService.loadFaceData"))
        #expect(!source.contains("storageService.loadThumbnail"))
    }

    @Test
    func appFaceDataCallersUseSerializedServiceInsteadOfStorageDirectly() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Aagedal Photo Agent/ViewModels/FaceRecognitionViewModel.swift",
            "Aagedal Photo Agent/ViewModels/MetadataViewModel.swift",
            "Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift",
            "Aagedal Photo Agent/Views/FTP/FTPUploadView.swift",
            "Aagedal Photo Agent/Services/RenameReassociationService.swift",
            "Aagedal Photo Agent/Services/FaceLensService.swift",
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: workspace.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(
                !source.contains("FaceDataStorageService()"),
                "\(relativePath) must use FaceDataFolderLoadService"
            )
        }
    }

}

@Suite("Face group deletion filesystem boundary")
@MainActor
struct FaceGroupDeletionTests {
    @Test("photo trash runs off MainActor and committed partial success still deletes the group")
    func partialTrashPreservesExistingDeletionSemantics() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("first.jpg")
        let secondURL = folder.appendingPathComponent("second.jpg")
        let fixture = makeFaceGroup(folder: folder, imageURLs: [firstURL, secondURL])
        let trashProbe = FaceGroupTrashProbe(failingURLs: [secondURL])
        let viewModel = makeViewModel(trashHandler: trashProbe)
        viewModel.faceData = fixture.data

        let result = await viewModel.deleteGroup(fixture.groupID, includePhotos: true)

        #expect(result.trashedPhotoURLs == [firstURL])
        #expect(result.failures.map(\.sourceURL) == [secondURL])
        #expect(!result.cancellationStoppedRemainingPhotos)
        #expect(result.faceDataDisposition == .applied)
        #expect(viewModel.faceData?.faces.isEmpty == true)
        #expect(viewModel.faceData?.groups.isEmpty == true)
        #expect(!trashProbe.ranOnMainThread)

        let persisted = try #require(FaceDataStorageService().loadFaceData(for: folder))
        #expect(persisted.faces.isEmpty)
        #expect(persisted.groups.isEmpty)
    }

    @Test("a stale trash completion reports commits without overwriting newer face data")
    func staleCompletionPreservesReplacementState() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalURL = folder.appendingPathComponent("original.jpg")
        let original = makeFaceGroup(folder: folder, imageURLs: [originalURL])
        let trashProbe = FaceGroupTrashProbe(blocksUntilReleased: true)
        let viewModel = makeViewModel(trashHandler: trashProbe)
        viewModel.faceData = original.data

        let deletion = Task {
            await viewModel.deleteGroup(original.groupID, includePhotos: true)
        }
        while !trashProbe.hasStarted {
            await Task.yield()
        }

        let replacementURL = folder.appendingPathComponent("replacement.jpg")
        let replacement = makeFaceGroup(folder: folder, imageURLs: [replacementURL])
        viewModel.faceData = replacement.data
        trashProbe.release()

        let result = await deletion.value
        #expect(result.trashedPhotoURLs == [originalURL])
        #expect(result.faceDataDisposition == .staleStatePreserved)
        #expect(viewModel.faceData?.groups.map(\.id) == [replacement.groupID])
        #expect(viewModel.faceData?.faces.map(\.imageURL) == [replacementURL])
        #expect(!trashProbe.ranOnMainThread)
    }

    @Test("pre-cancelled deletion leaves face data untouched")
    func preCancelledDeletionDoesNotMutate() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = makeFaceGroup(
            folder: folder,
            imageURLs: [folder.appendingPathComponent("cancelled.jpg")]
        )
        let trashProbe = FaceGroupTrashProbe()
        let viewModel = makeViewModel(trashHandler: trashProbe)
        viewModel.faceData = fixture.data

        let deletion = Task {
            await Task.yield()
            return await viewModel.deleteGroup(fixture.groupID, includePhotos: true)
        }
        deletion.cancel()

        let result = await deletion.value
        #expect(result.trashedPhotoURLs.isEmpty)
        #expect(result.failures.isEmpty)
        #expect(result.cancellationStoppedRemainingPhotos)
        #expect(result.faceDataDisposition == .cancelledBeforeMutation)
        #expect(viewModel.faceData?.groups.map(\.id) == [fixture.groupID])
        #expect(viewModel.faceData?.faces.count == 1)
        #expect(trashProbe.attemptedURLs.isEmpty)
    }

    private func makeViewModel(
        trashHandler: any ImageTrashHandling
    ) -> FaceRecognitionViewModel {
        FaceRecognitionViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            fileSystemService: FileSystemService(),
            imageTrashHandler: trashHandler
        )
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FaceGroupDeletion-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func makeFaceGroup(
        folder: URL,
        imageURLs: [URL]
    ) -> (data: FolderFaceData, groupID: UUID) {
        let groupID = UUID()
        let faces = imageURLs.map { imageURL in
            DetectedFace(
                id: UUID(),
                imageURL: imageURL,
                faceRect: .zero,
                featurePrintData: Data([1]),
                groupID: groupID,
                detectedAt: Date()
            )
        }
        let group = FaceGroup(
            id: groupID,
            name: "Test Group",
            representativeFaceID: faces[0].id,
            faceIDs: faces.map(\.id),
            userCreated: true,
            manualNumber: nil
        )
        return (
            FolderFaceData(
                folderURL: folder,
                faces: faces,
                groups: [group],
                lastScanDate: Date(),
                scanComplete: true
            ),
            groupID
        )
    }
}

nonisolated private final class FaceGroupTrashProbe: ImageTrashHandling, @unchecked Sendable {
    private enum Failure: Error {
        case injected
    }

    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let failingURLs: Set<URL>
    private let blocksUntilReleased: Bool
    private var started = false
    private var mainThreadObserved = false
    private var attempted: [URL] = []

    init(failingURLs: Set<URL> = [], blocksUntilReleased: Bool = false) {
        self.failingURLs = failingURLs
        self.blocksUntilReleased = blocksUntilReleased
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var ranOnMainThread: Bool {
        lock.withLock { mainThreadObserved }
    }

    var attemptedURLs: [URL] {
        lock.withLock { attempted }
    }

    func trashItem(at url: URL) throws {
        lock.withLock {
            started = true
            mainThreadObserved = mainThreadObserved || Thread.isMainThread
            attempted.append(url)
        }
        if blocksUntilReleased {
            releaseSemaphore.wait()
        }
        if failingURLs.contains(url) {
            throw Failure.injected
        }
    }

    func release() {
        releaseSemaphore.signal()
    }
}

nonisolated private final class AuraFaceResolutionProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let resolutions: [AuraFaceComponentResolution]
    private var recordedCallCount = 0
    private var activeCallCount = 0
    private var recordedMaximumConcurrentCalls = 0
    private var observedMainThread = false
    private var firstCallReleased = false

    init(resolutions: [AuraFaceComponentResolution]) {
        precondition(!resolutions.isEmpty)
        self.resolutions = resolutions
    }

    var callCount: Int {
        condition.withLock { recordedCallCount }
    }

    var maximumConcurrentCalls: Int {
        condition.withLock { recordedMaximumConcurrentCalls }
    }

    var ranOnMainThread: Bool {
        condition.withLock { observedMainThread }
    }

    func resolve() -> AuraFaceComponentResolution {
        condition.lock()
        let index = recordedCallCount
        recordedCallCount += 1
        activeCallCount += 1
        recordedMaximumConcurrentCalls = max(recordedMaximumConcurrentCalls, activeCallCount)
        observedMainThread = observedMainThread || Thread.isMainThread
        condition.broadcast()
        while index == 0, !firstCallReleased {
            condition.wait()
        }
        activeCallCount -= 1
        let resolution = resolutions[min(index, resolutions.count - 1)]
        condition.unlock()
        return resolution
    }

    func releaseFirstCall() {
        condition.withLock {
            firstCallReleased = true
            condition.broadcast()
        }
    }

    func waitUntilCallCount(_ expected: Int) async -> Bool {
        for _ in 0..<100 {
            if callCount >= expected { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

nonisolated private final class AuraFacePublishedURLProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL?] = []

    var urls: [URL?] {
        lock.withLock { recordedURLs }
    }

    func record(_ url: URL?) {
        lock.withLock { recordedURLs.append(url) }
    }
}
