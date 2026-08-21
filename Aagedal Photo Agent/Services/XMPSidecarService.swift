import Foundation
import SwiftExif
import os

nonisolated private let xmpLog = Logger(subsystem: "com.aagedal.photo-agent", category: "XMPSidecarService")

/// Reads and writes Adobe-compatible `.xmp` sidecars for RAW (and any file we don't embed into).
///
/// Pure Swift: parsing goes through SwiftExif's `XMPReader` and serialization through its
/// string-based `XMPWriter` (via `XMPDataBuilder`) — there is NO Foundation NSXML / libxml2 DOM
/// here. That removes the process-global libxml2 state that used to race ImageIO/RAW decode and
/// crash with EXC_BAD_ACCESS, and makes every method thread-safe with no lock (`XMPData` is a
/// `Sendable` value type). The develop/crs/mask/tone encoders are shared with the embedded-file
/// writer via `XMPDataBuilder`, so the sidecar and embedded XMP can't drift.
struct XMPSidecarService: Sendable {

    nonisolated func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    nonisolated func sidecarExists(for imageURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: imageURL).path)
    }

    /// Reads the sidecar file's bytes if it exists. Pure file I/O — safe to call off the main actor
    /// (and intended to be, since `Data(contentsOf:)` can stall on iCloud-not-downloaded files).
    nonisolated func sidecarDataIfExists(for imageURL: URL) -> Data? {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Nonisolated, lightweight read of just the display orientation from the `.xmp` sidecar —
    /// `tiff:Orientation` (Adobe's authoritative tag), falling back to `exif:Orientation`. For
    /// off-main thumbnail generation, which needs only the orientation. Returns nil when there's no
    /// sidecar or it carries no orientation.
    nonisolated func sidecarOrientation(for imageURL: URL) -> Int? {
        guard let data = sidecarDataIfExists(for: imageURL),
              let xmp = try? XMPReader.readFromXML(data) else { return nil }
        let raw = xmp.tiffOrientation ?? xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
        return raw.flatMap { Int($0) }
    }

    /// Pretty-prints the sidecar's XML for the metadata inspector by round-tripping it through the
    /// pure-Swift reader/writer (stable formatting). Falls back to the raw UTF-8 bytes if it won't
    /// parse. Returns nil when there's no sidecar.
    nonisolated func prettyPrintedSidecarXML(for imageURL: URL) -> String? {
        guard let data = sidecarDataIfExists(for: imageURL) else { return nil }
        if let xmp = try? XMPReader.readFromXML(data) {
            return XMPWriter.generateXML(xmp)
        }
        return String(data: data, encoding: .utf8) ?? "Unable to read XMP sidecar"
    }

    nonisolated func loadSidecar(for imageURL: URL) -> IPTCMetadata? {
        guard let data = sidecarDataIfExists(for: imageURL) else { return nil }
        return loadSidecar(fromData: data, imageAspect: { ImagePixelAspect.aspect(at: imageURL) })
    }

    /// Parses already-read XMP bytes into IPTCMetadata. `imageAspect` supplies the image's
    /// sensor-frame width/height ratio for the ACR angled-crop conversion; it is only invoked when
    /// the sidecar carries an angled crop (the conversion is the identity at angle 0).
    nonisolated func loadSidecar(fromData data: Data, imageAspect: () -> Double? = { nil }) -> IPTCMetadata? {
        guard let xmp = try? XMPReader.readFromXML(data) else { return nil }
        return parseMetadata(from: xmp, imageAspect: imageAspect)
    }

    /// Removes all IPTC/descriptive metadata from the sidecar while preserving Camera Raw edit
    /// settings. Deletes the sidecar entirely if no edit settings remain.
    func stripIPTCFromSidecar(for imageURL: URL) {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard let metadata = loadSidecar(for: imageURL) else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                xmpLog.warning("Failed to remove unreadable XMP sidecar for \(imageURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if let cameraRaw = metadata.cameraRaw, !cameraRaw.isEmpty {
            let editOnly = IPTCMetadata(cameraRaw: cameraRaw, exifOrientation: metadata.exifOrientation)
            do {
                try saveSidecar(metadata: editOnly, for: imageURL)
            } catch {
                xmpLog.error("Failed to save stripped XMP sidecar for \(imageURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                xmpLog.warning("Failed to remove empty XMP sidecar for \(imageURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func saveSidecar(metadata: IPTCMetadata, for imageURL: URL) throws {
        let url = sidecarURL(for: imageURL)
        // Merge into the existing sidecar so unknown third-party XMP (namespaces / properties we
        // don't model) is preserved by design — XMPData round-trips every property it parsed.
        var xmp = (try? XMPSidecar.read(from: url)) ?? XMPData()
        XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
        // nil cameraRaw clears the crs block (matches the prior "nil = clear" contract).
        XMPDataBuilder.applyCameraRaw(
            metadata.cameraRaw,
            imageAspect: imageAspectIfCropAngled(for: imageURL, crop: metadata.cameraRaw?.crop),
            into: &xmp
        )
        xmp.creatorTool = SwiftExifWriteEngine.creatorTool
        try writeXMP(xmp, to: url)
    }

    /// Writes a descriptive-metadata record to the `.xmp` sidecar WITHOUT disturbing any develop
    /// (`crs`) block already on disk. `saveSidecar` treats a nil `cameraRaw` as "clear", which is
    /// wrong for descriptive writes (rating/label/orientation/keywords) whose metadata never carries
    /// `cameraRaw`; those callers must use this so a caption change doesn't wipe the user's edits.
    nonisolated func saveSidecarPreservingDevelopSettings(metadata: IPTCMetadata, for imageURL: URL) throws {
        var merged = metadata
        if merged.cameraRaw == nil {
            merged.cameraRaw = loadSidecar(for: imageURL)?.cameraRaw
        }
        try saveSidecar(metadata: merged, for: imageURL)
    }

    func saveCameraRawOnly(_ settings: CameraRawSettings?, orientation: Int?, for imageURL: URL) throws {
        let url = sidecarURL(for: imageURL)
        if let settings, !settings.isEmpty {
            var xmp = (try? XMPSidecar.read(from: url)) ?? XMPData()
            XMPDataBuilder.applyCameraRaw(
                settings,
                imageAspect: imageAspectIfCropAngled(for: imageURL, crop: settings.crop),
                into: &xmp
            )
            if let orientation {
                let value = String(orientation)
                xmp.setValue(.simple(value), namespace: XMPNamespace.tiff, property: "Orientation")
                xmp.setValue(.simple(value), namespace: XMPNamespace.exif, property: "Orientation")
            }
            xmp.creatorTool = SwiftExifWriteEngine.creatorTool
            try writeXMP(xmp, to: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            var xmp = (try? XMPSidecar.read(from: url)) ?? XMPData()
            XMPDataBuilder.removeCRSBlock(&xmp)
            try writeXMP(xmp, to: url)
        }
    }

    // MARK: - Read

    nonisolated private func parseMetadata(from xmp: XMPData, imageAspect: () -> Double?) -> IPTCMetadata {
        var dict = ImageMetadata(xmp: xmp).asMetadataDict()
        fillXMPOnlyGaps(&dict, xmp: xmp, imageAspect: imageAspect)
        return iptcMetadataFromDict(dict)
    }

    /// `asMetadataDict` sources Orientation, GPS and the IPTC date only from the EXIF segment, which
    /// a sidecar-only `ImageMetadata(xmp:)` lacks. Fill those three from XMP, and seed the sensor
    /// dimensions for the angled-crop conversion (which otherwise reads dimensions a sidecar dict
    /// has none of) — all the other descriptive + crs fields `asMetadataDict` already covers.
    nonisolated private func fillXMPOnlyGaps(_ dict: inout [String: Any], xmp: XMPData, imageAspect: () -> Double?) {
        // Orientation — tiff authoritative, exif fallback (matches the old reader).
        let orientationString = xmp.tiffOrientation
            ?? xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
        if let orientationString, let orientation = Int(orientationString) {
            dict[MetadataDictKey.orientation] = orientation
        }

        // GPS — the sidecar stores decimal degrees in exif:GPSLatitude/Longitude; the reader expects
        // a Double. parseCoordinateComponent also tolerates the DMS / N-S-E-W forms other tools write.
        if let latString = xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSLatitude"),
           let lat = parseCoordinateComponent(latString) {
            dict[MetadataDictKey.gpsLatitude] = lat
        }
        if let lonString = xmp.simpleValue(namespace: XMPNamespace.exif, property: "GPSLongitude"),
           let lon = parseCoordinateComponent(lonString) {
            dict[MetadataDictKey.gpsLongitude] = lon
        }

        // photoshop:DateCreated (the IPTC date) — asMetadataDict only surfaces xmp:CreateDate.
        if dict[MetadataDictKey.dateCreated] == nil,
           let dateCreated = xmp.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated") {
            dict[MetadataDictKey.dateCreated] = dateCreated
        }

        // Angled-crop ACR→upright conversion needs the sensor aspect; iptcMetadataFromDict derives it
        // from image dimensions that a sidecar dict lacks. Seed them from the service's aspect closure
        // — only when the crop is actually angled, keeping the closure's file read lazy.
        if let angle = parseDoubleValue(dict[MetadataDictKey.crsCropAngle]), abs(angle) > 0.0001,
           dict[MetadataDictKey.imageWidth] == nil, dict[MetadataDictKey.imageHeight] == nil,
           let aspect = imageAspect(), aspect > 0 {
            dict[MetadataDictKey.imageWidth] = aspect * 10000.0
            dict[MetadataDictKey.imageHeight] = 10000.0
        }
    }

    /// Parses a GPS coordinate string — decimal, decimal + N/S/E/W, DMS, or DDM — into signed
    /// decimal degrees. (Ported from the old NSXML reader; sidecars we write use plain `%.6f`
    /// decimal, but third-party sidecars may use the other forms.)
    nonisolated private func parseCoordinateComponent(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) {
            return direct
        }

        let decimalWithDir = /^\s*(-?\d+\.?\d*)\s*([NSEWnsew])\s*$/
        if let match = trimmed.firstMatch(of: decimalWithDir),
           let base = Double(match.1) {
            let dir = String(match.2).uppercased()
            if dir == "S" || dir == "W" { return -abs(base) }
            return abs(base)
        }

        let dms = /(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: dms),
           let degrees = Int(match.1),
           let minutes = Int(match.2),
           let seconds = Double(match.3) {
            var decimal = Double(abs(degrees)) + Double(minutes) / 60.0 + seconds / 3600.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.4.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        let ddm = /(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: ddm),
           let degrees = Int(match.1),
           let minutes = Double(match.2) {
            var decimal = Double(abs(degrees)) + minutes / 60.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.3.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        return nil
    }

    // MARK: - Write

    nonisolated private func writeXMP(_ xmp: XMPData, to url: URL) throws {
        let xml = XMPWriter.generateXML(xmp)
        guard let data = xml.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        // `.atomic` keeps the sidecar crash-safe (XMPSidecar.write is a plain non-atomic write).
        try data.write(to: url, options: .atomic)
    }

    /// Sensor-frame aspect for the ACR crop-convention conversion — read from the image header only
    /// when the crop is angled (the conversion is the identity at angle 0, so straight crops skip
    /// the file I/O).
    nonisolated private func imageAspectIfCropAngled(for imageURL: URL, crop: CameraRawCrop?) -> Double? {
        guard let crop, abs(crop.angle ?? 0) > 0.0001 else { return nil }
        return ImagePixelAspect.aspect(at: imageURL)
    }
}
