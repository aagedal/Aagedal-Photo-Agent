import Foundation

/// Import metadata from JSON or CSV files and apply to images.
public struct MetadataImporter: Sendable {

    /// How to match import records to image files.
    public enum FileMatching: Sendable {
        /// Match by a filename column in the import data.
        case byFilename(column: String)
        /// Apply records sequentially to files in order.
        case sequential
    }

    // MARK: - JSON Parsing

    /// Parse a JSON array of objects (ExifTool `-json` format) into import records.
    public static func parseJSON(_ data: Data) throws -> [[String: String]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw MetadataError.encodingError("Invalid JSON data")
        }

        guard let array = json as? [[String: Any]] else {
            throw MetadataError.encodingError("Expected JSON array of objects")
        }

        return array.map { obj in
            var record: [String: String] = [:]
            for (key, value) in obj {
                if let arr = value as? [Any] {
                    record[key] = arr.map { String(describing: $0) }.joined(separator: ";")
                } else {
                    record[key] = String(describing: value)
                }
            }
            return record
        }
    }

    // MARK: - CSV Parsing

    /// Parse CSV data (RFC 4180, matching CSVExporter output) into import records.
    public static func parseCSV(_ string: String) throws -> [[String: String]] {
        let lines = parseCSVLines(string)
        guard lines.count >= 2 else {
            throw MetadataError.encodingError("CSV must have at least a header row and one data row")
        }

        let headers = lines[0]
        var records: [[String: String]] = []

        for i in 1..<lines.count {
            let fields = lines[i]
            var record: [String: String] = [:]
            for (j, header) in headers.enumerated() where j < fields.count {
                let value = fields[j]
                if !value.isEmpty {
                    record[header] = value
                }
            }
            if !record.isEmpty {
                records.append(record)
            }
        }

        return records
    }

    // MARK: - Apply Record

    /// Apply a single import record to an ImageMetadata instance.
    /// Supports IPTC and XMP fields. EXIF fields are skipped (read-only).
    public static func apply(_ record: [String: String], to metadata: inout ImageMetadata) {
        for (key, value) in record {
            applyField(key: key, value: value, to: &metadata)
        }
    }

    /// Apply a filtered import record.
    public static func apply(_ record: [String: String], to metadata: inout ImageMetadata, filter: TagFilter?) {
        for (key, value) in record {
            if let filter, !filter.matches(key: key) { continue }
            applyField(key: key, value: value, to: &metadata)
        }
    }

    // MARK: - Batch Import

    /// Import records onto matching files.
    public static func importToFiles(
        records: [[String: String]],
        files: [URL],
        matching: FileMatching,
        filter: TagFilter? = nil,
        writeOptions: ImageMetadata.WriteOptions = .default
    ) throws -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0

        switch matching {
        case .byFilename(let column):
            // Build filename → record lookup
            var recordMap: [String: [String: String]] = [:]
            for record in records {
                if let filename = record[column] {
                    let name = URL(fileURLWithPath: filename).lastPathComponent
                    recordMap[name] = record
                }
            }
            for url in files {
                guard let record = recordMap[url.lastPathComponent] else { continue }
                do {
                    var metadata = try ImageMetadata.read(from: url)
                    apply(record, to: &metadata, filter: filter)
                    try metadata.write(to: url, options: writeOptions)
                    succeeded += 1
                } catch {
                    failed += 1
                }
            }

        case .sequential:
            for (i, url) in files.enumerated() where i < records.count {
                do {
                    var metadata = try ImageMetadata.read(from: url)
                    apply(records[i], to: &metadata, filter: filter)
                    try metadata.write(to: url, options: writeOptions)
                    succeeded += 1
                } catch {
                    failed += 1
                }
            }
        }

        return (succeeded, failed)
    }

    // MARK: - Private

    private static func applyField(key: String, value: String, to metadata: inout ImageMetadata) {
        // IPTC fields
        switch key {
        case "IPTC:Headline", "Headline":
            metadata.iptc.headline = value
        case "IPTC:Caption-Abstract", "Caption", "Caption-Abstract":
            metadata.iptc.caption = value
        case "IPTC:By-line", "By-line", "Byline":
            metadata.iptc.byline = value
        case "IPTC:Credit", "Credit":
            metadata.iptc.credit = value
        case "IPTC:Source":
            metadata.iptc.source = value
        case "IPTC:CopyrightNotice", "CopyrightNotice":
            metadata.iptc.copyright = value
        case "IPTC:City":
            metadata.iptc.city = value
        case "IPTC:Sub-location", "Sub-location", "Sublocation":
            metadata.iptc.sublocation = value
        case "IPTC:Province-State", "Province-State":
            metadata.iptc.provinceState = value
        case "IPTC:Country-PrimaryLocationCode", "CountryCode":
            metadata.iptc.countryCode = value
        case "IPTC:Country-PrimaryLocationName", "Country":
            metadata.iptc.countryName = value
        case "IPTC:DateCreated":
            metadata.iptc.dateCreated = value
        case "IPTC:TimeCreated":
            metadata.iptc.timeCreated = value
        case "IPTC:SpecialInstructions":
            metadata.iptc.specialInstructions = value
        case "IPTC:ObjectName", "ObjectName":
            metadata.iptc.objectName = value
        case "IPTC:Writer-Editor":
            metadata.iptc.writerEditor = value
        case "IPTC:OriginalTransmissionReference":
            metadata.iptc.jobId = value
        case "IPTC:Keywords", "Keywords":
            metadata.iptc.keywords = value.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces)) }

        // PDF Info fields
        case _ where key.hasPrefix("PDF:"):
            if case .pdf(var file) = metadata.container {
                let pdfKey = String(key.dropFirst(4))
                file.infoDict[pdfKey] = value
                metadata.container = .pdf(file)
            }

        // XMP tags
        case _ where key.hasPrefix("XMP-") || key.hasPrefix("XMP:"):
            applyXMPField(key: key, value: value, to: &metadata)

        default:
            break // Skip EXIF and other read-only fields
        }
    }

    private static func applyXMPField(key: String, value: String, to metadata: inout ImageMetadata) {
        if metadata.xmp == nil { metadata.xmp = XMPData() }

        let stripped: String
        if key.hasPrefix("XMP-") {
            stripped = String(key.dropFirst(4))
        } else {
            stripped = String(key.dropFirst(4))
        }

        let parts = stripped.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }

        let prefix = String(parts[0])
        let property = String(parts[1])

        let namespace = XMPNamespace.prefixes.first(where: { $0.value == prefix })?.key
            ?? "http://\(prefix.lowercased())/"

        if value.contains(";") {
            let items = value.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces)) }
            metadata.xmp?.setValue(.array(items), namespace: namespace, property: property)
        } else {
            metadata.xmp?.setValue(.simple(value), namespace: namespace, property: property)
        }
    }

    // MARK: - CSV Line Parsing (RFC 4180)

    private static func parseCSVLines(_ string: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        var i = string.startIndex

        while i < string.endIndex {
            let c = string[i]

            if inQuotes {
                if c == "\"" {
                    let next = string.index(after: i)
                    if next < string.endIndex && string[next] == "\"" {
                        field.append("\"")
                        i = string.index(after: next)
                    } else {
                        inQuotes = false
                        i = string.index(after: i)
                    }
                } else {
                    field.append(c)
                    i = string.index(after: i)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                    i = string.index(after: i)
                } else if c == "," {
                    current.append(field)
                    field = ""
                    i = string.index(after: i)
                } else if c == "\r" || c == "\n" {
                    current.append(field)
                    field = ""
                    if !current.allSatisfy({ $0.isEmpty }) || !current.isEmpty {
                        result.append(current)
                    }
                    current = []
                    // Skip CRLF
                    i = string.index(after: i)
                    if c == "\r" && i < string.endIndex && string[i] == "\n" {
                        i = string.index(after: i)
                    }
                } else {
                    field.append(c)
                    i = string.index(after: i)
                }
            }
        }

        // Last field/row
        if !field.isEmpty || !current.isEmpty {
            current.append(field)
            result.append(current)
        }

        return result
    }
}
