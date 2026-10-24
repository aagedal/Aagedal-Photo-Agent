import AppKit
import Foundation

/// What the Browser knows about whether a photo's Develop settings redact pixels (an enabled
/// Anonymizer mask or a global Anonymizer, see `CameraRawSettings.hasActiveRedaction`).
nonisolated enum RedactionKnowledge: Sendable, Equatable {
    case none
    case redacts
    /// The photo's Develop settings have not loaded yet (a folder scan before its metadata batch,
    /// or a file that changed on disk). Privacy paths treat this as possibly redacting.
    case unknown

    var mayRedact: Bool { self != .none }
}

/// UI-level privacy decisions for paths that hand the ORIGINAL file (or unrendered pixels) to
/// someone else: dragging out of the grid, Open in External Editor, forensic Analysis exports,
/// and the unredacted JPEG half of a RAW+JPEG pair. Rendered exports are protected in the
/// pipeline (`ExportCameraRawSourcePolicy`); these paths never render, so they warn or refuse.
enum RedactionPrivacyGuard {
    static let dragBlockedMessage =
        "Photos with face blurs can't be dragged out as originals. Use Export or Save As to share a blurred copy."
    static let dragPendingMessage =
        "Photos can't be dragged out of the app until their develop settings have loaded. Try again in a moment."
    static let pairedRawMessage =
        "The RAW version of this photo has face blurs, but this JPEG doesn't."
    static let pairedRawDragMessage =
        pairedRawMessage + " Export the RAW to share a blurred copy."
    static let externalEditorMessage =
        "The external editor will show the unblurred original — face blurs are app-only settings."
    static let analysisExportMessage =
        "This export contains the unblurred original image."

    /// Redaction state from the Browser's in-memory copy (built with the full parser).
    static func knowledge(for image: ImageFile) -> RedactionKnowledge {
        if image.cameraRawSettings?.hasActiveRedaction == true { return .redacts }
        if image.developSettingsLoaded || !image.isImageFile { return .none }
        return .unknown
    }

    /// True when the photo redacts according to the in-memory copy, or — defensively, for a
    /// user-initiated action that can afford one small read — its sidecar does. A sidecar can
    /// carry redactions the in-memory copy lacks (an external edit the folder watcher has not
    /// reloaded yet, or a photo whose metadata batch has not landed).
    static func redactsIncludingSidecar(
        _ image: ImageFile,
        readSidecar: (URL) -> CameraRawSettings? = { XMPSidecarService().loadDevelopSettings(for: $0) }
    ) -> Bool {
        if knowledge(for: image) == .redacts { return true }
        guard image.isImageFile,
              image.sidecarModified != nil || !image.developSettingsLoaded else { return false }
        return readSidecar(image.url)?.hasActiveRedaction == true
    }

    // MARK: - Clean Feed

    /// A rendered frame of a photo may reach the Clean Feed (audience) display only when the
    /// photo does not redact, or the frame was rendered with its redactions.
    nonisolated static func mayPublishToCleanFeed(
        rendersRedaction: Bool,
        photo: RedactionKnowledge
    ) -> Bool {
        rendersRedaction || photo == .none
    }

    // MARK: - RAW+JPEG pairs

    /// Targets that are a non-RAW half of a RAW+JPEG pair whose same-stem RAW (same folder, in
    /// `candidates`) redacts while the target itself does not: publishing that JPEG would show
    /// the faces the photographer blurred on the RAW.
    static func unredactedPairedJPEGs(
        in targets: [ImageFile],
        candidates: [ImageFile]
    ) -> [ImageFile] {
        let nonRawTargets = targets.filter { !SupportedImageFormats.isRaw(url: $0.url) }
        guard !nonRawTargets.isEmpty else { return [] }
        var redactingRawStems: Set<String> = []
        for candidate in candidates
        where SupportedImageFormats.isRaw(url: candidate.url)
            && candidate.cameraRawSettings?.hasActiveRedaction == true {
            redactingRawStems.insert(stemKey(candidate.url))
        }
        guard !redactingRawStems.isEmpty else { return [] }
        return nonRawTargets.filter { target in
            target.cameraRawSettings?.hasActiveRedaction != true
                && redactingRawStems.contains(stemKey(target.url))
        }
    }

    private static func stemKey(_ url: URL) -> String {
        url.standardizedFileURL.deletingPathExtension().path
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Drag out of the app

    nonisolated enum OutsideDragDecision: Equatable, Sendable {
        case allow
        case blocked(message: String)

        var message: String? {
            if case .blocked(let message) = self { return message }
            return nil
        }
    }

    /// Whether `dragged` photos may leave the app as their original files. In-app drags (moves
    /// between folders) are not affected. A drag cannot show a Continue/Cancel prompt, so every
    /// case that would warn elsewhere refuses here and explains.
    static func outsideDragDecision(
        for dragged: [ImageFile],
        candidates: [ImageFile]
    ) -> OutsideDragDecision {
        let knowledge = dragged.map(knowledge(for:))
        if knowledge.contains(.redacts) { return .blocked(message: dragBlockedMessage) }
        if knowledge.contains(.unknown) { return .blocked(message: dragPendingMessage) }
        if !unredactedPairedJPEGs(in: dragged, candidates: candidates).isEmpty {
            return .blocked(message: pairedRawDragMessage)
        }
        return .allow
    }
}

/// Modal confirmations for the warn-but-allow paths. Kept apart from the pure decisions above
/// so those stay unit-testable.
@MainActor
enum RedactionPrivacyPrompt {
    /// NSAlert with a confirm and a Cancel button; true when the user confirms.
    static func confirm(messageText: String, informativeText: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Open in External Editor hands the original file to another app.
    static func confirmExternalEditor(for images: [ImageFile]) -> Bool {
        guard images.contains(where: { RedactionPrivacyGuard.redactsIncludingSidecar($0) }) else { return true }
        return confirm(
            messageText: images.count == 1 ? "This Photo Has Face Blurs" : "Some Photos Have Face Blurs",
            informativeText: RedactionPrivacyGuard.externalEditorMessage,
            confirmTitle: "Open Anyway"
        )
    }

    /// Forensic Analysis exports embed the original pixels by design.
    static func confirmAnalysisExport(containsRedactedPhoto: Bool) -> Bool {
        guard containsRedactedPhoto else { return true }
        return confirm(
            messageText: "Export Unblurred Original?",
            informativeText: RedactionPrivacyGuard.analysisExportMessage
                + " Face blurs are not applied to Analysis exports.",
            confirmTitle: "Export Anyway"
        )
    }

    /// Export, Save As and FTP of the unredacted JPEG half of a RAW+JPEG pair.
    static func confirmPairedJPEGs(in targets: [ImageFile], candidates: [ImageFile]) -> Bool {
        let flagged = RedactionPrivacyGuard.unredactedPairedJPEGs(in: targets, candidates: candidates)
        guard !flagged.isEmpty else { return true }
        let names = flagged.prefix(5).map(\.filename).joined(separator: ", ")
            + (flagged.count > 5 ? " and \(flagged.count - 5) more" : "")
        return confirm(
            messageText: flagged.count == 1 ? "JPEG Without Face Blurs" : "JPEGs Without Face Blurs",
            informativeText: (flagged.count == 1
                ? RedactionPrivacyGuard.pairedRawMessage
                : "The RAW versions of these photos have face blurs, but these JPEGs don't.")
                + "\n\n" + names,
            confirmTitle: "Continue"
        )
    }
}

extension AppCommand {
    /// Export, Save As and FTP commands handled by ContentView's file-operation switch: they
    /// publish rendered pixels of the selection (or the whole folder), so they first check for
    /// the unredacted JPEG half of a redacted RAW+JPEG pair. Render and Sign checks in its own
    /// handler.
    var publishesSelectionPixels: Bool {
        switch self {
        case .renderSelected, .advancedExportSelected, .renderAll, .saveAsJPEG, .saveAsPNG,
             .uploadSelected, .uploadAll:
            return true
        default:
            return false
        }
    }

    /// The folder-wide variants of `publishesSelectionPixels`.
    var publishesWholeFolder: Bool {
        self == .renderAll || self == .uploadAll
    }
}
