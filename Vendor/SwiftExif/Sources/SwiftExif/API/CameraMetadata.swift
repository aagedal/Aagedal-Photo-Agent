import Foundation

/// ASC CDL (American Society of Cinematographers Color Decision List) values
/// carried in Sony NRT `<ExtendedContents><cdl:ColorCorrectionCollection>`.
///
/// Each of `slope`, `offset`, `power` is a 3-element array `[R, G, B]`.
/// `saturation` is a single scalar applied after the SOP transform. The
/// formula is `out = pow(in × slope + offset, 1/power)` followed by
/// saturation around luma — see ASC CDL v1.2 §6.
public struct ASCCDLValues: Sendable, Equatable {
    public var slope: [Double]
    public var offset: [Double]
    public var power: [Double]
    public var saturation: Double

    public init(slope: [Double], offset: [Double], power: [Double], saturation: Double) {
        self.slope = slope
        self.offset = offset
        self.power = power
        self.saturation = saturation
    }

    /// True when the values match the ASC CDL identity transform — Sony cameras
    /// often write this when no on-set grade was applied. Suppressed from
    /// exports so the field doesn't pollute every clip.
    public var isIdentity: Bool {
        slope == [1.0, 1.0, 1.0]
            && offset == [0.0, 0.0, 0.0]
            && power == [1.0, 1.0, 1.0]
            && saturation == 1.0
    }
}

/// Camera/clip metadata extracted from professional video containers.
/// Sourced from Sony NonRealTimeMeta (NRT) XML — either embedded in MXF
/// or carried as a sidecar `.XML` file next to MP4/MXF clips.
public struct CameraMetadata: Sendable, Equatable {
    /// Device manufacturer — e.g. "Sony" (from `<Device manufacturer="…" />`).
    public var deviceManufacturer: String?
    /// Device model — e.g. "PXW-FX9" (from `<Device modelName="…" />`).
    public var deviceModelName: String?
    /// Device serial number (from `<Device serialNo="…" />`).
    public var deviceSerialNumber: String?
    /// Lens model name (from `<LensUnitMetadata><LensModelName />`).
    public var lensModelName: String?
    /// Capture time zone offset (from `<TimeZone />`).
    public var timeZone: String?
    /// Capture gamma curve — e.g. "Rec709", "SLog3"
    /// (from `<AcquisitionRecord><Group><Item name="CaptureGammaEquation" value="…" />`).
    public var captureGammaEquation: String?
    /// Recording mode — "normal", "S&Q", etc. (from `<RecordingMode type="…" />`).
    public var recordingModeType: String?
    /// Capture frame rate in frames-per-second
    /// (from `<VideoFormat><VideoFrame captureFps="…" />`).
    public var captureFps: Double?

    /// Start timecode of the clip, as the Sony NRT LtcChangeTable reports it
    /// at `frameCount="0"`. Format `HH:MM:SS:FF` (or `HH:MM:SS;FF` for
    /// drop-frame). Nil when the NRT document omits an LtcChangeTable or its
    /// first entry doesn't carry a value attribute.
    public var startTimecode: String?

    /// User descriptive metadata "name" tokens.
    public var userMetaNames: [String]
    /// User descriptive metadata "content" tokens (aligned with `userMetaNames`).
    public var userMetaContents: [String]
    /// Clip creation date reported by the camera.
    public var creationDate: Date?

    // MARK: - X-OCN / cinema-camera additions

    /// Raw videoCodec attribute from `<VideoFrame videoCodec="…">` — e.g.
    /// `"F55_X-OCN_LT_8.6K_3:2"`. Sony writes the camera-body × codec-class
    /// × resolution × pixel-aspect tuple here as a single label.
    public var videoCodecLabel: String?
    /// Pixel aspect ratio from `<VideoLayout pixelAspect="…">` — e.g. `"1.5:1"`.
    public var pixelAspect: String?

    // CameraUnitMetadataSet
    public var exposureIndex: Int?
    public var isoSensitivity: Int?
    public var shutterAngle: Double?
    public var shutterTimeMs: Double?
    public var ndFilter: String?
    public var whiteBalanceK: Int?
    public var tintCorrection: Int?
    public var autoExposureMode: String?
    public var autoWhiteBalanceMode: String?
    public var imageSensorReadoutMode: String?
    public var imageSensorEffectiveWidth: Int?
    public var imageSensorEffectiveHeight: Int?
    public var gammaForCDL: String?
    public var cameraMasterGainDb: Double?
    public var electricalExtenderMagnification: String?
    public var cameraAttributes: String?

    // SonyF65CameraMetadataSet (also F55 / VENICE / BURANO)
    public var gammaForLook: String?
    public var colorForLook: String?
    public var monitoringBaseCurve: String?
    public var monitoringCharacteristics: String?
    public var monitoringColorPrimaries: String?
    public var monitoringCodingEquations: String?
    public var monitoringDescriptions: String?
    public var preCDLTransform: String?
    public var postCDLTransform: String?
    public var lookProcessBaked: Bool?
    public var rawBlackCodeValue: Int?
    public var rawGrayCodeValue: Int?
    public var rawWhiteCodeValue: Int?
    public var effectiveMarkerCoverage: String?
    public var effectiveMarkerAspectRatio: String?
    public var activeAreaAspectRatio: String?
    public var imageOrientation: String?
    public var cameraProcessDiscriminationCode: String?

    // CameraPostureMetadataSet
    public var cameraTiltAngle: Double?
    public var cameraRollAngle: Double?

    // LensUnitMetadataSet — populated by VENICE / BURANO / FX9 with a
    // smart lens. Cinema-PL lenses leave most of these unset.
    public var irisFNumber: Double?
    public var irisTNumber: Double?
    public var focusPositionMeters: Double?
    public var lensZoom35mmEquivalentMm: Double?
    public var lensZoomActualFocalLengthMm: Double?
    /// Sony-private lens identifier code (e.g. `"2040.0201"`). Maps to a
    /// specific lens model in Sony's own database; preserved verbatim so
    /// downstream tools can resolve it.
    public var lensAttributes: String?
    /// `<VideoLayout aspectRatio="…">` — full frame DAR (e.g. `"256:135"`).
    public var videoFrameAspectRatio: String?

    /// Parsed ASC CDL values from `<ExtendedContents>`. Identity transforms
    /// (the camera default) are suppressed and surface as nil.
    public var ascCDL: ASCCDLValues?

    /// Catch-all for every NRT `<AcquisitionRecord><Group><Item>` keyed by
    /// `groupName → itemName → itemValue`. Lets unknown future Sony items
    /// surface even before we hand-type them.
    public var acquisitionGroups: [String: [String: String]]

    /// Canon `CanonColorData` white-balance multipliers, in `[R, G1, G2, B]`
    /// order. Populated from CTMD record types 7/8/9 in Cinema RAW Light
    /// (.CRM/.CRL) clips. Deriving correlated color temperature from these
    /// requires a Canon-model-specific inversion table, which is out of scope
    /// here — consumers can compute Kelvin if they have the table.
    public var whiteBalanceCoefficients: [Double]?

    public init(
        deviceManufacturer: String? = nil,
        deviceModelName: String? = nil,
        deviceSerialNumber: String? = nil,
        lensModelName: String? = nil,
        timeZone: String? = nil,
        captureGammaEquation: String? = nil,
        recordingModeType: String? = nil,
        captureFps: Double? = nil,
        startTimecode: String? = nil,
        userMetaNames: [String] = [],
        userMetaContents: [String] = [],
        creationDate: Date? = nil,
        videoCodecLabel: String? = nil,
        pixelAspect: String? = nil,
        exposureIndex: Int? = nil,
        isoSensitivity: Int? = nil,
        shutterAngle: Double? = nil,
        shutterTimeMs: Double? = nil,
        ndFilter: String? = nil,
        whiteBalanceK: Int? = nil,
        tintCorrection: Int? = nil,
        autoExposureMode: String? = nil,
        autoWhiteBalanceMode: String? = nil,
        imageSensorReadoutMode: String? = nil,
        imageSensorEffectiveWidth: Int? = nil,
        imageSensorEffectiveHeight: Int? = nil,
        gammaForCDL: String? = nil,
        cameraMasterGainDb: Double? = nil,
        electricalExtenderMagnification: String? = nil,
        cameraAttributes: String? = nil,
        gammaForLook: String? = nil,
        colorForLook: String? = nil,
        monitoringBaseCurve: String? = nil,
        monitoringCharacteristics: String? = nil,
        monitoringColorPrimaries: String? = nil,
        monitoringCodingEquations: String? = nil,
        monitoringDescriptions: String? = nil,
        preCDLTransform: String? = nil,
        postCDLTransform: String? = nil,
        lookProcessBaked: Bool? = nil,
        rawBlackCodeValue: Int? = nil,
        rawGrayCodeValue: Int? = nil,
        rawWhiteCodeValue: Int? = nil,
        effectiveMarkerCoverage: String? = nil,
        effectiveMarkerAspectRatio: String? = nil,
        activeAreaAspectRatio: String? = nil,
        imageOrientation: String? = nil,
        cameraProcessDiscriminationCode: String? = nil,
        cameraTiltAngle: Double? = nil,
        cameraRollAngle: Double? = nil,
        irisFNumber: Double? = nil,
        irisTNumber: Double? = nil,
        focusPositionMeters: Double? = nil,
        lensZoom35mmEquivalentMm: Double? = nil,
        lensZoomActualFocalLengthMm: Double? = nil,
        lensAttributes: String? = nil,
        videoFrameAspectRatio: String? = nil,
        ascCDL: ASCCDLValues? = nil,
        acquisitionGroups: [String: [String: String]] = [:],
        whiteBalanceCoefficients: [Double]? = nil
    ) {
        self.deviceManufacturer = deviceManufacturer
        self.deviceModelName = deviceModelName
        self.deviceSerialNumber = deviceSerialNumber
        self.lensModelName = lensModelName
        self.timeZone = timeZone
        self.captureGammaEquation = captureGammaEquation
        self.recordingModeType = recordingModeType
        self.captureFps = captureFps
        self.startTimecode = startTimecode
        self.userMetaNames = userMetaNames
        self.userMetaContents = userMetaContents
        self.creationDate = creationDate
        self.videoCodecLabel = videoCodecLabel
        self.pixelAspect = pixelAspect
        self.exposureIndex = exposureIndex
        self.isoSensitivity = isoSensitivity
        self.shutterAngle = shutterAngle
        self.shutterTimeMs = shutterTimeMs
        self.ndFilter = ndFilter
        self.whiteBalanceK = whiteBalanceK
        self.tintCorrection = tintCorrection
        self.autoExposureMode = autoExposureMode
        self.autoWhiteBalanceMode = autoWhiteBalanceMode
        self.imageSensorReadoutMode = imageSensorReadoutMode
        self.imageSensorEffectiveWidth = imageSensorEffectiveWidth
        self.imageSensorEffectiveHeight = imageSensorEffectiveHeight
        self.gammaForCDL = gammaForCDL
        self.cameraMasterGainDb = cameraMasterGainDb
        self.electricalExtenderMagnification = electricalExtenderMagnification
        self.cameraAttributes = cameraAttributes
        self.gammaForLook = gammaForLook
        self.colorForLook = colorForLook
        self.monitoringBaseCurve = monitoringBaseCurve
        self.monitoringCharacteristics = monitoringCharacteristics
        self.monitoringColorPrimaries = monitoringColorPrimaries
        self.monitoringCodingEquations = monitoringCodingEquations
        self.monitoringDescriptions = monitoringDescriptions
        self.preCDLTransform = preCDLTransform
        self.postCDLTransform = postCDLTransform
        self.lookProcessBaked = lookProcessBaked
        self.rawBlackCodeValue = rawBlackCodeValue
        self.rawGrayCodeValue = rawGrayCodeValue
        self.rawWhiteCodeValue = rawWhiteCodeValue
        self.effectiveMarkerCoverage = effectiveMarkerCoverage
        self.effectiveMarkerAspectRatio = effectiveMarkerAspectRatio
        self.activeAreaAspectRatio = activeAreaAspectRatio
        self.imageOrientation = imageOrientation
        self.cameraProcessDiscriminationCode = cameraProcessDiscriminationCode
        self.cameraTiltAngle = cameraTiltAngle
        self.cameraRollAngle = cameraRollAngle
        self.irisFNumber = irisFNumber
        self.irisTNumber = irisTNumber
        self.focusPositionMeters = focusPositionMeters
        self.lensZoom35mmEquivalentMm = lensZoom35mmEquivalentMm
        self.lensZoomActualFocalLengthMm = lensZoomActualFocalLengthMm
        self.lensAttributes = lensAttributes
        self.videoFrameAspectRatio = videoFrameAspectRatio
        self.ascCDL = ascCDL
        self.acquisitionGroups = acquisitionGroups
        self.whiteBalanceCoefficients = whiteBalanceCoefficients
    }

    /// True when no interesting field was populated.
    public var isEmpty: Bool {
        deviceManufacturer == nil && deviceModelName == nil && deviceSerialNumber == nil
            && lensModelName == nil && timeZone == nil && captureGammaEquation == nil
            && recordingModeType == nil && captureFps == nil && startTimecode == nil
            && userMetaNames.isEmpty && userMetaContents.isEmpty && creationDate == nil
            && videoCodecLabel == nil && pixelAspect == nil
            && exposureIndex == nil && isoSensitivity == nil
            && shutterAngle == nil && shutterTimeMs == nil
            && ndFilter == nil && whiteBalanceK == nil && tintCorrection == nil
            && autoExposureMode == nil && autoWhiteBalanceMode == nil
            && imageSensorReadoutMode == nil
            && imageSensorEffectiveWidth == nil && imageSensorEffectiveHeight == nil
            && gammaForCDL == nil && cameraMasterGainDb == nil
            && electricalExtenderMagnification == nil && cameraAttributes == nil
            && gammaForLook == nil && colorForLook == nil
            && monitoringBaseCurve == nil && monitoringCharacteristics == nil
            && monitoringColorPrimaries == nil && monitoringCodingEquations == nil
            && monitoringDescriptions == nil
            && preCDLTransform == nil && postCDLTransform == nil
            && lookProcessBaked == nil
            && rawBlackCodeValue == nil && rawGrayCodeValue == nil && rawWhiteCodeValue == nil
            && effectiveMarkerCoverage == nil && effectiveMarkerAspectRatio == nil
            && activeAreaAspectRatio == nil && imageOrientation == nil
            && cameraProcessDiscriminationCode == nil
            && cameraTiltAngle == nil && cameraRollAngle == nil
            && irisFNumber == nil && irisTNumber == nil
            && focusPositionMeters == nil
            && lensZoom35mmEquivalentMm == nil && lensZoomActualFocalLengthMm == nil
            && lensAttributes == nil && videoFrameAspectRatio == nil
            && ascCDL == nil && acquisitionGroups.isEmpty
            && whiteBalanceCoefficients == nil
    }
}
