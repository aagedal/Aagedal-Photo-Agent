import Foundation

/// Opt-in launch configuration used only by the macOS UI smoke target.
///
/// Normal launches never contain `--ui-testing`, so none of these paths can change a
/// production session. The seam lets UI tests bypass system file panels while still
/// exercising the app's real browser, import, Caption, Batch Rename, and Deadline views.
struct UITestLaunchConfiguration {
    enum Workflow: String {
        case openFolder = "open-folder"
        case importPreflight = "import-preflight"
        case caption
        case batchRename = "batch-rename"
        case deadline
        case recoveryError = "recovery-error"
    }

    let isEnabled: Bool
    let workflow: Workflow?
    let folderURL: URL?
    let sourceURL: URL?
    let destinationURL: URL?
    let profileStoreURL: URL?

    static let current = Self(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        isEnabled = arguments.contains("--ui-testing")
        workflow = value(after: "--ui-test-workflow").flatMap(Workflow.init(rawValue:))
        folderURL = value(after: "--ui-test-folder").map { URL(fileURLWithPath: $0) }
        sourceURL = value(after: "--ui-test-source").map { URL(fileURLWithPath: $0) }
        destinationURL = value(after: "--ui-test-destination").map { URL(fileURLWithPath: $0) }
        profileStoreURL = value(after: "--ui-test-profile-store").map { URL(fileURLWithPath: $0) }
    }
}
