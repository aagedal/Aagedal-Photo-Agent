// Run with: xcrun swiftc -parse-as-library 'Aagedal Photo Agent/Services/GGUFChatTemplate.swift' \
// 'Aagedal Photo Agent/Services/DescriptionModelDiscovery.swift' scripts/ci/test_description_model_discovery.swift \
// -o /tmp/test-model-discovery && /tmp/test-model-discovery
import Foundation
import CryptoKit

@main
struct DiscoveryChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ path: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
        func integer(_ n: UInt64, _ width: Int) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
        }
        func string(_ s: String) -> Data { integer(UInt64(s.utf8.count), 8) + Data(s.utf8) }
        let gguf = Data("GGUF".utf8) + integer(3, 4) + integer(0, 8) + integer(1, 8)
            + string("tokenizer.chat_template") + integer(8, 4) + string("{{ messages }}")
        let blob = try write("hf/models--org--model/blobs/weights", gguf)
        let snapshot = root.appendingPathComponent("hf/models--org--model/snapshots/revision")
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let ggufURL = snapshot.appendingPathComponent("model.gguf")
        try fm.createSymbolicLink(at: ggufURL, withDestinationURL: blob)
        _ = try write("hf/broken.gguf", Data("GGUF".utf8))
        _ = try write("hf/model-00001-of-00002.gguf", gguf)
        _ = try write("hf/models--org--mlx/snapshots/revision/config.json", Data(#"{"model_type":"qwen2","quantization":{"bits":4}}"#.utf8))
        _ = try write("hf/models--org--mlx/snapshots/revision/tokenizer_config.json", Data("{}".utf8))
        _ = try write("hf/models--org--mlx/snapshots/revision/tokenizer.json", Data("{}".utf8))
        _ = try write("hf/models--org--mlx/snapshots/revision/model.safetensors", Data([1]))
        let digest = String(repeating: "a", count: 64)
        let ollamaBlob = try write("ollama/blobs/sha256-" + digest, gguf)
        let manifest = #"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:DIGEST"}]}"#.replacingOccurrences(of: "DIGEST", with: digest)
        _ = try write("ollama/manifests/registry.ollama.ai/library/test/latest", Data(manifest.utf8))
        _ = try write("ollama/manifests/registry.ollama.ai/library/unsafe/latest", Data(manifest.replacingOccurrences(of: digest, with: "../../invalid").utf8))
        let locations = [
            DescriptionModelDiscovery.Location(url: root.appendingPathComponent("hf"), source: "Hugging Face"),
            DescriptionModelDiscovery.Location(url: snapshot, source: "llama.cpp"),
            DescriptionModelDiscovery.Location(url: root.appendingPathComponent("ollama"), source: "Ollama", ollama: true)
        ]
        let models = DescriptionModelDiscovery.discover(locations: locations)
        precondition(models.count == 3, "Discover complete MLX, HF symlink and Ollama model; deduplicate aliases, reject invalid/split files")
        precondition(models.contains { $0.url.resolvingSymlinksInPath().path == ggufURL.resolvingSymlinksInPath().path })
        precondition(models.contains { $0.url.resolvingSymlinksInPath().path == ollamaBlob.resolvingSymlinksInPath().path && $0.name == "test:latest" })
        precondition(models.contains { $0.name == "org/mlx" && $0.format == "MLX" })
        let hash = SHA256.hash(data: gguf).map { String(format: "%02x", $0) }.joined()
        let match = try DescriptionModelDiscovery.existingArtifact(byteCount: Int64(gguf.count), sha256: hash, models: models)
        let mismatch = try DescriptionModelDiscovery.existingArtifact(byteCount: Int64(gguf.count), sha256: String(repeating: "0", count: 64), models: models)
        precondition(match != nil)
        precondition(mismatch == nil)
        let hfMatch = try DescriptionModelDiscovery.existingArtifact(byteCount: Int64(gguf.count), sha256: hash,
            models: models.filter { $0.source == "Hugging Face" })
        precondition(hfMatch != nil, "Checksum reuse must follow Hugging Face snapshot symlinks")
        let configured = DescriptionModelDiscovery.locations(home: root, environment: ["HF_HOME": root.appendingPathComponent("custom-hf").path, "LLAMA_CACHE": root.appendingPathComponent("custom-llama").path, "OLLAMA_MODELS": root.appendingPathComponent("custom-ollama").path])
        precondition(configured[0].url.path == root.appendingPathComponent("custom-hf/hub").path)
        precondition(configured[2].url.path == root.appendingPathComponent("custom-llama").path)
        precondition(configured[4].url.path == root.appendingPathComponent("custom-ollama").path)
        // Removing cached weights invalidates discovery rather than selecting a dangling snapshot.
        try fm.removeItem(at: blob)
        precondition(!DescriptionModelDiscovery.discover(locations: locations).contains { $0.url.resolvingSymlinksInPath().path == ggufURL.resolvingSymlinksInPath().path })
        print("Model discovery checks passed")
    }
}
