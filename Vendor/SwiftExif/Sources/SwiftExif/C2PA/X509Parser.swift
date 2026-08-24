import Foundation

/// Minimal ASN.1 DER walker tailored to the X.509 fields C2PA needs:
/// subject/issuer common names, validity dates, signature algorithm OID, and
/// the SubjectPublicKeyInfo that CryptoKit consumes to verify COSE_Sign1.
///
/// This is intentionally narrow — no extension parsing, no CRL/OCSP, no
/// support for arbitrary directory string types beyond UTF8String /
/// PrintableString / IA5String. If a field cannot be parsed, the surrounding
/// parser falls back to leaving the corresponding accessor nil rather than
/// throwing.
enum ASN1Tag: UInt8 {
    case integer = 0x02
    case bitString = 0x03
    case octetString = 0x04
    case null = 0x05
    case oid = 0x06
    case utf8String = 0x0C
    case printableString = 0x13
    case ia5String = 0x16
    case utcTime = 0x17
    case generalizedTime = 0x18
    case sequence = 0x30
    case set = 0x31
}

/// One TLV (tag-length-value) record extracted from a DER blob.
struct ASN1TLV {
    let tag: UInt8
    let value: Data
    /// Total length consumed from the input buffer (header + value).
    let totalLength: Int
}

/// Parse a single TLV at `offset` inside `data`. Returns nil on truncation.
struct ASN1Reader {
    static func read(from data: Data, at offset: Int) -> ASN1TLV? {
        guard offset < data.count else { return nil }
        let s = data.startIndex + offset
        let tag = data[s]
        guard offset + 2 <= data.count else { return nil }

        let firstLen = data[s + 1]
        var length = 0
        var headerLen = 2
        if firstLen < 0x80 {
            length = Int(firstLen)
        } else {
            let lengthByteCount = Int(firstLen & 0x7F)
            guard lengthByteCount > 0, lengthByteCount <= 4,
                  offset + 2 + lengthByteCount <= data.count else { return nil }
            for i in 0..<lengthByteCount {
                length = (length << 8) | Int(data[s + 2 + i])
            }
            headerLen = 2 + lengthByteCount
        }
        guard offset + headerLen + length <= data.count else { return nil }
        let value = data.subdata(in: (s + headerLen)..<(s + headerLen + length))
        return ASN1TLV(tag: tag, value: value, totalLength: headerLen + length)
    }

    /// Walk every immediate child TLV inside a constructed-type's value.
    static func children(of value: Data) -> [ASN1TLV] {
        var out: [ASN1TLV] = []
        var offset = 0
        while offset < value.count {
            guard let tlv = read(from: value, at: offset) else { break }
            out.append(tlv)
            offset += tlv.totalLength
        }
        return out
    }

    /// Decode an OID's encoded subidentifiers back into dotted-decimal form.
    static func decodeOID(_ value: Data) -> String? {
        guard !value.isEmpty else { return nil }
        let first = value[value.startIndex]
        var parts = ["\(Int(first / 40))", "\(Int(first % 40))"]
        var i = 1
        while i < value.count {
            var v: UInt64 = 0
            while i < value.count {
                let b = value[value.startIndex + i]
                v = (v << 7) | UInt64(b & 0x7F)
                i += 1
                if b & 0x80 == 0 { break }
            }
            parts.append("\(v)")
        }
        return parts.joined(separator: ".")
    }

    static func decodeString(_ tlv: ASN1TLV) -> String? {
        switch tlv.tag {
        case ASN1Tag.utf8String.rawValue:
            return String(data: tlv.value, encoding: .utf8)
        case ASN1Tag.printableString.rawValue,
             ASN1Tag.ia5String.rawValue:
            return String(data: tlv.value, encoding: .ascii)
        default:
            return String(data: tlv.value, encoding: .utf8)
                ?? String(data: tlv.value, encoding: .ascii)
        }
    }

    /// Decode UTCTime ("YYMMDDHHMMSSZ") or GeneralizedTime ("YYYYMMDDHHMMSSZ")
    /// to a `Date`. Returns nil for malformed input.
    static func decodeDate(_ tlv: ASN1TLV) -> Date? {
        guard let s = String(data: tlv.value, encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if tlv.tag == ASN1Tag.utcTime.rawValue {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
        } else {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        }
        return formatter.date(from: s)
    }
}

/// Common OIDs that C2PA signature parsing cares about.
enum X509OID {
    static let commonName = "2.5.4.3"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let p256Curve = "1.2.840.10045.3.1.7"
    static let p384Curve = "1.3.132.0.34"
    static let p521Curve = "1.3.132.0.35"
    static let ed25519 = "1.3.101.112"
    static let rsaEncryption = "1.2.840.113549.1.1.1"
}

/// A minimally-parsed X.509 certificate.
public struct C2PACertificate: Sendable {
    /// Subject common name (CN).
    public let subjectCommonName: String?
    /// Issuer common name (CN).
    public let issuerCommonName: String?
    public let notBefore: Date?
    public let notAfter: Date?
    /// Public-key algorithm OID (e.g. id-ecPublicKey).
    public let publicKeyAlgorithmOID: String?
    /// Curve OID for ECDSA keys (P-256/384/521).
    public let publicKeyCurveOID: String?
    /// Raw `subjectPublicKey` BIT STRING bytes (without the leading 0x00
    /// unused-bits octet). For ECDSA this is the X9.63 uncompressed point
    /// (`0x04 || X || Y`).
    public let subjectPublicKeyBytes: Data
    /// Original DER bytes for round-tripping or downstream verification.
    public let derBytes: Data

    public init(
        subjectCommonName: String?,
        issuerCommonName: String?,
        notBefore: Date?,
        notAfter: Date?,
        publicKeyAlgorithmOID: String?,
        publicKeyCurveOID: String?,
        subjectPublicKeyBytes: Data,
        derBytes: Data
    ) {
        self.subjectCommonName = subjectCommonName
        self.issuerCommonName = issuerCommonName
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.publicKeyAlgorithmOID = publicKeyAlgorithmOID
        self.publicKeyCurveOID = publicKeyCurveOID
        self.subjectPublicKeyBytes = subjectPublicKeyBytes
        self.derBytes = derBytes
    }

    /// True when both `notBefore` and `notAfter` enclose `date`.
    public func isValidAt(_ date: Date = Date()) -> Bool {
        guard let nb = notBefore, let na = notAfter else { return false }
        return nb <= date && date <= na
    }
}

/// Parser for the minimal X.509 fields C2PA verification needs.
public struct X509Parser: Sendable {

    public static func parse(_ der: Data) -> C2PACertificate? {
        guard let cert = ASN1Reader.read(from: der, at: 0),
              cert.tag == ASN1Tag.sequence.rawValue else { return nil }
        let topLevel = ASN1Reader.children(of: cert.value)
        guard let tbs = topLevel.first, tbs.tag == ASN1Tag.sequence.rawValue else { return nil }

        // TBSCertificate fields. Skip the optional [0] EXPLICIT version
        // wrapper if present (tag 0xA0).
        var fields = ASN1Reader.children(of: tbs.value)
        if let first = fields.first, first.tag == 0xA0 {
            fields.removeFirst()
        }

        // 1: serialNumber INTEGER (skip)
        // 2: signature AlgorithmIdentifier (skip — same OID is in the outer cert)
        // 3: issuer Name
        // 4: validity
        // 5: subject Name
        // 6: subjectPublicKeyInfo
        guard fields.count >= 6 else { return nil }
        let issuer = fields[2]
        let validity = fields[3]
        let subject = fields[4]
        let spki = fields[5]

        let issuerCN = extractCommonName(from: issuer.value)
        let subjectCN = extractCommonName(from: subject.value)
        let (notBefore, notAfter) = parseValidity(validity.value)
        let (algOID, curveOID, keyBytes) = parseSPKI(spki.value)

        return C2PACertificate(
            subjectCommonName: subjectCN,
            issuerCommonName: issuerCN,
            notBefore: notBefore,
            notAfter: notAfter,
            publicKeyAlgorithmOID: algOID,
            publicKeyCurveOID: curveOID,
            subjectPublicKeyBytes: keyBytes,
            derBytes: der
        )
    }

    /// Walk a Name (SEQUENCE OF RelativeDistinguishedName) and pluck the CN.
    static func extractCommonName(from nameValue: Data) -> String? {
        for rdn in ASN1Reader.children(of: nameValue) {
            // RDN is a SET OF AttributeTypeAndValue
            for atv in ASN1Reader.children(of: rdn.value) {
                // ATV is a SEQUENCE { type OID, value ANY }
                let parts = ASN1Reader.children(of: atv.value)
                guard parts.count >= 2,
                      parts[0].tag == ASN1Tag.oid.rawValue,
                      let oid = ASN1Reader.decodeOID(parts[0].value),
                      oid == X509OID.commonName,
                      let cn = ASN1Reader.decodeString(parts[1]) else { continue }
                return cn
            }
        }
        return nil
    }

    static func parseValidity(_ value: Data) -> (Date?, Date?) {
        let parts = ASN1Reader.children(of: value)
        guard parts.count >= 2 else { return (nil, nil) }
        return (ASN1Reader.decodeDate(parts[0]), ASN1Reader.decodeDate(parts[1]))
    }

    /// Parse a SubjectPublicKeyInfo. Returns `(algOID, curveOID, keyBytes)`.
    /// `keyBytes` is the raw BIT STRING contents without the leading 0x00
    /// unused-bits octet — i.e. the X9.63 uncompressed point for ECDSA keys.
    static func parseSPKI(_ value: Data) -> (String?, String?, Data) {
        let parts = ASN1Reader.children(of: value)
        guard parts.count >= 2 else { return (nil, nil, Data()) }

        let alg = parts[0]
        let bitString = parts[1]

        var algOID: String?
        var curveOID: String?

        let algParts = ASN1Reader.children(of: alg.value)
        if let first = algParts.first, first.tag == ASN1Tag.oid.rawValue {
            algOID = ASN1Reader.decodeOID(first.value)
        }
        if algParts.count >= 2, algParts[1].tag == ASN1Tag.oid.rawValue {
            curveOID = ASN1Reader.decodeOID(algParts[1].value)
        }

        // BIT STRING: first byte = unused-bits count (always 0 for the keys
        // we care about), remainder is the key bytes.
        var keyBytes = Data()
        if bitString.tag == ASN1Tag.bitString.rawValue, !bitString.value.isEmpty {
            keyBytes = bitString.value.dropFirst()
        }
        return (algOID, curveOID, Data(keyBytes))
    }
}

extension C2PASignature {
    /// Parse the raw DER cert chain into structured `C2PACertificate` values.
    /// Bad DER blobs are silently skipped — partial chains are still useful
    /// for displaying signer info even if verification fails.
    public var parsedCertificates: [C2PACertificate] {
        certificateChain.compactMap(X509Parser.parse(_:))
    }
}
