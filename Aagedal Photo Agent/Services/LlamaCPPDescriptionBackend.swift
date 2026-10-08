import Foundation

/// One-shot subprocesses release all model/Metal memory after each caption. The service
/// owns admission/cancellation; a future batch worker can reuse the same request API.
nonisolated enum LlamaCPPDescriptionBackend {
    static func executable(bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Resources/llama-runtime/llama-completion")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                "The bundled llama.cpp runtime is missing. Rebuild or reinstall the app."])
        }
        return url
    }

    static func install(model: DescriptionAssistantDownloadModel, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        _ = try executable()
        return try await WhisperModelDownloadService(directory: DescriptionAssistantDownloadModel.storageDirectory,
            maximumModelByteCount: DescriptionAssistantDownloadModel.maximumDownloadByteCount)
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
        let template = folder.appendingPathComponent("chat-template.jinja")
        try GGUFChatTemplate.writingTemplate(from: model).write(to: template, atomically: true, encoding: .utf8)
        try prompt.write(to: file, atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let output = try await Process.run(executableURL: executable,
            arguments: arguments(model: model, promptFile: file, templateFile: template),
            currentDirectoryURL: executable.deletingLastPathComponent())
        try Task.checkCancellation()
        return try caption(from: output.stdout)
    }

    static func arguments(model: URL, promptFile: URL, templateFile: URL) -> [String] {
        ["--model", model.path, "--file", promptFile.path, "--ctx-size", "8192",
         "--n-predict", "768", "--temp", "0.1", "--gpu-layers", "99",
         "--jinja", "--chat-template-file", templateFile.path, "--conversation", "--single-turn",
         "--no-escape", "--no-display-prompt", "--no-context-shift",
         "--simple-io", "--color", "off", "--special"]
    }

    static func caption(from output: String) throws -> String {
        // Pinned completion emits this suffix only on an actual EOG token. A token
        // or context limit must never become an apparently complete proposal.
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = " [end of text]"
        guard text.hasSuffix(marker) else { throw DescriptionAssistantError.outputLimit }
        text.removeLast(marker.count)
        for token in ["<end_of_turn>", "<eos>", "<|turn_end|>", "<turn|>", "<|im_end|>", "</s>"] where text.hasSuffix(token) {
            text.removeLast(token.count)
        }
        // Never expose reasoning as an editable caption, even if a model emits it
        // despite the non-thinking template. Incomplete thought blocks are rejected.
        for (start, end) in [("<think>", "</think>"), ("<|channel>thought", "<channel|>")] {
            while let opening = text.range(of: start) {
                guard let closing = text.range(of: end, range: opening.upperBound..<text.endIndex) else {
                    throw DescriptionAssistantError.outputLimit
                }
                text.removeSubrange(opening.lowerBound..<closing.upperBound)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DescriptionAssistantError.emptyOutput }
        return text
    }
}
