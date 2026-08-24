import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parser for Sony NonRealTimeMeta (NRT / RDD-18) XML.
///
/// Produced by Sony XDCAM/XAVC cameras and PXW/FX-series camcorders, plus
/// CineAlta cinema bodies (F55, F65, VENICE/VENICE 2, BURANO) recording
/// X-OCN to MXF. The XML is either embedded in an MXF metadata track or
/// written as a sidecar file next to the clip
/// (`CLIP.MXF` → `CLIPM01.XML`, `CLIP.MP4` → `CLIPM01.XML`).
///
/// Shape (simplified):
///
/// ```xml
/// <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:…">
///   <Device manufacturer="Sony" modelName="PXW-FX9" serialNo="12345"/>
///   <LensUnitMetadata>
///     <LensModelName>Sony FE 24-70mm F2.8 GM</LensModelName>
///   </LensUnitMetadata>
///   <CreationDate value="2024-01-15T10:30:00+02:00"/>
///   <TimeZone>+02:00</TimeZone>
///   <RecordingMode type="normal"/>
///   <VideoFormat>
///     <VideoFrame captureFps="24p" formatFps="24p" videoCodec="F55_X-OCN_LT_8.6K_3:2"/>
///     <VideoLayout numOfVerticalLine="5760" pixel="8640" pixelAspect="1.5:1"/>
///   </VideoFormat>
///   <AcquisitionRecord>
///     <Group name="CameraUnitMetadataSet">
///       <Item name="CaptureGammaEquation" value="rec709"/>
///     </Group>
///   </AcquisitionRecord>
///   <ExtendedContents>
///     <cdl:ColorCorrectionCollection xmlns:cdl="urn:ASC:CDL:v1.01">
///       <cdl:ColorCorrection><cdl:SOPNode>…</cdl:SOPNode></cdl:ColorCorrection>
///     </cdl:ColorCorrectionCollection>
///   </ExtendedContents>
/// </NonRealTimeMeta>
/// ```
public struct NRTXMLParser: Sendable {

    /// Parse Sony NRT XML from a file URL.
    public static func parse(from url: URL) throws -> CameraMetadata {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Parse Sony NRT XML from data. Throws `invalidVideo` if the XML
    /// cannot be parsed at all.
    public static func parse(_ data: Data) throws -> CameraMetadata {
        let delegate = NRTDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw MetadataError.invalidVideo(
                "NonRealTimeMeta XML parse error: \(delegate.parseError ?? "unknown")"
            )
        }
        return delegate.build()
    }

    // MARK: - Sidecar discovery

    /// Candidate sidecar XML URLs for a given video clip URL.
    ///
    /// Handles both common Sony layouts:
    /// - XDCAM optical / MXF: `CLIP.MXF` → `CLIP.XML`
    /// - XAVC / NXCAM cards:  `CLIP.MP4` → `CLIPM01.XML`
    ///
    /// Plus lowercase variants and the occasional `.NFO` used by older
    /// NXCAM firmware.
    public static func sidecarCandidates(for videoURL: URL) -> [URL] {
        let dir = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent

        // Order matters — the `M01` layout is by far the most common on
        // modern Sony cameras (FX3/FX6/A7S/FS5/FX9), so probe it first.
        let candidateNames: [String] = [
            "\(baseName)M01.XML",
            "\(baseName)M01.xml",
            "\(baseName)m01.XML",
            "\(baseName)m01.xml",
            "\(baseName).XML",
            "\(baseName).xml",
            "\(baseName).M01",
            "\(baseName).m01",
            "\(baseName).NFO",
            "\(baseName).nfo",
        ]
        return candidateNames.map { dir.appendingPathComponent($0) }
    }

    /// Return the first existing sidecar URL, or nil if none is present.
    public static func sidecarURL(for videoURL: URL) -> URL? {
        let fm = FileManager.default
        for candidate in sidecarCandidates(for: videoURL) {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - XMLParser delegate

private final class NRTDelegate: NSObject, XMLParserDelegate {

    var parseError: String?

    // Flat fields
    private var deviceManufacturer: String?
    private var deviceModelName: String?
    private var deviceSerialNumber: String?
    private var lensModelName: String?
    private var timeZone: String?
    private var captureGammaEquation: String?
    private var recordingModeType: String?
    private var captureFps: Double?
    private var startTimecode: String?
    private var userMetaNames: [String] = []
    private var userMetaContents: [String] = []
    private var creationDate: Date?

    // X-OCN / cinema additions
    private var videoCodecLabel: String?
    private var pixelAspect: String?
    private var exposureIndex: Int?
    private var isoSensitivity: Int?
    private var shutterAngle: Double?
    private var shutterTimeMs: Double?
    private var ndFilter: String?
    private var whiteBalanceK: Int?
    private var tintCorrection: Int?
    private var autoExposureMode: String?
    private var autoWhiteBalanceMode: String?
    private var imageSensorReadoutMode: String?
    private var imageSensorEffectiveWidth: Int?
    private var imageSensorEffectiveHeight: Int?
    private var gammaForCDL: String?
    private var cameraMasterGainDb: Double?
    private var electricalExtenderMagnification: String?
    private var cameraAttributes: String?
    private var gammaForLook: String?
    private var colorForLook: String?
    private var monitoringBaseCurve: String?
    private var monitoringCharacteristics: String?
    private var monitoringColorPrimaries: String?
    private var monitoringCodingEquations: String?
    private var monitoringDescriptions: String?
    private var preCDLTransform: String?
    private var postCDLTransform: String?
    private var lookProcessBaked: Bool?
    private var rawBlackCodeValue: Int?
    private var rawGrayCodeValue: Int?
    private var rawWhiteCodeValue: Int?
    private var effectiveMarkerCoverage: String?
    private var effectiveMarkerAspectRatio: String?
    private var activeAreaAspectRatio: String?
    private var imageOrientation: String?
    private var cameraProcessDiscriminationCode: String?
    private var cameraTiltAngle: Double?
    private var cameraRollAngle: Double?
    private var irisFNumber: Double?
    private var irisTNumber: Double?
    private var focusPositionMeters: Double?
    private var lensZoom35mmEquivalentMm: Double?
    private var lensZoomActualFocalLengthMm: Double?
    private var lensAttributes: String?
    private var videoFrameAspectRatio: String?
    private var acquisitionGroups: [String: [String: String]] = [:]
    private var ascCDL: ASCCDLValues?

    // ASC CDL parsing state
    private var cdlSlope: [Double]?
    private var cdlOffset: [Double]?
    private var cdlPower: [Double]?
    private var cdlSaturation: Double?

    // Per-element text accumulator
    private var currentText = ""
    private var inLensUnit = false
    private var currentAcquisitionGroup: String?

    func build() -> CameraMetadata {
        // Materialize ASC CDL only if all four parts were captured.
        if ascCDL == nil,
           let s = cdlSlope, s.count == 3,
           let o = cdlOffset, o.count == 3,
           let p = cdlPower, p.count == 3,
           let sat = cdlSaturation {
            let cdl = ASCCDLValues(slope: s, offset: o, power: p, saturation: sat)
            // Suppress identity transforms — Sony cameras write these by
            // default when no on-set grade was applied.
            if !cdl.isIdentity {
                ascCDL = cdl
            }
        }

        // Body identification fallback for Sony cinema cameras whose NRT
        // schema (v2.00) omits the `<Device>` element. The
        // `CameraAttributes` Item under `CameraUnitMetadataSet` carries
        // `"<MPC-CODE> <SERIAL> Version<X.YY>"` — decode the model code
        // when we recognise it and back-fill `deviceManufacturer`,
        // `deviceModelName`, and `deviceSerialNumber`. The explicit
        // `<Device>` form (FX9 / Alpha series) always wins.
        if let attrs = cameraAttributes {
            let parts = attrs.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let codeSubstring = parts.first {
                let code = String(codeSubstring)
                if let friendly = NRTDelegate.sonyModelForCameraCode(code) {
                    if deviceManufacturer == nil { deviceManufacturer = "Sony" }
                    if deviceModelName == nil { deviceModelName = friendly }
                }
                if deviceSerialNumber == nil, parts.count >= 2 {
                    deviceSerialNumber = String(parts[1])
                }
            }
        }

        return CameraMetadata(
            deviceManufacturer: deviceManufacturer,
            deviceModelName: deviceModelName,
            deviceSerialNumber: deviceSerialNumber,
            lensModelName: lensModelName,
            timeZone: timeZone,
            captureGammaEquation: captureGammaEquation,
            recordingModeType: recordingModeType,
            captureFps: captureFps,
            startTimecode: startTimecode,
            userMetaNames: userMetaNames,
            userMetaContents: userMetaContents,
            creationDate: creationDate,
            videoCodecLabel: videoCodecLabel,
            pixelAspect: pixelAspect,
            exposureIndex: exposureIndex,
            isoSensitivity: isoSensitivity,
            shutterAngle: shutterAngle,
            shutterTimeMs: shutterTimeMs,
            ndFilter: ndFilter,
            whiteBalanceK: whiteBalanceK,
            tintCorrection: tintCorrection,
            autoExposureMode: autoExposureMode,
            autoWhiteBalanceMode: autoWhiteBalanceMode,
            imageSensorReadoutMode: imageSensorReadoutMode,
            imageSensorEffectiveWidth: imageSensorEffectiveWidth,
            imageSensorEffectiveHeight: imageSensorEffectiveHeight,
            gammaForCDL: gammaForCDL,
            cameraMasterGainDb: cameraMasterGainDb,
            electricalExtenderMagnification: electricalExtenderMagnification,
            cameraAttributes: cameraAttributes,
            gammaForLook: gammaForLook,
            colorForLook: colorForLook,
            monitoringBaseCurve: monitoringBaseCurve,
            monitoringCharacteristics: monitoringCharacteristics,
            monitoringColorPrimaries: monitoringColorPrimaries,
            monitoringCodingEquations: monitoringCodingEquations,
            monitoringDescriptions: monitoringDescriptions,
            preCDLTransform: preCDLTransform,
            postCDLTransform: postCDLTransform,
            lookProcessBaked: lookProcessBaked,
            rawBlackCodeValue: rawBlackCodeValue,
            rawGrayCodeValue: rawGrayCodeValue,
            rawWhiteCodeValue: rawWhiteCodeValue,
            effectiveMarkerCoverage: effectiveMarkerCoverage,
            effectiveMarkerAspectRatio: effectiveMarkerAspectRatio,
            activeAreaAspectRatio: activeAreaAspectRatio,
            imageOrientation: imageOrientation,
            cameraProcessDiscriminationCode: cameraProcessDiscriminationCode,
            cameraTiltAngle: cameraTiltAngle,
            cameraRollAngle: cameraRollAngle,
            irisFNumber: irisFNumber,
            irisTNumber: irisTNumber,
            focusPositionMeters: focusPositionMeters,
            lensZoom35mmEquivalentMm: lensZoom35mmEquivalentMm,
            lensZoomActualFocalLengthMm: lensZoomActualFocalLengthMm,
            lensAttributes: lensAttributes,
            videoFrameAspectRatio: videoFrameAspectRatio,
            ascCDL: ascCDL,
            acquisitionGroups: acquisitionGroups
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        let local = localName(elementName)

        switch local {
        case "Device":
            deviceManufacturer = deviceManufacturer ?? attributeDict["manufacturer"]
            deviceModelName = deviceModelName ?? attributeDict["modelName"]
            deviceSerialNumber = deviceSerialNumber ?? attributeDict["serialNo"]

        case "LensUnitMetadata":
            inLensUnit = true

        case "Lens":
            // Shorter attribute form used by Alpha-series NRT XML:
            //   <Lens modelName="FE 16-35mm F4 ZA OSS"/>
            // This lives outside <LensUnitMetadata>, so it's handled here
            // rather than in didEndElement.
            if lensModelName == nil, let v = attributeDict["modelName"], !v.isEmpty {
                lensModelName = v
            }

        case "RecordingMode":
            if let t = attributeDict["type"] { recordingModeType = t }

        case "VideoFrame":
            if let fps = attributeDict["captureFps"] {
                captureFps = parseFps(fps)
            }
            if let codec = attributeDict["videoCodec"], !codec.isEmpty {
                videoCodecLabel = codec
            }

        case "VideoLayout":
            if let pa = attributeDict["pixelAspect"], !pa.isEmpty {
                pixelAspect = pa
            }
            if let ar = attributeDict["aspectRatio"], !ar.isEmpty {
                videoFrameAspectRatio = ar
            }

        case "Group":
            // <Group name="CameraUnitMetadataSet"> opens an acquisition group;
            // every <Item> within belongs to it.
            currentAcquisitionGroup = attributeDict["name"]

        case "Item":
            ingestItem(name: attributeDict["name"], value: attributeDict["value"])

        case "CreationDate":
            if let v = attributeDict["value"], let d = parseISO8601(v) {
                creationDate = d
            }

        case "LtcChange":
            // RDD-18 `<LtcChangeTable>` carries `<LtcChange frameCount="N"
            // value="HH:MM:SS:FF" status="…"/>` entries. The first entry
            // (frameCount="0") is the clip start timecode. Later entries
            // only exist when the camera's LTC reel changed mid-clip, which
            // Sony tags with status="increment"/"reset" — we ignore those
            // and keep the first reading as the start TC.
            if startTimecode == nil,
               let frameCount = attributeDict["frameCount"],
               frameCount == "0",
               let v = attributeDict["value"], !v.isEmpty {
                startTimecode = formatLtcValue(v)
            }

        case "Meta":
            // <Meta name="Creator" content="Jane Doe"/>
            if let name = attributeDict["name"] { userMetaNames.append(name) }
            if let content = attributeDict["content"] { userMetaContents.append(content) }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "LensModelName":
            if inLensUnit, !text.isEmpty { lensModelName = text }

        case "LensUnitMetadata":
            inLensUnit = false

        case "TimeZone":
            if !text.isEmpty { timeZone = text }

        case "CreationDate":
            // Some writers use element text instead of value="" attr.
            if creationDate == nil, !text.isEmpty, let d = parseISO8601(text) {
                creationDate = d
            }

        case "Group":
            currentAcquisitionGroup = nil

        // ASC CDL element-text values. Each element holds whitespace-separated
        // floats. The first ColorCorrection wins — Sony rarely writes more.
        case "Slope":
            if cdlSlope == nil, let v = parseFloatTriple(text) { cdlSlope = v }
        case "Offset":
            if cdlOffset == nil, let v = parseFloatTriple(text) { cdlOffset = v }
        case "Power":
            if cdlPower == nil, let v = parseFloatTriple(text) { cdlPower = v }
        case "Saturation":
            if cdlSaturation == nil, let v = Double(text) { cdlSaturation = v }

        default:
            break
        }

        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError.localizedDescription
    }

    // MARK: - AcquisitionRecord items

    /// Route a single `<Item name= value=>` from `<AcquisitionRecord>` into
    /// both the catch-all dictionary and the typed fields when we recognise
    /// the item name.
    private func ingestItem(name: String?, value: String?) {
        guard let name, let value else { return }

        // Always stash the raw value in the catch-all dictionary so unknown
        // future items still surface.
        if let group = currentAcquisitionGroup {
            acquisitionGroups[group, default: [:]][name] = value
        }

        switch name {
        // CameraUnitMetadataSet
        case "CaptureGammaEquation":
            captureGammaEquation = value
        case "GammaForCDL":
            gammaForCDL = value
        case "ExposureIndexOfPhotoMeter":
            exposureIndex = parseInt(value)
        case "ISOSensitivity":
            isoSensitivity = parseInt(value)
        case "ShutterSpeed_Angle":
            shutterAngle = parseDoubleSuffixed(value, suffix: "deg")
        case "ShutterSpeed_Time":
            shutterTimeMs = parseShutterTime(value)
        case "NeutralDensityFilterWheelSetting":
            ndFilter = value
        case "WhiteBalance":
            whiteBalanceK = parseInt(value)
        case "TintCorrection":
            tintCorrection = parseInt(value)
        case "AutoExposureMode":
            autoExposureMode = value
        case "AutoWhiteBalanceMode":
            autoWhiteBalanceMode = value
        case "ImageSensorReadoutMode":
            imageSensorReadoutMode = value
        case "ImageSensorEffectiveWidth":
            imageSensorEffectiveWidth = parseInt(value)
        case "ImageSensorEffectiveHeight":
            imageSensorEffectiveHeight = parseInt(value)
        case "CameraMasterGainAdjustment":
            cameraMasterGainDb = parseDoubleSuffixed(value, suffix: "db")
        case "ElectricalExtenderMagnification":
            electricalExtenderMagnification = value
        case "CameraAttributes":
            cameraAttributes = value

        // SonyF65CameraMetadataSet (also F55 / VENICE / BURANO)
        case "GammaForLook":
            gammaForLook = value
        case "ColorForLook":
            colorForLook = value
        case "MonitoringBaseCurve":
            monitoringBaseCurve = value
        case "MonitoringCharacteristics":
            monitoringCharacteristics = value
        case "MonitoringColorPrimaries":
            monitoringColorPrimaries = value
        case "MonitoringCodingEquations":
            monitoringCodingEquations = value
        case "MonitoringDescriptions":
            monitoringDescriptions = value
        case "PreCDLTransform":
            preCDLTransform = value
        case "PostCDLTransform":
            postCDLTransform = value
        case "LookProcessBaked":
            lookProcessBaked = parseBool(value)
        case "RawBlackCodeValue":
            rawBlackCodeValue = parseInt(value)
        case "RawGrayCodeValue":
            rawGrayCodeValue = parseInt(value)
        case "RawWhiteCodeValue":
            rawWhiteCodeValue = parseInt(value)
        case "EffectiveMarkerCoverage":
            effectiveMarkerCoverage = value
        case "EffectiveMarkerAspectRatio":
            effectiveMarkerAspectRatio = value
        case "ActiveAreaAspectRatio":
            activeAreaAspectRatio = value
        case "ImageOrientation":
            imageOrientation = value
        case "CameraProcessDiscriminationCode":
            cameraProcessDiscriminationCode = value

        // CameraPostureMetadataSet
        case "CameraTiltAngle":
            cameraTiltAngle = parseDoubleSuffixed(value, suffix: "deg")
        case "CameraRollAngle":
            cameraRollAngle = parseDoubleSuffixed(value, suffix: "deg")

        // LensUnitMetadataSet — typed where the unit suffix lets us
        // confidently parse a number; otherwise the value is preserved
        // verbatim via `acquisitionGroups`.
        case "IrisFNumber":
            irisFNumber = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case "IrisTNumber":
            irisTNumber = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case "FocusPositionFromImagePlane":
            focusPositionMeters = parseDoubleSuffixed(value, suffix: "m")
        case "LensZoom35mmStillCameraEquivalent":
            lensZoom35mmEquivalentMm = parseDoubleSuffixed(value, suffix: "mm")
        case "LensZoomActualFocalLength":
            lensZoomActualFocalLengthMm = parseDoubleSuffixed(value, suffix: "mm")
        case "LensAttributes":
            // Sony writes `"Unknown"` when no smart lens is mounted; skip
            // those so the field truly signals lens-ID availability.
            if value != "Unknown", !value.isEmpty {
                lensAttributes = value
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    /// Translate a Sony "MPC-xxxx" body code (the leading token of
    /// `CameraAttributes`) to a friendly cinema-camera model name. Returns
    /// nil for codes we don't recognise — callers leave `deviceModelName`
    /// untouched in that case rather than emit a half-decoded label.
    ///
    /// Codes confirmed against on-set NRT XML samples:
    ///   - `MPC-3628` → VENICE
    ///   - `MPC-3633` → VENICE 2
    ///   - `MPC-2610` → BURANO
    ///
    /// PMW/PXW/ILCE/HDC bodies (FX9, A7S, broadcast cameras) write their
    /// product name directly in the `<Device modelName="…"/>` element, so
    /// they never reach this fallback path.
    static func sonyModelForCameraCode(_ code: String) -> String? {
        switch code {
        case "MPC-3628": return "VENICE"
        case "MPC-3633": return "VENICE 2"
        case "MPC-2610": return "BURANO"
        default:         return nil
        }
    }

    private func localName(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private func parseFps(_ value: String) -> Double? {
        // Strip trailing 'p' / 'i' ("24p", "59.94i") and accept "30000/1001".
        var s = value
        if s.hasSuffix("p") || s.hasSuffix("P") || s.hasSuffix("i") || s.hasSuffix("I") {
            s = String(s.dropLast())
        }
        if s.contains("/") {
            let parts = s.split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 {
                return a / b
            }
        }
        return Double(s)
    }

    private func parseInt(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Parse a Sony-style suffixed scalar such as `"173.00deg"` or
    /// `"0.00db"`. Suffix matching is case-insensitive; whitespace is
    /// tolerated.
    private func parseDoubleSuffixed(_ value: String, suffix: String) -> Double? {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasSuffix(suffix.lowercased()) {
            s = String(s.dropLast(suffix.count))
        }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Parse `<Item name="ShutterSpeed_Time" value="20ms"/>` into
    /// milliseconds. Sony also writes shutter time as `1/50s` or `1/50` —
    /// convert those into ms.
    private func parseShutterTime(_ value: String) -> Double? {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasSuffix("ms") {
            s = String(s.dropLast(2))
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lower.hasSuffix("s") {
            s = String(s.dropLast(1))
        }
        if s.contains("/") {
            let parts = s.split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 {
                return (a / b) * 1000.0
            }
        }
        if let secs = Double(s) {
            return secs * 1000.0
        }
        return nil
    }

    /// Parse three whitespace-separated floats used by ASC CDL Slope/Offset/Power.
    private func parseFloatTriple(_ text: String) -> [Double]? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard parts.count == 3 else { return nil }
        let nums = parts.compactMap { Double($0) }
        guard nums.count == 3 else { return nil }
        return nums
    }

    /// Decode a Sony NRT `LtcChange value="…"` attribute into
    /// `HH:MM:SS:FF` form. Sony RDD-18 files carry two different encodings
    /// in the wild:
    ///   1. an 8 hex-digit SMPTE 12M LTC word (byte0=frames+flags,
    ///      byte1=seconds, byte2=minutes, byte3=hours, all BCD) — what
    ///      XDCAM / XAVC professional cameras write;
    ///   2. the already-formatted "HH:MM:SS:FF" / "HH:MM:SS;FF" string —
    ///      what a few Alpha-series consumer bodies write.
    /// Returns nil when the string matches neither shape.
    private func formatLtcValue(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.contains(":") || v.contains(";") { return v }

        var hex = v
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count == 8, let word = UInt32(hex, radix: 16) else { return nil }

        let byte0 = UInt8((word >> 24) & 0xFF) // FF + drop-frame/color-frame flags
        let byte1 = UInt8((word >> 16) & 0xFF) // SS + phase bit
        let byte2 = UInt8((word >>  8) & 0xFF) // MM + binary-group flag
        let byte3 = UInt8( word        & 0xFF) // HH + binary-group flag

        let ff = Int(byte0 & 0x0F) + 10 * Int((byte0 >> 4) & 0x3)
        let ss = Int(byte1 & 0x0F) + 10 * Int((byte1 >> 4) & 0x7)
        let mm = Int(byte2 & 0x0F) + 10 * Int((byte2 >> 4) & 0x7)
        let hh = Int(byte3 & 0x0F) + 10 * Int((byte3 >> 4) & 0x3)
        let dropFrame = (byte0 & 0x40) != 0
        let sep = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }

    nonisolated(unsafe) private static let noFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let withFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseISO8601(_ value: String) -> Date? {
        if let d = NRTDelegate.noFracFormatter.date(from: value) { return d }
        return NRTDelegate.withFracFormatter.date(from: value)
    }
}
