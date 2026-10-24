import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftMediaMetadata

/// A retained Dispatch executor keeps collision probes, image encoding and publication off the
/// main actor while preserving the extraction task's cancellation, priority and task locals.
actor VideoStillFilesystemService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = VideoStillFilesystemService()

    enum Operation: Sendable {
        case collisionProbe, encode, publish, jxlRead, cleanup
    }

    typealias JXLExtractor = @Sendable (URL, Double, URL) async throws -> Void
    private let beforeOperation: @Sendable (Operation, URL) throws -> Void
    private let extractJXL: JXLExtractor

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.video-still.filesystem", qos: .userInitiated
        ),
        beforeOperation: @escaping @Sendable (Operation, URL) throws -> Void = { _, _ in },
        extractJXL: @escaping JXLExtractor = { source, seconds, temporary in
            try await FFmpegService.extractVideoStillJXL(
                input: source.path, output: temporary.path, seconds: seconds
            )
        }
    ) {
        self.filesystemQueue = filesystemQueue
        self.beforeOperation = beforeOperation
        self.extractJXL = extractJXL
    }

    private func check(_ operation: Operation, at url: URL) throws {
        try Task.checkCancellation()
        try beforeOperation(operation, url)
        try Task.checkCancellation()
    }

    func destination(directory: URL, stem: String, timestamp: String, format: String) throws -> URL {
        var candidate = directory.appendingPathComponent("\(stem)_\(timestamp).\(format)")
        var suffix = 2
        while true {
            try check(.collisionProbe, at: candidate)
            let exists = FileManager.default.fileExists(atPath: candidate.path)
            try Task.checkCancellation()
            if !exists { return candidate }
            candidate = directory.appendingPathComponent("\(stem)_\(timestamp)_\(suffix).\(format)")
            suffix += 1
        }
    }

    func write(
        image: CGImage, format: String, destination: URL, description: String,
        sourceMetadata: VideoStillSourceMetadata = VideoStillSourceMetadata(), frameOffset: Double = 0
    ) throws {
        try check(.encode, at: destination)
        let type = format == "jpg" ? UTType.jpeg : UTType.tiff
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description],
        ]
        if let exif = sourceMetadata.exifDateProperties(frameOffset: frameOffset) {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        // Descriptive fields go through SwiftMediaMetadata so IPTC carries the UTF-8 charset
        // marker (ImageIO omits it, which mojibakes non-ASCII names on news servers).
        let tagged = try sourceMetadata.applying(to: data as Data, description: description, frameOffset: frameOffset)
        try publish(tagged, to: destination)
    }

    func exportJXL(
        source: URL, seconds: Double, destination: URL, description: String,
        sourceMetadata: VideoStillSourceMetadata = VideoStillSourceMetadata()
    ) async throws {
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jxl")
        defer {
            // Cleanup must run even after cancellation or an extractor failure.
            try? beforeOperation(.cleanup, temporary)
            try? FileManager.default.removeItem(at: temporary)
        }
        try await extractJXL(source, seconds, temporary)
        try check(.jxlRead, at: temporary)
        var file = try JXLParser.parse(Data(contentsOf: temporary))
        var xmp = sourceMetadata.xmp(description: description, frameOffset: seconds)
        sourceMetadata.addDateCreated(to: &xmp, frameOffset: seconds)
        file.replaceOrAddBox("xml ", data: Data(XMPWriter.generateXML(xmp).utf8))
        try publish(JXLWriter.write(file), to: destination)
    }

    private func publish(_ data: Data, to destination: URL) throws {
        try check(.publish, at: destination)
        // Probing is advisory: exclusive creation also protects against a competing writer.
        try data.write(to: destination, options: .withoutOverwriting)
        // Publication is the commit point. Return success even if cancellation arrives during
        // the write so the view removes and reports this completed marker exactly once.
    }
}

/// The parts of a video's metadata worth carrying onto stills extracted from it: when and
/// where it was shot, and the descriptive/rights fields a photo desk relies on. Read from the
/// video's embedded XMP/QuickTime metadata, with an `.xmp` sidecar (if any) taking precedence.
/// Fields the container doesn't expose are simply left out.
nonisolated struct VideoStillSourceMetadata: Equatable, Sendable {
    var captureDate: Date?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var creators: [String] = []
    var copyright: String?
    var credit: String?
    var city: String?
    var state: String?
    var country: String?
    var keywords: [String] = []

    @concurrent static func read(videoURL: URL) async -> VideoStillSourceMetadata {
        var result = VideoStillSourceMetadata()
        if let video = try? await readVideoMetadata(from: videoURL) {
            result.captureDate = video.creationDate
            if let lat = video.gpsLatitude, let lon = video.gpsLongitude {
                result.latitude = lat
                result.longitude = lon
                result.altitude = video.gpsAltitude
            }
            if let xmp = video.xmp { result.merge(xmp) }
            if result.creators.isEmpty, let artist = video.artist.flatMap(Self.trimmedNonEmpty) {
                result.creators = [artist]
            }
        }
        if let sidecar = try? readXMPSidecar(for: videoURL) {
            result.merge(sidecar)
        }
        return result
    }

    /// Overlays the non-empty descriptive fields of `xmp`.
    mutating func merge(_ xmp: XMPData) {
        if !xmp.creator.isEmpty { creators = xmp.creator }
        if let v = xmp.rights.flatMap(Self.trimmedNonEmpty) { copyright = v }
        if let v = xmp.credit.flatMap(Self.trimmedNonEmpty) { credit = v }
        if let v = xmp.city.flatMap(Self.trimmedNonEmpty) { city = v }
        if let v = xmp.state.flatMap(Self.trimmedNonEmpty) { state = v }
        if let v = xmp.country.flatMap(Self.trimmedNonEmpty) { country = v }
        if !xmp.subject.isEmpty { keywords = xmp.subject }
    }

    /// Capture time of the frame `frameOffset` seconds into the clip.
    func frameDate(frameOffset: Double) -> Date? {
        captureDate.map { $0.addingTimeInterval(max(frameOffset, 0)) }
    }

    /// ImageIO EXIF date entries (DateTimeOriginal + offset + subseconds) for the frame.
    func exifDateProperties(frameOffset: Double) -> [CFString: Any]? {
        guard let date = frameDate(frameOffset: frameOffset) else { return nil }
        let seconds = date.timeIntervalSince1970
        let millis = Int(((seconds - seconds.rounded(.down)) * 1000).rounded(.down))
        let stamp = Self.formatted(date, "yyyy:MM:dd HH:mm:ss")
        return [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
            kCGImagePropertyExifOffsetTimeOriginal: Self.formatted(date, "xxx"),
            kCGImagePropertyExifSubsecTimeOriginal: String(format: "%03d", min(max(millis, 0), 999)),
        ]
    }

    /// XMP carrying the caption plus every copied field except `photoshop:DateCreated`, which
    /// must not pass through the IIM sync (it would land in IPTC 2:55 in ISO form).
    func xmp(description: String, frameOffset: Double) -> XMPData {
        var xmp = XMPData()
        xmp.description = description
        if !creators.isEmpty { xmp.creator = creators }
        xmp.rights = copyright
        xmp.credit = credit
        xmp.city = city
        xmp.state = state
        xmp.country = country
        if !keywords.isEmpty { xmp.subject = keywords }
        if let date = frameDate(frameOffset: frameOffset) {
            xmp.exifDateTimeOriginal = Self.formatted(date, Self.isoFormat)
        }
        if let latitude, let longitude {
            xmp.exifGPSLatitude = Self.xmpCoordinate(latitude, positive: "N", negative: "S")
            xmp.exifGPSLongitude = Self.xmpCoordinate(longitude, positive: "E", negative: "W")
        }
        return xmp
    }

    func addDateCreated(to xmp: inout XMPData, frameOffset: Double) {
        guard let date = frameDate(frameOffset: frameOffset) else { return }
        xmp.setValue(.simple(Self.formatted(date, Self.isoFormat)),
                     namespace: XMPNamespace.photoshop, property: "DateCreated")
    }

    /// Writes the caption and copied fields into an encoded JPEG/TIFF as XMP + IPTC (+ EXIF GPS).
    func applying(to encoded: Data, description: String, frameOffset: Double) throws -> Data {
        var metadata = try readMetadata(from: encoded)
        var xmp = xmp(description: description, frameOffset: frameOffset)
        metadata.xmp = xmp
        try metadata.syncXMPToIPTC()
        if let date = frameDate(frameOffset: frameOffset) {
            try metadata.iptc.setValue(Self.formatted(date, "yyyyMMdd"), for: .dateCreated)
            try metadata.iptc.setValue(Self.formatted(date, "HHmmssxx"), for: .timeCreated)
            addDateCreated(to: &xmp, frameOffset: frameOffset)
            metadata.xmp = xmp
        }
        if let latitude, let longitude {
            metadata.setGPS(latitude: latitude, longitude: longitude, altitude: altitude,
                            timestamp: frameDate(frameOffset: frameOffset) ?? Date())
        }
        return try metadata.writeToData()
    }

    private static let isoFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// XMP GPS form: "DDD,MM.mmmmmmN".
    private static func xmpCoordinate(_ value: Double, positive: String, negative: String) -> String {
        let magnitude = abs(value)
        let degrees = Int(magnitude)
        let minutes = (magnitude - Double(degrees)) * 60
        return String(format: "%d,%.6f%@", degrees, minutes, value < 0 ? negative : positive)
    }
}
