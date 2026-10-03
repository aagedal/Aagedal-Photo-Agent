import Foundation

/// Curated Gemma 3 instruction models share the completion backend and chat format.
/// Every download has an immutable revision, exact size, checksum and distinct filename.
nonisolated enum DescriptionAssistantDownloadModel: String, CaseIterable, Identifiable, Sendable {
    case borealis, gemma3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .borealis: "Borealis 4B Q4_K_M"
        case .gemma3: "Gemma 3 4B Instruct Q4_K_M"
        }
    }
    var purpose: String {
        switch self {
        case .borealis: "Optimized for Norwegian Bokmål and Nynorsk."
        case .gemma3: "General-purpose multilingual model, including English."
        }
    }
    var sourceURL: URL {
        switch self {
        case .borealis: URL(string: "https://huggingface.co/NbAiLab/borealis-4b-gguf")!
        case .gemma3: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF")!
        }
    }
    var artifact: WhisperDownloadableModel {
        switch self {
        case .borealis:
            WhisperDownloadableModel(id: "borealis-4b-q4-k-m", title: title, byteCount: 2_489_894_560,
                sha256: "4486e86d94194c631e8c18b530b796b1287fdf959f9a0ac1fb17441beadb8c51",
                url: sourceURL.appendingPathComponent("resolve/c5611e7f4aa5abe4dbd2bf2337fac71b40f953f7/borealis-4b-Q4_K_M.gguf"),
                fileName: "borealis-4b-Q4_K_M.gguf")
        case .gemma3:
            WhisperDownloadableModel(id: "gemma-3-4b-it-q4-k-m", title: title, byteCount: 2_489_757_856,
                sha256: "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863",
                url: sourceURL.appendingPathComponent("resolve/d0976223747697cb51e056d85c532013931fe52e/gemma-3-4b-it-Q4_K_M.gguf"),
                fileName: "gemma-3-4b-it-Q4_K_M.gguf")
        }
    }
    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aagedal Photo Agent/DescriptionModels", isDirectory: true)
    }
    var installedFile: URL { Self.storageDirectory.appendingPathComponent(artifact.fileName!) }
}
