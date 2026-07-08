import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("ImportViewModel")
@MainActor
struct ImportViewModelTests {
    @Test("File type filter restores from defaults and survives reset")
    func fileTypeFilterRestoresFromDefaultsAndSurvivesReset() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: UserDefaultsKeys.importFileTypeFilter)
        defer {
            if let original {
                defaults.set(original, forKey: UserDefaultsKeys.importFileTypeFilter)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.importFileTypeFilter)
            }
        }

        defaults.set(ImportFileTypeFilter.rawOnly.rawValue, forKey: UserDefaultsKeys.importFileTypeFilter)
        let viewModel = ImportViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine()
        )

        #expect(viewModel.configuration.fileTypeFilter == .rawOnly)

        viewModel.configuration.fileTypeFilter = .jpegOnly
        viewModel.reset()

        #expect(viewModel.configuration.fileTypeFilter == .jpegOnly)
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
