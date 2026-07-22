import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("ImportViewModel", .serialized)
@MainActor
struct ImportViewModelTests {
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
}
