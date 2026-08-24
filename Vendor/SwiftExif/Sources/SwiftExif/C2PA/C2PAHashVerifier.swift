import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Result of verifying a C2PA hard binding against an asset.
public enum C2PAHardBindingStatus: Sendable, Equatable {
    /// All hashes matched the asset bytes.
    case valid
    /// At least one hash did not match — `reason` describes which.
    case invalid(reason: String)
    /// The binding type or algorithm is not supported by this verifier.
    /// (E.g. `c2pa.hash.bmff.v2` Merkle reconstruction.)
    case unsupported(reason: String)
}

/// Verify C2PA hard-binding hash assertions against the asset bytes they
/// claim to cover.
///
/// Supports `c2pa.hash.data` (full file hash with byte-range exclusions) and
/// `c2pa.hash.boxes` (per-box hashes for ISOBMFF assets). `c2pa.hash.bmff.v2`
/// with Merkle trees is parsed but not reconstructed here — callers receive
/// `.unsupported` and should use the typed assertion struct directly.
public struct C2PAHashVerifier: Sendable {

    /// Verify a `c2pa.hash.data` assertion against the full asset bytes. The
    /// exclusions named in the assertion are zero-filled before hashing
    /// (per C2PA spec §15.5 — exclusion ranges cover the embedded manifest
    /// store itself, since hashing-with-self is impossible).
    public static func verifyHashData(_ assertion: C2PAHashData, against assetBytes: Data) -> C2PAHardBindingStatus {
        guard let computed = computeDigest(of: assetBytes, with: assertion.exclusions, algorithm: assertion.algorithm) else {
            return .unsupported(reason: "Unsupported hash algorithm: \(assertion.algorithm)")
        }
        return computed == assertion.hash
            ? .valid
            : .invalid(reason: "Hash mismatch (algorithm: \(assertion.algorithm))")
    }

    /// Verify a `c2pa.hash.boxes` assertion against an ISOBMFF asset's parsed
    /// top-level boxes. Each entry's named boxes are concatenated in file
    /// order and hashed; the result is compared to the entry's stored hash.
    public static func verifyHashBoxes(_ assertion: C2PAHashBoxes, against boxes: [ISOBMFFBox]) -> C2PAHardBindingStatus {
        for entry in assertion.boxes {
            let alg = entry.algorithm ?? assertion.algorithm ?? "sha256"

            // Concatenate the bytes of every named box (header + payload) in
            // file order. Boxes named in the entry but missing from the asset
            // count as a verification failure.
            var bytes = Data()
            for name in entry.names {
                guard let box = boxes.first(where: { $0.type == name }) else {
                    return .invalid(reason: "Missing box \(name)")
                }
                bytes.append(reconstructBoxBytes(box))
            }

            guard let computed = digest(of: bytes, algorithm: alg) else {
                return .unsupported(reason: "Unsupported hash algorithm: \(alg)")
            }
            if computed != entry.hash {
                return .invalid(reason: "Hash mismatch on box(es) \(entry.names.joined(separator: ","))")
            }
        }
        return .valid
    }

    // MARK: - Digest helpers

    /// Compute the digest of `data` minus the byte ranges in `exclusions`,
    /// where excluded ranges are replaced with zero bytes (NOT skipped — the
    /// spec hashes a "blanked" buffer of the same length so offsets are
    /// preserved).
    static func computeDigest(of data: Data, with exclusions: [C2PAExclusion], algorithm: String) -> Data? {
        var working = data
        for excl in exclusions {
            let start = Int(excl.start)
            let length = Int(excl.length)
            guard start >= 0, length >= 0, start + length <= working.count else { continue }
            working.replaceSubrange(
                (working.startIndex + start)..<(working.startIndex + start + length),
                with: Data(repeating: 0x00, count: length)
            )
        }
        return digest(of: working, algorithm: algorithm)
    }

    /// Compute a digest over `data` using the named C2PA algorithm. Returns
    /// nil for unsupported algorithms.
    static func digest(of data: Data, algorithm: String) -> Data? {
        switch algorithm.lowercased() {
        case "sha256":
            #if canImport(CryptoKit)
            return Data(SHA256.hash(data: data))
            #else
            return Data(PureSHA256.hash(data))
            #endif
        case "sha384":
            #if canImport(CryptoKit)
            return Data(SHA384.hash(data: data))
            #else
            return nil
            #endif
        case "sha512":
            #if canImport(CryptoKit)
            return Data(SHA512.hash(data: data))
            #else
            return nil
            #endif
        default:
            return nil
        }
    }

    /// Rebuild the on-wire bytes of a parsed ISOBMFF box (8-byte size+type
    /// header followed by payload). Used when concatenating boxes for
    /// `c2pa.hash.boxes` verification.
    static func reconstructBoxBytes(_ box: ISOBMFFBox) -> Data {
        let size = UInt32(8 + box.data.count)
        var buf = Data(capacity: Int(size))
        buf.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        buf.append(box.type.data(using: .ascii) ?? Data(count: 4))
        buf.append(box.data)
        return buf
    }
}

extension C2PAManifest {
    /// Verify the manifest's hard-binding hash assertions against the asset
    /// bytes. Walks the assertion list and returns `.valid` only if every
    /// recognized hard-binding assertion matches.
    ///
    /// Pass the full original asset bytes; for ISOBMFF assets, pre-parsed
    /// top-level boxes can be supplied via `bmffBoxes` so `c2pa.hash.boxes`
    /// can be verified.
    public func verifyHardBinding(against assetData: Data, bmffBoxes: [ISOBMFFBox]? = nil) -> C2PAHardBindingStatus {
        var sawAny = false
        for assertion in assertions {
            switch assertion.content {
            case .hashData(let h):
                sawAny = true
                let status = C2PAHashVerifier.verifyHashData(h, against: assetData)
                if case .valid = status { continue } else { return status }
            case .hashBoxes(let h):
                sawAny = true
                guard let boxes = bmffBoxes else {
                    return .unsupported(reason: "c2pa.hash.boxes requires pre-parsed BMFF boxes")
                }
                let status = C2PAHashVerifier.verifyHashBoxes(h, against: boxes)
                if case .valid = status { continue } else { return status }
            case .hashBMFFv2:
                return .unsupported(reason: "c2pa.hash.bmff.v2 verification not implemented")
            case .hashCollection:
                return .unsupported(reason: "c2pa.hash.collection.data requires per-URI asset access")
            default:
                continue
            }
        }
        return sawAny ? .valid : .unsupported(reason: "No hard-binding hash assertion found")
    }
}
