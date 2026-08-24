import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Result of cryptographically verifying a C2PA claim signature.
public enum C2PAVerificationResult: Sendable {
    /// Signature verified against the signer's certificate. Chain trust is
    /// NOT validated by this verifier — see `untrustedChain` for the current
    /// posture on root anchoring.
    case signatureValid(signer: C2PACertificate?)
    /// Signature did not verify against the signer's certificate, OR no
    /// usable certificate was present.
    case signatureInvalid(reason: String)
    /// Signature verified, but the certificate chain is not anchored to a
    /// known C2PA trust list. Trust-list pinning is intentionally out of
    /// scope here — callers wanting a stricter posture should pin against
    /// their own roots and downgrade this case to "valid" only on a match.
    case untrustedChain(signer: C2PACertificate?)
    /// The signature algorithm is recognized by C2PA but not implemented by
    /// this verifier (e.g. PSS RSA). Callers should fall back to a richer
    /// crypto stack if they need full coverage.
    case unsupportedAlgorithm(name: String)
    /// The signer certificate is expired or not yet valid against the
    /// reference time.
    case certificateExpired(signer: C2PACertificate)
}

/// Cryptographically verify a C2PA `c2pa.signature` (COSE_Sign1) against the
/// claim it was computed over. Supports ECDSA (P-256, P-384, P-521) and
/// Ed25519 today; PSS RSA returns `.unsupportedAlgorithm`.
///
/// Out of scope (intentional — see plan §C.2):
/// - CRL / OCSP revocation checking
/// - Root anchoring against C2PA trust lists
/// - RFC 3161 timestamp re-verification (the TST bytes are surfaced via
///   `C2PASignature.timestamp` for downstream consumers)
public struct C2PASignatureVerifier: Sendable {

    /// Verify `signature` using the public key of its first parsed
    /// certificate. `claimBytes` must be the raw CBOR bytes of the claim
    /// (the bytes inside the `cbor` content box of the claim JUMBF) — these
    /// form the COSE_Sign1 detached payload.
    ///
    /// `referenceTime` defaults to "now" but can be overridden to validate
    /// against a captured timestamp (e.g. an RFC 3161 TST genTime).
    public static func verify(
        _ signature: C2PASignature,
        claimBytes: Data,
        referenceTime: Date = Date()
    ) -> C2PAVerificationResult {
        guard let cert = signature.parsedCertificates.first else {
            return .signatureInvalid(reason: "No usable signer certificate in chain")
        }
        guard let alg = signature.algorithm else {
            return .signatureInvalid(reason: "Missing COSE algorithm")
        }
        if !cert.isValidAt(referenceTime) {
            return .certificateExpired(signer: cert)
        }

        // Reconstruct the COSE_Sign1 Sig_structure that was actually signed:
        //   Sig_structure = ["Signature1", body_protected, external_aad, payload]
        // body_protected is read from the original COSE_Sign1[0]; external_aad
        // is empty (C2PA convention); payload is the detached claim bytes.
        guard let coseArray = extractCOSEArray(signature.raw),
              coseArray.count >= 4,
              let bodyProtected = coseArray[0].byteStringValue else {
            return .signatureInvalid(reason: "Malformed COSE_Sign1 structure")
        }

        let sigStructure = encodeSigStructure(
            bodyProtected: bodyProtected,
            externalAAD: Data(),
            payload: claimBytes
        )

        switch alg {
        case .es256, .es384, .es512:
            return verifyECDSA(
                cert: cert,
                algorithm: alg,
                signedData: sigStructure,
                signature: signature.signatureBytes
            )
        case .edDSA:
            return verifyEdDSA(
                cert: cert,
                signedData: sigStructure,
                signature: signature.signatureBytes
            )
        case .ps256, .ps384, .ps512, .unknown:
            return .unsupportedAlgorithm(name: alg.description)
        }
    }

    // MARK: - Algorithm-specific verifiers

    static func verifyECDSA(
        cert: C2PACertificate,
        algorithm: C2PASignatureAlgorithm,
        signedData: Data,
        signature: Data
    ) -> C2PAVerificationResult {
        #if canImport(CryptoKit)
        let key = cert.subjectPublicKeyBytes
        do {
            switch algorithm {
            case .es256:
                let pub = try P256.Signing.PublicKey(x963Representation: key)
                let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
                let digest = SHA256.hash(data: signedData)
                return pub.isValidSignature(sig, for: digest)
                    ? .signatureValid(signer: cert)
                    : .signatureInvalid(reason: "ES256 verification failed")
            case .es384:
                let pub = try P384.Signing.PublicKey(x963Representation: key)
                let sig = try P384.Signing.ECDSASignature(rawRepresentation: signature)
                let digest = SHA384.hash(data: signedData)
                return pub.isValidSignature(sig, for: digest)
                    ? .signatureValid(signer: cert)
                    : .signatureInvalid(reason: "ES384 verification failed")
            case .es512:
                let pub = try P521.Signing.PublicKey(x963Representation: key)
                let sig = try P521.Signing.ECDSASignature(rawRepresentation: signature)
                let digest = SHA512.hash(data: signedData)
                return pub.isValidSignature(sig, for: digest)
                    ? .signatureValid(signer: cert)
                    : .signatureInvalid(reason: "ES512 verification failed")
            default:
                return .unsupportedAlgorithm(name: algorithm.description)
            }
        } catch {
            return .signatureInvalid(reason: "ECDSA key/sig parse failed: \(error)")
        }
        #else
        return .unsupportedAlgorithm(name: algorithm.description)
        #endif
    }

    static func verifyEdDSA(
        cert: C2PACertificate,
        signedData: Data,
        signature: Data
    ) -> C2PAVerificationResult {
        #if canImport(CryptoKit)
        do {
            let pub = try Curve25519.Signing.PublicKey(rawRepresentation: cert.subjectPublicKeyBytes)
            return pub.isValidSignature(signature, for: signedData)
                ? .signatureValid(signer: cert)
                : .signatureInvalid(reason: "Ed25519 verification failed")
        } catch {
            return .signatureInvalid(reason: "Ed25519 key parse failed: \(error)")
        }
        #else
        return .unsupportedAlgorithm(name: "EdDSA")
        #endif
    }

    // MARK: - COSE structure helpers

    /// Pull the COSE_Sign1 outer array out of the decoded signature CBOR,
    /// tolerating both tagged (tag 18) and untagged forms.
    static func extractCOSEArray(_ cbor: CBORValue) -> [CBORValue]? {
        if let tagged = cbor.taggedValue, tagged.tag == 18 {
            return tagged.value.arrayValue
        }
        return cbor.arrayValue
    }

    /// Encode `Sig_structure` per RFC 8152 §4.4 for COSE_Sign1:
    ///   ["Signature1", body_protected, external_aad, payload]
    static func encodeSigStructure(bodyProtected: Data, externalAAD: Data, payload: Data) -> Data {
        var data = Data()
        data.append(0x84) // array(4)
        data.append(cborTextString("Signature1"))
        data.append(cborByteString(bodyProtected))
        data.append(cborByteString(externalAAD))
        data.append(cborByteString(payload))
        return data
    }

    private static func cborTextString(_ s: String) -> Data {
        let bytes = [UInt8](s.utf8)
        var out = Data()
        let n = bytes.count
        if n <= 23 {
            out.append(0x60 | UInt8(n))
        } else if n <= 0xFF {
            out.append(0x78); out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0x79); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(0x7A)
            out.append(contentsOf: withUnsafeBytes(of: UInt32(n).bigEndian) { Array($0) })
        }
        out.append(contentsOf: bytes)
        return out
    }

    private static func cborByteString(_ d: Data) -> Data {
        var out = Data()
        let n = d.count
        if n <= 23 {
            out.append(0x40 | UInt8(n))
        } else if n <= 0xFF {
            out.append(0x58); out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0x59); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(0x5A)
            out.append(contentsOf: withUnsafeBytes(of: UInt32(n).bigEndian) { Array($0) })
        }
        out.append(d)
        return out
    }
}

extension C2PAManifest {
    /// Verify this manifest's claim signature against the bytes the COSE_Sign1
    /// was computed over (the raw CBOR of the claim content box, retained on
    /// `claim.rawCBORBytes`).
    public func verifySignature(referenceTime: Date = Date()) -> C2PAVerificationResult {
        C2PASignatureVerifier.verify(
            signature,
            claimBytes: claim.rawCBORBytes,
            referenceTime: referenceTime
        )
    }
}
