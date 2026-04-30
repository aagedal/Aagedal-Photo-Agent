import Foundation

/// Structured data for writes that go beyond simple key-value pairs (tone curves, masks).
struct StructuredWriteData: Sendable {
    var toneCurve: ToneCurve?
    var masks: [MaskAdjustment]?

    var isEmpty: Bool {
        (toneCurve == nil || (toneCurve?.isEmpty ?? true)) && (masks == nil || (masks?.isEmpty ?? true))
    }

    static let empty = StructuredWriteData()
}

/// Abstraction over metadata write backends.
/// Both implementations must handle XMP/IPTC mirroring and file creation date preservation internally.
protocol MetadataWriteEngine: AnyObject, Sendable {
    /// Write key-value metadata fields to one or more files.
    func writeFields(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws

    /// Add and/or remove individual list values (keywords, persons) with deduplication.
    func addRemoveListValues(
        add: [MetadataFieldKey: [String]],
        remove: [MetadataFieldKey: [String]],
        to urls: [URL]
    ) async throws

    /// Write star rating.
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws

    /// Write color label.
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws

    /// Write EXIF orientation.
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws

    /// Strip all IPTC and XMP metadata.
    func stripIPTCAndXMP(from urls: [URL]) async throws

    /// Copy all metadata from source to rendered destination with standard exclusions.
    func copyMetadataToRenderedFile(from source: URL, to destination: URL) async throws
}

extension MetadataWriteEngine {
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL]) async throws {
        try await writeFields(fields, to: urls, structuredData: .empty)
    }
}

// MARK: - Shared Helpers

/// Capture file creation dates before a write operation so they can be restored after.
/// Direct file writes may reset the creation date.
func captureCreationDates(for urls: [URL]) -> [URL: Date] {
    var result: [URL: Date] = [:]
    for url in urls {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let creationDate = attrs[.creationDate] as? Date else {
            continue
        }
        result[url] = creationDate
    }
    return result
}

/// Restore file creation dates after a write operation.
func restoreCreationDates(_ creationDates: [URL: Date]) {
    for (url, creationDate) in creationDates {
        try? FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
    }
}

/// Format a number in ACR's style: integers for whole numbers, minimal trailing decimals otherwise.
func acrNum(_ value: Double) -> String {
    if value == value.rounded(.toNearestOrEven) && abs(value) < 1_000_000 {
        return String(Int(value))
    }
    var s = String(format: "%.6f", value)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
