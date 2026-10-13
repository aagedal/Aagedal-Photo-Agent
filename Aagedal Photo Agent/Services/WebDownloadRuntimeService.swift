import Foundation

actor WebDownloadRuntimeService {
    static let shared = WebDownloadRuntimeService()
    private let support: URL
    private let bundled: URL
    private let bridge: URL
    private var updating = false

    enum RuntimeError: LocalizedError {
        case unavailable, invalidResponse, busy
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The bundled web downloader runtime is missing. Reinstall Photo Agent."
            case .invalidResponse: "The web downloader returned an incompatible response."
            case .busy: "A downloader update is already running."
            case .failed(let message): message
            }
        }
    }

    init(resourcesURL: URL? = nil, supportURL: URL? = nil) {
        let resources = resourcesURL ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
        bundled = resources.appendingPathComponent("web-download-runtime")
        let flatBridge = resources.appendingPathComponent("web_download_bridge.py")
        bridge = FileManager.default.fileExists(atPath: flatBridge.path) ? flatBridge
            : resources.appendingPathComponent("WebDownloads/web_download_bridge.py")
        support = supportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AagedalPhotoAgent/WebDownloads", isDirectory: true)
    }

    private func currentGeneration() -> String {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("current.json")),
              let generation = try? JSONDecoder().decode(String.self, from: data),
              UUID(uuidString: generation) != nil,
              FileManager.default.fileExists(atPath: support.appendingPathComponent(generation + "/packages.json").path)
        else { return "bundled" }
        return generation
    }

    private func packages(_ generation: String) throws -> URL {
        if generation == "bundled" { return bundled.appendingPathComponent("packages") }
        guard UUID(uuidString: generation) != nil else { throw RuntimeError.invalidResponse }
        return support.appendingPathComponent(generation, isDirectory: true)
    }

    private struct Response<T: Decodable & Sendable>: Decodable, Sendable {
        let `protocol`: Int
        let result: T?
        let error: String?
    }

    private func execute<T: Decodable & Sendable>(
        _ request: [String: Any], generation: String, as type: T.Type
    ) async throws -> T {
        let python = bundled.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: bridge.path) else { throw RuntimeError.unavailable }
        var payload = request
        payload["packages"] = try packages(generation).path
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let output = try await Process.run(executableURL: python, arguments: ["-I", "-B", bridge.path, input.path],
                                           allowNonZeroExit: true)
        try Task.checkCancellation()
        guard let data = output.stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response<T>.self, from: data),
              response.protocol == 1 else { throw RuntimeError.invalidResponse }
        if let error = response.error { throw RuntimeError.failed(error) }
        guard let result = response.result else { throw RuntimeError.invalidResponse }
        return result
    }

    func installedVersions() async throws -> [String: String] {
        try await execute(["action": "versions"], generation: currentGeneration(), as: [String: String].self)
    }

    func availableVersions() async throws -> [String: String] {
        try await execute(["action": "available"], generation: "bundled", as: [String: String].self)
    }

    func update(to versions: [String: String]) async throws -> [String: String] {
        guard !updating else { throw RuntimeError.busy }
        updating = true
        defer { updating = false }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let generation = UUID().uuidString
        let destination = support.appendingPathComponent(generation)
        var activated = false
        defer { if !activated { try? FileManager.default.removeItem(at: destination) } }
        let _: [String: String] = try await execute(
            ["action": "update", "versions": versions, "destination": destination.path],
            generation: "bundled", as: [String: String].self)
        let verified = try await execute(["action": "versions"], generation: generation, as: [String: String].self)
        guard verified == versions else { throw RuntimeError.invalidResponse }
        try Task.checkCancellation()
        try JSONEncoder().encode(generation).write(to: support.appendingPathComponent("current.json"), options: .atomic)
        activated = true
        return verified
    }

    func restoreBundled() throws {
        guard !updating else { throw RuntimeError.busy }
        let pointer = support.appendingPathComponent("current.json")
        if FileManager.default.fileExists(atPath: pointer.path) { try FileManager.default.removeItem(at: pointer) }
        // Retain generations: an in-flight import may still be using one.
    }

    func inspect(url: String, cookies: URL?) async throws -> WebPostInspection {
        let generation = currentGeneration()
        var request: [String: Any] = ["action": "inspect", "url": url]
        if let cookies { request["cookies"] = cookies.path }
        var inspection = try await execute(request, generation: generation, as: WebPostInspection.self)
        inspection.generation = generation
        return inspection
    }

    func download(_ inspection: WebPostInspection, selected: Set<String>, cookies: URL?, to destination: URL) async throws -> WebDownloadResult {
        let items = inspection.items.filter { selected.contains($0.id) }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items))
        var request: [String: Any] = ["action": "download", "url": inspection.url, "items": encoded,
                                      "destination": destination.path]
        if let cookies { request["cookies"] = cookies.path }
        if let ffmpeg = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) { request["ffmpeg"] = ffmpeg.path }
        return try await execute(request, generation: inspection.generation, as: WebDownloadResult.self)
    }
}
