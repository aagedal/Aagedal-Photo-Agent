import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

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
