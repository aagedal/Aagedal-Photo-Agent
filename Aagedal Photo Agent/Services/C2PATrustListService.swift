import Foundation
import os

nonisolated private let trustListLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "C2PATrustList")

/// Public state shown in Settings. A cached list remains usable even when an
/// attempted refresh failed, so validation never loses its last known-good
/// trust anchors merely because the device is offline.
nonisolated struct C2PATrustListStatus: Sendable {
    let isAvailable: Bool
    let hasLegacyCompatibilityList: Bool
    let lastRefreshed: Date?
    let lastError: String?
}

/// A complete local c2patool trust configuration. The legacy list is checked
/// only after the official list fails to recognize an otherwise valid signer.
nonisolated struct C2PATrustConfiguration: Sendable {
    let name: String
    let source: C2PATrustSource
    let arguments: [String]
    let fileURLs: [URL]
}

/// Maintains the official C2PA trust-anchor list as a small local PEM cache.
/// Validation reads only this local file; it never performs a network request.
actor C2PATrustListService {
    static let shared = C2PATrustListService()

    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    static let officialTrustListURL = URL(string: "https://raw.githubusercontent.com/c2pa-org/conformance-public/refs/heads/main/trust-list/C2PA-TRUST-LIST.pem")!
    static let interimAnchorsURL = URL(string: "https://contentcredentials.org/trust/anchors.pem")!
    static let interimAllowedListURL = URL(string: "https://contentcredentials.org/trust/allowed.sha256.txt")!
    static let interimTrustConfigURL = URL(string: "https://contentcredentials.org/trust/store.cfg")!

    private var refreshTask: Task<C2PATrustListStatus, Error>?

    private var trustAnchorsURL: URL {
        AppPaths.c2paTrustDirectory.appendingPathComponent("official-c2pa-trust-anchors.pem")
    }

    private var interimAnchorsFileURL: URL {
        AppPaths.c2paTrustDirectory.appendingPathComponent("interim-trust-anchors.pem")
    }

    private var interimAllowedListFileURL: URL {
        AppPaths.c2paTrustDirectory.appendingPathComponent("interim-allowed-list.txt")
    }

    private var interimTrustConfigFileURL: URL {
        AppPaths.c2paTrustDirectory.appendingPathComponent("interim-trust-config.cfg")
    }

    /// Starts a refresh only for a missing or stale list. Safe to call every
    /// launch; concurrent callers share a single in-flight download.
    func refreshIfNeeded() async {
        guard !AppPaths.isTestProcess else { return }
        let current = status()
        guard !current.isAvailable || isStale(current.lastRefreshed) else { return }
        _ = try? await refreshNow()
    }

    /// Downloads and atomically installs fresh official trust anchors. The
    /// existing cache remains in place when the download or validation fails.
    func refreshNow() async throws -> C2PATrustListStatus {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task<C2PATrustListStatus, Error> {
            try await self.downloadAndInstall()
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func status() -> C2PATrustListStatus {
        let available = FileManager.default.fileExists(atPath: trustAnchorsURL.path)
        let hasLegacyCompatibilityList = [
            interimAnchorsFileURL,
            interimAllowedListFileURL,
            interimTrustConfigFileURL,
        ].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let lastRefreshed = AppDefaults.store.object(forKey: UserDefaultsKeys.c2paTrustListLastRefreshed) as? Date
        let lastError = AppDefaults.store.string(forKey: UserDefaultsKeys.c2paTrustListLastError)
        return C2PATrustListStatus(
            isAvailable: available,
            hasLegacyCompatibilityList: hasLegacyCompatibilityList,
            lastRefreshed: lastRefreshed,
            lastError: lastError
        )
    }

    /// Local policy configurations for c2patool's `trust` command. This method
    /// never waits for a network request.
    func cachedTrustConfigurations() -> [C2PATrustConfiguration] {
        var configurations: [C2PATrustConfiguration] = []
        if FileManager.default.fileExists(atPath: trustAnchorsURL.path) {
            configurations.append(C2PATrustConfiguration(
                name: "official C2PA trust list",
                source: .official,
                arguments: ["--trust_anchors=\(trustAnchorsURL.path(percentEncoded: false))"],
                fileURLs: [trustAnchorsURL]
            ))
        }
        if [interimAnchorsFileURL, interimAllowedListFileURL, interimTrustConfigFileURL]
            .allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            configurations.append(C2PATrustConfiguration(
                name: "legacy C2PA compatibility list",
                source: .legacy,
                arguments: [
                    "--trust_anchors=\(interimAnchorsFileURL.path(percentEncoded: false))",
                    "--allowed_list=\(interimAllowedListFileURL.path(percentEncoded: false))",
                    "--trust_config=\(interimTrustConfigFileURL.path(percentEncoded: false))",
                ],
                fileURLs: [interimAnchorsFileURL, interimAllowedListFileURL, interimTrustConfigFileURL]
            ))
        }
        return configurations
    }

    private func isStale(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) >= Self.refreshInterval
    }

    private func downloadAndInstall() async throws -> C2PATrustListStatus {
        do {
            try await downloadAndReplace(
                from: Self.officialTrustListURL,
                at: trustAnchorsURL,
                validator: Self.isValidTrustAnchorPEM
            )

            // The interim list is frozen, but still recognizes many otherwise-valid
            // Content Credentials created before the official program launched.
            // Treat it as a compatibility supplement: the official list remains the
            // primary trust policy even if this secondary download is unavailable.
            do {
                try await downloadAndReplace(
                    from: Self.interimAnchorsURL,
                    at: interimAnchorsFileURL,
                    validator: Self.isValidTrustAnchorPEM
                )
                try await downloadAndReplace(
                    from: Self.interimAllowedListURL,
                    at: interimAllowedListFileURL,
                    validator: Self.isValidInterimAllowedList
                )
                try await downloadAndReplace(
                    from: Self.interimTrustConfigURL,
                    at: interimTrustConfigFileURL,
                    validator: Self.isValidInterimTrustConfig
                )
            } catch {
                trustListLogger.error("Could not refresh legacy C2PA compatibility list: \(error.localizedDescription, privacy: .private)")
            }

            let refreshed = Date()
            AppDefaults.store.set(refreshed, forKey: UserDefaultsKeys.c2paTrustListLastRefreshed)
            AppDefaults.store.removeObject(forKey: UserDefaultsKeys.c2paTrustListLastError)
            trustListLogger.info("Refreshed C2PA trust lists")
            return status()
        } catch {
            let message = error.localizedDescription
            AppDefaults.store.set(message, forKey: UserDefaultsKeys.c2paTrustListLastError)
            trustListLogger.error("Could not refresh official C2PA trust anchors: \(message, privacy: .private)")
            throw error
        }
    }

    private func downloadAndReplace(
        from sourceURL: URL,
        at destinationURL: URL,
        validator: @Sendable (Data) -> Bool
    ) async throws {
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw C2PATrustListError.invalidServerResponse
        }
        guard validator(data) else {
            throw C2PATrustListError.invalidTrustData
        }

        let fileManager = FileManager.default
        let stagedURL = AppPaths.c2paTrustDirectory
            .appendingPathComponent("trust-list-\(UUID().uuidString).tmp")
        try data.write(to: stagedURL, options: [.atomic])
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
            } else {
                try fileManager.moveItem(at: stagedURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    /// A small sanity check before replacing the cached security policy. c2patool
    /// performs full certificate parsing; this prevents saving an HTML error page
    /// or an unexpectedly large response as a trust-anchor file.
    nonisolated static func isValidTrustAnchorPEM(_ data: Data) -> Bool {
        guard data.count >= 128, data.count <= 5_000_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("-----BEGIN CERTIFICATE-----")
            && text.contains("-----END CERTIFICATE-----")
    }

    nonisolated static func isValidInterimAllowedList(_ data: Data) -> Bool {
        guard data.count >= 32, data.count <= 5_000_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces).count >= 64
        }
    }

    nonisolated static func isValidInterimTrustConfig(_ data: Data) -> Bool {
        guard data.count >= 2, data.count <= 1_000_000,
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("1.")
    }
}

private enum C2PATrustListError: LocalizedError {
    case invalidServerResponse
    case invalidTrustData

    var errorDescription: String? {
        switch self {
        case .invalidServerResponse:
            return "The official C2PA trust-list server returned an invalid response."
        case .invalidTrustData:
            return "The downloaded C2PA trust list had an unsupported format."
        }
    }
}
