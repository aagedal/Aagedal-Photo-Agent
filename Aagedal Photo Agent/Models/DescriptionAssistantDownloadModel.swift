import Foundation

/// Text-only GGUF downloads pinned to an immutable revision, size and SHA-256.
nonisolated enum DescriptionAssistantDownloadModel: String, CaseIterable, Identifiable, Sendable {
    case gemma4_12B = "gemma-4-12b-it-q4-k-m"
    case gemma4_E4B = "gemma-4-e4b-it-q4-k-m"
    case qwen35_9B = "qwen-3-5-9b-q4-k-m"
    case ministral3_14B = "ministral-3-14b-instruct-q4-k-m"
    case gemma4_26B = "gemma-4-26b-a4b-it-q4-k-m"
    static let recommended: Self = .gemma4_12B
    static let maximumDownloadByteCount: Int64 = 20_000_000_000
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemma4_12B: "Gemma 4 12B — Recommended"
        case .gemma4_E4B: "Gemma 4 E4B — Lightweight"
        case .qwen35_9B: "Qwen3.5 9B"
        case .ministral3_14B: "Ministral 3 14B Instruct"
        case .gemma4_26B: "Gemma 4 26B A4B — High quality"
        }
    }
    var purpose: String {
        switch self {
        case .gemma4_12B: "Recommended balance of multilingual writing quality and memory use."
        case .gemma4_E4B: "Lighter Gemma 4 option for Macs with less memory. Writing quality may be lower than 12B."
        case .qwen35_9B: "A smaller multilingual alternative for grammar and wording assistance."
        case .ministral3_14B: "Multilingual instruction model for direct writing assistance."
        case .gemma4_26B: "Higher-quality option with substantially higher RAM use. Only 4B parameters are active per token, but all 26B weights need memory."
        }
    }

    /// Guidance for total Mac memory, including macOS, the app and inference overhead.
    /// These are recommendations, not measured minimums or admission limits.
    var recommendedMemoryGB: Int {
        switch self {
        case .gemma4_E4B, .qwen35_9B: 16
        case .gemma4_12B, .ministral3_14B: 24
        case .gemma4_26B: 32
        }
    }
    var memoryGuidance: String {
        "Recommended Mac RAM: \(recommendedMemoryGB) GB or more. Download size is not total memory use."
    }
    func hasMemoryWarning(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory < UInt64(recommendedMemoryGB) * 1_073_741_824
    }
    var downloadSize: String {
        ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .decimal)
    }

    private var pin: (repo: String, revision: String, file: String, bytes: Int64, sha256: String) {
        switch self {
        case .gemma4_12B:
            ("unsloth/gemma-4-12B-it-GGUF", "fc034cfff751157913579611efad8462ac1be606",
             "gemma-4-12b-it-Q4_K_M.gguf", 7_121_861_440,
             "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42")
        case .gemma4_E4B:
            ("unsloth/gemma-4-E4B-it-GGUF", "bfc15c382204943c3a8fff0c750b94ae2364d7a3",
             "gemma-4-E4B-it-Q4_K_M.gguf", 4_977_171_584,
             "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87")
        case .qwen35_9B:
            ("unsloth/Qwen3.5-9B-GGUF", "3885219b6810b007914f3a7950a8d1b469d598a5",
             "Qwen3.5-9B-Q4_K_M.gguf", 5_680_522_464,
             "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8")
        case .ministral3_14B:
            ("mistralai/Ministral-3-14B-Instruct-2512-GGUF", "74fac473c43357d7fb2671713608183cc72496d0",
             "Ministral-3-14B-Instruct-2512-Q4_K_M.gguf", 8_239_593_024,
             "824e0f3373e69b84f2cae46fdcb9bd1ebc6ab3bfc7acc125d818b7b8178cc613")
        case .gemma4_26B:
            ("bartowski/google_gemma-4-26B-A4B-it-GGUF", "10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d",
             "google_gemma-4-26B-A4B-it-Q4_K_M.gguf", 17_035_039_872,
             "a07f72221e8e3f77455ab0d7f7652d01a9f63c262b954aa6932a53275a0e895a")
        }
    }
    var sourceURL: URL { URL(string: "https://huggingface.co/\(pin.repo)")! }
    var artifact: WhisperDownloadableModel {
        WhisperDownloadableModel(id: rawValue, title: title, byteCount: pin.bytes, sha256: pin.sha256,
            url: sourceURL.appendingPathComponent("resolve/\(pin.revision)/\(pin.file)"), fileName: pin.file)
    }
    static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aagedal Photo Agent/DescriptionModels", isDirectory: true)
    }
    var installedFile: URL { Self.storageDirectory.appendingPathComponent(artifact.fileName!) }
}
