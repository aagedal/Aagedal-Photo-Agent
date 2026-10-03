import Foundation

/// One-shot subprocesses release all model/Metal memory after each caption. The service
/// owns admission/cancellation; a future batch worker can reuse the same request API.
nonisolated enum LlamaCPPDescriptionBackend {
    static func executable(bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/llama.cpp/llama-completion")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                "The bundled llama.cpp runtime is missing. Rebuild or reinstall the app."])
        }
        return url
    }

    static func install(model: DescriptionAssistantDownloadModel, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        _ = try executable()
        return try await WhisperModelDownloadService(directory: DescriptionAssistantDownloadModel.storageDirectory)
            .download(model.artifact, progress: progress)
    }

    static func generate(prompt: String, model: URL) async throws -> String {
        let executable = try executable()
        let accessing = model.startAccessingSecurityScopedResource()
        defer { if accessing { model.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("prompt.txt")
        // Gemma 3/Borealis single-turn chat template. llama.cpp adds the BOS token.
        let formatted = "<start_of_turn>user\n\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))<end_of_turn>\n<start_of_turn>model\n"
        try formatted.write(to: file, atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let output = try await Process.run(executableURL: executable, arguments: [
            "--model", model.path, "--file", file.path, "--ctx-size", "8192",
            "--n-predict", "768", "--temp", "0.1", "--gpu-layers", "99",
            "--no-conversation", "--no-display-prompt", "--no-context-shift",
            "--simple-io", "--color", "off", "--special"
        ], currentDirectoryURL: executable.deletingLastPathComponent())
        try Task.checkCancellation()
        return try caption(from: output.stdout)
    }

    static func caption(from output: String) throws -> String {
        // Pinned completion emits this suffix only on an actual EOG token. A token
        // or context limit must never become an apparently complete proposal.
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = " [end of text]"
        guard text.hasSuffix(marker) else { throw DescriptionAssistantError.outputLimit }
        text.removeLast(marker.count)
        for token in ["<end_of_turn>", "<eos>"] where text.hasSuffix(token) {
            text.removeLast(token.count)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DescriptionAssistantError.emptyOutput }
        return text
    }
}
