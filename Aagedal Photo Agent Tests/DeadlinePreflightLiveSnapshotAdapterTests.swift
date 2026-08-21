import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Deadline live preflight snapshot adapter")
struct DeadlinePreflightLiveSnapshotAdapterTests {
    private let renameRoot = URL(fileURLWithPath: "/live/assignment", isDirectory: true)
    private let stagingRoot = URL(fileURLWithPath: "/live/staging", isDirectory: true)

    @Test("live inventories project exact stable resources and observed local facts")
    func exactProjection() {
        let validationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let renameID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let validation = MetadataValidationProfile(name: "Desk", rules: [])
            .withID(validationID)
        let recipe = BatchRenameRecipe(name: "Wire", components: [.token(.originalFilename)])
        let preset = BatchRenameRecipePreset(id: renameID, recipe: recipe)
        let export = exportSnapshot()
        let existing = renameRoot.appendingPathComponent("existing.jpg")
        let sidecar = renameRoot.appendingPathComponent(".photo_metadata/existing.jpg.meta.json")
        let uppercaseConnectionID = "AAAAAAAA-8888-7777-6666-555555555555"
        let connectionID = uppercaseConnectionID.lowercased()
        let profile = DeadlineProfile(
            name: "Ready",
            validationProfile: .reference(.init(id: validationID)),
            requiredLists: [.init(identifier: DeadlineLiveResourceIdentifier.approvedKeywords)],
            rename: .init(recipe: .reference(.init(id: renameID)), collisionPolicy: .block),
            export: .reference(.init(identifier: DeadlineLiveResourceIdentifier.currentExportConfiguration)),
            destination: .init(connectionIdentifier: connectionID, remotePathTemplate: "/incoming"),
            metadataWriteStrategy: .stagedCopies
        )
        let adapter = makeAdapter(
            contents: [renameRoot: [existing], renameRoot.appendingPathComponent(".photo_metadata"): [sidecar]],
            capacity: 50_000,
            caseSensitive: true
        )
        let inventory = DeadlineLiveResourceInventory(
            validationProfiles: [validation],
            metadataTemplateIdentifiers: ["template"],
            availableRequiredListIdentifiers: [DeadlineLiveResourceIdentifier.approvedKeywords],
            renamePresets: [preset],
            exportConfigurations: [.init(
                identifier: DeadlineLiveResourceIdentifier.currentExportConfiguration,
                snapshot: export
            )]
        )

        let projection = adapter.project(.init(
            profile: profile,
            inventory: inventory,
            renameDirectoryURL: renameRoot,
            stagingRootURL: stagingRoot,
            estimatedRequiredBytes: 10_000,
            connectionIdentifiers: [connectionID, uppercaseConnectionID, "not-a-uuid"]
        ))

        #expect(projection.resources.validationProfiles[validationID.uuidString] == validation)
        #expect(projection.resources.validationProfiles[validationID.uuidString.lowercased()] == validation)
        #expect(projection.resources.metadataTemplateIdentifiers == ["template"])
        #expect(projection.resources.listIdentifiers == [DeadlineLiveResourceIdentifier.approvedKeywords])
        #expect(projection.resources.renameRecipes[renameID.uuidString.lowercased()] == recipe)
        #expect(projection.resources.exportConfigurations[DeadlineLiveResourceIdentifier.currentExportConfiguration] == export)
        #expect(projection.renameEnvironment.caseSensitivity == .caseSensitive)
        #expect(projection.renameEnvironment.isComplete)
        #expect(projection.renameEnvironment.existingURLs == [existing, sidecar])
        #expect(projection.exportCapabilities.isKnown)
        #expect(projection.exportCapabilities.availableSDRFormats == [.jpeg, .tiff])
        #expect(projection.exportCapabilities.availableHDRFormats == [.jpegGainMap, .tiff16bit])
        #expect(projection.delivery.stagingState == .ready)
        #expect(projection.delivery.stagingRootURL == stagingRoot)
        #expect(projection.delivery.stagingAvailableBytes == 50_000)
        #expect(projection.delivery.connections[connectionID] == .configuredReachabilityUnknown)
        #expect(projection.delivery.connections[uppercaseConnectionID] == nil)
        #expect(projection.delivery.connections["not-a-uuid"] == nil)
        #expect(projection.delivery.remotePathState == .valid(resolvedPath: "/incoming"))
    }

    @Test("missing referenced inventories remain typed preflight blockers")
    func missingResourcesBlock() async throws {
        let validationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let renameID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let profile = DeadlineProfile(
            name: "Missing",
            validationProfile: .reference(.init(id: validationID)),
            metadataTemplate: .init(
                source: .reference(.init(identifier: "missing-template")),
                variablePolicy: .preservePlaceholders
            ),
            requiredLists: [.init(identifier: "missing-list")],
            rename: .init(recipe: .reference(.init(id: renameID)), collisionPolicy: .block),
            export: .reference(.init(identifier: "missing-export")),
            metadataWriteStrategy: .xmpSidecars
        )
        let projection = makeAdapter().project(.init(
            profile: profile,
            inventory: DeadlineLiveResourceInventory(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))
        let report = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [.init(sourceURL: renameRoot.appendingPathComponent("image.jpg"))],
            resources: projection.resources,
            renameEnvironment: projection.renameEnvironment,
            exportCapabilities: projection.exportCapabilities,
            delivery: projection.delivery
        ))

        #expect(report.issues.map(\.code).contains(.missingValidationProfile(
            reference: validationID.uuidString.lowercased()
        )))
        #expect(report.issues.map(\.code).contains(.missingMetadataTemplate(reference: "missing-template")))
        #expect(report.issues.map(\.code).contains(.missingRequiredList(reference: "missing-list")))
        #expect(report.issues.map(\.code).contains(.missingRenameRecipe(
            reference: renameID.uuidString.lowercased()
        )))
        #expect(report.issues.map(\.code).contains(.missingExportConfiguration(reference: "missing-export")))
    }

    @Test("unknown rename case semantics never produce a complete collision inventory")
    func unknownRenameSemanticsRemainIncomplete() {
        let adapter = makeAdapter(caseSensitive: nil)
        let projection = adapter.project(.init(
            profile: DeadlineProfile(name: "Rename"),
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))

        #expect(!projection.renameEnvironment.isComplete)
    }

    @Test("staging readiness requires a successful write probe and measured capacity")
    func stagingRequiresObservedFacts() {
        let profile = DeadlineProfile(name: "Stage", metadataWriteStrategy: .stagedCopies)
        let failedWrite = makeAdapter(stagingPreparationFails: true).project(.init(
            profile: profile,
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: stagingRoot
        ))
        let unknownCapacity = makeAdapter(capacity: nil).project(.init(
            profile: profile,
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: stagingRoot
        ))
        let insufficient = makeAdapter(capacity: 99).project(.init(
            profile: profile,
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: stagingRoot,
            estimatedRequiredBytes: 100
        ))

        #expect(failedWrite.delivery.stagingState == .unavailable(
            reason: "The application staging root could not be verified."
        ))
        #expect(unknownCapacity.delivery.stagingState == .unavailable(
            reason: "The application staging root could not be verified."
        ))
        #expect(insufficient.delivery.stagingState == .insufficientSpace(
            requiredBytes: 100,
            availableBytes: 99
        ))
    }

    @Test("remote paths rejected by the production transport are invalid during live preflight")
    func remotePathSafetyMatchesTransport() {
        let connectionID = "99999999-8888-7777-6666-555555555555"
        for path in ["incoming", "//server/share", "/incoming/../escape", "/incoming/./desk", "/incoming\\desk", "/incoming?token=value"] {
            let profile = DeadlineProfile(
                name: "Unsafe remote path",
                destination: .init(
                    connectionIdentifier: connectionID,
                    remotePathTemplate: path
                ),
                metadataWriteStrategy: .stagedCopies
            )
            let projection = makeAdapter().project(.init(
                profile: profile,
                inventory: .init(),
                renameDirectoryURL: renameRoot,
                stagingRootURL: stagingRoot,
                connectionIdentifiers: [connectionID]
            ))
            guard case .invalid = projection.delivery.remotePathState else {
                Issue.record("Unsafe path was advertised as valid: \(path)")
                continue
            }
        }
    }

    @Test("capabilities are copied exactly from the production renderer matrix")
    func exactEncoderCapabilities() {
        let nativeOnly = makeAdapter(ffmpeg: false).project(.init(
            profile: DeadlineProfile(name: "Native"),
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))
        let withFFmpeg = makeAdapter(ffmpeg: true).project(.init(
            profile: DeadlineProfile(name: "Bundled"),
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))

        #expect(!nativeOnly.exportCapabilities.availableSDRFormats.contains(.jxl))
        #expect(!nativeOnly.exportCapabilities.availableHDRFormats.contains(.avifFFmpeg10bit))
        #expect(withFFmpeg.exportCapabilities.availableSDRFormats.suffix(2) == [.avifFFmpeg, .jxl])
        #expect(withFFmpeg.exportCapabilities.availableHDRFormats.contains(.jxl))
    }

    @Test("value revisions are stable and change with captured inventory")
    func revisions() {
        let adapter = makeAdapter()
        let profile = DeadlineProfile(name: "Revisions")
        let base = adapter.project(.init(
            profile: profile,
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))
        let identical = adapter.project(.init(
            profile: profile,
            inventory: .init(),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))
        let changed = adapter.project(.init(
            profile: profile,
            inventory: .init(availableRequiredListIdentifiers: ["list"]),
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil
        ))

        #expect(base == identical)
        #expect(base.resourceRevision != changed.resourceRevision)
    }

    @Test("replacement capture cancels its predecessor and suppresses stale publication")
    func cancellationAndLatestWins() async {
        let probe = DeadlineCaptureCancellationProbe()
        let coordinator = DeadlinePreflightLiveSnapshotCoordinator { request in
            if request.profile.name == "slow" {
                try await probe.runUntilCancelled()
            }
            return workspaceInput(for: request.profile)
        }
        async let stale = coordinator.latest(captureRequest(named: "slow"))
        // The complete Swift Testing bundle runs heavily in parallel; executor saturation can
        // delay this child task substantially even though the capture itself starts immediately
        // once scheduled. Wait for the explicit start signal instead of assuming a wall-clock
        // scheduling latency, while retaining a bounded failure path.
        let slowStarted = await probe.waitUntilStarted(timeout: .seconds(30))
        #expect(slowStarted)
        guard slowStarted else { return }

        let current = await coordinator.latest(captureRequest(named: "current"))
        let gateWatchdog = Task {
            do {
                try await Task.sleep(for: .seconds(5))
                await probe.expireGate()
            } catch {
                // The expected cancellation path completed before the watchdog was needed.
            }
        }
        let staleResult = await stale
        gateWatchdog.cancel()
        let wasCancelled = await probe.wasCancelled

        #expect(staleResult == nil)
        #expect(current?.request.profile.name == "current")
        #expect(wasCancelled)
    }

    @Test("capture projects exact source observations and never infers original writability")
    func sourceCapture() async throws {
        let source = renameRoot.appendingPathComponent("portrait.jpg")
        let adapter = makeAdapter()
        let profile = DeadlineProfile(name: "Originals", metadataWriteStrategy: .originals)
        let input = try await adapter.capture(.init(
            profile: profile,
            items: [DeadlineLiveSourceItem(
                sourceURL: source,
                metadata: IPTCMetadata(),
                sidecarState: .clean,
                renameContext: BatchRenameContext(originalFilename: "portrait.jpg"),
                byteCount: 123,
                isICloudDownloadPending: false,
                isSupportedFormat: true,
                isHDR: false,
                hasC2PA: true,
                exifOrientation: 6
            )],
            inventory: .init(),
            requiredListCandidates: [],
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil,
            useDefaultApplicationStagingRoot: false,
            estimatedRequiredBytes: nil,
            connectionIdentifiers: [],
            selectionSourceRevision: 1,
            metadataRevision: 2,
            profileRevision: 3,
            developSnapshots: [nil]
        ))
        let item = input.request.items[0]

        #expect(item.source.isAvailable)
        #expect(item.source.isReadable)
        #expect(item.source.canDecode)
        #expect(item.source.pixelWidth == 3_000)
        #expect(item.source.pixelHeight == 4_000)
        #expect(!item.source.isWritabilityKnown)
        #expect(!item.source.isWritable)
        #expect(item.c2paConsequence == .originalWriteInvalidatesManifest)
        #expect(input.cachePolicy == .bypass)
        #expect(input.sourceRevisions[0]?.canonicalURL == source.standardizedFileURL)
    }

    @Test("failed exact source hashing publishes no revision and cannot be sent")
    func failedSourceRevisionCaptureIsExplicit() async throws {
        let source = renameRoot.appendingPathComponent("unhashable.jpg")
        let input = try await makeAdapter(sourceRevisionFails: true).capture(.init(
            profile: DeadlineProfile(name: "Wire"),
            items: [DeadlineLiveSourceItem(
                sourceURL: source,
                metadata: IPTCMetadata(),
                sidecarState: .clean,
                renameContext: .init(originalFilename: source.lastPathComponent),
                byteCount: 123,
                isICloudDownloadPending: false,
                isSupportedFormat: true,
                isHDR: false,
                hasC2PA: false,
                exifOrientation: 1
            )],
            inventory: .init(),
            requiredListCandidates: [],
            renameDirectoryURL: renameRoot,
            stagingRootURL: nil,
            useDefaultApplicationStagingRoot: false,
            estimatedRequiredBytes: nil,
            connectionIdentifiers: [],
            selectionSourceRevision: 1,
            metadataRevision: 1,
            profileRevision: 1,
            developSnapshots: [nil]
        ))

        #expect(input.sourceRevisions == [nil])
    }

    @Test("live production matrix blocks non-staged write strategies with typed issues")
    func unsupportedLiveWriteStrategies() async throws {
        for strategy in [DeadlineMetadataWriteStrategy.originals, .xmpSidecars] {
            let profile = DeadlineProfile(name: strategy.rawValue, metadataWriteStrategy: strategy)
            let projection = makeAdapter().project(.init(
                profile: profile,
                inventory: .init(),
                renameDirectoryURL: renameRoot,
                stagingRootURL: nil
            ))
            let report = try await DeadlinePreflightService().evaluate(.init(
                profile: profile,
                items: [.init(
                    sourceURL: renameRoot.appendingPathComponent("image.jpg"),
                    source: .init(isWritable: false, isWritabilityKnown: false)
                )],
                resources: projection.resources,
                renameEnvironment: projection.renameEnvironment,
                exportCapabilities: projection.exportCapabilities,
                delivery: projection.delivery
            ))

            #expect(report.issues.map(\.code).contains(.unsupportedDeliveryWriteStrategy(strategy)))
            if strategy == .originals {
                #expect(report.issues.map(\.code).contains(.sourceWritabilityUnknown))
            }
        }
    }

    private func makeAdapter(
        contents: [URL: [URL]] = [:],
        capacity: Int64? = 50_000,
        caseSensitive: Bool? = false,
        stagingPreparationFails: Bool = false,
        sourceRevisionFails: Bool = false,
        ffmpeg: Bool = false
    ) -> DeadlinePreflightLiveSnapshotAdapter {
        DeadlinePreflightLiveSnapshotAdapter(
            fileSystem: DeadlineLiveFileSystem(
                itemExists: { _ in true },
                itemIsReadable: { _ in true },
                nativePixelSize: { _ in CGSize(width: 4_000, height: 3_000) },
                requiredListExists: { _ in false },
                defaultApplicationStagingRoot: { stagingRoot },
                directoryExists: { url in
                    url.standardizedFileURL == renameRoot.standardizedFileURL
                        || url.standardizedFileURL == stagingRoot.standardizedFileURL
                        || contents.keys.contains {
                            $0.standardizedFileURL.path == url.standardizedFileURL.path
                        }
                },
                directoryContents: { url in
                    contents.first {
                        $0.key.standardizedFileURL.path == url.standardizedFileURL.path
                    }?.value ?? []
                },
                volumeIsCaseSensitive: { _ in caseSensitive },
                availableCapacity: { _ in capacity },
                prepareAndVerifyApplicationStagingRoot: { _ in
                    if stagingPreparationFails {
                        throw DeadlineLiveSnapshotError.stagingWriteVerificationFailed(stagingRoot)
                    }
                }
            ),
            sourceRevisionCapture: DeadlineLiveSourceRevisionCapture { url, width, height, orientation in
                if sourceRevisionFails { throw CocoaError(.fileReadUnknown) }
                return SourceImageRevision(
                    canonicalURL: url.standardizedFileURL,
                    fileResourceIdentifier: nil,
                    filenameAtCreation: url.lastPathComponent,
                    byteCount: 123,
                    contentModificationDate: Date(timeIntervalSince1970: 1),
                    pixelWidth: width,
                    pixelHeight: height,
                    exifOrientation: orientation,
                    sha256: String(repeating: "a", count: 64),
                    hashCompletedAt: Date(timeIntervalSince1970: 2)
                )
            },
            productionExportCapabilities: {
                DeadlineExportCapabilitySnapshot(
                    isKnown: true,
                    availableSDRFormats: ffmpeg ? [.jpeg, .tiff, .avifFFmpeg, .jxl] : [.jpeg, .tiff],
                    availableHDRFormats: ffmpeg
                        ? [.jpegGainMap, .tiff16bit, .avifFFmpeg10bit, .jxl]
                        : [.jpegGainMap, .tiff16bit],
                    availableSDRGamuts: [.sRGB, .displayP3, .rec2020, .adobeRGB],
                    availableHDRGamuts: [.sRGB, .displayP3, .rec2020]
                )
            }
        )
    }

    private func exportSnapshot() -> DeadlineExportSnapshot {
        DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .heic10bit,
            hdrQuality: 0.8,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000
        )
    }
}

private actor DeadlineCaptureCancellationProbe {
    private(set) var wasStarted = false
    private(set) var wasCancelled = false
    private var gateWasReleased = false
    private var gateContinuation: CheckedContinuation<Void, Never>?

    func runUntilCancelled() async throws {
        wasStarted = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if gateWasReleased {
                    continuation.resume()
                } else {
                    gateContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.releaseGate() }
        }
        if Task.isCancelled {
            wasCancelled = true
            throw CancellationError()
        }
        throw DeadlineCaptureCancellationProbeError.gateExpired
    }

    func waitUntilStarted(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !wasStarted, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return wasStarted
    }

    func expireGate() {
        releaseGate()
    }

    private func releaseGate() {
        gateWasReleased = true
        gateContinuation?.resume()
        gateContinuation = nil
    }
}

private enum DeadlineCaptureCancellationProbeError: Error {
    case gateExpired
}

private func captureRequest(named name: String) -> DeadlinePreflightLiveCaptureRequest {
    DeadlinePreflightLiveCaptureRequest(
        profile: DeadlineProfile(name: name),
        items: [],
        inventory: .init(),
        requiredListCandidates: [],
        renameDirectoryURL: nil,
        stagingRootURL: nil,
        useDefaultApplicationStagingRoot: false,
        estimatedRequiredBytes: nil,
        connectionIdentifiers: [],
        selectionSourceRevision: 0,
        metadataRevision: 0,
        profileRevision: 0,
        developSnapshots: []
    )
}

private nonisolated func workspaceInput(for profile: DeadlineProfile) -> DeadlineWorkspaceInput {
    DeadlineWorkspaceInput(
        request: DeadlinePreflightRequest(profile: profile, items: []),
        revisionToken: DeadlinePreflightRevisionToken(
            selectionSourceRevision: 0,
            metadataRevision: 0,
            profileRevision: 0,
            resourceRevision: 0,
            renameEnvironmentRevision: 0,
            exportCapabilityRevision: 0,
            deliverySnapshotRevision: 0
        ),
        developSnapshots: [],
        sourceRevisions: [],
        cachePolicy: .bypass
    )
}

private extension MetadataValidationProfile {
    func withID(_ id: UUID) -> Self {
        MetadataValidationProfile(id: id, name: name, rules: rules)
    }
}
