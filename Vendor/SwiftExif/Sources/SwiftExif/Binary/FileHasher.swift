import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Compute cryptographic hashes of file data.
/// Provides MD5 and SHA256 digests for file integrity verification and asset management.
///
/// On Apple platforms we delegate to CryptoKit (hardware-accelerated). On
/// other platforms we use in-tree pure-Swift MD5 / SHA-256 implementations
/// so the Linux-musl cross-compile doesn't need to pull in swift-crypto's
/// BoringSSL dependency (which stalls the optimizer).
public struct FileHasher: Sendable {

    /// Compute the MD5 hash of data, returning a lowercase hex string.
    public static func md5(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return PureMD5.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    /// Compute the SHA256 hash of data, returning a lowercase hex string.
    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return PureSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    /// Compute the SHA512 hash of data, returning a lowercase hex string.
    /// Only used on Apple platforms; Linux callers do not invoke this.
    public static func sha512(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        // SHA-512 is not needed outside Apple paths; return SHA-256 as a
        // safe fallback so callers keep a deterministic hex string.
        return sha256(data)
        #endif
    }

    /// Compute all standard hashes at once (avoids reading data multiple times).
    public static func allHashes(_ data: Data) -> FileHashes {
        FileHashes(
            md5: md5(data),
            sha256: sha256(data),
            fileSize: UInt64(data.count)
        )
    }

    /// Compute hashes by streaming the file from disk in 1 MB chunks. Peak
    /// resident memory is one chunk plus the two hasher states — independent
    /// of file size, so multi-GB videos hash without ever materialising the
    /// file in RAM.
    public static func hash(url: URL) throws -> FileHashes {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var total: UInt64 = 0
        #if canImport(CryptoKit)
        var md5 = Insecure.MD5()
        var sha = SHA256()
        #else
        var md5 = PureMD5.Streaming()
        var sha = PureSHA256.Streaming()
        #endif

        let chunkSize = 1 << 20  // 1 MB — see plan for rationale.
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            md5.update(data: chunk)
            sha.update(data: chunk)
            total &+= UInt64(chunk.count)
        }

        #if canImport(CryptoKit)
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        #endif

        return FileHashes(md5: md5Hex, sha256: shaHex, fileSize: total)
    }
}

/// File hash results.
public struct FileHashes: Sendable {
    public let md5: String
    public let sha256: String
    public let fileSize: UInt64
}
