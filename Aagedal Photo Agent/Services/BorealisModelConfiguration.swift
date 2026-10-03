import Foundation

/// Transformers 5 serializes Gemma 3 RoPE as per-attention `rope_parameters`.
/// MLX Swift 2.30 reads the equivalent legacy keys. Adapt only the decoding input;
/// retain downloaded/tokenizer/weight artifacts byte-for-byte.
nonisolated enum BorealisModelConfiguration {
    static func adapted(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var text = root["text_config"] as? [String: Any] ?? root
        if let parameters = text["rope_parameters"] as? [String: Any] {
            if let full = parameters["full_attention"] as? [String: Any] {
                text["rope_scaling"] = full
                if let theta = full["rope_theta"] { text["rope_theta"] = theta }
            }
            if let sliding = parameters["sliding_attention"] as? [String: Any],
               let theta = sliding["rope_theta"] {
                text["rope_local_base_freq"] = theta
            }
        }
        if root["text_config"] != nil { root["text_config"] = text }
        else { root = text }
        return try JSONSerialization.data(withJSONObject: root)
    }
}
