import Foundation

/// Reads and parses C2PA manifest stores from image data.
public struct C2PAReader: Sendable {

    /// UUID user type for C2PA in BMFF uuid boxes (AVIF/HEIF/MP4).
    static let bmffC2PAUUID: [UInt8] = [
        0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
        0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81,
    ]

    // MARK: - Format-Specific JUMBF Extraction

    /// Extract JUMBF data from JPEG APP11 segments.
    public static func extractJUMBFFromJPEG(_ jpegFile: JPEGFile) throws -> Data? {
        let app11Segments = jpegFile.segments.filter { $0.rawMarker == JPEGMarker.app11.rawValue }
        guard !app11Segments.isEmpty else { return nil }
        return try JUMBFParser.reassembleFromAPP11(app11Segments)
    }

    /// Extract JUMBF data from a PNG caBX chunk.
    public static func extractJUMBFFromPNG(_ pngFile: PNGFile) -> Data? {
        pngFile.findChunk("caBX")?.data
    }

    /// Extract JUMBF data from JPEG XL boxes.
    public static func extractJUMBFFromJPEGXL(_ jxlFile: JXLFile) -> Data? {
        // Look for a top-level jumb box
        if let jumbBox = jxlFile.findBox("jumb") {
            // Return the box data wrapped with its header so we can parse it as ISOBMFF
            return buildBoxData(type: "jumb", payload: jumbBox.data)
        }
        return nil
    }

    /// Extract JUMBF data from HEIF/HEIC BMFF boxes.
    public static func extractJUMBFFromHEIF(_ heifFile: HEIFFile) -> Data? {
        extractJUMBFFromISOBMFF(heifFile.boxes)
    }

    /// Extract JUMBF data from AVIF/BMFF boxes.
    public static func extractJUMBFFromAVIF(_ avifFile: AVIFFile) -> Data? {
        extractJUMBFFromISOBMFF(avifFile.boxes)
    }

    /// TIFF IFD0 tag carrying a JUMBF byte stream (C2PA spec §9.6 "TIFF, DNG").
    public static let tiffC2PATag: UInt16 = 0xCD41

    /// Extract JUMBF data from a TIFF IFD0 entry (tag 0xCD41).
    /// Same path covers DNG and TIFF-based RAW formats since they share IFD0.
    public static func extractJUMBFFromTIFF(_ tiffFile: TIFFFile) -> Data? {
        guard let entry = tiffFile.ifd0?.entry(for: tiffC2PATag) else { return nil }
        guard !entry.valueData.isEmpty else { return nil }
        return entry.valueData
    }

    /// Extract JUMBF data from a WebP RIFF "C2PA" chunk.
    public static func extractJUMBFFromWebP(_ webPFile: WebPFile) -> Data? {
        webPFile.findChunk("C2PA")?.data
    }

    /// Extract JUMBF data from a PDF associated file (`/AF`) declaring
    /// `/Subtype /application#2Fc2pa`.
    public static func extractJUMBFFromPDF(_ pdfFile: PDFFile) -> Data? {
        PDFParser.extractC2PAJUMBF(from: pdfFile.rawData)
    }

    /// Extract JUMBF data from a RIFF "C2PA" chunk. Works for WAV / BWF and
    /// any other RIFF-based container that follows the C2PA convention.
    /// `data` is the entire RIFF byte stream starting at the `RIFF` magic.
    public static func extractJUMBFFromRIFF(_ data: Data) -> Data? {
        guard data.count >= 12 else { return nil }
        let s = data.startIndex
        guard data[s] == 0x52, data[s + 1] == 0x49, data[s + 2] == 0x46, data[s + 3] == 0x46 else {
            return nil
        }

        var offset = 12
        while offset + 8 <= data.count {
            let idStart = s + offset
            let chunkID = String(
                data: data[idStart..<(idStart + 4)],
                encoding: .ascii
            ) ?? ""
            let size = Int(
                UInt32(data[idStart + 4])
                | (UInt32(data[idStart + 5]) << 8)
                | (UInt32(data[idStart + 6]) << 16)
                | (UInt32(data[idStart + 7]) << 24)
            )
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { break }

            if chunkID == "C2PA" {
                return Data(data[(s + payloadStart)..<(s + payloadEnd)])
            }

            offset = payloadEnd + (size & 1)
        }
        return nil
    }

    /// Extract JUMBF data from a GIF Application Extension with identifier "C2PA_GIF".
    /// Sub-block payloads are already concatenated by the GIF parser into the block's `data`.
    public static func extractJUMBFFromGIF(_ gifFile: GIFFile) -> Data? {
        for block in gifFile.blocks {
            if case .applicationExtension(let identifier, _, let data) = block.type,
               identifier == "C2PA_GIF" {
                return data
            }
        }
        return nil
    }

    /// Parse a sidecar `.c2pa` byte stream. The file is a raw JUMBF box (or a sequence
    /// starting with `jumb`), no container — we just hand it to `parseManifestStore`.
    public static func extractJUMBFFromSidecar(_ data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        // Sanity-check the first box type is "jumb"; otherwise scan for it.
        let bytes = [UInt8](data.prefix(8))
        if bytes[4] == 0x6A && bytes[5] == 0x75 && bytes[6] == 0x6D && bytes[7] == 0x62 {
            return data
        }
        if let start = findJUMBFStart(in: data) {
            return Data(data.suffix(from: data.startIndex + start))
        }
        return nil
    }

    /// Shared JUMBF extraction for any ISOBMFF-based format.
    static func extractJUMBFFromISOBMFF(_ boxes: [ISOBMFFBox]) -> Data? {
        // First try: top-level jumb box
        if let jumbBox = boxes.first(where: { $0.type == "jumb" }) {
            return buildBoxData(type: "jumb", payload: jumbBox.data)
        }

        // Second try: uuid box with C2PA user type
        for box in boxes where box.type == "uuid" {
            guard box.data.count > 16 else { continue }
            let userType = [UInt8](box.data.prefix(16))
            guard userType == bmffC2PAUUID else { continue }

            let payload = Data(box.data.suffix(from: box.data.startIndex + 16))
            if let jumbfStart = findJUMBFStart(in: payload) {
                return Data(payload.suffix(from: payload.startIndex + jumbfStart))
            }
        }

        return nil
    }

    // MARK: - Manifest Store Parsing

    /// Parse a C2PA manifest store from raw JUMBF data.
    public static func parseManifestStore(from jumbfData: Data) throws -> C2PAData? {
        // Parse outer ISOBMFF boxes
        let outerBoxes = try ISOBMFFBoxReader.parseBoxes(from: jumbfData)

        // Find the jumb box containing the manifest store
        guard let jumbBox = outerBoxes.first(where: { $0.type == "jumb" }) else {
            return nil
        }

        let store = try JUMBFParser.parseSuperbox(from: jumbBox.data)
        guard JUMBFParser.isManifestStore(store.description) else {
            return nil
        }

        // Each child of the manifest store is a manifest
        var manifests: [C2PAManifest] = []
        for child in store.children {
            guard JUMBFParser.isManifest(child.description) else { continue }
            if let manifest = try? parseManifest(child) {
                manifests.append(manifest)
            }
        }

        guard !manifests.isEmpty else { return nil }
        return C2PAData(manifests: manifests)
    }

    // MARK: - Manifest Parsing

    static func parseManifest(_ box: JUMBFBox) throws -> C2PAManifest {
        let label = box.description.label ?? "unknown"

        var claim: C2PAClaim?
        var signature: C2PASignature?
        var assertions: [C2PAAssertion] = []

        for child in box.children {
            if JUMBFParser.isClaim(child.description) {
                claim = try parseClaim(child)
            } else if JUMBFParser.isSignature(child.description) {
                signature = try parseSignature(child)
            } else if JUMBFParser.isAssertionStore(child.description) {
                assertions = try parseAssertionStore(child)
            }
        }

        guard let claim else {
            throw MetadataError.invalidC2PA("Manifest missing claim")
        }
        guard let signature else {
            throw MetadataError.invalidC2PA("Manifest missing signature")
        }

        return C2PAManifest(label: label, claim: claim, signature: signature, assertions: assertions)
    }

    // MARK: - Claim Parsing

    static func parseClaim(_ box: JUMBFBox) throws -> C2PAClaim {
        // The claim is CBOR-encoded in a cbor content box
        guard let cborBox = box.contentBoxes.first(where: { $0.type == "cbor" }) else {
            throw MetadataError.invalidC2PA("Claim missing CBOR content box")
        }

        let cbor = try CBORDecoder.decode(from: cborBox.data)

        // Extract fields from the CBOR map
        // v2: claim_generator_info (map with name/version)
        // v1: claim_generator (string)
        var generator = "unknown"
        var generatorInfo: C2PAGeneratorInfo?

        if let infoArray = cbor["claim_generator_info"]?.arrayValue, let first = infoArray.first {
            // C2PA v2: claim_generator_info is an array of {name, version, icon} maps
            let name = first["name"]?.textStringValue ?? "unknown"
            let version = first["version"]?.textStringValue
            generatorInfo = C2PAGeneratorInfo(name: name, version: version)
            generator = version.map { "\(name) \($0)" } ?? name
        } else if let info = cbor["claim_generator_info"], info.arrayValue == nil {
            // Tolerate non-array claim_generator_info (single map)
            let name = info["name"]?.textStringValue ?? "unknown"
            let version = info["version"]?.textStringValue
            generatorInfo = C2PAGeneratorInfo(name: name, version: version)
            generator = version.map { "\(name) \($0)" } ?? name
        } else if let gen = cbor["claim_generator"]?.textStringValue {
            generator = gen
        }

        let instanceID = cbor["instanceID"]?.textStringValue
        let format = cbor["dc:format"]?.textStringValue
        let title = cbor["dc:title"]?.textStringValue
        let algorithm = cbor["alg"]?.textStringValue

        // Parse assertion references. v2 claims split these into
        // created_assertions / gathered_assertions; v1 claims (e.g. Sony's
        // in-camera "SONY_CAMERA" generator) list them all under "assertions".
        var assertionRefs: [C2PAHashedURI] = []
        if let assertions = cbor["assertions"]?.arrayValue {
            assertionRefs.append(contentsOf: assertions.compactMap { parseHashedURI($0) })
        }
        if let created = cbor["created_assertions"]?.arrayValue {
            assertionRefs.append(contentsOf: created.compactMap { parseHashedURI($0) })
        }
        if let gathered = cbor["gathered_assertions"]?.arrayValue {
            assertionRefs.append(contentsOf: gathered.compactMap { parseHashedURI($0) })
        }

        return C2PAClaim(
            claimGenerator: generator,
            claimGeneratorInfo: generatorInfo,
            instanceID: instanceID,
            format: format,
            title: title,
            algorithm: algorithm,
            assertionReferences: assertionRefs,
            raw: cbor,
            rawCBORBytes: cborBox.data
        )
    }

    static func parseHashedURI(_ cbor: CBORValue) -> C2PAHashedURI? {
        guard let url = cbor["url"]?.textStringValue else { return nil }
        let algorithm = cbor["alg"]?.textStringValue
        let hash = cbor["hash"]?.byteStringValue ?? Data()
        return C2PAHashedURI(url: url, algorithm: algorithm, hash: hash)
    }

    // MARK: - Signature Parsing (COSE Sign1)

    static func parseSignature(_ box: JUMBFBox) throws -> C2PASignature {
        guard let cborBox = box.contentBoxes.first(where: { $0.type == "cbor" }) else {
            throw MetadataError.invalidC2PA("Signature missing CBOR content box")
        }

        let cbor = try CBORDecoder.decode(from: cborBox.data)

        // COSE_Sign1_Tagged = tag(18, [protected, unprotected, payload, signature])
        let coseArray: [CBORValue]
        if let tagged = cbor.taggedValue, tagged.tag == 18 {
            guard let arr = tagged.value.arrayValue, arr.count >= 4 else {
                throw MetadataError.invalidC2PA("Invalid COSE Sign1 structure")
            }
            coseArray = arr
        } else if let arr = cbor.arrayValue, arr.count >= 4 {
            // Some implementations omit the tag
            coseArray = arr
        } else {
            throw MetadataError.invalidC2PA("Invalid COSE Sign1 structure")
        }

        // [0] protected: bstr (serialized CBOR map)
        var algorithm: C2PASignatureAlgorithm?
        var certChain: [Data] = []

        if let protectedBytes = coseArray[0].byteStringValue, !protectedBytes.isEmpty {
            let protectedMap = try CBORDecoder.decode(from: protectedBytes)
            // Key 1 = alg
            if let algValue = protectedMap[intKey: 1]?.intValue {
                algorithm = C2PASignatureAlgorithm(coseValue: algValue)
            }
            certChain = x5chain(from: protectedMap)
        }

        // The x5chain may live in the unprotected header instead of (or in
        // addition to) the protected one — COSE permits either bucket. Sony's
        // in-camera signer, for instance, places it in the protected header but
        // under the text label "x5chain" rather than the registered integer 33;
        // `x5chain(from:)` accepts both. Fall back to the unprotected header.
        if certChain.isEmpty {
            certChain = x5chain(from: coseArray[1])
        }

        // [1] unprotected: map — check for timestamp
        var timestamp: Data?
        if case .map(let entries) = coseArray[1] {
            // sigTst or sigTst2
            for entry in entries {
                if entry.key.textStringValue == "sigTst" {
                    // { "tstTokens": [ { "val": bstr } ] }
                    if let tokens = entry.value["tstTokens"]?.arrayValue,
                       let first = tokens.first,
                       let val = first["val"]?.byteStringValue {
                        timestamp = val
                    }
                } else if entry.key.textStringValue == "sigTst2" {
                    timestamp = entry.value.byteStringValue
                }
            }
        }

        // [3] signature: bstr
        let signatureBytes = coseArray[3].byteStringValue ?? Data()

        return C2PASignature(
            algorithm: algorithm,
            certificateChain: certChain,
            timestamp: timestamp,
            signatureBytes: signatureBytes,
            raw: cbor
        )
    }

    /// Extract the COSE x5chain (DER cert or certs) from a header map. Accepts
    /// both the registered integer label 33 and the non-standard text label
    /// "x5chain" used by some signers (e.g. Sony in-camera C2PA).
    private static func x5chain(from map: CBORValue) -> [Data] {
        guard let chainValue = map[intKey: 33] ?? map["x5chain"] else { return [] }
        switch chainValue {
        case .byteString(let cert):
            return [cert]
        case .array(let certs):
            return certs.compactMap { $0.byteStringValue }
        default:
            return []
        }
    }

    // MARK: - Assertion Parsing

    static func parseAssertionStore(_ box: JUMBFBox) throws -> [C2PAAssertion] {
        var assertions: [C2PAAssertion] = []

        for child in box.children {
            let label = child.description.label ?? "unknown"
            let content = try parseAssertionContent(label: label, box: child)
            assertions.append(C2PAAssertion(label: label, content: content))
        }

        return assertions
    }

    static func parseAssertionContent(label: String, box: JUMBFBox) throws -> C2PAAssertionContent {
        // Thumbnails are stored as embedded files (bfdb + bidb)
        if label.hasPrefix("c2pa.thumbnail.") {
            // Extract format suffix after the last dot (e.g. "jpeg" from "c2pa.thumbnail.claim.jpeg")
            let format = label.split(separator: ".").last.map(String.init) ?? "unknown"
            if let bidb = box.contentBoxes.first(where: { $0.type == "bidb" }) {
                return .thumbnail(bidb.data, format: format)
            }
            return .thumbnail(Data(), format: format)
        }

        // CBOR content box
        if let cborBox = box.contentBoxes.first(where: { $0.type == "cbor" }) {
            let cbor = try CBORDecoder.decode(from: cborBox.data)
            return parseTypedAssertion(label: label, cbor: cbor)
        }

        // JSON content box
        if let jsonBox = box.contentBoxes.first(where: { $0.type == "json" }) {
            return .json(jsonBox.data)
        }

        // Binary content (bidb without thumbnail label)
        if let bidb = box.contentBoxes.first(where: { $0.type == "bidb" }) {
            return .binary(bidb.data)
        }

        // Fallback: return the first content box data as binary
        if let first = box.contentBoxes.first {
            return .binary(first.data)
        }

        return .binary(Data())
    }

    static func parseTypedAssertion(label: String, cbor: CBORValue) -> C2PAAssertionContent {
        if label.hasPrefix("c2pa.actions") {
            return parseActionsAssertion(cbor)
        }
        if label == "c2pa.hash.data" {
            return parseHashDataAssertion(cbor)
        }
        if label == "c2pa.hash.boxes" {
            return parseHashBoxesAssertion(cbor)
        }
        if label == "c2pa.hash.bmff.v2" {
            return parseHashBMFFv2Assertion(cbor)
        }
        if label == "c2pa.hash.collection.data" {
            return parseHashCollectionAssertion(cbor)
        }
        if label.hasPrefix("c2pa.ingredient") {
            return parseIngredientAssertion(cbor)
        }
        if label.hasPrefix("stds.iptc") {
            return parseIPTCAssertion(cbor)
        }
        if label == "stds.exif" {
            return parseExifAssertion(cbor)
        }
        if label == "stds.schema-org.CreativeWork" {
            return parseSchemaOrgCreativeWorkAssertion(cbor)
        }
        if label.hasPrefix("c2pa.training-mining") {
            return parseTrainingMiningAssertion(cbor)
        }
        if label == "c2pa.redactions" {
            return parseRedactionsAssertion(cbor)
        }
        if label == "c2pa.identity.assertion" || label.hasPrefix("cawg.identity") {
            return parseIdentityAssertion(cbor)
        }
        return .cbor(cbor)
    }

    static func parseActionsAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let actionsArray = cbor["actions"]?.arrayValue else {
            return .cbor(cbor)
        }

        let actions = actionsArray.compactMap { item -> C2PAAction? in
            guard let action = item["action"]?.textStringValue else { return nil }

            // softwareAgent: v1 is a string, v2 is a map with "name"
            var softwareAgent: String?
            if let agent = item["softwareAgent"] {
                switch agent {
                case .textString(let s): softwareAgent = s
                case .map: softwareAgent = agent["name"]?.textStringValue
                default: break
                }
            }

            return C2PAAction(
                action: action,
                softwareAgent: softwareAgent,
                description: item["description"]?.textStringValue,
                digitalSourceType: item["digitalSourceType"]?.textStringValue,
                parameters: item["parameters"]
            )
        }

        return .actions(C2PAActions(actions: actions))
    }

    static func parseHashDataAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let alg = cbor["alg"]?.textStringValue,
              let hash = cbor["hash"]?.byteStringValue else {
            return .cbor(cbor)
        }

        var exclusions: [C2PAExclusion] = []
        if let exclArray = cbor["exclusions"]?.arrayValue {
            for item in exclArray {
                if let start = item["start"]?.unsignedIntValue,
                   let length = item["length"]?.unsignedIntValue {
                    exclusions.append(C2PAExclusion(start: start, length: length))
                }
            }
        }

        return .hashData(C2PAHashData(algorithm: alg, hash: hash, exclusions: exclusions))
    }

    static func parseHashBoxesAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let boxesArray = cbor["boxes"]?.arrayValue else { return .cbor(cbor) }
        let alg = cbor["alg"]?.textStringValue
        let entries: [C2PAHashBoxEntry] = boxesArray.compactMap { item in
            let names: [String] = item["names"]?.arrayValue?.compactMap { $0.textStringValue } ?? []
            let entryAlg = item["alg"]?.textStringValue
            let hash = item["hash"]?.byteStringValue ?? Data()
            let pad = item["pad"]?.byteStringValue
            guard !names.isEmpty || !hash.isEmpty else { return nil }
            return C2PAHashBoxEntry(names: names, algorithm: entryAlg, hash: hash, pad: pad)
        }
        guard !entries.isEmpty else { return .cbor(cbor) }
        return .hashBoxes(C2PAHashBoxes(algorithm: alg, boxes: entries))
    }

    static func parseHashBMFFv2Assertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        let alg = cbor["alg"]?.textStringValue
        let hash = cbor["hash"]?.byteStringValue

        var exclusions: [C2PABMFFv2Exclusion] = []
        if let arr = cbor["exclusions"]?.arrayValue {
            for item in arr {
                let xpath = item["xpath"]?.textStringValue
                let length = item["length"]?.unsignedIntValue
                let version = item["version"]?.unsignedIntValue
                let flags = item["flags"]?.unsignedIntValue

                var subset: [C2PAExclusion] = []
                if let subsetArr = item["subset"]?.arrayValue {
                    for s in subsetArr {
                        if let off = s["offset"]?.unsignedIntValue,
                           let len = s["length"]?.unsignedIntValue {
                            subset.append(C2PAExclusion(start: off, length: len))
                        }
                    }
                }

                var overlays: [C2PABMFFv2DataOverlay] = []
                if let dataArr = item["data"]?.arrayValue {
                    for d in dataArr {
                        if let off = d["offset"]?.unsignedIntValue,
                           let val = d["value"]?.byteStringValue {
                            overlays.append(C2PABMFFv2DataOverlay(offset: off, value: val))
                        }
                    }
                }

                exclusions.append(C2PABMFFv2Exclusion(
                    xpath: xpath, length: length, version: version, flags: flags,
                    subset: subset, dataOverlays: overlays
                ))
            }
        }

        var merkle: [C2PABMFFv2Merkle] = []
        if let arr = cbor["merkle"]?.arrayValue {
            for item in arr {
                guard let uniqueId = item["uniqueId"]?.unsignedIntValue,
                      let localId = item["localId"]?.unsignedIntValue,
                      let count = item["count"]?.unsignedIntValue else { continue }
                let mAlg = item["alg"]?.textStringValue
                let initHash = item["initHash"]?.byteStringValue
                let hashes = item["hashes"]?.arrayValue?.compactMap { $0.byteStringValue } ?? []
                merkle.append(C2PABMFFv2Merkle(
                    uniqueId: uniqueId, localId: localId, count: count,
                    algorithm: mAlg, initHash: initHash, hashes: hashes
                ))
            }
        }

        if alg == nil && hash == nil && exclusions.isEmpty && merkle.isEmpty {
            return .cbor(cbor)
        }
        return .hashBMFFv2(C2PAHashBMFFv2(
            algorithm: alg, hash: hash,
            exclusions: exclusions, merkle: merkle
        ))
    }

    static func parseHashCollectionAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let arr = cbor["uris"]?.arrayValue else { return .cbor(cbor) }
        let alg = cbor["alg"]?.textStringValue
        let entries: [C2PACollectionEntry] = arr.compactMap { item in
            guard let uri = item["uri"]?.textStringValue else { return nil }
            let hash = item["hash"]?.byteStringValue ?? Data()
            let size = item["size"]?.unsignedIntValue
            let format = item["dc:format"]?.textStringValue
            return C2PACollectionEntry(uri: uri, hash: hash, size: size, format: format)
        }
        guard !entries.isEmpty else { return .cbor(cbor) }
        return .hashCollection(C2PAHashCollection(algorithm: alg, uris: entries))
    }

    static func parseIngredientAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        let ingredient = C2PAIngredient(
            title: cbor["dc:title"]?.textStringValue,
            format: cbor["dc:format"]?.textStringValue,
            instanceID: cbor["instanceID"]?.textStringValue,
            relationship: cbor["relationship"]?.textStringValue
        )
        return .ingredient(ingredient)
    }

    // MARK: - Phase B Assertion Parsers

    /// Flatten a CBOR map into a `[String: CBORValue]` keyed by text-string
    /// keys. Non-text keys are dropped. Used by stds.iptc / stds.exif /
    /// stds.schema-org.CreativeWork which are all JSON-LD-shaped.
    static func textKeyedMap(_ cbor: CBORValue) -> [String: CBORValue] {
        guard let entries = cbor.mapEntries else { return [:] }
        var out: [String: CBORValue] = [:]
        for entry in entries {
            if let key = entry.key.textStringValue {
                out[key] = entry.value
            }
        }
        return out
    }

    static func parseIPTCAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        let fields = textKeyedMap(cbor)
        guard !fields.isEmpty else { return .cbor(cbor) }
        return .iptc(C2PAIPTCAssertion(fields: fields))
    }

    static func parseExifAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        let fields = textKeyedMap(cbor)
        guard !fields.isEmpty else { return .cbor(cbor) }
        return .exif(C2PAExifAssertion(fields: fields))
    }

    static func parseSchemaOrgCreativeWorkAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        let fields = textKeyedMap(cbor)
        guard !fields.isEmpty else { return .cbor(cbor) }
        return .schemaOrgCreativeWork(C2PASchemaOrgCreativeWork(fields: fields))
    }

    static func parseTrainingMiningAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        // Two encodings seen in the wild:
        //   1) `{ entries: { "<category>": { use, constraint_info } } }`
        //   2) `{ "<category>": { use, ... }, ... }` (older drafts)
        // Try (1) first, fall back to (2).
        let entriesMap: CBORValue?
        if let inner = cbor["entries"], inner.mapEntries != nil {
            entriesMap = inner
        } else if cbor.mapEntries != nil {
            entriesMap = cbor
        } else {
            entriesMap = nil
        }

        guard let map = entriesMap?.mapEntries else { return .cbor(cbor) }
        var entries: [C2PATrainingMiningEntry] = []
        for entry in map {
            guard let category = entry.key.textStringValue else { continue }
            // The "entries" wrapper key itself shouldn't be treated as a category.
            if category == "entries" { continue }
            let use = entry.value["use"]?.textStringValue ?? "unknown"
            let constraintInfo = entry.value["constraint_info"]?.textStringValue
            entries.append(C2PATrainingMiningEntry(
                category: category,
                use: use,
                constraintInfo: constraintInfo
            ))
        }
        guard !entries.isEmpty else { return .cbor(cbor) }
        return .trainingMining(C2PATrainingMining(entries: entries))
    }

    static func parseRedactionsAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let arr = cbor["redactions"]?.arrayValue else { return .cbor(cbor) }
        let urls = arr.compactMap { $0.textStringValue }
        return .redactions(C2PARedactions(redactions: urls))
    }

    static func parseIdentityAssertion(_ cbor: CBORValue) -> C2PAAssertionContent {
        guard let signerPayload = cbor["signer_payload"] else { return .cbor(cbor) }
        let signature = cbor["signature"]?.byteStringValue ?? Data()
        let pad1 = cbor["pad1"]?.byteStringValue
        let pad2 = cbor["pad2"]?.byteStringValue
        return .identityAssertion(C2PAIdentityAssertion(
            signerPayload: signerPayload,
            signature: signature,
            pad1: pad1,
            pad2: pad2
        ))
    }

    // MARK: - Helpers

    /// Build a complete ISOBMFF box from type + payload (for wrapping back into parseable data).
    static func buildBoxData(type: String, payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        var data = Data(capacity: Int(size))
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii) ?? Data(count: 4))
        data.append(payload)
        return data
    }

    /// Find the start offset of JUMBF data within a buffer (looks for a valid jumb box header).
    static func findJUMBFStart(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        // Scan for "jumb" box type at offset+4
        for i in 0..<max(0, bytes.count - 8) {
            if bytes[i + 4] == 0x6A && bytes[i + 5] == 0x75
                && bytes[i + 6] == 0x6D && bytes[i + 7] == 0x62 { // "jumb"
                // Validate that the size makes sense
                let size = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                    | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
                if size > 8 && Int(size) + i <= bytes.count {
                    return i
                }
            }
        }
        return nil
    }
}
