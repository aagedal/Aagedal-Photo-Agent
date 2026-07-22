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
    static func hashFile(at url: URL, chunkSize: Int = 1 << 20) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// A sampled SHA-256 for fast equality checks before import.
    ///
    /// Small files are hashed in full. For larger files, the digest covers equally
    /// sized samples from the beginning, middle, and end, together with the file
    /// size and each sample offset. This keeps card re-import checks cheap without
    /// relying on filename and size alone.
    static func quickHashFile(at url: URL, sampleSize: Int = 64 << 10) throws -> Data {
        precondition(sampleSize > 0)

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = values.fileSize else {
            throw NSError(
                domain: "HashStream",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not read the size of \(url.lastPathComponent)."]
            )
        }

        let fileSize = UInt64(byteCount)
        let sampleLength = UInt64(sampleSize)
        let offsets: [UInt64]
        if fileSize <= sampleLength * 3 {
            offsets = [0]
        } else {
            offsets = [0, (fileSize - sampleLength) / 2, fileSize - sampleLength]
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        update(&hasher, with: fileSize)

        for offset in offsets {
            let length = offsets.count == 1
                ? Int(fileSize)
                : Int(min(sampleLength, fileSize - offset))
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else {
                throw NSError(
                    domain: "HashStream",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected end of file while checking \(url.lastPathComponent)."]
                )
            }
            update(&hasher, with: offset)
            hasher.update(data: data)
        }

        return Data(hasher.finalize())
    }

    private static func update(_ hasher: inout SHA256, with integer: UInt64) {
        var littleEndian = integer.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            hasher.update(bufferPointer: bytes)
        }
    }
}

extension Data {
    /// Eight-character hex prefix for compact display in error messages.
    nonisolated var shortHex: String {
        prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
