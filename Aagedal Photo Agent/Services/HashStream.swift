import Foundation
import CryptoKit

/// Streaming hash used by `ImportCopyService` for copy verification.
///
/// SHA-256 is hardware-accelerated on Apple Silicon (~2 GB/s) — faster than any
/// SD/CFexpress reader can produce bytes, so verification overhead is dominated
/// by the second-pass re-read, not by the hashing itself.
nonisolated struct HashStream: Sendable {
    private var hasher = SHA256()

    mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    mutating func update(buffer: UnsafeRawBufferPointer) {
        hasher.update(bufferPointer: buffer)
    }

    consuming func finalize() -> Data {
        Data(hasher.finalize())
    }

    /// Hash an entire file by streaming 1 MB chunks from disk.
    static func hashFile(at url: URL, chunkSize: Int = 1 << 20) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: { () -> Bool in
            do {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    return false
                }
                hasher.update(data: chunk)
                return true
            } catch {
                return false
            }
        }) {}
        return Data(hasher.finalize())
    }
}

extension Data {
    /// Eight-character hex prefix for compact display in error messages.
    nonisolated var shortHex: String {
        prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
