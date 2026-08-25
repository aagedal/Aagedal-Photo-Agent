import AppKit

/// The complete set of text that the app may post as an accessibility announcement.
/// Associated values are intentionally limited to fixed-copy enums so paths, filenames,
/// identifiers, editorial content, and error descriptions cannot enter spoken output.
nonisolated enum AppAccessibilityAnnouncement: Equatable, Sendable {
    nonisolated enum Success: String, CaseIterable, Sendable {
        case captionSavedAndAdvanced = "Saved and moved to the next photo."
        case captionWroteAndAdvanced = "Wrote metadata and moved to the next photo."
        case templateSaved = "Template saved."
        case contentCredentialsLoaded = "Content Credentials inspection completed."
        case contentCredentialsNotFound = "No Content Credentials were found."
    }

    nonisolated enum Failure: String, CaseIterable, Sendable {
        case templateSave = "Template wasn’t saved. Your edits are still here. Retry the save or save a new copy."
        case contentCredentialsInspection = "Content Credentials could not be inspected. Retry is available."
        case contentCredentialsValidation = "Content Credentials validation could not be completed. Retry is available."
    }

    nonisolated enum Cancellation: String, CaseIterable, Sendable {
        case templateEditing = "Template editing cancelled."
        case contentCredentialsInspection = "Content Credentials inspection cancelled."
    }

    nonisolated enum Recovery: String, CaseIterable, Sendable {
        case templateSaved = "Template saved after recovery."
        case contentCredentialsInspection = "Content Credentials inspection completed after retry."
        case contentCredentialsNotFound = "No Content Credentials were found after retry."
    }

    case success(Success)
    case failure(Failure)
    case cancellation(Cancellation)
    case recovery(Recovery)

    var spokenText: String {
        switch self {
        case .success(let announcement): announcement.rawValue
        case .failure(let announcement): announcement.rawValue
        case .cancellation(let announcement): announcement.rawValue
        case .recovery(let announcement): announcement.rawValue
        }
    }

    static var allFixedCopy: [Self] {
        Success.allCases.map(Self.success)
            + Failure.allCases.map(Self.failure)
            + Cancellation.allCases.map(Self.cancellation)
            + Recovery.allCases.map(Self.recovery)
    }
}

@MainActor
enum AccessibilityAnnouncementCenter {
    static func post(_ announcement: AppAccessibilityAnnouncement) {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.spokenText,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
