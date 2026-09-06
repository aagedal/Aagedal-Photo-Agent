import AppKit
import Foundation

nonisolated enum AdobeDNGCompression: Sendable {
    case lossless
    case lossy

    var commandLineOption: String {
        switch self {
        case .lossless: return "-c"
        case .lossy: return "-lossy"
        }
    }
}

nonisolated enum AdobeDNGConverterError: LocalizedError {
    case notInstalled
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Adobe DNG Converter is not installed. Download and install the free converter from Adobe, then try again."
        case .noOutput(let filename):
            return "Adobe DNG Converter completed without creating \(filename)."
        }
    }
}

nonisolated enum AdobeDNGConverterService {
    static let bundleIdentifier = "com.adobe.DNGConverter"
    static let downloadURL = URL(
        string: "https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html"
    )!

    nonisolated static func executableURL(in applicationURL: URL) -> URL? {
        let executable = applicationURL
            .appendingPathComponent("Contents/MacOS/Adobe DNG Converter")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        return executable
    }

    nonisolated static func conversionArguments(
        sourceURL: URL,
        destinationURL: URL,
        compression: AdobeDNGCompression
    ) -> [String] {
        [
            compression.commandLineOption,
            "-d", destinationURL.deletingLastPathComponent().path,
            "-o", destinationURL.lastPathComponent,
            sourceURL.path
        ]
    }

    @discardableResult
    nonisolated static func convert(
        sourceURL: URL,
        destinationFolder: URL,
        compression: AdobeDNGCompression,
        executableURL: URL
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AdobeDNGConverterError.notInstalled
        }

        let destinationURL = RAWArchiveService.uniqueDestinationURL(
            for: sourceURL,
            in: destinationFolder,
            extension: "dng"
        )
        let arguments = conversionArguments(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            compression: compression
        )
        do {
            _ = try await Process.run(
                executableURL: executableURL,
                arguments: arguments
            )
        } catch {
            // The converter may leave an incomplete destination after failure or
            // cancellation. It is newly created by this operation and safe to discard.
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw AdobeDNGConverterError.noOutput(destinationURL.lastPathComponent)
        }

        do {
            try RAWArchiveService.copySidecarIfPresent(
                from: sourceURL,
                to: destinationURL
            )
        } catch {
            // Avoid reporting a complete archive when its authoritative RAW
            // develop sidecar could not be preserved.
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return destinationURL
    }
}

nonisolated enum AdobeDNGDiscoveryResult: Sendable, Equatable {
    case complete(executableURL: URL?)
    case cancelled(inspectedCount: Int)
}

/// Launch Services lookup and executable probes may block on application volumes.
/// Keep the entire ordered lookup on a serialized worker, including fallback probes.
actor AdobeDNGDiscoveryService {
    static let shared = AdobeDNGDiscoveryService()
    private let applications: @Sendable () -> [URL]
    private let executable: @Sendable (URL) -> URL?

    init(
        applications: @escaping @Sendable () -> [URL] = {
            var urls: [URL] = []
            if let registered = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: AdobeDNGConverterService.bundleIdentifier
            ) {
                urls.append(registered)
            }
            urls.append(URL(fileURLWithPath: "/Applications/Adobe DNG Converter.app", isDirectory: true))
            urls.append(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Adobe DNG Converter.app", isDirectory: true))
            return urls
        },
        executable: @escaping @Sendable (URL) -> URL? = AdobeDNGConverterService.executableURL
    ) {
        self.applications = applications
        self.executable = executable
    }

    func discover() -> AdobeDNGDiscoveryResult {
        guard !Task.isCancelled else { return .cancelled(inspectedCount: 0) }
        let candidates = applications()
        var inspectedCount = 0
        guard !Task.isCancelled else { return .cancelled(inspectedCount: 0) }
        for candidate in candidates {
            guard !Task.isCancelled else { return .cancelled(inspectedCount: inspectedCount) }
            let resolved = executable(candidate)
            inspectedCount += 1
            guard !Task.isCancelled else { return .cancelled(inspectedCount: inspectedCount) }
            if let resolved { return .complete(executableURL: resolved) }
        }
        return .complete(executableURL: nil)
    }
}

/// Context menus read a cached snapshot. The archive action always performs a fresh
/// asynchronous lookup so installation/removal since the last menu cannot select a stale tool.
@MainActor
final class AdobeDNGDiscoveryStore {
    static let shared = AdobeDNGDiscoveryStore()
    private(set) var hasChecked = false
    private(set) var executableURL: URL?
    private let service: AdobeDNGDiscoveryService
    private var requestID = UUID()
    private var backgroundRefresh: Task<Void, Never>?

    init(service: AdobeDNGDiscoveryService = .shared) { self.service = service }

    func refreshInBackground() {
        guard backgroundRefresh == nil else { return }
        backgroundRefresh = Task {
            _ = await refresh()
            backgroundRefresh = nil
        }
    }

    func refresh() async -> AdobeDNGDiscoveryResult {
        let id = UUID()
        requestID = id
        let result = await service.discover()
        if id == requestID, !Task.isCancelled, case .complete(let url) = result {
            executableURL = url
            hasChecked = true
        }
        return result
    }
}
