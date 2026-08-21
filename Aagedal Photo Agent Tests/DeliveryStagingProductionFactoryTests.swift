import AppKit
import Foundation
import ImageIO
import SwiftExif
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Production staged-delivery adapters")
struct DeliveryStagingProductionFactoryTests {
    @Test("real JPEG staging uses frozen config, exact-byte verification, and preservation evidence")
    func realJPEGStaging() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let recorder = FrozenConfigurationRecorder()
        let renderer = DeliveryFrozenArtifactRenderer { _, _, _, configuration, outputDirectory in
            await recorder.record(configuration)
            return try makeProductionAdapterJPEG(
                in: outputDirectory, name: "source.jpg", width: 9, height: 5
            )
        }
        let coordinator = try DeliveryStagingProductionFactory(
            artifactRenderer: renderer
        ).makeCoordinator(for: fixture.plan)

        // These mutable defaults deliberately disagree with the plan. The adapter must pass the
        // frozen configuration and must not let the legacy renderer consult these values.
        UserDefaults.standard.set(0.11, forKey: UserDefaultsKeys.exportQualitySDR)
        UserDefaults.standard.set("rec2020", forKey: UserDefaultsKeys.exportColorGamutSDR)
        defer {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.exportQualitySDR)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.exportColorGamutSDR)
        }

        let originalBytes = try Data(contentsOf: fixture.sourceURL)
        let result = try await coordinator.stage(fixture.request)

        #expect(result.status == .completed)
        #expect(result.requiredBytes > 0)
        #expect(result.items.count == 1)
        let item = try #require(result.items.first)
        #expect(item.failure == nil)
        #expect(item.stage == .verified)
        #expect(item.checkedFields == IPTCMetadataVerificationField.writableFields)
        #expect(item.mismatchedFields.isEmpty)
        #expect(item.stagedSHA256?.count == 64)
        #expect(item.metadataPreservation?.mismatchedDomains == [])
        #expect(item.metadataPreservation?.isAcceptableForDelivery == true)
        #expect(item.renderSettings == DeliveryRenderSettings(
            formatIdentifier: "jpeg",
            colorSpaceIdentifier: "sRGB",
            pixelWidth: 9,
            pixelHeight: 5,
            bitDepth: 8,
            quality: 73
        ))

        let stagedURL = result.stagingDirectoryURL.appendingPathComponent(
            fixture.plan.items[0].stagedRelativePath
        )
        let stagedMetadata = try await SwiftExifReadService().readFullMetadata(url: stagedURL)
        #expect(stagedMetadata.title == "Frozen delivery headline")
        #expect(stagedMetadata.description == "Frozen delivery caption")
        #expect(try Data(contentsOf: fixture.sourceURL) == originalBytes)
        let currentSource = try await SourceImageRevision.capture(at: fixture.sourceURL)
        #expect(currentSource.relationship(to: fixture.plan.items[0].sourceRevision) == .exactRevision)

        let recordedConfiguration = await recorder.configuration
        let captured = try #require(recordedConfiguration)
        #expect(captured.sdrFormat == .jpeg)
        #expect(captured.sdrQuality == 0.73)
        #expect(captured.sdrGamut == .sRGB)
        #expect(captured.resolutionLimit == .pixels1600)
        #expect(captured.locationMode == .askOnSave)
    }

    @Test("source mutation during rendering is refused before descriptive write")
    func sourceMutationRefusal() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let renderer = DeliveryFrozenArtifactRenderer { source, _, _, _, outputDirectory in
            let rendered = try makeProductionAdapterJPEG(
                in: outputDirectory, name: "source.jpg", width: 8, height: 6
            )
            var bytes = try Data(contentsOf: source)
            bytes.append(0)
            try bytes.write(to: source)
            return rendered
        }
        let coordinator = try DeliveryStagingProductionFactory(
            artifactRenderer: renderer
        ).makeCoordinator(for: fixture.plan)
        let result = try await coordinator.stage(fixture.request)

        #expect(result.status == .failed)
        #expect(result.items[0].stage == .failed)
        #expect(result.items[0].failure?.code == .renderOrCopyFailed)
        #expect(result.items[0].stagedSHA256 == nil)
    }

    @Test("renderer-aware estimate gates capacity before rendering")
    func capacityGate() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let calls = RenderCallCounter()
        let renderer = DeliveryFrozenArtifactRenderer { _, _, _, _, outputDirectory in
            await calls.increment()
            return try makeProductionAdapterJPEG(
                in: outputDirectory, name: "source.jpg", width: 8, height: 6
            )
        }
        let constrainedFileSystem = DeliveryStagingFileSystem(
            availableCapacity: { _ in 1 },
            createUniqueBatchDirectory: DeliveryStagingFileSystem.live.createUniqueBatchDirectory,
            readStagedBytes: DeliveryStagingFileSystem.live.readStagedBytes,
            removeBatchDirectory: DeliveryStagingFileSystem.live.removeBatchDirectory
        )
        let coordinator = try DeliveryStagingProductionFactory(
            artifactRenderer: renderer,
            fileSystem: constrainedFileSystem
        ).makeCoordinator(for: fixture.plan)

        await #expect(throws: DeliveryStagingPreflightError.self) {
            try await coordinator.stage(fixture.request)
        }
        #expect(await calls.count == 0)
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.stagingRoot,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test("renderer cancellation yields a retained cancelled batch")
    func cancellation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = DeliveryFrozenArtifactRenderer { _, _, _, _, _ in
            throw CancellationError()
        }
        let coordinator = try DeliveryStagingProductionFactory(
            artifactRenderer: renderer
        ).makeCoordinator(for: fixture.plan)

        let result = try await coordinator.stage(fixture.request)
        #expect(result.status == .cancelled)
        #expect(result.items[0].stage == .cancelled)
        #expect(FileManager.default.fileExists(atPath: result.stagingDirectoryURL.path))
    }

    @Test("renderer output with a substituted color profile is refused")
    func colorProfileMismatch() async throws {
        let fixture = try await makeFixture(sdrGamut: .displayP3)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renderer = DeliveryFrozenArtifactRenderer { _, _, _, _, outputDirectory in
            try makeProductionAdapterJPEG(
                in: outputDirectory, name: "source.jpg", width: 8, height: 6
            )
        }
        let coordinator = try DeliveryStagingProductionFactory(
            artifactRenderer: renderer
        ).makeCoordinator(for: fixture.plan)

        let result = try await coordinator.stage(fixture.request)
        #expect(result.status == .failed)
        #expect(result.items[0].stage == .failed)
        #expect(result.items[0].failure?.code == .renderOrCopyFailed)
    }

    @Test("unsupported strategy, carriers, and substituted HDR gamut fail before staging")
    func unsupportedContracts() async throws {
        let sidecar = try await makeFixture(strategy: .xmpSidecars)
        defer { try? FileManager.default.removeItem(at: sidecar.directory) }
        #expect(throws: DeliveryStagingProductionError.sidecarsNotSupported) {
            _ = try DeliveryStagingProductionFactory().makeCoordinator(for: sidecar.plan)
        }

        let png = try await makeFixture(sdrFormat: .png)
        defer { try? FileManager.default.removeItem(at: png.directory) }
        #expect(throws: DeliveryStagingProductionError.unsupportedSDRFormat(.png)) {
            _ = try DeliveryStagingProductionFactory().makeCoordinator(for: png.plan)
        }

        let hdr = try await makeFixture(isHDR: true, hdrFormat: .heic10bit)
        defer { try? FileManager.default.removeItem(at: hdr.directory) }
        #expect(throws: DeliveryStagingProductionError.unsupportedHDRFormat(.heic10bit)) {
            _ = try DeliveryStagingProductionFactory().makeCoordinator(for: hdr.plan)
        }

        let substituted = try await makeFixture(
            isHDR: true,
            hdrFormat: .jpegGainMap,
            hdrGamut: .adobeRGB
        )
        defer { try? FileManager.default.removeItem(at: substituted.directory) }
        #expect(throws: DeliveryStagingProductionError.unsupportedHDRGamut(.adobeRGB)) {
            _ = try DeliveryStagingProductionFactory().makeCoordinator(for: substituted.plan)
        }
    }

    private func makeFixture(
        strategy: DeadlineMetadataWriteStrategy = .stagedCopies,
        sdrFormat: DeadlineExportSnapshot.SDRFormat = .jpeg,
        sdrGamut: DeadlineExportSnapshot.ColorGamut = .sRGB,
        isHDR: Bool = false,
        hdrFormat: DeadlineExportSnapshot.HDRFormat = .jpegGainMap,
        hdrGamut: DeadlineExportSnapshot.ColorGamut = .displayP3
    ) async throws -> ProductionStagingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionStaging-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let sourceURL = try makeProductionAdapterJPEG(
            in: directory, name: "source.jpg", width: 16, height: 12
        )

        var embedded = try ImageMetadata.read(from: sourceURL)
        embedded.iptc = IPTCData(datasets: [
            try IPTCDataSet(tag: .headline, stringValue: "Old controlled headline"),
            try IPTCDataSet(tag: .captionAbstract, stringValue: "Old controlled caption"),
            try IPTCDataSet(tag: .editStatus, stringValue: "unrelated-newsroom-value"),
        ])
        try embedded.write(to: sourceURL)

        let revision = try await SourceImageRevision.capture(
            at: sourceURL,
            pixelWidth: 16,
            pixelHeight: 12,
            exifOrientation: 1
        )
        let metadata = IPTCMetadata(
            title: "Frozen delivery headline",
            description: "Frozen delivery caption",
            creator: "Reporter",
            credit: "Newsroom"
        )
        let export = DeadlineExportSnapshot(
            sdrFormat: sdrFormat,
            sdrQuality: 0.73,
            sdrGamut: sdrGamut,
            hdrFormat: hdrFormat,
            hdrQuality: 0.81,
            hdrGamut: hdrGamut,
            tiffCompression: .lzw,
            resolutionLimit: .pixels1600
        )
        let connectionID = UUID().uuidString.lowercased()
        let profile = DeadlineProfile(
            name: "Production adapter fixture",
            validationProfile: .snapshot(MetadataValidationProfile(
                name: "No required fields",
                rules: []
            )),
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: connectionID,
                remotePathTemplate: "/incoming"
            ),
            metadataWriteStrategy: strategy
        )
        let preflightRequest = DeadlinePreflightRequest(
            profile: profile,
            items: [DeadlinePreflightItemSnapshot(
                sourceURL: sourceURL,
                metadata: metadata,
                source: DeadlineSourceSnapshot(
                    byteCount: revision.byteCount,
                    pixelWidth: 16,
                    pixelHeight: 12,
                    isHDR: isHDR
                )
            )],
            renameEnvironment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [],
                isComplete: true
            ),
            delivery: DeadlineBatchDeliverySnapshot(
                destinationAvailableBytes: 1_000_000,
                estimatedRequiredBytes: 100_000,
                stagingState: .ready,
                connections: [connectionID: .reachable],
                remotePathState: .valid(resolvedPath: "/incoming")
            )
        )
        let report = try await DeadlinePreflightService().evaluate(preflightRequest)
        let token = DeadlinePreflightRevisionToken(
            selectionSourceRevision: 1,
            metadataRevision: 1,
            profileRevision: 1,
            resourceRevision: 1,
            renameEnvironmentRevision: 1,
            exportCapabilityRevision: 1,
            deliverySnapshotRevision: 1
        )
        let plan = try DeliveryPlanningService().makePlan(DeliveryPlanningRequest(
            preflightRequest: preflightRequest,
            publication: DeadlinePreflightPublication(
                token: token,
                report: report,
                wasCached: false
            ),
            currentRevision: token,
            currentProfile: profile,
            items: [DeliveryPlanningItemInput(
                sourceRevision: revision,
                resolvedMetadata: metadata
            )]
        ))
        return ProductionStagingFixture(
            directory: directory,
            stagingRoot: stagingRoot,
            sourceURL: sourceURL,
            plan: plan,
            request: DeliveryStagingRequest(
                plan: plan,
                currentProfile: profile,
                stagingRootURL: stagingRoot
            )
        )
    }
}

private struct ProductionStagingFixture {
    let directory: URL
    let stagingRoot: URL
    let sourceURL: URL
    let plan: DeliveryPlan
    let request: DeliveryStagingRequest
}

private actor FrozenConfigurationRecorder {
    private(set) var configuration: AdvancedExportConfiguration?
    func record(_ configuration: AdvancedExportConfiguration) { self.configuration = configuration }
}

private actor RenderCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

nonisolated private func makeProductionAdapterJPEG(
    in directory: URL,
    name: String,
    width: Int,
    height: Int
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let paintedImage = context.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, paintedImage, [
        kCGImageDestinationLossyCompressionQuality: 0.9,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return url
}
