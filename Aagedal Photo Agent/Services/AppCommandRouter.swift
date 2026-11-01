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
    case showWebImport
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
    case transcribeVoiceMemosSelected
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
    case browserTab(BrowserTabCommand)
}

/// Browser pane tab commands (View menu). They only act in the Browser workspace: the
/// editors follow the active pane, so switching it under them would change their photo.
enum BrowserTabCommand: Equatable, Sendable {
    case newTab
    case closeTab
    case showNextTab
    case showPreviousTab
}

extension AppCommand {
    /// Commands that act on the Browser selection without their own full-screen handling.
    /// Full screen shows one photo of a possibly larger kept selection; these must affect the
    /// photo the user sees, so the selection collapses to it first. Ratings, labels, rotation
    /// and delete already target the shown photo; folder-wide commands are unaffected.
    var actsOnBrowserSelection: Bool {
        switch self {
        case .renderSelected, .advancedExportSelected, .saveAsJPEG, .saveAsPNG, .archiveRAW,
             .renameSelected, .duplicateSelected, .resetAllEdits, .removeAllIPTC,
             .backupEditedFiles, .openInInternalEditor, .openInExternalEditor,
             .uploadSelected, .processVariablesSelected, .transcribeVoiceMemosSelected,
             .showTemplatePalette, .applyTemplateShortcut, .renderAndSignSelected,
             .pasteIPTCMetadata:
            return true
        default:
            return false
        }
    }

    /// Commands that change or read the displayed folder's photos. Ignored while that folder
    /// is known to be gone (ejected card, unmounted share), where they would act on rows the
    /// user can't see and whose files no longer exist.
    var requiresAvailableFolder: Bool {
        if actsOnBrowserSelection { return true }
        switch self {
        case .setRating, .setLabel, .rotateClockwise, .rotateCounterclockwise,
             .deleteSelected, .moveRejectedToFolder, .renderAll, .uploadAll,
             .processVariablesAll, .copyIPTCMetadata, .writeAllPendingMetadata:
            return true
        default:
            return false
        }
    }
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
