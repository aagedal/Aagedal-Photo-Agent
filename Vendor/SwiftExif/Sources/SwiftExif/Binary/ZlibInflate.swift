import CZlib
import Foundation

/// Cross-platform zlib inflate wrapper.
///
/// Replaces the Apple-only `NSData.decompressed(using: .zlib)` so PNG / PDF
/// flate streams parse the same way on macOS and Linux-musl.
enum ZlibInflate {

    /// Default cap on decompressed output. Sized generously above anything a
    /// legitimate PNG iCCP/iTXt chunk or PDF FlateDecode metadata stream would
    /// produce (real ICC profiles stay under 10 MB, XMP packets under a few
    /// MB), while stopping a crafted deflate bomb — which can expand 1000:1 or
    /// more — from filling memory. Callers needing more can pass a larger cap.
    static let defaultMaxOutput = 256 * 1024 * 1024

    /// Inflate zlib-framed (RFC 1950) data. Returns nil on malformed input or
    /// when the decompressed output would exceed `maxOutput` bytes.
    static func inflate(_ data: Data, maxOutput: Int = defaultMaxOutput) -> Data? {
        inflate(data, rawDeflate: false, maxOutput: maxOutput)
    }

    /// Inflate either zlib-framed or raw deflate (negative `windowBits`).
    /// PDF `/FlateDecode` streams are supposed to be zlib-framed, but some
    /// encoders emit raw deflate; call with `rawDeflate: true` for the retry.
    static func inflate(_ data: Data, rawDeflate: Bool, maxOutput: Int = defaultMaxOutput) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        // windowBits: 15 = zlib, -15 = raw deflate, 15+32 = auto-detect gzip/zlib.
        let windowBits: Int32 = rawDeflate ? -15 : 15 + 32
        guard inflateInit2Wrapper(&stream, windowBits: windowBits) == Z_OK else {
            return nil
        }
        defer { _ = CZlib.inflateEnd(&stream) }

        return data.withUnsafeBytes { (inputRaw: UnsafeRawBufferPointer) -> Data? in
            guard let inputBase = inputRaw.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<UInt8>(
                mutating: inputBase.assumingMemoryBound(to: UInt8.self)
            )
            stream.avail_in = UInt32(data.count)

            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)

            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buf -> Int32 in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = UInt32(buf.count)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 {
                    // Enforce the output cap before the append so we never
                    // commit more than maxOutput bytes to memory.
                    if output.count + produced > maxOutput { return nil }
                    output.append(chunk, count: produced)
                }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK, Z_BUF_ERROR:
                    if stream.avail_in == 0 && produced == 0 { return nil }
                    continue
                default:
                    return nil
                }
            }
        }
    }

    /// `inflateInit2` is a macro in zlib.h — wrap the underlying `inflateInit2_`
    /// call with the correct version / size arguments.
    private static func inflateInit2Wrapper(_ stream: inout z_stream, windowBits: Int32) -> Int32 {
        let version = zlibVersion()
        return CZlib.inflateInit2_(&stream, windowBits, version, Int32(MemoryLayout<z_stream>.size))
    }

    /// Deflate (zlib-frame) `data` with the default compression level. Matches
    /// Apple's `NSData.compressed(using: .zlib)` output format.
    static func deflate(_ data: Data) -> Data? {
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        // Z_DEFAULT_COMPRESSION (-1), windowBits 15, memLevel 8, Z_DEFAULT_STRATEGY.
        let version = zlibVersion()
        let initResult = CZlib.deflateInit2_(
            &stream, -1, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
            version, Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { return nil }
        defer { _ = CZlib.deflateEnd(&stream) }

        return data.withUnsafeBytes { (inputRaw: UnsafeRawBufferPointer) -> Data? in
            guard let inputBase = inputRaw.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<UInt8>(
                mutating: inputBase.assumingMemoryBound(to: UInt8.self)
            )
            stream.avail_in = UInt32(data.count)

            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)

            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buf -> Int32 in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = UInt32(buf.count)
                    return CZlib.deflate(&stream, Z_FINISH)
                }

                let produced = chunk.count - Int(stream.avail_out)
                if produced > 0 { output.append(chunk, count: produced) }

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK:
                    continue
                default:
                    return nil
                }
            }
        }
    }
}
