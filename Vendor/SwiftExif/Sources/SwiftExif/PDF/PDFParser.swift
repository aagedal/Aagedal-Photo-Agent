import Foundation

/// Parse PDF files to extract metadata (Info dictionary and XMP stream).
public struct PDFParser: Sendable {

    /// Standard PDF Info dictionary keys.
    static let infoKeys: Set<String> = [
        "Title", "Author", "Subject", "Keywords", "Creator",
        "Producer", "CreationDate", "ModDate"
    ]

    /// Parse a PDF file and extract metadata.
    public static func parse(_ data: Data) throws -> PDFFile {
        guard data.count >= 8 else {
            throw MetadataError.invalidPDF("File too small")
        }

        // Verify header
        guard let headerLine = findLine(in: data, from: 0),
              headerLine.hasPrefix("%PDF-") else {
            throw MetadataError.invalidPDF("Missing %PDF- header")
        }
        let version = String(headerLine.dropFirst(5))

        // Check for encryption
        if findString(in: data, target: "/Encrypt") != nil {
            throw MetadataError.invalidPDF("Encrypted PDFs are not supported")
        }

        // Find startxref
        let startXRefOffset = try findStartXRef(in: data)

        // Parse xref table to find object offsets
        let (xrefEntries, trailerDict) = try parseXRef(data: data, offset: startXRefOffset)

        // Find highest object number for new object allocation
        let maxObjNum = xrefEntries.keys.max() ?? 0

        // Extract Info dictionary
        var infoDict: [String: String] = [:]
        var infoObjNum: Int? = nil
        var infoGenNum: Int = 0

        if let infoRef = trailerDict["Info"] {
            let (objNum, genNum) = parseReference(infoRef)
            infoObjNum = objNum
            infoGenNum = genNum
            if let objNum, let offset = xrefEntries[objNum] {
                infoDict = parseInfoDict(data: data, offset: offset)
            }
        }

        // Extract XMP metadata stream
        var xmpStreamData: Data? = nil
        var xmpObjNum: Int? = nil
        var xmpGenNum: Int = 0

        if let rootRef = trailerDict["Root"] {
            let (rootObjNum, _) = parseReference(rootRef)
            if let rootObjNum, let rootOffset = xrefEntries[rootObjNum] {
                let catalogDict = parseDictionary(data: data, offset: rootOffset)
                if let metaRef = catalogDict["Metadata"] {
                    let (metaObjNum, metaGenNum) = parseReference(metaRef)
                    xmpObjNum = metaObjNum
                    xmpGenNum = metaGenNum
                    if let metaObjNum, let metaOffset = xrefEntries[metaObjNum] {
                        xmpStreamData = extractStream(data: data, offset: metaOffset)
                    }
                }
            }
        }

        return PDFFile(
            headerVersion: version,
            rawData: data,
            infoDict: infoDict,
            xmpStreamData: xmpStreamData,
            infoObjectNumber: infoObjNum,
            infoGenerationNumber: infoGenNum,
            xmpObjectNumber: xmpObjNum,
            xmpGenerationNumber: xmpGenNum,
            lastXRefOffset: startXRefOffset,
            nextObjectNumber: maxObjNum + 1
        )
    }

    // MARK: - Private Parsing

    /// Find the startxref value at the end of the PDF.
    private static func findStartXRef(in data: Data) throws -> Int {
        // Search backwards from end for "startxref" using byte scanning
        let target = Array("startxref".utf8)
        var pos = data.count - 1
        let minPos = max(0, data.count - 1024)

        var found = -1
        while pos >= minPos + target.count - 1 {
            let start = pos - target.count + 1
            var match = true
            for j in 0..<target.count {
                if data[data.startIndex + start + j] != target[j] {
                    match = false
                    break
                }
            }
            if match {
                found = start
                break
            }
            pos -= 1
        }

        guard found >= 0 else {
            throw MetadataError.invalidPDF("Missing startxref")
        }

        // Read the offset number after "startxref"
        let afterPos = found + target.count
        let remaining = data[data.startIndex + afterPos ..< data.endIndex]
        guard let str = String(data: remaining, encoding: .ascii) ?? String(data: remaining, encoding: .utf8) else {
            throw MetadataError.invalidPDF("Cannot read startxref value")
        }

        let digits = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).first ?? ""

        guard let offset = Int(digits), offset >= 0, offset < data.count else {
            throw MetadataError.invalidPDF("Invalid startxref offset")
        }

        return offset
    }

    /// Parse xref table and trailer dictionary.
    /// Returns a map of object number → byte offset, and trailer key-value pairs.
    private static func parseXRef(data: Data, offset: Int) throws -> ([Int: Int], [String: String]) {
        guard offset < data.count else {
            throw MetadataError.invalidPDF("Invalid xref offset")
        }

        // Check if this is a traditional xref table or an xref stream
        let chunk = data[data.startIndex + offset ..< data.startIndex + min(offset + 20, data.count)]
        guard let lineStart = String(data: chunk, encoding: .ascii) else {
            throw MetadataError.invalidPDF("Cannot read xref section")
        }

        if lineStart.hasPrefix("xref") {
            return try parseTraditionalXRef(data: data, offset: offset)
        }

        // Could be an xref stream (PDF 1.5+) — fall back to scanning for trailer
        throw MetadataError.invalidPDF("Xref streams not supported; use traditional xref table")
    }

    private static func parseTraditionalXRef(data: Data, offset: Int) throws -> ([Int: Int], [String: String]) {
        var entries: [Int: Int] = [:]
        var pos = offset

        // Skip "xref" line
        guard let _ = findLine(in: data, from: pos) else {
            throw MetadataError.invalidPDF("Cannot read xref header")
        }
        pos = skipLine(in: data, from: pos)

        // Parse xref sections: each starts with "startObj count"
        while pos < data.count {
            guard let line = findLine(in: data, from: pos) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("trailer") {
                break
            }

            let parts = trimmed.split(separator: " ")
            if parts.count == 2, let startObj = Int(parts[0]), let count = Int(parts[1]) {
                pos = skipLine(in: data, from: pos)
                for i in 0..<count {
                    guard let entryLine = findLine(in: data, from: pos) else { break }
                    let entryParts = entryLine.trimmingCharacters(in: .whitespaces).split(separator: " ")
                    if entryParts.count >= 3 {
                        let entryOffset = Int(entryParts[0]) ?? 0
                        let inUse = entryParts[2] == "n"
                        if inUse && entryOffset > 0 {
                            entries[startObj + i] = entryOffset
                        }
                    }
                    pos = skipLine(in: data, from: pos)
                }
            } else {
                pos = skipLine(in: data, from: pos)
            }
        }

        // Find and parse trailer dictionary
        guard let trailerPos = findString(in: data, target: "trailer", startingAt: offset) else {
            throw MetadataError.invalidPDF("Missing trailer dictionary")
        }
        let trailerDict = parseDictionaryFromPos(data: data, offset: trailerPos + 7)

        return (entries, trailerDict)
    }

    /// Parse an object's dictionary (the `<< ... >>` section of an indirect object).
    private static func parseDictionary(data: Data, offset: Int) -> [String: String] {
        // Skip "N G obj" prefix to find the << dict >>
        guard let dictStart = findString(in: data, target: "<<", startingAt: offset, maxSearch: 200) else {
            return [:]
        }
        return parseDictionaryFromPos(data: data, offset: dictStart)
    }

    /// Parse a dictionary starting from a position near `<<`.
    private static func parseDictionaryFromPos(data: Data, offset: Int) -> [String: String] {
        // Find << and >>
        guard let start = findString(in: data, target: "<<", startingAt: offset, maxSearch: 200) else {
            return [:]
        }
        let searchEnd = min(start + 4096, data.count)
        guard let end = findString(in: data, target: ">>", startingAt: start + 2, maxSearch: searchEnd - start - 2) else {
            return [:]
        }

        let dictData = data[data.startIndex + start + 2 ..< data.startIndex + end]
        guard let dictStr = String(data: dictData, encoding: .ascii) ?? String(data: dictData, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        var remaining = dictStr[dictStr.startIndex...]

        while !remaining.isEmpty {
            // Find next /Name
            guard let slashIdx = remaining.firstIndex(of: "/") else { break }
            remaining = remaining[remaining.index(after: slashIdx)...]

            // Read name (until whitespace, /, <, (, [)
            var name = ""
            while !remaining.isEmpty {
                let c = remaining[remaining.startIndex]
                if c == " " || c == "\n" || c == "\r" || c == "\t" || c == "/" || c == "<" || c == "(" || c == "[" {
                    break
                }
                name.append(c)
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }

            guard !name.isEmpty else { continue }

            // Skip whitespace
            while !remaining.isEmpty && (remaining.first == " " || remaining.first == "\n" || remaining.first == "\r" || remaining.first == "\t") {
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
            guard !remaining.isEmpty else { break }

            // Read value
            let firstChar = remaining[remaining.startIndex]
            if firstChar == "(" {
                // String literal
                let str = readPDFString(&remaining)
                result[name] = str
            } else if firstChar == "<" {
                if remaining.count >= 2 && remaining[remaining.index(after: remaining.startIndex)] == "<" {
                    // Nested dictionary — skip
                    skipNestedDict(&remaining)
                } else {
                    // Hex string
                    let str = readHexString(&remaining)
                    result[name] = str
                }
            } else if firstChar == "/" {
                // Name value — don't consume the /
                var val = ""
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
                while !remaining.isEmpty {
                    let c = remaining[remaining.startIndex]
                    if c == " " || c == "\n" || c == "\r" || c == "/" || c == ">" { break }
                    val.append(c)
                    remaining = remaining[remaining.index(after: remaining.startIndex)...]
                }
                result[name] = "/\(val)"
            } else {
                // Number, boolean, reference (N G R), or other
                var val = ""
                while !remaining.isEmpty {
                    let c = remaining[remaining.startIndex]
                    if c == "/" || c == ">" || c == "<" { break }
                    val.append(c)
                    remaining = remaining[remaining.index(after: remaining.startIndex)...]
                }
                result[name] = val.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }

    /// Parse a PDF Info dictionary into standard metadata fields.
    private static func parseInfoDict(data: Data, offset: Int) -> [String: String] {
        let raw = parseDictionary(data: data, offset: offset)
        var result: [String: String] = [:]
        for key in infoKeys {
            if let value = raw[key] {
                result[key] = decodePDFString(value)
            }
        }
        return result
    }

    /// Locate a C2PA manifest store embedded as a PDF associated file (`/AF`) and
    /// return its raw JUMBF byte stream. Returns nil when no C2PA embedded file
    /// is present.
    ///
    /// The C2PA-PDF binding (C2PA spec §9.7) requires the embedded file stream
    /// to declare `/Subtype /application#2Fc2pa` (URL-encoded "application/c2pa")
    /// — that token is unique enough to drive a byte scan and avoid replicating
    /// full PDF object-graph traversal here.
    public static func extractC2PAJUMBF(from data: Data) -> Data? {
        let needles: [[UInt8]] = [
            Array("application#2Fc2pa".utf8),
            Array("application/c2pa".utf8),
        ]
        for needle in needles {
            var searchStart = 0
            while let pos = findBytes(needle, in: data, from: searchStart) {
                searchStart = pos + needle.count
                guard let objStart = findObjStart(in: data, before: pos) else { continue }
                if let stream = extractStream(data: data, offset: objStart),
                   !stream.isEmpty {
                    return stream
                }
            }
        }
        return nil
    }

    private static func findBytes(_ needle: [UInt8], in data: Data, from start: Int) -> Int? {
        guard !needle.isEmpty, data.count >= needle.count, start <= data.count - needle.count else {
            return nil
        }
        for i in start...(data.count - needle.count) {
            var match = true
            for j in 0..<needle.count {
                if data[data.startIndex + i + j] != needle[j] {
                    match = false
                    break
                }
            }
            if match { return i }
        }
        return nil
    }

    /// Walk backward from `pos` to find the byte immediately after the most
    /// recent "obj" keyword (preceded by whitespace, i.e. the "N G obj" header).
    private static func findObjStart(in data: Data, before pos: Int) -> Int? {
        var i = pos
        while i >= 4 {
            if data[data.startIndex + i - 3] == 0x6F /*o*/
                && data[data.startIndex + i - 2] == 0x62 /*b*/
                && data[data.startIndex + i - 1] == 0x6A /*j*/ {
                let preceding = data[data.startIndex + i - 4]
                if preceding == 0x20 || preceding == 0x09 || preceding == 0x0D || preceding == 0x0A {
                    return i
                }
            }
            i -= 1
        }
        return nil
    }

    /// Extract a stream's content from an indirect object.
    private static func extractStream(data: Data, offset: Int) -> Data? {
        let dict = parseDictionary(data: data, offset: offset)
        guard let lengthStr = dict["Length"],
              let length = Int(lengthStr.trimmingCharacters(in: .whitespaces)),
              length >= 0, length <= data.count else {
            return nil
        }

        guard let streamStart = findString(in: data, target: "stream", startingAt: offset, maxSearch: 2048) else {
            return nil
        }

        // Skip "stream" + newline (CR, LF, or CRLF)
        var contentStart = streamStart + 6
        if contentStart < data.count && data[data.startIndex + contentStart] == 0x0D { // CR
            contentStart += 1
        }
        if contentStart < data.count && data[data.startIndex + contentStart] == 0x0A { // LF
            contentStart += 1
        }

        // length is already bounded by data.count above, so contentStart+length
        // cannot overflow Int; only the end-of-data check remains.
        let contentEnd = contentStart + length
        guard contentEnd <= data.count else { return nil }

        var streamData = Data(data[data.startIndex + contentStart ..< data.startIndex + contentEnd])

        // Decompress if FlateDecode
        let filter = dict["Filter"]?.trimmingCharacters(in: .whitespaces)
        if filter == "/FlateDecode" {
            if let decompressed = decompress(streamData) {
                streamData = decompressed
            }
        }

        return streamData
    }

    // MARK: - String Parsing Helpers

    private static func readPDFString(_ remaining: inout Substring) -> String {
        guard !remaining.isEmpty && remaining.first == "(" else { return "" }
        remaining = remaining[remaining.index(after: remaining.startIndex)...]

        var result = ""
        var depth = 1

        while !remaining.isEmpty && depth > 0 {
            let c = remaining[remaining.startIndex]
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
            if c == "(" {
                depth += 1
                result.append(c)
            } else if c == ")" {
                depth -= 1
                if depth > 0 { result.append(c) }
            } else if c == "\\" && !remaining.isEmpty {
                let next = remaining[remaining.startIndex]
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
                switch next {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "(": result.append("(")
                case ")": result.append(")")
                case "\\": result.append("\\")
                default: result.append(next)
                }
            } else {
                result.append(c)
            }
        }
        return result
    }

    private static func readHexString(_ remaining: inout Substring) -> String {
        guard !remaining.isEmpty && remaining.first == "<" else { return "" }
        remaining = remaining[remaining.index(after: remaining.startIndex)...]

        var hex = ""
        while !remaining.isEmpty {
            let c = remaining[remaining.startIndex]
            remaining = remaining[remaining.index(after: remaining.startIndex)...]
            if c == ">" { break }
            if c.isHexDigit { hex.append(c) }
        }

        // Decode hex pairs to bytes
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let nextI = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[i..<nextI], radix: 16) {
                bytes.append(byte)
            }
            i = nextI
        }

        // Check for BOM (UTF-16 BE)
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            let utf16Data = Data(bytes[2...])
            if let str = String(data: utf16Data, encoding: .utf16BigEndian) {
                return str
            }
        }

        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func skipNestedDict(_ remaining: inout Substring) {
        // Skip past matching >>
        var depth = 0
        while !remaining.isEmpty {
            let c = remaining[remaining.startIndex]
            let nextIdx = remaining.index(after: remaining.startIndex)
            if c == "<" && nextIdx < remaining.endIndex && remaining[nextIdx] == "<" {
                depth += 1
                remaining = remaining[remaining.index(after: nextIdx)...]
            } else if c == ">" && nextIdx < remaining.endIndex && remaining[nextIdx] == ">" {
                depth -= 1
                remaining = remaining[remaining.index(after: nextIdx)...]
                if depth <= 0 { return }
            } else {
                remaining = remaining[nextIdx...]
            }
        }
    }

    /// Decode a PDF string value (handles UTF-16 BOM, PDF date format, etc.).
    private static func decodePDFString(_ value: String) -> String {
        value
    }

    /// Parse "N G R" reference to extract object and generation numbers.
    private static func parseReference(_ ref: String) -> (Int?, Int) {
        let parts = ref.trimmingCharacters(in: .whitespaces).split(separator: " ")
        if parts.count >= 2, let objNum = Int(parts[0]), let genNum = Int(parts[1]) {
            return (objNum, genNum)
        }
        return (nil, 0)
    }

    // MARK: - Data Utilities

    /// Find a line of text starting at a byte offset.
    private static func findLine(in data: Data, from offset: Int) -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count && data[data.startIndex + end] != 0x0A && data[data.startIndex + end] != 0x0D {
            end += 1
        }
        let lineData = data[data.startIndex + offset ..< data.startIndex + end]
        return String(data: lineData, encoding: .ascii)
    }

    /// Skip past the current line (including newline characters).
    private static func skipLine(in data: Data, from offset: Int) -> Int {
        var pos = offset
        while pos < data.count && data[data.startIndex + pos] != 0x0A && data[data.startIndex + pos] != 0x0D {
            pos += 1
        }
        // Skip CR, LF, or CRLF
        if pos < data.count && data[data.startIndex + pos] == 0x0D { pos += 1 }
        if pos < data.count && data[data.startIndex + pos] == 0x0A { pos += 1 }
        return pos
    }

    /// Find a string pattern in data starting at a given offset.
    private static func findString(in data: Data, target: String, startingAt: Int = 0, maxSearch: Int = 0) -> Int? {
        let targetBytes = Array(target.utf8)
        guard data.count >= targetBytes.count else { return nil }
        let maxEnd = data.count - targetBytes.count + 1
        let searchEnd: Int
        if maxSearch > 0 {
            searchEnd = min(startingAt + maxSearch, maxEnd)
        } else {
            searchEnd = maxEnd
        }
        guard searchEnd > startingAt else { return nil }

        for i in startingAt..<searchEnd {
            var match = true
            for j in 0..<targetBytes.count {
                if data[data.startIndex + i + j] != targetBytes[j] {
                    match = false
                    break
                }
            }
            if match { return i }
        }
        return nil
    }

    private static func decompress(_ data: Data) -> Data? {
        if let result = ZlibInflate.inflate(data) { return result }
        return ZlibInflate.inflate(data, rawDeflate: true)
    }
}
