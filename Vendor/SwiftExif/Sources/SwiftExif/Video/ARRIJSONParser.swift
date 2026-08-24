import Foundation

/// Parser for ARRI's JSON-shaped clip metadata embedded in ALEXA / AMIRA MXF files.
///
/// ARRI cameras (ALEXA 35, ALEXA Mini LF, AMIRA, etc.) carry production-side
/// metadata as a set of JSON documents wrapped in MXF KLV metadata sets.
/// Inside each set the layout is a sequence of 2-byte local-tag /
/// 2-byte big-endian length / value triplets where:
///
///   - tag `0x807A` — MIME type (`"application/json"`, UTF-16BE)
///   - tag `0x807B` — JSON payload, UTF-8
///   - tag `0x807C` — schema URL, UTF-16BE
///                   (e.g. `https://www.arri.com/schema/json/camera/slate_info/v1-1-0`)
///
/// The schema URL identifies which document is in the JSON blob. ARRI ships
/// six well-known schemas in current ALEXA 35 footage:
///
/// * `slate_info`        — scene, take, director, cinematographer, …
/// * `camera_device`     — model, serial, firmware
/// * `lens_device`       — lens model, serial, focus/iris/zoom encoder limits
/// * `recording_medium`  — Codex / SxS card identification
/// * `frameline`         — viewfinder frameline file & rectangles
/// * `custom_lut3d_design` — viewing LUT identifier
///
/// We don't try to parse the surrounding KLV metadata-set boundaries —
/// the `\x80\x7B LL LL {` marker is unambiguous and easy to substring-scan,
/// matching the way Sony NRT XML is recovered (see `findEmbeddedNRTXML`).
public struct ARRIJSONParser: Sendable {

    /// One decoded JSON blob, paired with the schema name that describes it.
    public struct Blob: Equatable {
        /// Schema short-name — the path component before the version segment
        /// in the schema URL (e.g. `"slate_info"`, `"camera_device"`).
        /// Empty when no `0x807C` schema URL was found near the JSON.
        public let schema: String
        /// Decoded JSON payload (compact-stringified for deterministic
        /// equality testing — most callers should use `jsonObject` instead).
        public let json: [String: Any]

        public static func == (lhs: Blob, rhs: Blob) -> Bool {
            return lhs.schema == rhs.schema
                && (try? JSONSerialization.data(withJSONObject: lhs.json, options: [.sortedKeys]))
                == (try? JSONSerialization.data(withJSONObject: rhs.json, options: [.sortedKeys]))
        }
    }

    /// How far into the file we look for ARRI metadata. The whole header
    /// metadata region in our reference ALEXA 35 footage sits inside the
    /// first ~10 KB of the file, but real-world MXF can carry index tables
    /// or larger header partitions before the first essence KLV — match the
    /// existing `findEmbeddedNRTXML` window so behaviour stays consistent
    /// across vendors.
    private static let scanWindow = 16 * 1024 * 1024

    /// 2-byte local-tag prefix for the JSON payload triplet.
    private static let jsonTagPrefix: [UInt8] = [0x80, 0x7B]

    /// 2-byte local-tag prefix for the schema-URL triplet (UTF-16BE).
    private static let schemaTagPrefix: [UInt8] = [0x80, 0x7C]

    /// How far past the JSON blob to search for the schema-URL triplet.
    /// In real ALEXA 35 footage the schema URL is the immediate next local-set
    /// item (typically 4 bytes after the JSON's closing brace); 1 KB is more
    /// than enough headroom for layouts that interleave other tags.
    private static let schemaLookahead = 1024

    // MARK: - Discovery

    /// Walk the first `scanWindow` bytes of `data` looking for ARRI JSON
    /// metadata blobs. Returns one `Blob` per successfully decoded payload,
    /// sorted by `schema` so callers can rely on stable iteration order.
    public static func findEmbeddedJSONBlobs(in data: Data) -> [Blob] {
        let limit = min(data.count, scanWindow)
        guard limit >= 5 else { return [] }
        var results: [Blob] = []

        // `data` may be a slice with a non-zero `startIndex` — this is public
        // API. Keep the scan cursor `i` relative to `base` and convert to the
        // Data's absolute index space at every subscript / `subdata` call; a
        // bare `data[i]` would read past the slice and trap.
        let base = data.startIndex
        var i = 0
        while i + 4 <= limit {
            // Cheap byte-by-byte scan for the JSON-tag prefix. `Data.range`
            // would be marginally faster on large windows but the constant
            // overhead per call dominates at our scale (<100 hits per file).
            guard data[base + i] == jsonTagPrefix[0], data[base + i + 1] == jsonTagPrefix[1] else {
                i += 1
                continue
            }
            let lenHi = data[base + i + 2]
            let lenLo = data[base + i + 3]
            let length = Int(lenHi) << 8 | Int(lenLo)
            let payloadStart = i + 4
            let payloadEnd = payloadStart + length
            guard length > 0, payloadEnd <= limit else {
                i += 1
                continue
            }
            let payload = data.subdata(in: (base + payloadStart)..<(base + payloadEnd))

            // Cheap content sniff: skip whitespace, the next byte must look
            // like a JSON document. This rules out the many KLV values that
            // happen to start with `0x80 0x7B` for unrelated reasons.
            guard let first = payload.first(where: { !($0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x20) }),
                  first == 0x7B || first == 0x5B /* '{' or '[' */ else {
                i = payloadEnd
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: payload, options: []),
                  let dict = object as? [String: Any] else {
                i = payloadEnd
                continue
            }

            let schema = findFollowingSchema(in: data, afterOffset: payloadEnd, limit: limit)
            results.append(Blob(schema: schema, json: dict))
            i = payloadEnd
        }

        // Stable order — schema then a compact JSON re-render — so test
        // assertions against `userMetaNames`/`userMetaContents` arrays don't
        // depend on the order ARRI happened to emit blobs in the file.
        results.sort { lhs, rhs in
            if lhs.schema != rhs.schema { return lhs.schema < rhs.schema }
            return compactJSON(lhs.json) < compactJSON(rhs.json)
        }
        return results
    }

    /// Search forward up to `schemaLookahead` bytes from `afterOffset` for
    /// the next `0x807C` schema-URL triplet (UTF-16BE). In ARRI's KLV layout
    /// the schema URL is the local-set item that immediately follows the
    /// JSON payload — see `https://www.arri.com/schema/json/camera/...` —
    /// so the pairing is forward, not back. Returns the short schema name
    /// (the URL path component before the `vN-…` version segment), or an
    /// empty string when no schema URL is present nearby.
    private static func findFollowingSchema(in data: Data, afterOffset: Int, limit: Int) -> String {
        let scanEnd = min(limit - 4, afterOffset + schemaLookahead)
        guard afterOffset >= 0, scanEnd >= afterOffset else { return "" }
        // Offsets here are relative; rebase onto the slice's `startIndex` (see
        // `findEmbeddedJSONBlobs`) so subscripts land inside a sliced `Data`.
        let base = data.startIndex
        var i = afterOffset
        while i <= scanEnd {
            if data[base + i] == schemaTagPrefix[0], data[base + i + 1] == schemaTagPrefix[1] {
                let length = Int(data[base + i + 2]) << 8 | Int(data[base + i + 3])
                let valueStart = i + 4
                let valueEnd = valueStart + length
                if length > 0, valueEnd <= limit {
                    let bytes = data.subdata(in: (base + valueStart)..<(base + valueEnd))
                    if let url = String(data: bytes, encoding: .utf16BigEndian) {
                        return shortSchemaName(from: url)
                    }
                }
            }
            i += 1
        }
        return ""
    }

    /// `https://www.arri.com/schema/json/camera/slate_info/v1-1-0` →
    /// `"slate_info"`. Pulls the path component just before the version
    /// segment so deeper schemas (e.g. `monitoring/frameline/v1-0-0`,
    /// `processing/custom_lut3d_design/v1-1-0`) collapse to a stable key.
    private static func shortSchemaName(from url: String) -> String {
        // Strip query / fragment and trailing slashes.
        let cleaned = url
            .split(separator: "?").first.map(String.init) ?? url
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        // Find the version component (`vN-M-O` or `vN_M_O` or just `vN`).
        if let versionIdx = parts.lastIndex(where: { isVersionToken($0) }), versionIdx > 0 {
            return String(parts[versionIdx - 1])
        }
        return String(parts.last ?? "")
    }

    private static func isVersionToken(_ s: Substring) -> Bool {
        guard let first = s.first, first == "v" || first == "V" else { return false }
        let rest = s.dropFirst()
        guard !rest.isEmpty else { return false }
        return rest.allSatisfy { $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    // MARK: - Mapping

    /// Map well-known schema fields onto typed `CameraMetadata` slots; push
    /// every other field onto the `userMetaNames`/`userMetaContents` pair so
    /// downstream JSON/CSV exporters surface them like the BRAW slate path.
    ///
    /// Existing typed fields are preserved (we only set them when nil), so a
    /// caller that pre-populated `cam` from another source — say an MXF
    /// Identification set — wins over the JSON.
    public static func merge(_ blobs: [Blob], into cam: inout CameraMetadata) {
        for blob in blobs {
            switch blob.schema {
            case "camera_device":
                mergeCameraDevice(blob.json, into: &cam)
            case "lens_device":
                mergeLensDevice(blob.json, into: &cam)
            case "slate_info":
                mergeSlateInfo(blob.json, into: &cam)
            case "recording_medium":
                mergeRecordingMedium(blob.json, into: &cam)
            case "frameline":
                mergeFrameline(blob.json, into: &cam)
            case "custom_lut3d_design":
                mergeLUT3DDesign(blob.json, into: &cam)
            default:
                // Unknown schema: dump every leaf value so future ARRI fields
                // surface in CSV/JSON output without code changes.
                let prefix = blob.schema.isEmpty ? "ARRI" : titleCaseFromSnake(blob.schema)
                for key in blob.json.keys.sorted() {
                    appendUserMeta(name: "\(prefix):\(titleCaseFirst(key))",
                                   value: blob.json[key],
                                   into: &cam)
                }
            }
        }
    }

    private static func mergeCameraDevice(_ json: [String: Any], into cam: inout CameraMetadata) {
        if cam.deviceModelName == nil, let v = json["cameraModel"] as? String, !v.isEmpty {
            cam.deviceModelName = v
        }
        if cam.deviceSerialNumber == nil, let v = json["cameraSerialNumber"] as? String, !v.isEmpty {
            cam.deviceSerialNumber = v
        }
        if let v = json["cameraSoftwarePackageName"] {
            appendUserMeta(name: "Camera:Firmware", value: v, into: &cam)
        }
    }

    private static func mergeLensDevice(_ json: [String: Any], into cam: inout CameraMetadata) {
        if cam.lensModelName == nil, let v = json["lensModel"] as? String, !v.isEmpty {
            cam.lensModelName = v
        }
        // Iterate the JSON in sorted-key order so the userMeta arrays come
        // out deterministic — essential for test assertions and stable diffs.
        for key in json.keys.sorted() {
            switch key {
            case "lensModel":
                continue // already mapped to typed slot
            case "circleOfConfusion":
                appendUserMeta(name: "Lens:CircleOfConfusion", value: json[key], into: &cam)
            default:
                let stripped = stripLowercasePrefix(key, prefix: "lens")
                let label = stripped.isEmpty ? titleCaseFirst(key) : titleCaseFirst(stripped)
                appendUserMeta(name: "Lens:\(label)", value: json[key], into: &cam)
            }
        }
    }

    private static func mergeSlateInfo(_ json: [String: Any], into cam: inout CameraMetadata) {
        // Convention for unset deviceManufacturer: the slate's
        // productionCompany is the camera manufacturer when the camera was
        // self-identified (real ALEXA footage always carries "ARRI" here).
        if cam.deviceManufacturer == nil,
           let mfg = json["productionCompany"] as? String,
           mfg.caseInsensitiveCompare("ARRI") == .orderedSame {
            cam.deviceManufacturer = "ARRI"
        }
        for key in json.keys.sorted() {
            if key == "userInfo" {
                if let entries = json[key] as? [[String: Any]] {
                    for entry in entries {
                        guard let rawKey = entry["key"] as? String else { continue }
                        let shortKey = stripCaseInsensitivePrefix(rawKey, prefix: "com.arri.metadata.")
                        appendUserMeta(name: "Slate:User:\(shortKey)",
                                       value: entry["value"],
                                       into: &cam)
                    }
                }
                continue
            }
            appendUserMeta(name: "Slate:\(titleCaseFirst(key))", value: json[key], into: &cam)
        }
    }

    private static func mergeRecordingMedium(_ json: [String: Any], into cam: inout CameraMetadata) {
        for key in json.keys.sorted() {
            let stripped = stripLowercasePrefix(key, prefix: "medium")
            let label = stripped.isEmpty ? titleCaseFirst(key) : titleCaseFirst(stripped)
            appendUserMeta(name: "Medium:\(label)", value: json[key], into: &cam)
        }
    }

    private static func mergeFrameline(_ json: [String: Any], into cam: inout CameraMetadata) {
        if let v = json["framelineFilename"] {
            appendUserMeta(name: "Frameline:File", value: v, into: &cam)
        }
        if let rects = json["framelineRect"] as? [Any] {
            for (i, rect) in rects.enumerated() {
                appendUserMeta(name: "Frameline:Rect[\(i)]", value: rect, into: &cam)
            }
        }
    }

    private static func mergeLUT3DDesign(_ json: [String: Any], into cam: inout CameraMetadata) {
        for key in json.keys.sorted() {
            let stripped = stripCaseInsensitivePrefix(key, prefix: "lut3D")
            let label = stripped.isEmpty ? titleCaseFirst(key) : titleCaseFirst(stripped)
            appendUserMeta(name: "LUT:\(label)", value: json[key], into: &cam)
        }
    }

    // MARK: - Value formatting

    /// Coerce any JSON value into a single-line string suitable for the
    /// userMeta arrays. Strings and numbers stringify trivially; bools become
    /// `"true"`/`"false"`; arrays and dictionaries are re-serialised as
    /// compact JSON so they survive the round-trip into JSON/CSV exporters.
    /// Empty strings and explicit `NSNull` are dropped — we don't want to
    /// surface noise like `Slate:CameraIndex = ` in the output.
    internal static func stringify(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if value is NSNull { return nil }
        if let s = value as? String {
            return s.isEmpty ? nil : s
        }
        if let b = value as? Bool {
            return b ? "true" : "false"
        }
        if let n = value as? NSNumber {
            // NSNumber covers Int, Double, and Bool — we already handled Bool
            // above; check the underlying type to avoid stringifying integers
            // as "12.0". CoreFoundation's CFNumberIsFloatType is Apple-only,
            // so detect integer-ness via Swift cast order: JSONSerialization
            // stores parsed `12` as a NSNumber that bridges to Int64, while
            // `12.5` (or any fractional) bridges only to Double.
            if let i = value as? Int64 {
                return String(i)
            }
            return String(format: "%g", n.doubleValue)
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    private static func appendUserMeta(name: String, value: Any?, into cam: inout CameraMetadata) {
        guard let stringValue = stringify(value) else { return }
        cam.userMetaNames.append(name)
        cam.userMetaContents.append(stringValue)
    }

    private static func compactJSON(_ json: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }

    // MARK: - String helpers

    /// Uppercase the first character of an ASCII identifier without touching
    /// the rest — `cameraIndex` → `CameraIndex`, `take` → `Take`. Designed
    /// for ARRI's camelCase JSON keys; not a general Unicode operation.
    private static func titleCaseFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Drop a leading lowercase prefix when present, regardless of the next
    /// character's case. `lensSerialNumber` → `SerialNumber`,
    /// `mediumModelName` → `ModelName`. Returns `""` if the key equals the
    /// prefix exactly (caller should fall back to the unstripped name).
    private static func stripLowercasePrefix(_ s: String, prefix: String) -> String {
        guard s.hasPrefix(prefix) else { return s }
        return String(s.dropFirst(prefix.count))
    }

    /// Like `stripLowercasePrefix` but case-insensitive on the prefix —
    /// `lut3DID` and `lut3did` both yield `ID`/`id`. Used for ARRI keys
    /// where the prefix camel-casing isn't always consistent across schemas.
    private static func stripCaseInsensitivePrefix(_ s: String, prefix: String) -> String {
        guard s.lowercased().hasPrefix(prefix.lowercased()) else { return s }
        return String(s.dropFirst(prefix.count))
    }

    /// `recording_medium` → `RecordingMedium`. Used as a userMeta prefix
    /// fallback when we encounter an unknown ARRI schema and want to surface
    /// its fields without inventing a code path for it.
    private static func titleCaseFromSnake(_ s: String) -> String {
        s.split(separator: "_").map { titleCaseFirst(String($0)) }.joined()
    }
}
