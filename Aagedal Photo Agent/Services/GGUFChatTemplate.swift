import Foundation

/// Reads bounded metadata without loading tensor weights or depending on model filenames.
nonisolated enum GGUFChatTemplate {
    static func read(from url: URL) throws -> String {
        let reader = try Reader(url: url)
        defer { try? reader.handle.close() }
        guard try reader.bytes(4) == Data("GGUF".utf8),
              [2, 3].contains(try reader.integer(4)) else { throw invalidMetadata }
        _ = try reader.integer(8) // tensor count
        let count = try reader.integer(8)
        guard count <= 100_000 else { throw invalidMetadata }
        for _ in 0..<count {
            let key = try reader.string()
            let type = try reader.integer(4)
            if key == "tokenizer.chat_template" {
                guard type == 8 else { throw invalidMetadata }
                let template = try reader.string()
                guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw invalidMetadata
                }
                return template
            }
            try reader.skip(type: type)
        }
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
            "This GGUF has no chat template. Choose an instruction-tuned model with an embedded chat template."])
    }

    static func writingTemplate(from url: URL) throws -> String {
        // The pinned completion helper does not forward --reasoning off to its initial
        // template render. Set the template variable explicitly for Gemma/Qwen instead.
        "{%- set enable_thinking = false -%}\n" + (try read(from: url))
    }

    private static var invalidMetadata: CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
            "The GGUF model metadata is invalid, truncated, or exceeds the supported size."])
    }

    private final class Reader {
        let handle: FileHandle
        let size: UInt64
        private var position: UInt64 = 0
        private let metadataLimit: UInt64 = 64 * 1_024 * 1_024

        init(url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            do {
                size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
            } catch {
                try? handle.close()
                throw error
            }
        }
        func bytes(_ count: UInt64) throws -> Data {
            guard count <= metadataLimit, position <= min(size, metadataLimit),
                  count <= min(size, metadataLimit) - position else { throw invalidMetadata }
            guard let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else {
                throw invalidMetadata
            }
            position += count
            return data
        }
        func integer(_ count: UInt64) throws -> UInt64 {
            let data = try bytes(count)
            return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        func string() throws -> String {
            let count = try integer(8)
            guard count <= 8 * 1_024 * 1_024, let value = String(data: try bytes(count), encoding: .utf8) else {
                throw invalidMetadata
            }
            return value
        }
        func advance(_ count: UInt64) throws {
            guard position <= min(size, metadataLimit), count <= min(size, metadataLimit) - position else {
                throw invalidMetadata
            }
            position += count
            try handle.seek(toOffset: position)
        }
        func skip(type: UInt64, arrayElement: Bool = false) throws {
            switch type {
            case 0, 1, 7: try advance(1)
            case 2, 3: try advance(2)
            case 4, 5, 6: try advance(4)
            case 10, 11, 12: try advance(8)
            case 8:
                let count = try integer(8)
                try advance(count)
            case 9:
                guard !arrayElement else { throw invalidMetadata }
                let elementType = try integer(4)
                let count = try integer(8)
                guard count <= 1_000_000 else { throw invalidMetadata }
                let widths: [UInt64: UInt64] = [0: 1, 1: 1, 7: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8]
                if let width = widths[elementType] {
                    try advance(count * width)
                } else {
                    guard elementType == 8 else { throw invalidMetadata }
                    for _ in 0..<count { try skip(type: elementType, arrayElement: true) }
                }
            default: throw invalidMetadata
            }
        }
    }
}
