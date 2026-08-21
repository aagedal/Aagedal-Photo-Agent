import Foundation
import Darwin
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Rename planning service")
struct RenamePlanningServiceTests {
    private let service = RenamePlanningService()
    private let root = URL(fileURLWithPath: "/rename-tests", isDirectory: true)

    @Test("Original-filename XMP work is explicit and frozen onto the correct artifact")
    func originalFilenameMetadataActions() throws {
        let jpeg = root.appendingPathComponent("camera.JPG")
        let jpegPlan = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: jpeg)],
            recipe: BatchRenameRecipe(
                name: "JPEG",
                components: [.literal("desk.JPG")],
                originalFilenameMetadata: .preserveInXMP
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        let jpegAction = try #require(jpegPlan.entries.first?.plannedArtifactActions.first)
        #expect(jpegAction.identifier == "image")
        #expect(jpegAction.originalFilenameMetadataMutation == RenameOriginalFilenameMetadataMutation(
            storage: .embeddedImageXMP,
            value: "camera.JPG"
        ))
        #expect(jpegAction.originalFilenameMetadataMutation?.namespaceURI == "http://ns.adobe.com/xap/1.0/mm/")
        #expect(jpegAction.originalFilenameMetadataMutation?.propertyName == "PreservedFileName")

        let raw = root.appendingPathComponent("camera.NEF")
        let sidecar = root.appendingPathComponent("camera.xmp")
        let rawPlan = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: raw)],
            recipe: BatchRenameRecipe(
                name: "RAW",
                components: [.literal("desk.NEF")],
                originalFilenameMetadata: .preserveInXMP
            ),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [sidecar]
            )
        )
        let rawEntry = try #require(rawPlan.entries.first)
        #expect(rawEntry.plannedArtifactActions.first(where: { $0.identifier == "image" })?
            .originalFilenameMetadataMutation == nil)
        #expect(rawEntry.plannedArtifactActions.first(where: { $0.identifier == "xmp" })?
            .originalFilenameMetadataMutation == RenameOriginalFilenameMetadataMutation(
                storage: .xmpSidecar,
                value: "camera.NEF"
            ))
        #expect(rawPlan.canExecute)

        let missingSidecar = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: raw)],
            recipe: BatchRenameRecipe(
                name: "RAW",
                components: [.literal("desk.NEF")],
                originalFilenameMetadata: .preserveInXMP
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        #expect(!missingSidecar.canExecute)
        #expect(missingSidecar.issues.contains { $0.code == .originalFilenameXMPSidecarMissing })
    }

    @Test("Visible input order allocates sequence values and preserves preview order")
    func visibleOrderControlsSequence() {
        let recipe = BatchRenameRecipe(
            name: "Sequence",
            components: [
                .literal("IMG_"),
                .token(.sequence(BatchRenameSequence(start: 100, step: 2, padding: 3))),
                .literal("."),
                .token(.originalExtension),
            ]
        )
        let items = ["z.jpg", "a.jpg", "m.jpg"].map {
            RenamePlanningItem(sourceImageURL: root.appendingPathComponent($0))
        }

        let plan = service.makePlan(
            items: items,
            recipe: recipe,
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )

        #expect(plan.entries.map(\.sourceImageURL.lastPathComponent) == ["z.jpg", "a.jpg", "m.jpg"])
        #expect(plan.entries.map(\.plannedDestinationImageURL?.lastPathComponent) == [
            "IMG_100.jpg", "IMG_102.jpg", "IMG_104.jpg",
        ])
        #expect(plan.entries.map(\.itemIndex) == [0, 1, 2])
        #expect(plan.canExecute)
    }

    @Test("Standard and caller-registered filename artifacts are previewed and reserved")
    func standardAndCustomArtifacts() throws {
        let source = root.appendingPathComponent("IMG_1.NEF")
        let xmp = root.appendingPathComponent("IMG_1.xmp")
        let currentJSON = root
            .appendingPathComponent(".photo_metadata", isDirectory: true)
            .appendingPathComponent("IMG_1.NEF.meta.json")
        let legacyJSON = root
            .appendingPathComponent(".photo_metadata", isDirectory: true)
            .appendingPathComponent("IMG_1.meta.json")
        let thumbnail = root
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("IMG_1.thumb")
        let custom = RenameArtifactRule(
            identifier: "thumbnail-cache",
            displayName: "Thumbnail cache",
            relativeDirectoryComponents: [".cache"],
            filenamePattern: RenameArtifactFilenamePattern(basis: .stem, suffix: ".thumb")
        )
        let registry = RenameArtifactRegistry.standard.registering(custom)
        let recipe = BatchRenameRecipe(
            name: "News",
            components: [.literal("news.NEF")]
        )

        let plan = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: recipe,
            artifactRegistry: registry,
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [xmp, currentJSON, legacyJSON, thumbnail]
            )
        )
        let entry = try #require(plan.entries.first)

        #expect(entry.plannedArtifactActions.map(\.identifier) == [
            "image", "xmp", "photo-metadata-current", "photo-metadata-legacy", "thumbnail-cache",
        ])
        #expect(entry.plannedArtifactActions.map(\.destinationURL.lastPathComponent) == [
            "news.NEF", "news.xmp", "news.NEF.meta.json", "news.meta.json", "news.thumb",
        ])
        #expect(plan.reservedDestinationURLs == entry.plannedArtifactActions.map(\.destinationURL))
        #expect(plan.associatedArtifactSummary.map(\.identifier) == [
            "xmp", "photo-metadata-current", "photo-metadata-legacy", "thumbnail-cache",
        ])
        #expect(plan.associatedArtifactSummary.allSatisfy {
            $0.presentCount == 1 && $0.renamedCount == 1 && $0.unchangedCount == 0
        })
    }

    @Test("Missing-value block, skip, and preserve outcomes stay structured")
    func missingValueOutcomes() throws {
        let source = root.appendingPathComponent("original.jpg")
        let components: [BatchRenameComponent] = [.token(.metadata(.event))]

        let blocked = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(
                name: "Block",
                components: components,
                missingValuePolicy: .block
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        #expect(blocked.entries.first?.disposition == .blocked)
        #expect(!blocked.canExecute)
        #expect(blocked.issues.first?.code == .missingValue(
            componentIndex: 0,
            token: .metadata(.event),
            resolution: .block
        ))

        let skipped = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(
                name: "Skip",
                components: components,
                missingValuePolicy: .skip
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        #expect(skipped.entries.first?.disposition == .skipped)
        #expect(skipped.canExecute)

        let preserved = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(
                name: "Preserve",
                components: components,
                missingValuePolicy: .preserveOriginal
            ),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )
        let preservedEntry = try #require(preserved.entries.first)
        #expect(preservedEntry.disposition == .unchanged)
        #expect(preservedEntry.plannedDestinationImageURL == source)
        #expect(preserved.reservedDestinationURLs == [source])
        #expect(preserved.canExecute)
    }

    @Test("Empty and unsafe recipe results are blocked before path planning")
    func invalidFilenames() {
        for (name, reason) in [
            ("", RenameInvalidFilenameReason.empty),
            ("..", .dotPathComponent),
            ("folder/name.jpg", .forbiddenCharacter),
            ("name. ", .trailingSpaceOrPeriod),
        ] {
            let plan = service.makePlan(
                items: [RenamePlanningItem(sourceImageURL: root.appendingPathComponent("a.jpg"))],
                recipe: BatchRenameRecipe(
                    name: "Invalid",
                    components: [.literal(name)],
                    sanitization: .disabled
                ),
                environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
            )
            #expect(plan.entries.first?.disposition == .blocked)
            #expect(plan.issues.contains { $0.code == .invalidFilename(reason) })
            #expect(!plan.canExecute)
        }
    }

    @Test("Duplicate targets are stable, blocking, and reserved only once")
    func duplicateTargets() {
        let items = ["a.jpg", "b.jpg"].map {
            RenamePlanningItem(sourceImageURL: root.appendingPathComponent($0))
        }
        let plan = service.makePlan(
            items: items,
            recipe: BatchRenameRecipe(name: "Same", components: [.literal("same.jpg")]),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseSensitive)
        )

        #expect(plan.entries.map(\.disposition) == [.rename, .blocked])
        #expect(plan.reservedDestinationURLs.map(\.lastPathComponent) == ["same.jpg"])
        #expect(plan.issues.contains {
            $0.itemIndex == 1 && $0.code == .duplicateTarget(
                otherItemIndex: 0,
                otherArtifactIdentifier: "image"
            )
        })
        #expect(!plan.canExecute)
    }

    @Test("Block, skip, and deterministic suffix policies handle existing destinations")
    func collisionPolicies() {
        let source = root.appendingPathComponent("old.jpg")
        let occupied = root.appendingPathComponent("event.jpg")
        let occupiedSuffix = root.appendingPathComponent("event 2.jpg")
        let environment = RenamePlanningEnvironment(
            caseSensitivity: .caseSensitive,
            existingURLs: [occupied, occupiedSuffix]
        )
        let recipe = BatchRenameRecipe(name: "Event", components: [.literal("event.jpg")])

        let blocked = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: recipe,
            environment: environment
        )
        #expect(blocked.entries.first?.disposition == .blocked)
        #expect(blocked.issues.contains { $0.code == .existingDestination(existingURL: occupied) })

        let skipped = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: recipe,
            collisionPolicy: .skip,
            environment: environment
        )
        #expect(skipped.entries.first?.disposition == .skipped)
        #expect(skipped.canExecute)
        #expect(skipped.reservedDestinationURLs.isEmpty)

        let suffixed = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: recipe,
            collisionPolicy: .appendDeterministicSuffix(),
            environment: environment
        )
        #expect(suffixed.entries.first?.requestedDestinationImageURL?.lastPathComponent == "event.jpg")
        #expect(suffixed.entries.first?.plannedDestinationImageURL?.lastPathComponent == "event 3.jpg")
        #expect(suffixed.entries.first?.disposition == .rename)
        #expect(suffixed.issues.contains {
            $0.code == .deterministicSuffixApplied(
                attempt: 3,
                requestedName: "event.jpg",
                resolvedName: "event 3.jpg"
            )
        })
        #expect(suffixed.canExecute)
    }

    @Test("Artifact destinations participate in suffix collision resolution")
    func artifactCollisionTriggersSuffix() throws {
        let source = root.appendingPathComponent("old.NEF")
        let sourceXMP = root.appendingPathComponent("old.xmp")
        let occupiedXMP = root.appendingPathComponent("news.xmp")
        let recipe = BatchRenameRecipe(name: "News", components: [.literal("news.NEF")])

        let plan = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: recipe,
            collisionPolicy: .appendDeterministicSuffix(),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [sourceXMP, occupiedXMP]
            )
        )
        let entry = try #require(plan.entries.first)

        #expect(entry.plannedDestinationImageURL?.lastPathComponent == "news 2.NEF")
        #expect(entry.plannedArtifactActions.first(where: { $0.identifier == "xmp" })?
            .destinationURL.lastPathComponent == "news 2.xmp")
        #expect(plan.reservedDestinationURLs.map(\.lastPathComponent) == ["news 2.NEF", "news 2.xmp"])
    }

    @Test("Case-only rename is warned while a different case-insensitive occupant blocks")
    func caseInsensitiveBehavior() {
        let source = root.appendingPathComponent("Photo.JPG")
        let caseOnly = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(name: "Case", components: [.literal("photo.JPG")]),
            environment: RenamePlanningEnvironment(caseSensitivity: .caseInsensitive)
        )
        #expect(caseOnly.entries.first?.disposition == .rename)
        #expect(caseOnly.issues.contains {
            $0.artifactIdentifier == "image" && $0.code == .caseOnlyRename
        })
        #expect(caseOnly.canExecute)

        let occupied = root.appendingPathComponent("TARGET.jpg")
        let insensitive = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(name: "Target", components: [.literal("target.jpg")]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: [occupied]
            )
        )
        #expect(insensitive.entries.first?.disposition == .blocked)
        #expect(insensitive.issues.contains {
            $0.code == .caseInsensitiveCollision(existingURL: occupied)
        })

        let sensitive = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(name: "Target", components: [.literal("target.jpg")]),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [occupied]
            )
        )
        #expect(sensitive.entries.first?.disposition == .rename)
        #expect(sensitive.canExecute)
    }

    @Test("Two-way swaps and their sidecars are planned as a reserved cycle")
    func twoWaySwapWithArtifacts() throws {
        let a = root.appendingPathComponent("A.jpg")
        let b = root.appendingPathComponent("B.jpg")
        let aXMP = root.appendingPathComponent("A.xmp")
        let bXMP = root.appendingPathComponent("B.xmp")
        let items = [
            RenamePlanningItem(
                sourceImageURL: a,
                context: BatchRenameContext(
                    originalFilename: "ignored",
                    metadata: [.title: "B.jpg"]
                )
            ),
            RenamePlanningItem(
                sourceImageURL: b,
                context: BatchRenameContext(
                    originalFilename: "ignored",
                    metadata: [.title: "A.jpg"]
                )
            ),
        ]
        let recipe = BatchRenameRecipe(
            name: "Swap",
            components: [.token(.metadata(.title))]
        )

        let plan = service.makePlan(
            items: items,
            recipe: recipe,
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [a, b, aXMP, bXMP]
            )
        )

        #expect(plan.entries.map(\.disposition) == [.rename, .rename])
        #expect(plan.entries.map(\.plannedDestinationImageURL?.lastPathComponent) == ["B.jpg", "A.jpg"])
        #expect(try #require(plan.entries[0].plannedArtifactActions.first {
            $0.identifier == "xmp"
        }).destinationURL.lastPathComponent == "B.xmp")
        #expect(try #require(plan.entries[1].plannedArtifactActions.first {
            $0.identifier == "xmp"
        }).destinationURL.lastPathComponent == "A.xmp")
        #expect(plan.canExecute)
    }

    @Test("Three-way image cycles preserve input order and reserve every destination")
    func threeWayCycle() {
        let names = ["A.jpg", "B.jpg", "C.jpg"]
        let destinations = ["B.jpg", "C.jpg", "A.jpg"]
        let items = zip(names, destinations).map { source, destination in
            RenamePlanningItem(
                sourceImageURL: root.appendingPathComponent(source),
                context: BatchRenameContext(
                    originalFilename: source,
                    metadata: [.title: destination]
                )
            )
        }

        let plan = service.makePlan(
            items: items,
            recipe: BatchRenameRecipe(
                name: "Cycle",
                components: [.token(.metadata(.title))]
            ),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: Set(names.map { root.appendingPathComponent($0) })
            )
        )

        #expect(plan.entries.map(\.plannedDestinationImageURL?.lastPathComponent) == destinations)
        #expect(plan.reservedDestinationURLs.map(\.lastPathComponent) == destinations)
        #expect(plan.canExecute)
    }

    @Test("A batch source that remains in place is not considered vacatable")
    func sourceThatRemainsBlocksIncomingRename() {
        let a = root.appendingPathComponent("A.jpg")
        let b = root.appendingPathComponent("B.jpg")
        let items = [
            RenamePlanningItem(
                sourceImageURL: a,
                context: BatchRenameContext(
                    originalFilename: "A.jpg",
                    metadata: [.title: "B.jpg"]
                )
            ),
            RenamePlanningItem(
                sourceImageURL: b,
                context: BatchRenameContext(
                    originalFilename: "B.jpg",
                    metadata: [.title: "B.jpg"]
                )
            ),
        ]

        let plan = service.makePlan(
            items: items,
            recipe: BatchRenameRecipe(
                name: "One remains",
                components: [.token(.metadata(.title))]
            ),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [a, b]
            )
        )

        #expect(plan.entries.map(\.disposition) == [.blocked, .unchanged])
        #expect(plan.entries[0].issues.contains {
            $0.code == .existingDestination(existingURL: b)
        })
        #expect(!plan.canExecute)
    }

    @Test("A skipped intended mover makes a dependent target blocking")
    func skippedMoverInvalidatesDependentTarget() {
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        let aMetadata = root
            .appendingPathComponent(".photo_metadata", isDirectory: true)
            .appendingPathComponent("A.meta.json")
        let items = [
            RenamePlanningItem(
                sourceImageURL: a,
                context: BatchRenameContext(
                    originalFilename: "A",
                    metadata: [.title: "B"]
                )
            ),
            RenamePlanningItem(
                sourceImageURL: b,
                context: BatchRenameContext(
                    originalFilename: "B",
                    metadata: [.title: "A"]
                )
            ),
        ]

        let plan = service.makePlan(
            items: items,
            recipe: BatchRenameRecipe(
                name: "Failed swap",
                components: [.token(.metadata(.title))]
            ),
            collisionPolicy: .skip,
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [a, b, aMetadata]
            )
        )

        // Current and legacy JSON rules collide for extensionless A, so A→B is skipped. B→A
        // must then block because A no longer vacates, even though A was a mover in the pre-pass.
        #expect(plan.entries.map(\.disposition) == [.skipped, .blocked])
        #expect(plan.entries[1].issues.contains {
            $0.code == .existingDestination(existingURL: a)
        })
        #expect(!plan.canExecute)
        #expect(plan.reservedDestinationURLs.isEmpty)
    }

    @Test("Unresolvable artifact target collisions exhaust a bounded suffix policy")
    func boundedSuffixExhaustion() {
        let source = root.appendingPathComponent("old.NEF")
        let current = root
            .appendingPathComponent(".photo_metadata", isDirectory: true)
            .appendingPathComponent("old.NEF.meta.json")
        let legacy = root
            .appendingPathComponent(".photo_metadata", isDirectory: true)
            .appendingPathComponent("old.meta.json")
        // With no destination extension, current and legacy rules always derive the same target.
        let plan = service.makePlan(
            items: [RenamePlanningItem(sourceImageURL: source)],
            recipe: BatchRenameRecipe(name: "No extension", components: [.literal("news")]),
            collisionPolicy: .appendDeterministicSuffix(maximumAttempts: 3),
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseSensitive,
                existingURLs: [current, legacy]
            )
        )

        #expect(plan.entries.first?.disposition == .blocked)
        #expect(plan.issues.contains {
            $0.code == .deterministicSuffixExhausted(maximumAttempts: 3)
        })
        #expect(plan.reservedDestinationURLs.isEmpty)
    }

    @Test("10,000-file preview remains deterministic with realistic artifacts and bounded resources")
    func tenThousandFilePreviewPerformance() throws {
        let count = 10_000
        let folder = root.appendingPathComponent("wire-batch", isDirectory: true)
        let metadataFolder = folder.appendingPathComponent(".photo_metadata", isDirectory: true)
        let cacheFolder = folder.appendingPathComponent(".cache", isDirectory: true)
        let thumbnailRule = RenameArtifactRule(
            identifier: "thumbnail-cache",
            displayName: "Thumbnail cache",
            relativeDirectoryComponents: [".cache"],
            filenamePattern: RenameArtifactFilenamePattern(basis: .stem, suffix: ".thumb")
        )
        let registry = RenameArtifactRegistry.standard.registering(thumbnailRule)
        let recipe = BatchRenameRecipe(
            name: "Wire sequence",
            components: [
                .literal("WIRE_"),
                .token(.metadata(.event)),
                .literal("_"),
                .token(.sequence(BatchRenameSequence(start: 1, step: 1, padding: 5))),
                .literal("."),
                .token(.originalExtension),
            ]
        )

        var items: [RenamePlanningItem] = []
        var existingURLs: Set<URL> = []
        items.reserveCapacity(count)
        existingURLs.reserveCapacity(count * 3)
        for index in 0..<count {
            let stem = String(format: "IMG_%05d", index)
            let filename = "\(stem).NEF"
            let source = folder.appendingPathComponent(filename)
            items.append(RenamePlanningItem(
                sourceImageURL: source,
                context: BatchRenameContext(
                    originalFilename: filename,
                    metadata: [.event: "FINAL"]
                )
            ))
            existingURLs.insert(folder.appendingPathComponent("\(stem).xmp"))
            existingURLs.insert(metadataFolder.appendingPathComponent("\(filename).meta.json"))
            existingURLs.insert(cacheFolder.appendingPathComponent("\(stem).thumb"))
        }

        let residentBefore = currentResidentSizeBytes()
        let start = ContinuousClock.now
        let plan = service.makePlan(
            items: items,
            recipe: recipe,
            artifactRegistry: registry,
            environment: RenamePlanningEnvironment(
                caseSensitivity: .caseInsensitive,
                existingURLs: existingURLs
            )
        )
        let elapsed = start.duration(to: .now)
        let residentAfter = currentResidentSizeBytes()
        let seconds = elapsed.secondsValue
        let residentGrowth = residentAfter.flatMap { after in
            residentBefore.map { before in after > before ? after - before : 0 }
        }

        print(String(
            format: "PERF RenamePlanning 10000 files: %.3f s, resident delta %.1f MiB",
            seconds,
            Double(residentGrowth ?? 0) / 1_048_576
        ))
        #expect(plan.entries.count == count)
        #expect(plan.reservedDestinationURLs.count == count * 4)
        #expect(plan.issues.isEmpty)
        #expect(plan.canExecute)
        #expect(plan.entries.first?.plannedDestinationImageURL?.lastPathComponent == "WIRE_FINAL_00001.NEF")
        #expect(plan.entries.last?.plannedDestinationImageURL?.lastPathComponent == "WIRE_FINAL_10000.NEF")
        // These are regression tripwires, not throughput promises. They intentionally leave wide
        // headroom for shared CI machines while catching accidental quadratic work or runaway
        // retention in this pure planning path.
        #expect(seconds < 60)
        if let residentGrowth {
            #expect(residentGrowth < 1_500 * 1_048_576)
        }
    }
}

private extension Duration {
    var secondsValue: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private func currentResidentSizeBytes() -> UInt64? {
    var information = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &information) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return UInt64(information.resident_size)
}
