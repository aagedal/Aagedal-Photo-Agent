import Foundation

/// Export video metadata in machine-readable formats.
public struct VideoMetadataExporter: Sendable {

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    /// Export video metadata as JSON Data.
    public static func toJSON(_ metadata: VideoMetadata) -> Data {
        let dict = buildDictionary(metadata)
        let data = try? JSONSerialization.data(withJSONObject: [dict], options: [.prettyPrinted, .sortedKeys])
        return data ?? Data("[]".utf8)
    }

    /// Export video metadata as a JSON string.
    public static func toJSONString(_ metadata: VideoMetadata) -> String {
        String(data: toJSON(metadata), encoding: .utf8) ?? "[]"
    }

    /// Build a flat dictionary of all video metadata fields.
    public static func buildDictionary(_ metadata: VideoMetadata) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["FileFormat"] = metadata.format.rawValue.uppercased()
        if let longName = metadata.formatLongName { dict["FormatLongName"] = longName }
        if let size = metadata.fileSize { dict["FileSize"] = size }
        if let tc = metadata.timecode { dict["Timecode"] = tc }
        // Provenance-tagged timecodes: every independent source the container
        // carries, with its label (tmcdTrack / quicktimeUdta / xmpDM /
        // mxfMaterialPackage / mxfFilePackage / sonyNRT / …). Emitted as a
        // flat array of dicts so JSON/table consumers can key off `source`.
        // The scalar `Timecode` field above stays in sync with the first
        // entry for backward compatibility.
        if !metadata.timecodes.isEmpty {
            dict["Timecodes"] = metadata.timecodes.map { tc -> [String: Any] in
                var entry: [String: Any] = [
                    "value": tc.value,
                    "source": tc.source.rawValue,
                ]
                if let fr = tc.frameRate { entry["frameRate"] = fr }
                return entry
            }
        }
        if !metadata.warnings.isEmpty {
            dict["Warnings"] = metadata.warnings
        }

        if let d = metadata.duration { dict["Duration"] = d }
        if let w = metadata.videoWidth { dict["VideoWidth"] = w }
        if let h = metadata.videoHeight { dict["VideoHeight"] = h }
        if let c = metadata.videoCodec { dict["VideoCodec"] = c }
        if let profile = metadata.videoStreams.first?.profile { dict["VideoProfile"] = profile }
        if let c = metadata.audioCodec { dict["AudioCodec"] = c }
        if let profile = metadata.audioStreams.first?.profile { dict["AudioProfile"] = profile }
        if let r = metadata.frameRate { dict["FrameRate"] = r }
        if let r = metadata.videoStreams.first?.avgFrameRate { dict["AvgFrameRate"] = r }
        if let r = metadata.videoStreams.first?.rFrameRate { dict["RFrameRate"] = r }
        if let f = metadata.fieldOrder { dict["FieldOrder"] = f.rawValue }
        if let depth = metadata.bitDepth { dict["BitDepth"] = depth }
        if let chroma = metadata.chromaSubsampling { dict["ChromaSubsampling"] = chroma }
        if let loc = metadata.videoStreams.first?.chromaLocation { dict["ChromaLocation"] = loc }
        if let pix = metadata.videoStreams.first?.pixelFormat { dict["PixelFormat"] = pix }
        if let par = metadata.pixelAspectRatio {
            dict["PixelAspectRatio"] = "\(par.0):\(par.1)"
        }
        if let dw = metadata.displayWidth { dict["DisplayWidth"] = dw }
        if let dh = metadata.displayHeight { dict["DisplayHeight"] = dh }
        if let sr = metadata.audioSampleRate { dict["AudioSampleRate"] = sr }
        if let ch = metadata.audioChannels { dict["AudioChannels"] = ch }
        if let layout = metadata.audioStreams.first?.channelLayout { dict["AudioChannelLayout"] = layout }
        if let audioBR = metadata.audioStreams.first?.bitRate { dict["AudioBitRate"] = audioBR }
        if let videoBR = metadata.videoStreams.first?.bitRate { dict["VideoBitRate"] = videoBR }
        if let br = metadata.bitRate { dict["BitRate"] = br }
        if let color = metadata.colorInfo {
            if let p = color.primaries { dict["ColorPrimaries"] = p }
            if let t = color.transfer { dict["TransferCharacteristics"] = t }
            if let m = color.matrix { dict["MatrixCoefficients"] = m }
            if let full = color.fullRange { dict["ColorRange"] = full ? "pc" : "tv" }
            if let label = color.label { dict["ColorSpace"] = label }
        }
        if let hdr = metadata.videoStreams.first?.hdr {
            if let md = hdr.masteringDisplay {
                dict["MasteringDisplayPrimariesR"] = String(format: "%.4f,%.4f", md.redX, md.redY)
                dict["MasteringDisplayPrimariesG"] = String(format: "%.4f,%.4f", md.greenX, md.greenY)
                dict["MasteringDisplayPrimariesB"] = String(format: "%.4f,%.4f", md.blueX, md.blueY)
                dict["MasteringDisplayWhitePoint"] = String(format: "%.4f,%.4f", md.whitePointX, md.whitePointY)
                dict["MasteringDisplayLuminance"]  = String(format: "%.1f-%.4f cd/m^2", md.maxLuminance, md.minLuminance)
            }
            if let cll = hdr.contentLightLevel {
                dict["MaxCLL"]  = cll.maxCLL
                dict["MaxFALL"] = cll.maxFALL
            }
            if let ccv = hdr.contentColourVolume {
                if let rx = ccv.redX, let ry = ccv.redY {
                    dict["ContentColourVolumePrimariesR"] = String(format: "%.4f,%.4f", rx, ry)
                }
                if let gx = ccv.greenX, let gy = ccv.greenY {
                    dict["ContentColourVolumePrimariesG"] = String(format: "%.4f,%.4f", gx, gy)
                }
                if let bx = ccv.blueX, let by = ccv.blueY {
                    dict["ContentColourVolumePrimariesB"] = String(format: "%.4f,%.4f", bx, by)
                }
                if let minL = ccv.minLuminance { dict["ContentColourVolumeMinLuminance"] = String(format: "%.4f cd/m^2", minL) }
                if let maxL = ccv.maxLuminance { dict["ContentColourVolumeMaxLuminance"] = String(format: "%.1f cd/m^2", maxL) }
                if let avgL = ccv.avgLuminance { dict["ContentColourVolumeAvgLuminance"] = String(format: "%.1f cd/m^2", avgL) }
            }
            if let ave = hdr.ambientViewingEnvironment {
                dict["AmbientViewingEnvironmentIlluminance"] = String(format: "%.4f lux", ave.ambientIlluminance)
                dict["AmbientViewingEnvironmentLight"] = String(format: "%.4f,%.4f", ave.ambientLightX, ave.ambientLightY)
            }
            if let dv = hdr.dolbyVision {
                dict["DolbyVisionProfile"] = dv.profile
                dict["DolbyVisionLevel"]   = dv.level
                dict["DolbyVisionVersion"] = "\(dv.versionMajor).\(dv.versionMinor)"
                dict["DolbyVisionBLCompatibility"] = dv.blSignalCompatibilityID
            }
        }
        if !metadata.videoStreams.isEmpty {
            dict["VideoStreamCount"] = metadata.videoStreams.count
            let titles = metadata.videoStreams.compactMap(\.title)
            if !titles.isEmpty { dict["VideoStreamTitles"] = titles }
            let attached = metadata.videoStreams.map { $0.isAttachedPic ?? false }
            dict["VideoAttachedPicFlags"] = attached
            let defaults = metadata.videoStreams.map { $0.isDefault ?? true }
            dict["VideoDefaultFlags"] = defaults
        }
        if !metadata.audioStreams.isEmpty {
            dict["AudioStreamCount"] = metadata.audioStreams.count
            let titles = metadata.audioStreams.compactMap(\.title)
            if !titles.isEmpty { dict["AudioStreamTitles"] = titles }
            let defaults = metadata.audioStreams.map { $0.isDefault ?? true }
            dict["AudioDefaultFlags"] = defaults
        }
        if !metadata.subtitleStreams.isEmpty {
            dict["SubtitleStreamCount"] = metadata.subtitleStreams.count
            // Build a flat summary the CLI / consumers can read at a glance.
            let codecs = metadata.subtitleStreams.compactMap { $0.codecName ?? $0.codec }
            if !codecs.isEmpty { dict["SubtitleCodecs"] = codecs }
            let languages = metadata.subtitleStreams.compactMap { $0.language }
            if !languages.isEmpty { dict["SubtitleLanguages"] = languages }
            let titles = metadata.subtitleStreams.compactMap { $0.title }
            if !titles.isEmpty { dict["SubtitleTitles"] = titles }
            // Disposition flags (default / forced / SDH). Always emit per-track
            // arrays so consumers can index by stream position; missing values
            // default per Matroska spec (FlagDefault=1, FlagForced=0,
            // FlagHearingImpaired=0).
            dict["SubtitleDefaultFlags"]         = metadata.subtitleStreams.map { $0.isDefault ?? true }
            dict["SubtitleForcedFlags"]          = metadata.subtitleStreams.map { $0.isForced ?? false }
            dict["SubtitleHearingImpairedFlags"] = metadata.subtitleStreams.map { $0.isHearingImpaired ?? false }
        }
        if !metadata.chapters.isEmpty {
            dict["ChapterCount"] = metadata.chapters.count
            dict["ChapterStartTimes"] = metadata.chapters.map(\.startTime)
            // End times — emit as a sparse array where missing entries are
            // represented by NSNull, since not every chapter source records an
            // explicit end (Matroska allows open-ended atoms, Nero `chpl`
            // never records end times).
            dict["ChapterEndTimes"] = metadata.chapters.map { $0.endTime.map { $0 as Any } ?? NSNull() }
            dict["ChapterDurations"] = metadata.chapters.map { $0.duration.map { $0 as Any } ?? NSNull() }
            dict["ChapterTitles"] = metadata.chapters.map { $0.title ?? "" }
            let languages = metadata.chapters.compactMap(\.language)
            if !languages.isEmpty { dict["ChapterLanguages"] = languages }
        }
        if !metadata.mpegPrograms.isEmpty {
            dict["MPEGProgramCount"] = metadata.mpegPrograms.count
            dict["MPEGProgramNumbers"] = metadata.mpegPrograms.map(\.programNumber)
            dict["MPEGProgramPMTPIDs"] = metadata.mpegPrograms.map(\.pmtPID)
            dict["MPEGProgramElementaryPIDs"] = metadata.mpegPrograms.map(\.elementaryPIDs)
            let names = metadata.mpegPrograms.compactMap(\.serviceName)
            if !names.isEmpty { dict["MPEGProgramServiceNames"] = names }
            let providers = metadata.mpegPrograms.compactMap(\.providerName)
            if !providers.isEmpty { dict["MPEGProgramProviderNames"] = providers }
        }
        if let t = metadata.title { dict["Title"] = t }
        if let a = metadata.artist { dict["Artist"] = a }
        if let c = metadata.comment { dict["Comment"] = c }
        if let lat = metadata.gpsLatitude { dict["GPSLatitude"] = lat }
        if let lon = metadata.gpsLongitude { dict["GPSLongitude"] = lon }
        if let alt = metadata.gpsAltitude { dict["GPSAltitude"] = alt }

        if let date = metadata.creationDate {
            dict["CreationDate"] = isoFormatter.string(from: date)
        }
        if let date = metadata.modificationDate {
            dict["ModificationDate"] = isoFormatter.string(from: date)
        }

        if let cam = metadata.camera {
            if let v = cam.deviceManufacturer    { dict["DeviceManufacturer"]    = v }
            if let v = cam.deviceModelName       { dict["DeviceModelName"]       = v }
            if let v = cam.deviceSerialNumber    { dict["DeviceSerialNumber"]    = v }
            if let v = cam.lensModelName         { dict["LensModelName"]         = v }
            if let v = cam.timeZone              { dict["TimeZone"]              = v }
            if let v = cam.captureGammaEquation  { dict["CaptureGammaEquation"]  = v }
            if let v = cam.recordingModeType     { dict["RecordingMode"]         = v }
            if let v = cam.captureFps            { dict["CaptureFps"]            = v }
            if !cam.userMetaNames.isEmpty {
                dict["UserDescriptiveMetadataMetaName"]    = cam.userMetaNames
                dict["UserDescriptiveMetadataMetaContent"] = cam.userMetaContents
            }
            if let date = cam.creationDate {
                dict["CreationDateValue"] = isoFormatter.string(from: date)
            }

            // X-OCN / cinema-camera fields. NRT AcquisitionRecord items map
            // 1:1 onto these tag names (PascalCase form of the Sony Item
            // attribute name), so a downstream consumer can grep for the
            // same identifier as the camera writes.
            if let v = cam.videoCodecLabel              { dict["VideoCodecLabel"]              = v }
            if let v = cam.pixelAspect                  { dict["PixelAspect"]                  = v }
            if let v = cam.exposureIndex                { dict["ExposureIndexOfPhotoMeter"]    = v }
            if let v = cam.isoSensitivity               { dict["ISOSensitivity"]               = v }
            if let v = cam.shutterAngle                 { dict["ShutterAngle"]                 = v }
            if let v = cam.shutterTimeMs                { dict["ShutterTimeMs"]                = v }
            if let v = cam.ndFilter                     { dict["NeutralDensityFilterWheelSetting"] = v }
            if let v = cam.whiteBalanceK                { dict["WhiteBalance"]                 = v }
            if let v = cam.tintCorrection               { dict["TintCorrection"]               = v }
            if let v = cam.autoExposureMode             { dict["AutoExposureMode"]             = v }
            if let v = cam.autoWhiteBalanceMode         { dict["AutoWhiteBalanceMode"]         = v }
            if let v = cam.imageSensorReadoutMode       { dict["ImageSensorReadoutMode"]       = v }
            if let v = cam.imageSensorEffectiveWidth    { dict["ImageSensorEffectiveWidth"]    = v }
            if let v = cam.imageSensorEffectiveHeight   { dict["ImageSensorEffectiveHeight"]   = v }
            if let v = cam.gammaForCDL                  { dict["GammaForCDL"]                  = v }
            if let v = cam.cameraMasterGainDb           { dict["CameraMasterGainAdjustmentDb"] = v }
            if let v = cam.electricalExtenderMagnification { dict["ElectricalExtenderMagnification"] = v }
            if let v = cam.cameraAttributes             { dict["CameraAttributes"]             = v }

            if let v = cam.gammaForLook                 { dict["GammaForLook"]                 = v }
            if let v = cam.colorForLook                 { dict["ColorForLook"]                 = v }
            if let v = cam.monitoringBaseCurve          { dict["MonitoringBaseCurve"]          = v }
            if let v = cam.monitoringCharacteristics    { dict["MonitoringCharacteristics"]    = v }
            if let v = cam.monitoringColorPrimaries     { dict["MonitoringColorPrimaries"]     = v }
            if let v = cam.monitoringCodingEquations    { dict["MonitoringCodingEquations"]    = v }
            if let v = cam.monitoringDescriptions       { dict["MonitoringDescriptions"]       = v }
            if let v = cam.preCDLTransform              { dict["PreCDLTransform"]              = v }
            if let v = cam.postCDLTransform             { dict["PostCDLTransform"]             = v }
            if let v = cam.lookProcessBaked             { dict["LookProcessBaked"]             = v }
            if let v = cam.rawBlackCodeValue            { dict["RawBlackCodeValue"]            = v }
            if let v = cam.rawGrayCodeValue             { dict["RawGrayCodeValue"]             = v }
            if let v = cam.rawWhiteCodeValue            { dict["RawWhiteCodeValue"]            = v }
            if let v = cam.effectiveMarkerCoverage      { dict["EffectiveMarkerCoverage"]      = v }
            if let v = cam.effectiveMarkerAspectRatio   { dict["EffectiveMarkerAspectRatio"]   = v }
            if let v = cam.activeAreaAspectRatio        { dict["ActiveAreaAspectRatio"]        = v }
            if let v = cam.imageOrientation             { dict["ImageOrientation"]             = v }
            if let v = cam.cameraProcessDiscriminationCode { dict["CameraProcessDiscriminationCode"] = v }

            if let v = cam.cameraTiltAngle              { dict["CameraTiltAngle"]              = v }
            if let v = cam.cameraRollAngle              { dict["CameraRollAngle"]              = v }

            if let v = cam.irisFNumber                  { dict["IrisFNumber"]                  = v }
            if let v = cam.irisTNumber                  { dict["IrisTNumber"]                  = v }
            if let v = cam.focusPositionMeters          { dict["FocusPositionFromImagePlane"]  = v }
            if let v = cam.lensZoom35mmEquivalentMm     { dict["LensZoom35mmStillCameraEquivalent"] = v }
            if let v = cam.lensZoomActualFocalLengthMm  { dict["LensZoomActualFocalLength"]    = v }
            if let v = cam.lensAttributes               { dict["LensAttributes"]               = v }
            if let v = cam.videoFrameAspectRatio        { dict["VideoFrameAspectRatio"]        = v }

            if let cdl = cam.ascCDL {
                dict["ASCCDL"] = [
                    "Slope":      cdl.slope,
                    "Offset":     cdl.offset,
                    "Power":      cdl.power,
                    "Saturation": cdl.saturation,
                ]
            }

            if !cam.acquisitionGroups.isEmpty {
                dict["AcquisitionRecord"] = cam.acquisitionGroups
            }
        }

        if let rtmd = metadata.rtmd {
            dict["HasRTMDTrack"] = true
            if let rate = rtmd.imuSampleRateHz {
                dict["RTMDIMUSampleRateHz"] = rate
            }
            if let f = rtmd.firstFrame {
                if let v = f.iso                    { dict["RTMDFirstFrameISO"]            = v }
                if let v = f.exposureTimeSeconds    { dict["RTMDFirstFrameExposureTime"]   = v }
                if let v = f.fNumber                { dict["RTMDFirstFrameFNumber"]        = v }
                if let v = f.focalLengthMm          { dict["RTMDFirstFrameFocalLengthMm"]  = v }
                if let v = f.whiteBalance           { dict["RTMDFirstFrameWhiteBalance"]   = v }
                if let v = f.frameRate              { dict["RTMDFirstFrameFrameRate"]      = v }
                if let v = f.dateTime               { dict["RTMDFirstFrameDateTime"]       = v }
                if let v = f.serialNumber           { dict["RTMDFirstFrameSerialNumber"]   = v }
                if let v = f.gpsLatitude            { dict["RTMDFirstFrameGPSLatitude"]    = v }
                if let v = f.gpsLongitude           { dict["RTMDFirstFrameGPSLongitude"]   = v }
            }
        }

        if let labeling = metadata.mcaAudioLabeling, !labeling.isEmpty {
            // Top-level MCA labelling block (SMPTE ST 377-4 / ST 2020-1).
            // Channels resolve to AudioStream slots by `TrackIndex`; the
            // soundfield-group and group-of-groups arrays carry the full link
            // graph so consumers can reconstruct bmxtools-style labels.txt.
            var mcaDict: [String: Any] = [:]
            mcaDict["Channels"] = labeling.channels.map { ch -> [String: Any] in
                var d: [String: Any] = [:]
                if let v = ch.trackIndex            { d["TrackIndex"]            = v }
                if let v = ch.symbol                { d["Symbol"]                = v }
                if let v = ch.name                  { d["Name"]                  = v }
                if let v = ch.channelID             { d["ChannelID"]             = v }
                if let v = ch.linkID                { d["LinkID"]                = v.uuidString }
                if let v = ch.soundfieldGroupLinkID { d["SoundfieldGroupLinkID"] = v.uuidString }
                if let v = ch.language              { d["Language"]              = v }
                return d
            }
            mcaDict["SoundfieldGroups"] = labeling.soundfieldGroups.map { sg -> [String: Any] in
                var d: [String: Any] = [:]
                if let v = sg.symbol   { d["Symbol"]   = v }
                if let v = sg.name     { d["Name"]     = v }
                if let v = sg.linkID   { d["LinkID"]   = v.uuidString }
                if !sg.groupOfGroupsLinkIDs.isEmpty {
                    d["GroupOfSoundfieldGroupsLinkIDs"] = sg.groupOfGroupsLinkIDs.map(\.uuidString)
                }
                if let v = sg.language { d["Language"] = v }
                return d
            }
            mcaDict["GroupsOfSoundfieldGroups"] = labeling.groupsOfSoundfieldGroups.map { gg -> [String: Any] in
                var d: [String: Any] = [:]
                if let v = gg.symbol   { d["Symbol"]   = v }
                if let v = gg.name     { d["Name"]     = v }
                if let v = gg.linkID   { d["LinkID"]   = v.uuidString }
                if let v = gg.language { d["Language"] = v }
                return d
            }
            dict["MCAAudioLabeling"] = mcaDict
        }

        if let c2pa = metadata.c2pa {
            dict["HasContentCredentials"] = true
            if let manifest = c2pa.activeManifest {
                dict["HasSignature"] = true
                dict["ManifestLabel"] = manifest.label
                dict["ClaimGenerator"] = manifest.claim.claimGenerator
                if let info = manifest.claim.claimGeneratorInfo {
                    dict["ClaimGeneratorInfoName"] = info.name
                    if let v = info.version { dict["ClaimGeneratorInfoVersion"] = v }
                }
                if let title = manifest.claim.title { dict["ClaimTitle"] = title }
                if let fmt = manifest.claim.format { dict["ClaimFormat"] = fmt }
                if let alg = manifest.signature.algorithm {
                    dict["SignatureAlgorithm"] = String(describing: alg)
                }
                if !manifest.signature.certificateChain.isEmpty {
                    dict["SignatureCertificateCount"] = manifest.signature.certificateChain.count
                }
                dict["Assertions"] = manifest.assertions.map(\.label)

                // First c2pa.actions assertion is what the Media Converter app uses
                // to populate actionsAction / actionsDigitalSourceType.
                if let actionsAssertion = manifest.assertions.first(where: { $0.label.hasPrefix("c2pa.actions") }),
                   case .actions(let actions) = actionsAssertion.content,
                   let firstAction = actions.actions.first {
                    dict["ActionsAction"] = firstAction.action
                    if let digital = firstAction.digitalSourceType {
                        dict["ActionsDigitalSourceType"] = digital
                    }
                    if let agent = firstAction.softwareAgent {
                        dict["ActionsSoftwareAgent"] = agent
                    }
                }
            }
        }

        return dict
    }
}
