import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Deadline preflight service")
struct DeadlinePreflightServiceTests {
    private let root = URL(fileURLWithPath: "/deadline-preflight", isDirectory: true)

    @Test("Metadata, variables, sidecars, source, stale XMP, and C2PA stay typed and ordered")
    func perImageChecksAndOrdering() async throws {
        let validation = MetadataValidationProfile(
            name: "Wire",
            rules: [
                MetadataValidationRule(
                    id: "headline-required",
                    severity: .blocker,
                    requirement: .required(field: .headline)
                ),
                MetadataValidationRule(
                    id: "credit-recommended",
                    severity: .warning,
                    requirement: .required(field: .credit)
                ),
            ]
        )
        let profile = DeadlineProfile(
            name: "Wire",
            validationProfile: .snapshot(validation),
            metadataWriteStrategy: .originals
        )
        let url = root.appendingPathComponent("a.jpg")
        let item = DeadlinePreflightItemSnapshot(
            sourceURL: url,
            metadata: IPTCMetadata(description: "Caption {filename}"),
            sidecarState: .failed(message: "disk full"),
            source: DeadlineSourceSnapshot(isWritable: false),
            descriptiveConflict: .staleXMPSidecarDiffersFromEmbedded(detail: "XMP is older"),
            c2paConsequence: .originalWriteInvalidatesManifest
        )

        let report = try await DeadlinePreflightService().evaluate(.init(profile: profile, items: [item]))

        #expect(report.issues.map(\.code) == [
            .metadataValidation(
                ruleID: "\(url.standardizedFileURL.path)|headline-required|title",
                field: .headline
            ),
            .unresolvedVariable(field: .description),
            .sidecarFailed,
            .sourceNotWritable,
            .staleDescriptiveMetadataConflict,
            .c2pa(.originalWriteInvalidatesManifest),
            .metadataValidation(
                ruleID: "\(url.standardizedFileURL.path)|credit-recommended|credit",
                field: .credit
            ),
        ])
        #expect(report.nextIssue?.code == report.issues.first?.code)
        #expect(report.imageReports.first?.issues == report.issues)
        #expect(report.blockerCount == 6)
        #expect(report.warningCount == 1)
        #expect(try await DeadlinePreflightService().evaluate(.init(profile: profile, items: [item])) == report)
    }

    @Test("Pending writes and injected source facts do not touch the filesystem")
    func pendingAndSourceSnapshotChecks() async throws {
        let profile = DeadlineProfile(name: "Sources", metadataWriteStrategy: .originals)
        let report = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [
                .init(
                    sourceURL: root.appendingPathComponent("unreadable.xyz"),
                    sidecarState: .pending,
                    source: .init(isReadable: false, isWritable: false, isSupportedFormat: false)
                ),
                .init(
                    sourceURL: root.appendingPathComponent("decode.jpg"),
                    source: .init(canDecode: false)
                ),
                .init(
                    sourceURL: root.appendingPathComponent("missing.jpg"),
                    source: .init(isAvailable: false)
                ),
                .init(
                    sourceURL: root.appendingPathComponent("unknown-permissions.jpg"),
                    source: .init(isWritable: false, isWritabilityKnown: false)
                ),
            ]
        ))

        #expect(report.issues.map(\.code) == [
            .sidecarPending,
            .sourceUnreadable,
            .sourceNotWritable,
            .unsupportedSourceFormat,
            .sourceCannotDecode,
            .sourceUnavailable,
            .sourceWritabilityUnknown,
        ])
    }

    @Test("Rename planner findings include duplicate outputs and reservation conflicts")
    func renamePlanningChecks() async throws {
        let recipe = BatchRenameRecipe(name: "Same", components: [.literal("same.jpg")])
        let profile = DeadlineProfile(
            name: "Wire",
            rename: DeadlineRenameConfiguration(recipe: .snapshot(recipe), collisionPolicy: .block)
        )
        let a = root.appendingPathComponent("a.jpg")
        let b = root.appendingPathComponent("b.jpg")
        let report = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [.init(sourceURL: a), .init(sourceURL: b)]
        ))

        #expect(report.renamePlan?.reservedDestinationURLs.map(\.lastPathComponent) == ["same.jpg"])
        #expect(report.issues.contains {
            $0.imageIndex == 1 && $0.code == .rename(.duplicateTarget) && $0.severity == .blocker
        })
        #expect(report.isBlocked)
    }

    @Test("Unknown live rename and export facts block without hiding deterministic previews")
    func unknownLiveAdapterFacts() async throws {
        let profile = DeadlineProfile(
            name: "Uncaptured facts",
            rename: .init(
                recipe: .snapshot(BatchRenameRecipe(
                    name: "Preview",
                    components: [.literal("wire_"), .token(.originalFilename)]
                )),
                collisionPolicy: .block
            ),
            export: .snapshot(DeadlineExportSnapshot(
                sdrFormat: .jpeg,
                sdrQuality: 0.9,
                sdrGamut: .sRGB,
                hdrFormat: .jpegGainMap,
                hdrQuality: 0.9,
                hdrGamut: .displayP3,
                tiffCompression: .lzw,
                resolutionLimit: .original
            ))
        )
        let report = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [.init(sourceURL: root.appendingPathComponent("a.jpg"))],
            renameEnvironment: .init(caseSensitivity: .caseInsensitive, isComplete: false),
            exportCapabilities: .init(isKnown: false)
        ))

        #expect(report.renamePlan?.entries.first?.plannedDestinationImageURL?.lastPathComponent == "wire_a.jpg")
        #expect(report.issues.contains { $0.code == .renameEnvironmentUnavailable && $0.severity == .blocker })
        #expect(report.issues.contains { $0.code == .exportCapabilitiesUnknown && $0.severity == .blocker })
    }

    @Test("Export, staging, free-space, connection, and remote path snapshots are assessed")
    func exportAndBatchChecks() async throws {
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jxl,
            hdrQuality: 0.9,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels2048
        )
        let profile = DeadlineProfile(
            name: "Wire",
            export: .snapshot(export),
            destination: .init(connectionIdentifier: "wire", remotePathTemplate: "/{job}"),
            metadataWriteStrategy: .stagedCopies
        )
        let item = DeadlinePreflightItemSnapshot(
            sourceURL: root.appendingPathComponent("hdr.heic"),
            source: DeadlineSourceSnapshot(pixelWidth: 6_000, pixelHeight: 4_000, isHDR: true)
        )
        let sdrItem = DeadlinePreflightItemSnapshot(
            sourceURL: root.appendingPathComponent("sdr.jpg")
        )
        let request = DeadlinePreflightRequest(
            profile: profile,
            items: [item, sdrItem],
            exportCapabilities: .init(
                availableHDRFormats: [.heic10bit],
                availableSDRGamuts: [.displayP3],
                availableHDRGamuts: [.rec2020]
            ),
            delivery: .init(
                destinationAvailableBytes: 99,
                estimatedRequiredBytes: 100,
                stagingState: .insufficientSpace(requiredBytes: 100, availableBytes: 20),
                connections: ["wire": .unreachable(reason: "offline")],
                remotePathState: .unresolvedVariables(["job"])
            )
        )

        let report = try await DeadlinePreflightService().evaluate(request)

        #expect(report.issues.map(\.code) == [
            .unavailableHDRExportFormat(.jxl),
            .unavailableHDRExportGamut(.displayP3),
            .unavailableSDRExportGamut(.sRGB),
            .insufficientDestinationSpace(requiredBytes: 100, availableBytes: 99),
            .stagingInsufficientSpace(requiredBytes: 100, availableBytes: 20),
            .connectionUnreachable(identifier: "wire"),
            .remotePathHasUnresolvedVariables(["job"]),
            .exportWillDownscale(maximumDimension: 2_048),
        ])
    }

    @Test("Per-item encoded-size estimates block only when trustworthy and over the limit")
    func maximumOutputEstimateChecks() async throws {
        let maximum: Int64 = 1_000
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.9,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .original,
            maximumOutputByteCount: maximum
        )
        let report = try await DeadlinePreflightService().evaluate(.init(
            profile: DeadlineProfile(name: "Wire", export: .snapshot(export)),
            items: [
                .init(
                    sourceURL: root.appendingPathComponent("within.jpg"),
                    estimatedOutputByteCount: maximum
                ),
                .init(
                    sourceURL: root.appendingPathComponent("over.jpg"),
                    estimatedOutputByteCount: maximum + 1
                ),
                .init(sourceURL: root.appendingPathComponent("unknown.jpg")),
                .init(
                    sourceURL: root.appendingPathComponent("invalid-estimate.jpg"),
                    estimatedOutputByteCount: -1
                ),
            ],
            delivery: .init(
                destinationAvailableBytes: 10_000,
                estimatedRequiredBytes: 4_000,
                stagingState: .ready
            )
        ))

        #expect(report.issues.map(\.code) == [
            .estimatedOutputExceedsMaximum(estimatedBytes: 1_001, maximumBytes: 1_000),
            .outputSizeEstimateUnknown(maximumBytes: 1_000),
            .outputSizeEstimateUnknown(maximumBytes: 1_000),
        ])
        #expect(report.blockerCount == 1)
        #expect(report.warningCount == 2)
        #expect(report.imageReports[0].issues.isEmpty)

        var invalidExport = export
        invalidExport.maximumOutputByteCount = 0
        let invalid = try await DeadlinePreflightService().evaluate(.init(
            profile: DeadlineProfile(name: "Invalid", export: .snapshot(invalidExport)),
            items: [.init(
                sourceURL: root.appendingPathComponent("invalid-limit.jpg"),
                estimatedOutputByteCount: 0
            )],
            delivery: .init(
                destinationAvailableBytes: 1,
                estimatedRequiredBytes: 1,
                stagingState: .ready
            )
        ))
        #expect(invalid.issues.map(\.code) == [.invalidMaximumOutputByteCount])
    }

    @Test("Reference failures are explicit while resolved snapshots run normally")
    func referenceResolution() async throws {
        let profile = DeadlineProfile(
            name: "References",
            validationProfile: .reference(.init(identifier: "validation")),
            metadataTemplate: .init(
                source: .reference(.init(identifier: "template")),
                variablePolicy: .processAtDeadline
            ),
            requiredLists: [.init(identifier: "list")],
            rename: .init(recipe: .reference(.init(identifier: "rename")), collisionPolicy: .block),
            export: .reference(.init(identifier: "export"))
        )
        let missing = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [.init(sourceURL: root.appendingPathComponent("a.jpg"))],
            delivery: .init(stagingState: .ready)
        ))
        #expect(missing.issues.map(\.code) == [
            .missingValidationProfile(reference: "validation"),
            .missingMetadataTemplate(reference: "template"),
            .missingRequiredList(reference: "list"),
            .missingRenameRecipe(reference: "rename"),
            .missingExportConfiguration(reference: "export"),
            .deliverySizeUnknown,
        ])

        let resources = DeadlinePreflightResourceSnapshot(
            validationProfiles: ["validation": MetadataValidationProfile(name: "Empty", rules: [])],
            metadataTemplateIdentifiers: ["template"],
            listIdentifiers: ["list"],
            renameRecipes: ["rename": BatchRenameRecipe(name: "Keep", components: [.token(.originalFilename)])],
            exportConfigurations: ["export": DeadlineExportSnapshot(
                sdrFormat: .jpeg,
                sdrQuality: 0.9,
                sdrGamut: .sRGB,
                hdrFormat: .jpegGainMap,
                hdrQuality: 0.9,
                hdrGamut: .displayP3,
                tiffCompression: .lzw,
                resolutionLimit: .original
            )]
        )
        let resolved = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [.init(sourceURL: root.appendingPathComponent("a.jpg"))],
            resources: resources,
            delivery: .init(
                destinationAvailableBytes: 0,
                estimatedRequiredBytes: 0,
                stagingState: .ready
            )
        ))
        #expect(resolved.issues.isEmpty)
        #expect(resolved.renamePlan?.canExecute == true)
    }

    @Test("Structured contact and location placeholders retain typed paths")
    func structuredPlaceholderChecks() async throws {
        let profile = DeadlineProfile(name: "Structured")
        let metadata = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(
                addressLines: ["Desk", "{field:city}"],
                emails: ["{field:creator}"]
            ),
            locationsCreated: [EditorialLocation(city: "{gps:city}")],
            locationsShown: [EditorialLocation(identifiers: ["loc", "{filename}"])]
        )
        let report = try await DeadlinePreflightService().evaluate(.init(
            profile: profile,
            items: [.init(sourceURL: root.appendingPathComponent("a.jpg"), metadata: metadata)],
            delivery: .init(
                destinationAvailableBytes: 0,
                estimatedRequiredBytes: 0,
                stagingState: .ready
            )
        ))

        #expect(report.issues.map(\.code) == [
            .unresolvedStructuredVariable(field: .creatorContact(field: .addressLine, valueIndex: 1)),
            .unresolvedStructuredVariable(field: .creatorContact(field: .email, valueIndex: 0)),
            .unresolvedStructuredVariable(field: .locationCreated(locationIndex: 0, field: .city)),
            .unresolvedStructuredVariable(field: .locationShown(
                locationIndex: 0,
                field: .identifier,
                valueIndex: 1
            )),
        ])
    }

    @Test("Progress publishes immutable partial reports in deterministic pipeline order")
    func progressivePublicationOrder() async throws {
        let recorder = DeadlineProgressRecorder()
        let request = DeadlinePreflightRequest(
            profile: DeadlineProfile(name: "Progress"),
            items: (0..<3).map { index in
                var metadata = IPTCMetadata()
                if index == 1 { metadata.description = "{filename}" }
                return DeadlinePreflightItemSnapshot(
                    sourceURL: root.appendingPathComponent("\(index).jpg"),
                    metadata: metadata
                )
            },
            delivery: .init(
                destinationAvailableBytes: 0,
                estimatedRequiredBytes: 0,
                stagingState: .ready
            )
        )

        let final = try await DeadlinePreflightService().evaluate(request) { progress in
            await recorder.append(progress)
        }
        let snapshots = await recorder.values

        #expect(snapshots.map(\.stage) == [
            .resolvingDependencies,
            .checkingImages,
            .checkingImages,
            .checkingImages,
            .planningRename,
            .checkingDelivery,
        ])
        #expect(snapshots.map(\.completedImageCount) == [0, 1, 2, 3, 3, 3])
        #expect(snapshots.map(\.reportSnapshot.imageReports.count) == [0, 1, 2, 3, 3, 3])
        #expect(snapshots[2].reportSnapshot.blockerCount == 1)
        #expect(snapshots.last?.reportSnapshot == final)
    }

    @Test("Cancellation while a progress consumer is suspended prevents later stages and final output")
    func progressiveCancellation() async {
        let gate = DeadlineProgressGate()
        let request = DeadlinePreflightRequest(
            profile: DeadlineProfile(name: "Cancel progress"),
            items: (0..<10).map {
                DeadlinePreflightItemSnapshot(sourceURL: root.appendingPathComponent("\($0).jpg"))
            }
        )
        let task = Task {
            try await DeadlinePreflightService().evaluate(request) { progress in
                await gate.consume(progress)
            }
        }

        await gate.waitUntilBlocked()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let stages = await gate.stages
        #expect(stages == [.resolvingDependencies, .checkingImages])
    }

    @Test("A cancelled task stops before producing a report")
    func cancellation() async {
        let profile = DeadlineProfile(name: "Cancelled")
        let task = Task {
            try await DeadlinePreflightService().evaluate(.init(
                profile: profile,
                items: (0..<1_000).map {
                    .init(sourceURL: root.appendingPathComponent("\($0).jpg"))
                }
            ))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor DeadlineProgressRecorder {
    private(set) var values: [DeadlinePreflightProgress] = []

    func append(_ value: DeadlinePreflightProgress) {
        values.append(value)
    }
}

private actor DeadlineProgressGate {
    private(set) var stages: [DeadlinePreflightProgress.Stage] = []
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func consume(_ progress: DeadlinePreflightProgress) async {
        stages.append(progress.stage)
        guard progress.stage == .checkingImages, progress.completedImageCount == 1 else { return }
        isBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
