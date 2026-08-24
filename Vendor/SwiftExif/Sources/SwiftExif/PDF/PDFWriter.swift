import Foundation

/// Write PDF metadata back using incremental update (append-only).
public struct PDFWriter: Sendable {

    /// Write modified metadata back to PDF using incremental update.
    /// Appends new objects and xref table to the end of the original file.
    public static func write(_ file: PDFFile, infoDict: [String: String]?, xmpData: Data?) throws -> Data {
        var output = file.rawData

        var newXRefEntries: [(objNum: Int, offset: Int, genNum: Int)] = []
        var nextObjNum = file.nextObjectNumber

        // Write updated Info dictionary object
        let infoObjNum: Int
        if let infoDict, !infoDict.isEmpty {
            infoObjNum = file.infoObjectNumber ?? nextObjNum
            if file.infoObjectNumber == nil { nextObjNum += 1 }

            let infoOffset = output.count
            let infoObj = buildInfoObject(objNum: infoObjNum, genNum: file.infoGenerationNumber, dict: infoDict)
            output.append(contentsOf: infoObj.utf8)
            newXRefEntries.append((infoObjNum, infoOffset, file.infoGenerationNumber))
        } else {
            infoObjNum = file.infoObjectNumber ?? 0
        }

        // Write updated XMP metadata stream object
        let xmpObjNum: Int
        if let xmpData, !xmpData.isEmpty {
            xmpObjNum = file.xmpObjectNumber ?? nextObjNum
            if file.xmpObjectNumber == nil { nextObjNum += 1 }

            let xmpOffset = output.count
            let xmpObj = buildXMPStreamObject(objNum: xmpObjNum, genNum: file.xmpGenerationNumber, data: xmpData)
            output.append(contentsOf: xmpObj)
            newXRefEntries.append((xmpObjNum, xmpOffset, file.xmpGenerationNumber))
        } else {
            xmpObjNum = file.xmpObjectNumber ?? 0
        }

        guard !newXRefEntries.isEmpty else {
            return output // Nothing to update
        }

        // Write new xref table
        let xrefOffset = output.count
        var xrefStr = "xref\n"

        // Write entries grouped by contiguous object numbers
        let sorted = newXRefEntries.sorted { $0.objNum < $1.objNum }
        var i = 0
        while i < sorted.count {
            let startObj = sorted[i].objNum
            var group: [(objNum: Int, offset: Int, genNum: Int)] = []
            while i < sorted.count && sorted[i].objNum == startObj + group.count {
                group.append(sorted[i])
                i += 1
            }
            xrefStr += "\(startObj) \(group.count)\n"
            for entry in group {
                xrefStr += String(format: "%010d %05d n \n", entry.offset, entry.genNum)
            }
        }

        output.append(contentsOf: xrefStr.utf8)

        // Write trailer
        var trailerStr = "trailer\n<<"
        trailerStr += "\n/Size \(max(nextObjNum, (sorted.last?.objNum ?? 0) + 1))"
        trailerStr += "\n/Prev \(file.lastXRefOffset)"
        if infoObjNum > 0 {
            trailerStr += "\n/Info \(infoObjNum) 0 R"
        }
        // Root should be inherited from previous trailer via /Prev
        trailerStr += "\n>>\nstartxref\n\(xrefOffset)\n%%EOF\n"

        output.append(contentsOf: trailerStr.utf8)

        return output
    }

    // MARK: - Object Builders

    private static func buildInfoObject(objNum: Int, genNum: Int, dict: [String: String]) -> String {
        var obj = "\(objNum) \(genNum) obj\n<<"
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            obj += "\n/\(key) \(encodePDFString(value))"
        }
        obj += "\n>>\nendobj\n"
        return obj
    }

    /// Encode a metadata value as a PDF string object.
    ///
    /// Pure ASCII values stay in the readable `(…)` literal form. Anything with a non-ASCII
    /// character is serialized as a UTF-16BE hex string with a BOM, which is the only
    /// encoding the PDF 1.x Info dictionary spec actually guarantees readers will decode as
    /// Unicode — raw UTF-8 inside `(…)` would otherwise be interpreted as PDFDocEncoding.
    private static func encodePDFString(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) {
            return "(\(escapePDFString(value)))"
        }
        var hex = "FEFF"
        for unit in value.utf16 {
            hex += String(format: "%04X", unit)
        }
        return "<\(hex)>"
    }

    private static func buildXMPStreamObject(objNum: Int, genNum: Int, data: Data) -> Data {
        var header = "\(objNum) \(genNum) obj\n"
        header += "<</Type /Metadata /Subtype /XML /Length \(data.count)>>\n"
        header += "stream\n"

        var result = Data(header.utf8)
        result.append(data)
        result.append(contentsOf: "\nendstream\nendobj\n".utf8)
        return result
    }

    /// Escape special characters in a PDF string literal.
    private static func escapePDFString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}
