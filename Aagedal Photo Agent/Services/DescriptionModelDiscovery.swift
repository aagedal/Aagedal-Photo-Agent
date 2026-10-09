import Foundation
import CryptoKit

nonisolated struct DiscoveredDescriptionModel: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let source: String
    let format: String
    var id: String { url.path }
    var title: String { "\(name) · \(format) · \(source)" }
}

/// Reads shared caches in place. Never copies, changes or deletes another tool's files.
nonisolated enum DescriptionModelDiscovery {
    struct Location: Sendable {
        let url: URL
        let source: String
        var ollama = false
    }

    /// Reuse a catalog download only when its complete bytes match the pinned artifact.
    /// This also identifies Ollama blobs whose names contain no model filename.
    static func existingArtifact(byteCount: Int64, sha256: String,
                                 models: [DiscoveredDescriptionModel]) throws -> URL? {
        for model in models where model.format == "GGUF" {
            try Task.checkCancellation()
            guard let size = try? model.url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == byteCount,
                  let handle = try? FileHandle(forReadingFrom: model.url) else { continue }
            defer { try? handle.close() }
            do {
                var hash = SHA256()
                var read: Int64 = 0
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                    try Task.checkCancellation()
                    read += Int64(bytes.count)
                    if read > byteCount { break }
                    hash.update(data: bytes)
                }
                if read == byteCount && hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 {
                    return model.url
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A shared cache may disappear or become unreadable while another tool updates it.
                continue
            }
        }
        return nil
    }

    static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> [Location] {
        func path(_ key: String, fallback: URL) -> URL {
            guard let value = environment[key], !value.isEmpty else { return fallback }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        let cache = path("XDG_CACHE_HOME", fallback: home.appendingPathComponent(".cache"))
        let hf = path("HF_HOME", fallback: cache.appendingPathComponent("huggingface"))
        return [
            Location(url: path("HF_HUB_CACHE", fallback: hf.appendingPathComponent("hub")), source: "Hugging Face"),
            Location(url: home.appendingPathComponent(".cache/huggingface/hub"), source: "Hugging Face"),
            Location(url: path("LLAMA_CACHE", fallback: home.appendingPathComponent("Library/Caches/llama.cpp")), source: "llama.cpp"),
            Location(url: cache.appendingPathComponent("llama.cpp"), source: "llama.cpp"),
            Location(url: path("OLLAMA_MODELS", fallback: home.appendingPathComponent(".ollama/models")), source: "Ollama", ollama: true)
        ]
    }

    static func isGGUF(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let limit = 8 * 1_024 * 1_024
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isMLXFolder(_ url: URL) -> Bool {
        guard let config = json(url.appendingPathComponent("config.json")),
              config["model_type"] is String,
              json(url.appendingPathComponent("tokenizer_config.json")) != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
              files.contains(where: { $0.pathExtension == "safetensors" && FileManager.default.isReadableFile(atPath: $0.path) }),
              files.contains(where: { ["tokenizer.json", "tokenizer.model"].contains($0.lastPathComponent) }) else { return false }
        if let index = json(url.appendingPathComponent("model.safetensors.index.json")),
           let weights = index["weight_map"] as? [String: String] {
            return !weights.isEmpty && Set(weights.values).allSatisfy {
                !$0.contains("/") && FileManager.default.isReadableFile(atPath: url.appendingPathComponent($0).path)
            }
        }
        return files.contains { $0.lastPathComponent == "model.safetensors" || $0.lastPathComponent == "weights.safetensors" }
    }

    static func discover(locations: [Location] = locations()) -> [DiscoveredDescriptionModel] {
        var found: [DiscoveredDescriptionModel] = []
        var seen = Set<String>()
        var roots = Set<String>()
        func add(_ url: URL, name: String, source: String, format: String) {
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { return }
            found.append(.init(url: url, name: name, source: source, format: format))
        }
        for location in locations {
            guard !Task.isCancelled, roots.insert(location.url.standardizedFileURL.path).inserted else { continue }
            let root = location.ollama ? location.url.appendingPathComponent("manifests") : location.url
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            var count = 0
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { return found }
                count += 1
                if count > 20_000 { break }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory {
                    if ["blobs", "refs", ".git"].contains(url.lastPathComponent) || enumerator.level > 8 {
                        enumerator.skipDescendants()
                    } else if !location.ollama && isMLXFolder(url) {
                        let repo = url.pathComponents.first { $0.hasPrefix("models--") }
                        let name = repo.map { $0.dropFirst(8).replacingOccurrences(of: "--", with: "/") } ?? url.lastPathComponent
                        add(url, name: name, source: location.source, format: "MLX")
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if location.ollama {
                    guard let manifest = json(url), let layers = manifest["layers"] as? [[String: Any]],
                          !layers.contains(where: { ($0["mediaType"] as? String) == "application/vnd.ollama.image.adapter" }) else { continue }
                    let models = layers.filter { ($0["mediaType"] as? String) == "application/vnd.ollama.image.model" }
                    guard models.count == 1, let digest = models[0]["digest"] as? String,
                          digest.hasPrefix("sha256:"), digest.count == 71,
                          digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else { continue }
                    let blob = location.url.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
                    guard isGGUF(blob), (try? GGUFChatTemplate.read(from: blob)) != nil else { continue }
                    add(blob, name: url.deletingLastPathComponent().lastPathComponent + ":" + url.lastPathComponent,
                        source: location.source, format: "GGUF")
                } else if url.pathExtension.lowercased() == "gguf" {
                    // Split GGUFs require a complete shard set; do not offer individual shards.
                    guard !url.lastPathComponent.contains("-of-"), isGGUF(url),
                          (try? GGUFChatTemplate.read(from: url)) != nil else { continue }
                    add(url, name: url.deletingPathExtension().lastPathComponent, source: location.source, format: "GGUF")
                }
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
