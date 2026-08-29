import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

private actor ImportSourceDiscoveryProgressRecorder {
    private var snapshots: [ImportSourceDiscoveryProgress] = []

    func append(_ snapshot: ImportSourceDiscoveryProgress) {
        snapshots.append(snapshot)
    }

    func recordedSnapshots() -> [ImportSourceDiscoveryProgress] {
        snapshots
    }
}

private nonisolated final class ImportPreflightTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if hasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func suspend() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }
}

private nonisolated final class ImportPreflightProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.withLock {
            count += 1
        }
    }

    var recordedCount: Int {
        lock.withLock { count }
    }
}

private nonisolated final class ImportPreflightSerializationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeProbeCount = 0
    private var maximumProbeCount = 0
    private var firstProbeStarted = false
    private var released = false

    func probe(_ path: String) -> Bool {
        condition.lock()
        activeProbeCount += 1
        maximumProbeCount = max(maximumProbeCount, activeProbeCount)
        let shouldSuspend = path == "/photos/first.jpg"
        if shouldSuspend {
            firstProbeStarted = true
            condition.broadcast()
            while !released {
                condition.wait()
            }
        }
        activeProbeCount -= 1
        condition.unlock()
        return false
    }

    func waitForFirstProbe() async -> Bool {
        for _ in 0..<200 {
            if hasStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    var maximumConcurrentProbeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumProbeCount
    }

    private var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return firstProbeStarted
    }
}

@Suite("Import duplicate and collision preflight")
struct ImportPreflightServiceTests {
    @Test("Preflight freezes duplicate skips and complete collision evidence")
    func freezesDuplicateAndCollisionEvidence() async throws {
        let source = URL(fileURLWithPath: "/card/photo.jpg")
        let memo = URL(fileURLWithPath: "/card/photo.wav")
        let primary = URL(fileURLWithPath: "/photos/photo.jpg")
        let memoPrimary = URL(fileURLWithPath: "/photos/photo.wav")
        let backup = URL(fileURLWithPath: "/backup/photo.jpg")
        let otherSource = URL(fileURLWithPath: "/card/other.jpg")
        let sharedDestination = URL(fileURLWithPath: "/photos/shared.jpg")
        let jobs = [
            ImportCopyService.CopyJob(
                source: source,
                desiredPrimaryDest: primary,
                desiredBackupDest: backup
            ),
            ImportCopyService.CopyJob(
                source: memo,
                desiredPrimaryDest: memoPrimary,
                desiredBackupDest: nil
            ),
            ImportCopyService.CopyJob(
                source: otherSource,
                desiredPrimaryDest: sharedDestination,
                desiredBackupDest: backup
            ),
            ImportCopyService.CopyJob(
                source: URL(fileURLWithPath: "/card/final.jpg"),
                desiredPrimaryDest: sharedDestination,
                desiredBackupDest: nil
            ),
        ]
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in [source] },
            fileExists: { $0 == backup.standardizedFileURL.path }
        )

        let result = try await service.prepare(ImportPreflightService.Request(
            jobs: jobs,
            previousImportCandidates: [
                PreviousImportDetector.Candidate(
                    source: source,
                    dateFolderName: "2026-08-29"
                ),
            ],
            companionParentBySource: [memo: source],
            destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
            skipPreviouslyImported: true,
            freezeOverwriteCollisions: true
        ))

        #expect(result.jobs[0].preflightSkipReason == .previouslyImported)
        #expect(result.jobs[1].preflightSkipReason == .previouslyImported)
        #expect(result.jobs[2].expectedPrimaryCollision == false)
        #expect(result.jobs[2].expectedBackupCollision == true)
        #expect(result.jobs[3].expectedPrimaryCollision == true)
        #expect(result.overwrite?.primaryCollisionCount == 1)
        #expect(result.overwrite?.backupCollisionCount == 1)
        #expect(result.overwrite?.signature.map(\.isSkipped) == [true, true, false, false])
    }

    @Test("Pre-cancelled preflight performs no filesystem probes")
    func preCancelledPreflightIsExplicit() async {
        let probes = ImportPreflightProbeRecorder()
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in
                probes.record()
                return []
            },
            fileExists: { _ in
                probes.record()
                return false
            }
        )
        let task = Task {
            try await service.prepare(ImportPreflightService.Request(
                jobs: [],
                previousImportCandidates: [],
                companionParentBySource: [:],
                destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
                skipPreviouslyImported: true,
                freezeOverwriteCollisions: true
            ))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected preflight cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        #expect(probes.recordedCount == 0)
    }

    @Test("Actor serializes overlapping collision preflights")
    func serializesOverlappingPreflights() async throws {
        let gate = ImportPreflightSerializationGate()
        let service = ImportPreflightService(fileExists: { gate.probe($0) })
        let first = ImportPreflightService.Request(
            jobs: [ImportCopyService.CopyJob(
                source: URL(fileURLWithPath: "/card/first.jpg"),
                desiredPrimaryDest: URL(fileURLWithPath: "/photos/first.jpg"),
                desiredBackupDest: nil
            )],
            previousImportCandidates: [],
            companionParentBySource: [:],
            destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
            skipPreviouslyImported: false,
            freezeOverwriteCollisions: true
        )
        let second = ImportPreflightService.Request(
            jobs: [ImportCopyService.CopyJob(
                source: URL(fileURLWithPath: "/card/second.jpg"),
                desiredPrimaryDest: URL(fileURLWithPath: "/photos/second.jpg"),
                desiredBackupDest: nil
            )],
            previousImportCandidates: [],
            companionParentBySource: [:],
            destinationBaseURL: URL(fileURLWithPath: "/photos", isDirectory: true),
            skipPreviouslyImported: false,
            freezeOverwriteCollisions: true
        )

        let firstTask = Task { try await service.prepare(first) }
        defer { gate.release() }
        let firstProbeDidStart = await gate.waitForFirstProbe()
        #expect(firstProbeDidStart)
        let secondTask = Task { try await service.prepare(second) }
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.maximumConcurrentProbeCount == 1)
        gate.release()

        _ = try await firstTask.value
        _ = try await secondTask.value
        #expect(gate.maximumConcurrentProbeCount == 1)
    }
}

@Suite("Import source discovery")
struct ImportSourceDiscoveryServiceTests {
    @Test("Discovery progress uses a five-second production cadence")
    func progressCadence() {
        #expect(ImportSourceDiscoveryService.defaultProgressUpdateInterval == .seconds(5))
    }

    @Test("Discovery recursively returns regular files while skipping hidden and package contents")
    func discoversRegularFilesOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let package = root.appendingPathComponent("ignored.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let visible = nested.appendingPathComponent("visible.jpg")
        let hidden = root.appendingPathComponent(".hidden.jpg")
        let packaged = package.appendingPathComponent("packaged.jpg")
        try Data("visible".utf8).write(to: visible)
        try Data("hidden".utf8).write(to: hidden)
        try Data("packaged".utf8).write(to: packaged)

        let files = try await ImportSourceDiscoveryService().discoverFiles(at: root)

        #expect(
            files.map { $0.resolvingSymlinksInPath().path }
                == [visible.resolvingSymlinksInPath().path]
        )
    }

    @Test("Discovery surfaces cancellation before touching the source")
    func cancellationIsExplicit() async {
        let service = ImportSourceDiscoveryService()
        let task = Task {
            try await service.discoverFiles(at: URL(fileURLWithPath: "/source-is-never-read"))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected source discovery to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
    }

    @Test("Discovery progress reports files, supported images, and WAV files")
    func reportsDiscoveryProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSourceProgressTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("photo.jpg"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        try Data().write(to: root.appendingPathComponent("memo.wav"))

        let recorder = ImportSourceDiscoveryProgressRecorder()
        let files = try await ImportSourceDiscoveryService().discoverFiles(
            at: root,
            progressUpdateInterval: .zero
        ) { snapshot in
            await recorder.append(snapshot)
        }
        let snapshots = await recorder.recordedSnapshots()

        #expect(files.count == 3)
        #expect(snapshots.last == ImportSourceDiscoveryProgress(
            discoveredFileCount: 3,
            supportedImageCount: 1,
            wavFileCount: 1
        ))
    }
}

@Suite("ImportViewModel", .serialized)
@MainActor
struct ImportViewModelTests {
    @Test("RAW and JPEG filters include images from both selected cards")
    func fileTypeFilterSpansBothSources() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: UserDefaultsKeys.importFileTypeFilter)
        defer {
            if let original {
                defaults.set(original, forKey: UserDefaultsKeys.importFileTypeFilter)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.importFileTypeFilter)
            }
        }

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        let raw = URL(fileURLWithPath: "/card-1/TRA08908.ARW")
        let jpeg = URL(fileURLWithPath: "/card-2/TRA08908.JPG")
        let wav = URL(fileURLWithPath: "/card-2/TRA08908.WAV")
        viewModel.sourceFiles = [raw]
        viewModel.voiceMemoSourceFiles = [jpeg, wav]

        viewModel.configuration.fileTypeFilter = .rawOnly
        #expect(viewModel.filteredSourceFiles == [raw])
        viewModel.configuration.fileTypeFilter = .jpegOnly
        #expect(viewModel.filteredSourceFiles == [jpeg])
        viewModel.configuration.fileTypeFilter = .both
        #expect(viewModel.filteredSourceFiles == [raw, jpeg])
    }

    @Test("Import template preserves ordered creators and exact Date Created")
    func orderedCreatorAndDateTemplate() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        let creatorTransport = IPTCMetadata(
            creators: ["First Reporter", "Second Reporter"]
        ).creatorTransportValue!
        let template = MetadataTemplate(
            name: "Desk",
            fields: [
                TemplateField(fieldKey: "creator", templateValue: creatorTransport),
                TemplateField(
                    fieldKey: "dateCreated",
                    templateValue: "2026-08-21T10:15:30.120+02:30"
                ),
            ]
        )

        viewModel.applyTemplate(template)

        #expect(viewModel.configuration.metadata.creators == ["First Reporter", "Second Reporter"])
        #expect(viewModel.configuration.metadata.editorialDateCreated?.precision == .fractionalSecond)
        #expect(viewModel.configuration.metadata.editorialDateCreated?.timeZoneOffsetMinutes == 150)
        let fields = ImportViewModel.buildMetadataFields(from: viewModel.configuration.metadata)
        #expect(fields[.creator] == creatorTransport)
        #expect(fields[.dateCreated] == "2026-08-21T10:15:30.120+02:30")
    }

    @Test("Import readiness explains each blocked setup state")
    func importReadinessExplainsBlockedStates() {
        let defaults = UserDefaults.standard
        let keys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importSortByDate,
        ]
        var originals: [String: Any] = [:]
        for key in keys {
            originals[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let original = originals[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.fileTypeFilter = .both
        viewModel.sortByDate = false

        #expect(viewModel.importBlockingReason == "Choose a memory card or folder to import from.")

        let source = URL(fileURLWithPath: "/Volumes/Card", isDirectory: true)
        let image = source.appendingPathComponent("photo.jpg")
        viewModel.configuration.sourceURL = source
        viewModel.importPhase = .scanning
        #expect(viewModel.importBlockingReason == "Scanning the source folder…")

        viewModel.importPhase = .idle
        #expect(viewModel.importBlockingReason == "No supported images were found in the source folder.")

        viewModel.sourceFiles = [image]
        #expect(viewModel.importBlockingReason == "Enter an import title.")

        viewModel.configuration.importTitle = "Cup Final"
        #expect(viewModel.importBlockingReason == nil)

        viewModel.configuration.fileTypeFilter = .rawOnly
        #expect(viewModel.importBlockingReason == "No images match the RAW Only filter.")

        viewModel.configuration.fileTypeFilter = .both
        viewModel.sortByDate = true
        viewModel.isScanningDates = true
        #expect(viewModel.importBlockingReason == "Scanning capture dates…")

        viewModel.isScanningDates = false
        #expect(viewModel.importBlockingReason == "Scan capture dates before importing.")

        viewModel.dateGroups = [
            ImportDateGroup(
                dateString: "2026:07:26",
                folderName: "2026-07-26 – Cup Final",
                shootFolderName: nil,
                yearFolder: "2026",
                files: [image]
            )
        ]
        #expect(viewModel.importBlockingReason == nil)

        viewModel.dateGroups[0].isIncluded = false
        #expect(viewModel.importBlockingReason == "Select at least one date folder to import.")
    }

    @Test("Import behavior settings restore from defaults and survive reset")
    func importBehaviorSettingsRestoreFromDefaultsAndSurviveReset() {
        let defaults = UserDefaults.standard
        let keys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
            UserDefaultsKeys.importDateFolderGrouping,
            UserDefaultsKeys.importSplitShootsIntoSubfolders,
        ]
        var originals: [String: Any] = [:]
        for key in keys {
            if let original = defaults.object(forKey: key) {
                originals[key] = original
            }
        }
        defer {
            for key in keys {
                if let original = originals[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(ImportFileTypeFilter.rawOnly.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter)
        defaults.set(ImportConflictPolicy.skipExisting.rawValue, forKey: UserDefaultsKeys.importConflictPolicy)
        defaults.set(false, forKey: UserDefaultsKeys.importCreateSubFolders)
        defaults.set(CopyVerificationMode.off.rawValue, forKey: UserDefaultsKeys.importVerificationMode)
        defaults.set(false, forKey: UserDefaultsKeys.importSkipPreviouslyImported)
        defaults.set(true, forKey: UserDefaultsKeys.importSortByDate)
        defaults.set(ImportDateFolderGrouping.month.rawValue, forKey: UserDefaultsKeys.importDateFolderGrouping)
        defaults.set(true, forKey: UserDefaultsKeys.importSplitShootsIntoSubfolders)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )

        #expect(viewModel.configuration.fileTypeFilter == .rawOnly)
        #expect(viewModel.configuration.conflictPolicy == .skipExisting)
        #expect(viewModel.configuration.createSubFolders == false)
        #expect(viewModel.configuration.verificationMode == .off)
        #expect(viewModel.configuration.skipPreviouslyImported == false)
        #expect(viewModel.sortByDate == true)
        #expect(viewModel.dateFolderGrouping == .month)
        #expect(viewModel.splitShootsIntoSubfolders == true)

        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = true
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = true
        viewModel.sortByDate = false
        viewModel.dateFolderGrouping = .year
        viewModel.splitShootsIntoSubfolders = false
        viewModel.reset()

        #expect(viewModel.configuration.fileTypeFilter == .jpegOnly)
        #expect(viewModel.configuration.conflictPolicy == .overwrite)
        #expect(viewModel.configuration.createSubFolders == true)
        #expect(viewModel.configuration.verificationMode == .on)
        #expect(viewModel.configuration.skipPreviouslyImported == true)
        #expect(viewModel.sortByDate == false)
        #expect(viewModel.dateFolderGrouping == .year)
        #expect(viewModel.splitShootsIntoSubfolders == false)
    }

    @Test("Split-shoot folder preview updates when subfolder layout toggles")
    func splitShootFolderPreviewUpdatesWhenSubfolderLayoutToggles() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.destinationBaseURL = URL(fileURLWithPath: "/Volumes/Photos")
        viewModel.configuration.importTitle = "Cup Final"
        viewModel.sortByDate = true
        viewModel.dateFolderGrouping = .year
        viewModel.splitShootsIntoSubfolders = false
        viewModel.dateGroups = [
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "2026-07-08 \u{2013} Cup Final \u{2013} Shoot 1",
                shootFolderName: nil,
                yearFolder: "2026",
                monthFolder: "07",
                files: [URL(fileURLWithPath: "/card/one.jpg")]
            ),
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "2026-07-08 \u{2013} Cup Final \u{2013} Shoot 2",
                shootFolderName: nil,
                yearFolder: "2026",
                monthFolder: "07",
                files: [URL(fileURLWithPath: "/card/two.jpg")]
            ),
        ]

        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[0]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final \u{2013} Shoot 1")

        viewModel.splitShootsIntoSubfolders = true

        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[0]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final / Shoot 1")
        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[1]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final / Shoot 2")

        viewModel.splitShootsIntoSubfolders = false

        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[0]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final \u{2013} Shoot 1")
        #expect(viewModel.folderPathPreview(for: viewModel.dateGroups[1]) == "Photos / 2026 / 2026-07-08 \u{2013} Cup Final \u{2013} Shoot 2")
    }

    @Test("Split-shoot subfolder layout preserves a manually edited parent folder name")
    func splitShootSubfolderLayoutPreservesManualParentName() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.importTitle = "Cup Final"
        viewModel.sortByDate = true
        viewModel.splitShootsIntoSubfolders = true
        viewModel.dateGroups = [
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "My written folder title",
                shootFolderName: "Shoot 1",
                yearFolder: "2026",
                files: [URL(fileURLWithPath: "/card/one.jpg")]
            ),
            ImportDateGroup(
                dateString: "2026:07:08",
                folderName: "My written folder title",
                shootFolderName: "Shoot 2",
                yearFolder: "2026",
                files: [URL(fileURLWithPath: "/card/two.jpg")]
            ),
        ]

        viewModel.splitShootsIntoSubfolders = false
        #expect(viewModel.dateGroups[0].folderName == "My written folder title \u{2013} Shoot 1")
        #expect(viewModel.dateGroups[1].folderName == "My written folder title \u{2013} Shoot 2")

        viewModel.splitShootsIntoSubfolders = true
        #expect(viewModel.dateGroups[0].folderName == "My written folder title")
        #expect(viewModel.dateGroups[1].folderName == "My written folder title")
    }

    @Test("Capture-date scan uses an import title entered while the scan is running")
    func captureDateScanUsesLatestImportTitle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportDateTitleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.jpg")
        try Data().write(to: image)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.sourceFiles = [image]
        viewModel.configuration.importTitle = ""

        viewModel.scanCaptureDates()
        viewModel.configuration.importTitle = "Title entered during scan"

        for _ in 0..<500 where viewModel.isScanningDates {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isScanningDates)
        #expect(viewModel.dateGroups.count == 1)
        #expect(viewModel.dateGroups[0].folderName.hasSuffix(" \u{2013} Title entered during scan"))
    }

    @Test("Month date grouping previews use the month folder")
    func monthDateGroupingPreviewUsesMonthFolder() {
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.destinationBaseURL = URL(fileURLWithPath: "/Volumes/Photos")
        viewModel.sortByDate = true
        viewModel.dateFolderGrouping = .month
        let group = ImportDateGroup(
            dateString: "2026:07:08",
            folderName: "2026-07-08",
            shootFolderName: nil,
            yearFolder: "2026",
            monthFolder: "07",
            files: [URL(fileURLWithPath: "/card/one.jpg")]
        )

        #expect(viewModel.folderPathGroupingPrefix(for: group) == "2026/07")
        #expect(viewModel.folderPathPreview(for: group) == "Photos / 2026 / 07 / 2026-07-08")
    }

    @Test("Common ancestor chooses the nearest shared import folder")
    func commonAncestorChoosesNearestSharedImportFolder() {
        let shootFolders = [
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-08/Shoot 1"),
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-08/Shoot 2"),
        ]
        let dayFolders = [
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-08"),
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-09"),
        ]
        let monthFolders = [
            URL(fileURLWithPath: "/Volumes/Photos/2026/07/2026-07-31"),
            URL(fileURLWithPath: "/Volumes/Photos/2026/08/2026-08-01"),
        ]

        #expect(ImportViewModel.commonAncestor(of: shootFolders)?.path == "/Volumes/Photos/2026/07/2026-07-08")
        #expect(ImportViewModel.commonAncestor(of: dayFolders)?.path == "/Volumes/Photos/2026/07")
        #expect(ImportViewModel.commonAncestor(of: monthFolders)?.path == "/Volumes/Photos/2026")
    }

    @Test("Import opens its reveal folder only after the directory exists")
    func importStartedFollowsRevealFolderCreation() async throws {
        let defaults = UserDefaults.standard
        let preferenceKeys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys {
            originalPreferences[key] = defaults.object(forKey: key)
        }
        defer {
            for key in preferenceKeys {
                if let original = originalPreferences[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportFolderHandoffTests-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("card", isDirectory: true)
        let destinationBase = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sourceFolder.appendingPathComponent("photo.jpg")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: source)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = sourceFolder
        viewModel.configuration.destinationBaseURL = destinationBase
        viewModel.configuration.importTitle = "Folder Handoff"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .skipExisting
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .off
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        viewModel.sourceFiles = [source]

        let notificationTask = Task { @MainActor () -> (URL, Bool)? in
            for await notification in NotificationCenter.default.notifications(named: .importStarted) {
                guard let folder = notification.object as? URL else { continue }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: folder.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
                return (folder, exists)
            }
            return nil
        }
        await Task.yield()

        viewModel.startImport()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            notificationTask.cancel()
        }
        let observed = await notificationTask.value
        timeoutTask.cancel()

        #expect(
            observed?.0.standardizedFileURL.path
                == viewModel.configuration.destinationFolderURL.standardizedFileURL.path
        )
        #expect(observed?.1 == true)

        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!viewModel.isImporting)
        // The test host contains the real browser notification consumer. Let its small-folder
        // scan finish before the temporary tree is removed by `defer`.
        try await Task.sleep(for: .milliseconds(500))
    }

    @Test("Dual-card import copies a matched WAV with the image conflict suffix")
    func dualCardImportKeepsMemoBesideRenamedImage() async throws {
        let defaults = UserDefaults.standard
        let preferenceKeys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys { originalPreferences[key] = defaults.object(forKey: key) }
        defer {
            for key in preferenceKeys {
                if let original = originalPreferences[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualCardImportTests-\(UUID().uuidString)", isDirectory: true)
        let rawCard = root.appendingPathComponent("card-1", isDirectory: true)
        let memoCard = root.appendingPathComponent("card-2", isDirectory: true)
        let destinationBase = root.appendingPathComponent("photos", isDirectory: true)
        for folder in [rawCard, memoCard, destinationBase] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = rawCard.appendingPathComponent("TRA08908.ARW")
        try Data("synthetic-primary-raw".utf8).write(to: raw)
        let image = memoCard.appendingPathComponent("TRA08908.JPG")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: image)
        let memo = memoCard.appendingPathComponent("TRA08908.WAV")
        let memoBytes = Data("sony-voice-memo-bytes".utf8)
        try memoBytes.write(to: memo)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = rawCard
        viewModel.configuration.voiceMemoSourceURL = memoCard
        viewModel.configuration.destinationBaseURL = destinationBase
        viewModel.configuration.importTitle = "Dual Card"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .renameWithSuffix
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        viewModel.sourceFiles = [raw]
        viewModel.voiceMemoSourceFiles = [image, memo]
        viewModel.voiceMemoAssociationReport = VoiceMemoAssociationReport(
            profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
            associations: [raw, image].map {
                VoiceMemoAssociation(
                    profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                    imageURL: $0,
                    memoURL: memo
                )
            },
            imagesWithoutMemo: [],
            ambiguous: [],
            orphanMemoURLs: []
        )

        let destinationFolder = viewModel.configuration.destinationFolderURL
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        try jpeg.write(
            to: destinationFolder.appendingPathComponent("TRA08908.JPG")
        )

        viewModel.startImport()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        let importedImage = destinationFolder.appendingPathComponent("TRA08908-1.JPG")
        let importedMemo = destinationFolder.appendingPathComponent("TRA08908-1.WAV")
        #expect(!viewModel.isImporting)
        #expect(FileManager.default.fileExists(atPath: importedImage.path))
        #expect(try Data(contentsOf: importedMemo) == memoBytes)
        #expect(viewModel.copiedFiles == 2)
        #expect(viewModel.voiceMemoCopiedFiles == 1)
        #expect(viewModel.importSummary.contains("Imported 1 photo"))
        #expect(viewModel.importSummary.contains("voice memos 1"))

        try await Task.sleep(for: .milliseconds(500))
    }

    @Test("One-card import can keep RAW, JPEG, and their voice memo")
    func oneCardImportKeepsBothImageVariantsAndMemo() async throws {
        let defaults = UserDefaults.standard
        let preferenceKeys = [
            UserDefaultsKeys.importFileTypeFilter,
            UserDefaultsKeys.importConflictPolicy,
            UserDefaultsKeys.importCreateSubFolders,
            UserDefaultsKeys.importVerificationMode,
            UserDefaultsKeys.importSkipPreviouslyImported,
            UserDefaultsKeys.importSortByDate,
        ]
        var originalPreferences: [String: Any] = [:]
        for key in preferenceKeys { originalPreferences[key] = defaults.object(forKey: key) }
        defer {
            for key in preferenceKeys {
                if let original = originalPreferences[key] {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneCardVoiceMemoImportTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let destinationBase = root.appendingPathComponent("photos", isDirectory: true)
        for folder in [card, destinationBase] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = card.appendingPathComponent("TRA08912.ARW")
        let jpeg = card.appendingPathComponent("TRA08912.JPG")
        let memo = card.appendingPathComponent("TRA08912.WAV")
        let rawBytes = Data("synthetic-raw-copy-fixture".utf8)
        let jpegBytes = Data("synthetic-jpeg-copy-fixture".utf8)
        let memoBytes = Data("single-card-voice-memo".utf8)
        try rawBytes.write(to: raw)
        try jpegBytes.write(to: jpeg)
        try memoBytes.write(to: memo)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = destinationBase
        viewModel.configuration.importTitle = "One Card"
        viewModel.configuration.fileTypeFilter = .both
        viewModel.configuration.conflictPolicy = .renameWithSuffix
        viewModel.configuration.createSubFolders = true
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sortByDate = false
        viewModel.sourceFiles = [raw, jpeg]
        viewModel.sourceVoiceMemoFiles = [memo]
        viewModel.voiceMemoAssociationReport = VoiceMemoAssociationReport(
            profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
            associations: [raw, jpeg].map {
                VoiceMemoAssociation(
                    profileIdentifier: SonyDualCardVoiceMemoAssociationService.profileIdentifier,
                    imageURL: $0,
                    memoURL: memo
                )
            },
            imagesWithoutMemo: [],
            ambiguous: [],
            orphanMemoURLs: []
        )

        viewModel.startImport()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        let destination = viewModel.configuration.destinationFolderURL
        #expect(try Data(contentsOf: destination.appendingPathComponent("RAW/TRA08912.ARW")) == rawBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("RAW/TRA08912.WAV")) == memoBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("JPEG/TRA08912.JPG")) == jpegBytes)
        #expect(try Data(contentsOf: destination.appendingPathComponent("JPEG/TRA08912.WAV")) == memoBytes)
        #expect(viewModel.copiedFiles == 4)
        #expect(viewModel.voiceMemoCopiedFiles == 2)

        try await Task.sleep(for: .milliseconds(500))
    }

    @Test("overwrite preflight counts both legs, cancellation writes nothing, and results persist exact counts")
    func overwritePreflightIsExactAndDurable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwritePreflightTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        for folder in [card, photos, backup] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let source = card.appendingPathComponent("photo.jpg")
        let replacement = Data("new-photo".utf8)
        let originalPrimary = Data("old-primary".utf8)
        let originalBackup = Data("old-backup".utf8)
        try replacement.write(to: source)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Overwrite Audit"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.verificationMode = .on
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.configuration.backupDestination = BackupDestination(url: backup)
        viewModel.sortByDate = false
        viewModel.sourceFiles = [source]

        let primary = viewModel.configuration.destinationFolderURL.appendingPathComponent(source.lastPathComponent)
        let relative = try #require(ImportViewModel.relativePath(of: primary, under: photos))
        let backupFile = backup.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: primary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: backupFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalPrimary.write(to: primary)
        try originalBackup.write(to: backupFile)

        viewModel.startImport()

        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let preflight = try #require(viewModel.overwritePreflight)
        #expect(preflight.primaryCollisionCount == 1)
        #expect(preflight.backupCollisionCount == 1)
        #expect(preflight.totalCollisionCount == 2)
        #expect(preflight.primaryRoot.standardizedFileURL == photos.standardizedFileURL)
        #expect(preflight.backupRoot?.standardizedFileURL == backup.standardizedFileURL)
        #expect(viewModel.importPhase == .idle)
        #expect(try Data(contentsOf: primary) == originalPrimary)
        #expect(try Data(contentsOf: backupFile) == originalBackup)

        viewModel.cancelOverwritePreflight()
        #expect(viewModel.overwritePreflight == nil)
        #expect(try Data(contentsOf: primary) == originalPrimary)
        #expect(try Data(contentsOf: backupFile) == originalBackup)

        viewModel.startImport()
        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        viewModel.confirmOverwritePreflight()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try Data(contentsOf: primary) == replacement)
        #expect(try Data(contentsOf: backupFile) == replacement)
        #expect(viewModel.replacedFiles == 1)
        #expect(viewModel.backupReplacedFiles == 1)
        #expect(viewModel.lastCompletionEntry?.importResultCounts == ActivityImportResultCounts(
            replaced: 1,
            backupReplaced: 1,
            skipped: 0,
            renamed: 0
        ))
        let encoded = try JSONEncoder().encode(try #require(viewModel.lastCompletionEntry))
        let decoded = try JSONDecoder().decode(ActivityEntry.self, from: encoded)
        #expect(decoded.importResultCounts == viewModel.lastCompletionEntry?.importResultCounts)
    }

    @Test("overwrite confirmation is invalidated when the collision set changes")
    func overwriteConfirmationCannotBeReusedAfterCollisionChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteSignatureTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = card.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Changing Set"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [source]

        viewModel.startImport()
        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.overwritePreflight?.primaryCollisionCount == 0)

        let destination = viewModel.configuration.destinationFolderURL.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let intervening = Data("arrived-after-preflight".utf8)
        try intervening.write(to: destination)

        viewModel.confirmOverwritePreflight()

        for _ in 0..<500 where viewModel.overwritePreflight?.primaryCollisionCount != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.importPhase == .idle)
        #expect(viewModel.overwritePreflight?.primaryCollisionCount == 1)
        #expect(try Data(contentsOf: destination) == intervening)
    }

    @Test("overwrite preflight counts collisions created by earlier jobs in the same batch")
    func overwritePreflightCountsPlannedBatchCollisions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverwriteBatchCollisionTests-\(UUID().uuidString)", isDirectory: true)
        let firstCard = root.appendingPathComponent("card-1", isDirectory: true)
        let secondCard = root.appendingPathComponent("card-2", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        for folder in [firstCard, secondCard, photos] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let first = firstCard.appendingPathComponent("photo.jpg")
        let second = secondCard.appendingPathComponent("photo.jpg")
        try Data("first".utf8).write(to: first)
        let finalBytes = Data("second".utf8)
        try finalBytes.write(to: second)

        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )
        viewModel.configuration.sourceURL = firstCard
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Same Names"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = false
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [first, second]

        let destinationFolder = viewModel.configuration.destinationFolderURL
        viewModel.startImport()
        for _ in 0..<500 where viewModel.overwritePreflight == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.overwritePreflight?.primaryCollisionCount == 1)
        #expect(!FileManager.default.fileExists(atPath: destinationFolder.path))

        viewModel.confirmOverwritePreflight()
        for _ in 0..<500 where viewModel.isImporting {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(try Data(contentsOf: destinationFolder.appendingPathComponent("photo.jpg")) == finalBytes)
        #expect(viewModel.replacedFiles == 1)
        #expect(viewModel.lastCompletionEntry?.importResultCounts?.replaced == 1)
    }

    @Test("Reset rejects a late duplicate and collision preflight result")
    func resetRejectsStalePreflightResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleImportPreflightTests-\(UUID().uuidString)", isDirectory: true)
        let card = root.appendingPathComponent("card", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = card.appendingPathComponent("photo.jpg")
        try Data("source".utf8).write(to: source)
        let gate = ImportPreflightTestGate()
        defer { gate.release() }
        let service = ImportPreflightService(
            findDuplicateSources: { _, _ in
                gate.suspend()
                return []
            }
        )
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            preflightService: service
        )
        viewModel.configuration.sourceURL = card
        viewModel.configuration.destinationBaseURL = photos
        viewModel.configuration.importTitle = "Stale Preflight"
        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.configuration.conflictPolicy = .overwrite
        viewModel.configuration.createSubFolders = false
        viewModel.configuration.skipPreviouslyImported = true
        viewModel.configuration.applyMetadata = false
        viewModel.sourceFiles = [source]

        viewModel.startImport()
        let preflightDidStart = await gate.waitUntilStarted()
        #expect(preflightDidStart)
        viewModel.reset()
        gate.release()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(viewModel.importPhase == .idle)
        #expect(viewModel.overwritePreflight == nil)
        #expect(viewModel.sourceFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: photos.appendingPathComponent("Stale Preflight").path))
    }
}

@Suite("Safe import paths")
struct SafeImportPathTests {
    @Test("folder components reject separators and traversal")
    func rejectsUnsafeComponents() throws {
        #expect(throws: SafePathComponent.ValidationError.self) {
            try SafePathComponent.validate("../Outside")
        }
        #expect(throws: SafePathComponent.ValidationError.self) {
            try SafePathComponent.validate("nested/folder")
        }
        #expect(throws: SafePathComponent.ValidationError.self) {
            try SafePathComponent.validate("..")
        }
        #expect(try SafePathComponent.validate(" Cup Final ") == "Cup Final")
    }

    @Test("containment compares standardized path components")
    func containmentUsesCanonicalComponents() {
        let root = URL(fileURLWithPath: "/tmp/import-root", isDirectory: true)
        #expect(SafePathComponent.isContained(root.appendingPathComponent("day/photo.jpg"), in: root))
        #expect(!SafePathComponent.isContained(root.appendingPathComponent("../outside.jpg"), in: root))
    }

    @Test("containment rejects an existing symlink that escapes the root")
    func containmentResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafePathTests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = destination.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!SafePathComponent.isContained(link.appendingPathComponent("photo.jpg"), in: destination))
    }
}

@Suite("Import copy transaction", .serialized)
struct ImportCopyServiceTests {
    @Test("overwrite keeps the existing destination when the source cannot be opened")
    func overwritePreservesExistingFileOnSourceFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingSource = root.appendingPathComponent("missing.jpg")
        let destination = root.appendingPathComponent("existing.jpg")
        let original = Data("existing-good-copy".utf8)
        try original.write(to: destination)

        let service = ImportCopyService()
        let results = try await service.run(
            jobs: [.init(source: missingSource, desiredPrimaryDest: destination, desiredBackupDest: nil)],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results.count == 1)
        #expect(try Data(contentsOf: destination) == original)
        if case .failed = results[0].primary {
            // Expected.
        } else {
            Issue.record("A missing source must fail without replacing the destination")
        }
    }

    @Test("verified overwrite atomically promotes the replacement and leaves no staging file")
    func verifiedOverwritePromotesReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.jpg")
        let destination = root.appendingPathComponent("destination.jpg")
        let replacement = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        try replacement.write(to: source)
        try Data("old".utf8).write(to: destination)

        let service = ImportCopyService()
        let results = try await service.run(
            jobs: [.init(source: source, desiredPrimaryDest: destination, desiredBackupDest: nil)],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results.first?.primaryVerification == .verified)
        #expect(try Data(contentsOf: destination) == replacement)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test("source and destination identity is rejected without touching the file")
    func sameSourceAndDestinationIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("photo.jpg")
        let contents = Data("only-copy".utf8)
        try contents.write(to: file)

        let service = ImportCopyService()
        let results = try await service.run(
            jobs: [.init(source: file, desiredPrimaryDest: file, desiredBackupDest: nil)],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(try Data(contentsOf: file) == contents)
        if case .failed = results[0].primary {
            // Expected.
        } else {
            Issue.record("Copying a file onto itself must be rejected")
        }
    }

    @Test("a companion is skipped when its image copy fails")
    func companionRequiresSuccessfulImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingImage = root.appendingPathComponent("missing.ARW")
        let memo = root.appendingPathComponent("source.WAV")
        let imageDestination = root.appendingPathComponent("destination.ARW")
        let memoDestination = root.appendingPathComponent("destination.WAV")
        try Data("memo".utf8).write(to: memo)
        let imageJob = ImportCopyService.CopyJob(
            source: missingImage,
            desiredPrimaryDest: imageDestination,
            desiredBackupDest: nil
        )
        let memoJob = ImportCopyService.CopyJob(
            source: memo,
            desiredPrimaryDest: memoDestination,
            desiredBackupDest: nil,
            prerequisiteJobID: imageJob.id
        )

        let results = try await ImportCopyService().run(
            jobs: [imageJob, memoJob],
            conflictPolicy: .overwrite,
            verificationMode: .on,
            verifyBackup: true,
            progress: { _ in }
        )

        #expect(results.count == 2)
        if case .failed = results[0].primary {
            // Expected.
        } else {
            Issue.record("The missing image source should fail")
        }
        #expect(results[1].primary == .skipped(.associatedImageFailed))
        #expect(!FileManager.default.fileExists(atPath: memoDestination.path))
    }
}
