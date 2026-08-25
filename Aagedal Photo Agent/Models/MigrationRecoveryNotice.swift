import Foundation
import Observation

/// Coarse, user-facing categories for retryable one-shot migrations.
///
/// These labels are deliberately fixed. Migration errors can contain paths,
/// filenames, list contents, or person data and must never be interpolated into
/// a launch notice.
enum MigrationRecoveryCategory: String, CaseIterable, Sendable {
    case keywordLists
    case knownPeople

    var displayName: String {
        switch self {
        case .keywordLists: "Keyword Lists"
        case .knownPeople: "Known People"
        }
    }
}

struct MigrationRecoveryNotice: Equatable, Sendable {
    let affectedCategories: [MigrationRecoveryCategory]

    var title: String { "Some data still needs updating" }

    var message: String {
        let names = affectedCategories.map(\.displayName)
        let categoryText: String
        switch names.count {
        case 0:
            categoryText = "app data"
        case 1:
            categoryText = names[0]
        default:
            categoryText = names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        return "Photo Agent could not finish updating \(categoryText). Your existing data was kept. Photo Agent will try again the next time it opens."
    }
}

/// Retains launch-time migration failures until the main view can present them.
/// This is state rather than a fire-and-forget notification because Keyword
/// Lists migration runs before `ContentView` subscribes to app events.
@Observable
@MainActor
final class MigrationRecoveryNoticeCenter {
    static let shared = MigrationRecoveryNoticeCenter()

    private(set) var affectedCategories: Set<MigrationRecoveryCategory> = []

    var notice: MigrationRecoveryNotice? {
        guard !affectedCategories.isEmpty else { return nil }
        let ordered = MigrationRecoveryCategory.allCases.filter(affectedCategories.contains)
        return MigrationRecoveryNotice(affectedCategories: ordered)
    }

    func recordFailure(in category: MigrationRecoveryCategory) {
        affectedCategories.insert(category)
    }

    func clear(_ category: MigrationRecoveryCategory) {
        affectedCategories.remove(category)
    }

    func dismiss() {
        affectedCategories.removeAll()
    }
}
