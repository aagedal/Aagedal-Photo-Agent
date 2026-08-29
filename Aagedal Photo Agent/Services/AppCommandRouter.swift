import Foundation
import Observation

/// User-initiated commands sent by a scene's menus to that scene's content.
///
/// Keep process-wide state-change broadcasts in `NotificationCenter`; this type is
/// specifically for commands whose destination is the window that owns the menu.
enum AppCommand: Equatable, Sendable {
    case openFolder
    case openRecentFolder(URL)
    case setRating(StarRating)
    case setLabel(ColorLabel)
    case renderSelected
    case advancedExportSelected
    case renderAll
    case saveAsJPEG
    case saveAsPNG
    case archiveRAW(RAWArchiveFormat)
    case selectPreviousImage
    case selectNextImage
    case rotateClockwise
    case rotateCounterclockwise
    case renameSelected
    case duplicateSelected
    case resetAllEdits
    case removeAllIPTC
    case showImport
    case backupEditedFiles
    case backupEditedFilesForFolder(URL)
    case openInInternalEditor
    case openInExternalEditor
    case deleteSelected
    case moveRejectedToFolder
    case addNewMask
    case removeOrResetSelectedEditLayer
    case toggleHDR
    case setScopeMode(ScopeViewModel.ScopeMode)
    case toggleGamutClipping
    case uploadSelected
    case uploadAll
    case processVariablesSelected
    case processVariablesAll
    case showTemplatePalette
    case applyTemplateShortcut(Int)
    case applyDevelopTemplate(DevelopTemplate)
    case writeAllPendingMetadata
    case openCaptionWorkspace
    case renderAndSignSelected
    case copyIPTCMetadata
    case pasteIPTCMetadata
    case showVariableReference
    case showRawMetadata
    case showStructuredKeywords
    case showKnownPeopleDatabase
    case registerOpenFolderForSidebar(URL)
    case restoreCaptionEditorFocus
}

struct AppCommandDelivery: Equatable, Sendable {
    let sequence: UInt64
    let command: AppCommand
}

/// A router owned by one SwiftUI scene. The monotonically increasing delivery
/// identity ensures that sending the same command twice still produces two events.
@MainActor
@Observable
final class AppCommandRouter {
    private(set) var latestDelivery: AppCommandDelivery?
    private var nextSequence: UInt64 = 0

    func send(_ command: AppCommand) {
        nextSequence &+= 1
        latestDelivery = AppCommandDelivery(sequence: nextSequence, command: command)
    }
}
