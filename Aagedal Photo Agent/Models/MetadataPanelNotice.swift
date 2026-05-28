import Foundation

/// Lightweight, dismissible notice surfaced inside the metadata panel.
/// Used for bulk-add outcomes (template apply, partial-keyword promotion,
/// Quick List menu picks) where an inline field flash would be missed
/// because the user's focus isn't on the chip-input field.
struct MetadataPanelNotice: Identifiable, Equatable, Sendable {
    enum Severity: Sendable {
        case info
        case warning
        case error
    }

    let id = UUID()
    let title: String
    let detail: [String]
    let severity: Severity
}
