import Darwin
import Foundation

/// Disposable Debug-only storage for installed-pair UI qualification. This changes
/// storage locations only; the production socket protocol and signature checks apply.
nonisolated struct UITestNativeInvocationConfiguration: Sendable {
    let rootURL: URL
    let socketDirectory: URL

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["AAGEDAL_UI_TEST_NATIVE_INVOCATION"] == "1"
    }

    static var current: Self? {
        parse(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
    }

    static func parse(arguments: [String], environment: [String: String]) -> Self? {
        #if DEBUG
        guard arguments.contains("--ui-testing"), environment["AAGEDAL_UI_TEST_NATIVE_INVOCATION"] == "1" else { return nil }
        func value(_ flag: String) -> String? {
            guard arguments.filter({ $0 == flag }).count == 1,
                  let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let root = value("--ui-test-transcription-root"), root.hasPrefix("/"),
              let socket = value("--ui-test-transcription-socket"),
              socket.hasPrefix("/private/tmp/apa-integration-"),
              let suffix = socket.split(separator: "/").last,
              UUID(uuidString: String(suffix.dropFirst("apa-integration-".count))) != nil,
              socket.split(separator: "/").count == 3,
              !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        // Foundation shortens existing /private/tmp paths to the /tmp symlink.
        // Private durable stores walk every component with O_NOFOLLOW, so retain
        // the kernel's physical canonical spelling instead.
        guard let resolved = Darwin.realpath(root, nil) else { return nil }
        defer { free(resolved) }
        return Self(rootURL: URL(fileURLWithPath: String(cString: resolved), isDirectory: true),
            socketDirectory: URL(fileURLWithPath: socket, isDirectory: true))
        #else
        return nil
        #endif
    }

    var authorizationStore: MCPAuthorizationStore {
        let url = rootURL.appendingPathComponent("transcription-review-authorization.json")
        return .init(readConfigurationData: {
            // Unreadable or absent fixture authority stays default-off.
            try? Data(contentsOf: url)
        }, writeConfigurationData: { data in
            if let data { try data.write(to: url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        })
    }

    var plans: MCPVoiceTranscriptionPlanStore {
        .init(storageDirectory: rootURL.appendingPathComponent("transcription-review-plans"))
    }
    var requests: MCPVoiceTranscriptionReviewRequestStore {
        .init(storageDirectory: rootURL.appendingPathComponent("transcription-review-requests"))
    }
    var registry: AutomationOperationRegistry {
        .init(storageDirectory: rootURL.appendingPathComponent("transcription-review-operations"))
    }
    var facade: MCPAutomationFacade { .init(authorizationStore: authorizationStore) }

    func helperTools() -> MCPFoundationTools {
        let directory = socketDirectory
        return .init(authorizationStore: authorizationStore,
            patchPlans: .init(storageDirectory: rootURL.appendingPathComponent("isolated-patch-plans")),
            voiceTranscriptionPlans: plans, operationRegistry: registry,
            nativeReviewRequests: .init(storageDirectory: rootURL.appendingPathComponent("isolated-native-review")),
            voiceTranscriptionReviewRequests: requests, nativeReviewInvocation: { id, epoch in
                try AutomationNativeInvocationChannel.Client(directory: directory)
                    .invoke(.init(requestID: id, requestEpoch: epoch))
            })
    }
}
