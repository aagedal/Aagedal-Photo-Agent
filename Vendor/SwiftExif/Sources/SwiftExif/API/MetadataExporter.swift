import Foundation

/// Export metadata in machine-readable formats (JSON, XML).
public struct MetadataExporter: Sendable {

    // MARK: - JSON Export

    /// Export metadata as JSON Data, matching ExifTool's `-json` output format.
    public static func toJSON(_ metadata: ImageMetadata) -> Data {
        toJSON([metadata])
    }

    /// Export multiple files' metadata as a JSON array.
    public static func toJSON(_ items: [ImageMetadata]) -> Data {
        var entries: [[String: Any]] = []
        for metadata in items {
            entries.append(buildDictionary(metadata))
        }
        let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        return data ?? Data("[]".utf8)
    }

    /// Export metadata as a JSON string.
    public static func toJSONString(_ metadata: ImageMetadata) -> String {
        String(data: toJSON(metadata), encoding: .utf8) ?? "[]"
    }

    // MARK: - XML Export

    /// Export metadata as an XML string.
    public static func toXML(_ metadata: ImageMetadata) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        xml += "<rdf:Description>\n"

        let dict = buildDictionary(metadata)
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            if let array = value as? [String] {
                xml += "  <\(escapeXMLTag(key))>\n"
                for item in array {
                    xml += "    <rdf:li>\(escapeXMLValue(item))</rdf:li>\n"
                }
                xml += "  </\(escapeXMLTag(key))>\n"
            } else {
                xml += "  <\(escapeXMLTag(key))>\(escapeXMLValue(String(describing: value)))</\(escapeXMLTag(key))>\n"
            }
        }

        xml += "</rdf:Description>\n"
        xml += "</rdf:RDF>\n"
        return xml
    }

    // MARK: - Dictionary Building

    /// Build a flat dictionary of all metadata fields, including file-level tags if URL is provided.
    ///
    /// - Parameter includeHashes: When true, reads the full file to compute File:MD5 and File:SHA256.
    ///   This is expensive on large RAW/video files (full re-read plus two passes of cryptographic
    ///   hashing), so it's opt-in. FileSize/FileName/Directory are always cheap and always included.
    public static func buildDictionary(_ metadata: ImageMetadata, fileURL: URL? = nil, includeHashes: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["FileFormat"] = formatName(metadata.format)

        if let url = fileURL {
            dict["File:FileName"] = url.lastPathComponent
            dict["File:Directory"] = url.deletingLastPathComponent().path
            // Prefer stat over re-reading the file — a 60MB RAW shouldn't need to be reloaded just to report its size.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                dict["File:FileSize"] = size
            }
            if includeHashes, let hashes = try? FileHasher.hash(url: url) {
                dict["File:MD5"] = hashes.md5
                dict["File:SHA256"] = hashes.sha256
                // resourceValues didn't have the size (rare, e.g. non-file URL); the streaming
                // hasher counted bytes as it read them, so reuse that.
                if dict["File:FileSize"] == nil {
                    dict["File:FileSize"] = Int(hashes.fileSize)
                }
            }
        }

        // EXIF
        if let exif = metadata.exif {
            addExifFields(&dict, exif)
        }

        // IPTC
        addIPTCFields(&dict, metadata.iptc)

        // XMP
        if let xmp = metadata.xmp {
            addXMPFields(&dict, xmp)
        }

        // MakerNote
        if let makerNote = metadata.exif?.makerNote {
            for (key, value) in makerNote.tags {
                switch value {
                case .string(let s): dict["MakerNote:\(key)"] = s
                case .int(let i): dict["MakerNote:\(key)"] = i
                case .uint(let u): dict["MakerNote:\(key)"] = Int(u)
                case .double(let d): dict["MakerNote:\(key)"] = d
                case .data: break
                case .intArray(let arr): dict["MakerNote:\(key)"] = arr.map(String.init).joined(separator: " ")
                }
            }
        }

        // C2PA / Content Credentials
        if let c2pa = metadata.c2pa {
            dict["C2PA:ManifestCount"] = c2pa.manifests.count
            if let manifest = c2pa.activeManifest {
                dict["C2PA:ActiveManifest"] = manifest.label
                dict["C2PA:ClaimGenerator"] = manifest.claim.claimGenerator
                if let info = manifest.claim.claimGeneratorInfo {
                    dict["C2PA:ClaimGeneratorName"] = info.name
                    if let v = info.version { dict["C2PA:ClaimGeneratorVersion"] = v }
                }
                if let title = manifest.claim.title { dict["C2PA:Title"] = title }
                if let format = manifest.claim.format { dict["C2PA:Format"] = format }
                if let instanceID = manifest.claim.instanceID { dict["C2PA:InstanceID"] = instanceID }
                if let alg = manifest.signature.algorithm {
                    dict["C2PA:SignatureAlgorithm"] = String(describing: alg)
                }
                let chain = manifest.signature.certificateChain
                if !chain.isEmpty {
                    dict["C2PA:CertificateCount"] = chain.count
                    // Surface the signer/issuer identity from the leaf certificate.
                    if let cert = chain.first.flatMap(X509Parser.parse) {
                        if let cn = cert.subjectCommonName { dict["C2PA:SignerCommonName"] = cn }
                        if let issuer = cert.issuerCommonName { dict["C2PA:IssuerCommonName"] = issuer }
                    }
                }
                if !manifest.assertions.isEmpty {
                    dict["C2PA:Assertions"] = manifest.assertions.map(\.label).joined(separator: ", ")
                }
                // First c2pa.actions assertion records how the asset was produced.
                if let actionsAssertion = manifest.assertions.first(where: { $0.label.hasPrefix("c2pa.actions") }),
                   case .actions(let actions) = actionsAssertion.content,
                   let firstAction = actions.actions.first {
                    dict["C2PA:Action"] = firstAction.action
                    if let digital = firstAction.digitalSourceType { dict["C2PA:DigitalSourceType"] = digital }
                    if let agent = firstAction.softwareAgent { dict["C2PA:SoftwareAgent"] = agent }
                }
            }
        }

        // Composite Tags
        if let exif = metadata.exif {
            let composites = CompositeTagCalculator.calculate(from: exif)
            for (key, value) in composites {
                dict[key] = value
            }
        }

        // PDF Info dictionary
        if case .pdf(let pdfFile) = metadata.container {
            for (key, value) in pdfFile.infoDict {
                dict["PDF:\(key)"] = value
            }
        }

        // JPEG SOF dimensions — the canonical pixel size of the encoded
        // image, distinct from Exif's PixelXDimension (which can drift after
        // edits). Mirrors ExifTool's File:ImageWidth/ImageHeight.
        if case .jpeg(let jpegFile) = metadata.container,
           let dims = jpegFile.imageDimensions {
            dict["File:ImageWidth"] = dims.width
            dict["File:ImageHeight"] = dims.height
        }

        // JXL SizeHeader from the codestream — bare codestreams and Exif-less
        // container JXLs have no PixelXDimension to fall back on.
        if case .jpegXL(let jxlFile) = metadata.container,
           let dims = jxlFile.imageDimensions {
            dict["File:ImageWidth"] = dims.width
            dict["File:ImageHeight"] = dims.height
        }

        // BMP header info
        if case .bmp(let bmpFile) = metadata.container {
            dict["BMP:ImageWidth"] = Int(bmpFile.width)
            dict["BMP:ImageHeight"] = Int(bmpFile.absoluteHeight)
            dict["BMP:BitsPerPixel"] = Int(bmpFile.bitsPerPixel)
            dict["BMP:Compression"] = bmpFile.compressionName
            dict["BMP:Version"] = bmpFile.bmpVersion
            if bmpFile.xPixelsPerMeter != 0 {
                dict["BMP:XResolution"] = Int(round(bmpFile.xDPI))
                dict["BMP:YResolution"] = Int(round(bmpFile.yDPI))
            }
        }

        // GIF dimensions
        if case .gif(let gifFile) = metadata.container {
            dict["GIF:ImageWidth"] = Int(gifFile.width)
            dict["GIF:ImageHeight"] = Int(gifFile.height)
            let comments = gifFile.comments
            if !comments.isEmpty { dict["GIF:Comment"] = comments.joined(separator: "; ") }
        }

        // For formats without a dedicated container-level dimension extractor
        // (TIFF/RAW/HEIF/JXL/AVIF/WebP/CR3), fall back to Exif's rendered
        // dimensions (PixelXDimension/Y, tags 0xA002/0xA003). This matches
        // ExifTool's File:ImageWidth/Height behaviour for these formats.
        if dict["File:ImageWidth"] == nil,
           let w = metadata.exif?.pixelXDimension {
            dict["File:ImageWidth"] = Int(w)
        }
        if dict["File:ImageHeight"] == nil,
           let h = metadata.exif?.pixelYDimension {
            dict["File:ImageHeight"] = Int(h)
        }

        // SVG dimensions
        if case .svg(let svgFile) = metadata.container {
            if let w = svgFile.width { dict["SVG:Width"] = w }
            if let h = svgFile.height { dict["SVG:Height"] = h }
            if let vb = svgFile.viewBox { dict["SVG:ViewBox"] = vb }
        }

        // ICC Profile
        if let icc = metadata.iccProfile {
            dict["ICCProfile:ColorSpace"] = icc.colorSpace.trimmingCharacters(in: .whitespaces)
            if let desc = icc.profileDescription {
                dict["ICCProfile:Description"] = desc
            }
            dict["ICCProfile:Size"] = Int(icc.profileSize)
            if let v = icc.profileVersion { dict["ICCProfile:Version"] = v }
            if let cls = icc.deviceClass { dict["ICCProfile:Class"] = cls }
            dict["ICCProfile:ConnectionSpace"] = icc.profileConnectionSpace.trimmingCharacters(in: .whitespaces)
            if let dt = icc.creationDate { dict["ICCProfile:CreationDate"] = dt }
            if let pp = icc.primaryPlatform { dict["ICCProfile:PrimaryPlatform"] = pp }
            if let m = icc.manufacturer { dict["ICCProfile:Manufacturer"] = m }
            if let mo = icc.model { dict["ICCProfile:Model"] = mo }
            if let ri = icc.renderingIntent { dict["ICCProfile:RenderingIntent"] = Int(ri) }
            if let cr = icc.creator { dict["ICCProfile:Creator"] = cr }
            if let pid = icc.profileID { dict["ICCProfile:ProfileID"] = pid }
            if let cp = icc.copyright { dict["ICCProfile:Copyright"] = cp }
            if let wp = icc.mediaWhitePoint {
                dict["ICCProfile:MediaWhitePoint"] = String(format: "%.4f %.4f %.4f", wp.x, wp.y, wp.z)
            }
            if let bp = icc.mediaBlackPoint {
                dict["ICCProfile:MediaBlackPoint"] = String(format: "%.4f %.4f %.4f", bp.x, bp.y, bp.z)
            }
            if let chad = icc.chromaticAdaptation {
                dict["ICCProfile:ChromaticAdaptation"] = chad.map { String(format: "%.4f", $0) }.joined(separator: " ")
            }
            if let r = icc.redColorant {
                dict["ICCProfile:RedColorant"] = String(format: "%.4f %.4f %.4f", r.x, r.y, r.z)
            }
            if let g = icc.greenColorant {
                dict["ICCProfile:GreenColorant"] = String(format: "%.4f %.4f %.4f", g.x, g.y, g.z)
            }
            if let b = icc.blueColorant {
                dict["ICCProfile:BlueColorant"] = String(format: "%.4f %.4f %.4f", b.x, b.y, b.z)
            }
            if let trc = icc.redTRC { dict["ICCProfile:RedTRC"] = describeTRC(trc) }
            if let trc = icc.greenTRC { dict["ICCProfile:GreenTRC"] = describeTRC(trc) }
            if let trc = icc.blueTRC { dict["ICCProfile:BlueTRC"] = describeTRC(trc) }
            if let trc = icc.grayTRC { dict["ICCProfile:GrayTRC"] = describeTRC(trc) }
            if let lut = icc.aToB0 { dict["ICCProfile:AToB0"] = describeLUT(lut) }
            if let lut = icc.aToB1 { dict["ICCProfile:AToB1"] = describeLUT(lut) }
            if let lut = icc.aToB2 { dict["ICCProfile:AToB2"] = describeLUT(lut) }
            if let lut = icc.bToA0 { dict["ICCProfile:BToA0"] = describeLUT(lut) }
            if let lut = icc.bToA1 { dict["ICCProfile:BToA1"] = describeLUT(lut) }
            if let lut = icc.bToA2 { dict["ICCProfile:BToA2"] = describeLUT(lut) }
            if let n = icc.namedColorCount { dict["ICCProfile:NamedColorCount"] = n }
            if icc.hasViewingConditions { dict["ICCProfile:ViewingConditions"] = true }
            if icc.hasMeasurement { dict["ICCProfile:Measurement"] = true }
        }

        // HDR static metadata from HEIF / AVIF `mdcv` / `clli` properties.
        if let hdr = metadata.hdr {
            if let md = hdr.masteringDisplay {
                dict["HDR:MasteringDisplayPrimariesR"] = String(format: "%.4f,%.4f", md.redX, md.redY)
                dict["HDR:MasteringDisplayPrimariesG"] = String(format: "%.4f,%.4f", md.greenX, md.greenY)
                dict["HDR:MasteringDisplayPrimariesB"] = String(format: "%.4f,%.4f", md.blueX, md.blueY)
                dict["HDR:MasteringDisplayWhitePoint"] = String(format: "%.4f,%.4f", md.whitePointX, md.whitePointY)
                dict["HDR:MasteringDisplayLuminance"]  = String(format: "%.1f-%.4f cd/m^2", md.maxLuminance, md.minLuminance)
            }
            if let cll = hdr.contentLightLevel {
                dict["HDR:MaxCLL"]  = cll.maxCLL
                dict["HDR:MaxFALL"] = cll.maxFALL
            }
        }

        // DNG private tags (Adobe DNG specification 1.7).
        if let dng = metadata.dng {
            if let v = dng.dngVersion { dict["DNG:DNGVersion"] = v }
            if let v = dng.dngBackwardVersion { dict["DNG:DNGBackwardVersion"] = v }
            if let v = dng.uniqueCameraModel { dict["DNG:UniqueCameraModel"] = v }
            if let v = dng.localizedCameraModel { dict["DNG:LocalizedCameraModel"] = v }
            if let v = dng.cameraSerialNumber { dict["DNG:CameraSerialNumber"] = v }
            if let v = dng.calibrationIlluminant1 { dict["DNG:CalibrationIlluminant1"] = Int(v) }
            if let v = dng.calibrationIlluminant2 { dict["DNG:CalibrationIlluminant2"] = Int(v) }
            if let v = dng.colorMatrix1 {
                dict["DNG:ColorMatrix1"] = v.map { String(format: "%.6f", $0) }.joined(separator: " ")
            }
            if let v = dng.colorMatrix2 {
                dict["DNG:ColorMatrix2"] = v.map { String(format: "%.6f", $0) }.joined(separator: " ")
            }
            if let v = dng.cameraCalibration1 {
                dict["DNG:CameraCalibration1"] = v.map { String(format: "%.6f", $0) }.joined(separator: " ")
            }
            if let v = dng.cameraCalibration2 {
                dict["DNG:CameraCalibration2"] = v.map { String(format: "%.6f", $0) }.joined(separator: " ")
            }
            if let v = dng.analogBalance {
                dict["DNG:AnalogBalance"] = v.map { String(format: "%.6g", $0) }.joined(separator: " ")
            }
            if let v = dng.asShotNeutral {
                dict["DNG:AsShotNeutral"] = v.map { String(format: "%.6f", $0) }.joined(separator: " ")
            }
            if let v = dng.asShotWhiteXY {
                dict["DNG:AsShotWhiteXY"] = v.map { String(format: "%.6f", $0) }.joined(separator: " ")
            }
            if let v = dng.baselineExposure { dict["DNG:BaselineExposure"] = v }
            if let v = dng.baselineNoise { dict["DNG:BaselineNoise"] = v }
            if let v = dng.baselineSharpness { dict["DNG:BaselineSharpness"] = v }
            if let v = dng.bayerGreenSplit { dict["DNG:BayerGreenSplit"] = Int(v) }
            if let v = dng.linearResponseLimit { dict["DNG:LinearResponseLimit"] = v }
            if let v = dng.antiAliasStrength { dict["DNG:AntiAliasStrength"] = v }
            if let v = dng.shadowScale { dict["DNG:ShadowScale"] = v }
            if let v = dng.bestQualityScale { dict["DNG:BestQualityScale"] = v }
            if let v = dng.cfaPlaneColor { dict["DNG:CFAPlaneColor"] = v }
            if let v = dng.cfaLayout { dict["DNG:CFALayout"] = Int(v) }
            if let v = dng.cfaRepeatPatternDim {
                dict["DNG:CFARepeatPatternDim"] = v.map { String(format: "%.0f", $0) }.joined(separator: " ")
            }
            if let v = dng.blackLevelRepeatDim {
                dict["DNG:BlackLevelRepeatDim"] = v.map { String(format: "%.0f", $0) }.joined(separator: " ")
            }
            if let v = dng.blackLevel {
                dict["DNG:BlackLevel"] = v.map { String(format: "%.6g", $0) }.joined(separator: " ")
            }
            if let v = dng.whiteLevel {
                dict["DNG:WhiteLevel"] = v.map { String(format: "%.0f", $0) }.joined(separator: " ")
            }
            if let v = dng.defaultScale {
                dict["DNG:DefaultScale"] = v.map { String(format: "%.6g", $0) }.joined(separator: " ")
            }
            if let v = dng.activeArea {
                dict["DNG:ActiveArea"] = v.map { String(format: "%.0f", $0) }.joined(separator: " ")
            }
            if let v = dng.defaultUserCrop {
                dict["DNG:DefaultUserCrop"] = v.map { String(format: "%.6g", $0) }.joined(separator: " ")
            }
            if let v = dng.defaultCropOrigin {
                dict["DNG:DefaultCropOrigin"] = v.map { String(format: "%.0f", $0) }.joined(separator: " ")
            }
            if let v = dng.defaultCropSize {
                dict["DNG:DefaultCropSize"] = v.map { String(format: "%.0f", $0) }.joined(separator: " ")
            }
            if let v = dng.profileName { dict["DNG:ProfileName"] = v }
            if let v = dng.profileCopyright { dict["DNG:ProfileCopyright"] = v }
            if let v = dng.previewApplicationName { dict["DNG:PreviewApplicationName"] = v }
            if let v = dng.previewApplicationVersion { dict["DNG:PreviewApplicationVersion"] = v }
            if let v = dng.previewSettingsName { dict["DNG:PreviewSettingsName"] = v }
            if let v = dng.originalRawFileName { dict["DNG:OriginalRawFileName"] = v }
            if let v = dng.rawDataUniqueID { dict["DNG:RawDataUniqueID"] = v }
            if let v = dng.colorimetricReference { dict["DNG:ColorimetricReference"] = Int(v) }
            if let v = dng.profileEmbedPolicy { dict["DNG:ProfileEmbedPolicy"] = Int(v) }
            if let v = dng.profileHueSatMapDims {
                dict["DNG:ProfileHueSatMapDims"] = v.map { String($0) }.joined(separator: " ")
            }
            if let v = dng.profileLookTableDims {
                dict["DNG:ProfileLookTableDims"] = v.map { String($0) }.joined(separator: " ")
            }
            if let v = dng.noiseProfile {
                dict["DNG:NoiseProfile"] = v.map { String(format: "%.6g", $0) }.joined(separator: " ")
            }
            if let v = dng.baselineExposureOffset { dict["DNG:BaselineExposureOffset"] = v }
            if let v = dng.opcodeList1Size { dict["DNG:OpcodeList1Size"] = v }
            if let v = dng.opcodeList2Size { dict["DNG:OpcodeList2Size"] = v }
            if let v = dng.opcodeList3Size { dict["DNG:OpcodeList3Size"] = v }
            if let v = dng.profileLookTableSampleCount { dict["DNG:ProfileLookTableSamples"] = v }
        }

        // MPF (Multi-Picture Format) — Live Photo aux frames, depth maps,
        // multi-shot bursts, stereo pairs.
        if let mpf = metadata.mpf {
            if let v = mpf.version { dict["MPF:Version"] = v }
            dict["MPF:NumberOfImages"] = mpf.numberOfImages
            for (i, e) in mpf.entries.enumerated() {
                let prefix = "MPF:Image\(i + 1)"
                dict["\(prefix):Type"] = e.imageType
                dict["\(prefix):Size"] = Int(e.imageSize)
                dict["\(prefix):Offset"] = Int(e.imageOffset)
                if e.isRepresentative { dict["\(prefix):Representative"] = true }
                if e.isDependentParent { dict["\(prefix):DependentParent"] = true }
                if e.isDependentChild { dict["\(prefix):DependentChild"] = true }
            }
        }

        return dict
    }

    /// Build a filtered dictionary, including only keys that match the filter.
    public static func filteredDictionary(_ metadata: ImageMetadata, filter: TagFilter) -> [String: Any] {
        filter.apply(to: buildDictionary(metadata))
    }

    // MARK: - EXIF Fields

    private static func addExifFields(_ dict: inout [String: Any], _ exif: ExifData) {
        if let v = exif.make { dict["Make"] = v }
        if let v = exif.model { dict["Model"] = v }
        if let v = exif.software { dict["Software"] = v }
        if let v = exif.dateTime { dict["DateTime"] = v }
        if let v = exif.dateTimeOriginal { dict["DateTimeOriginal"] = v }
        if let v = exif.copyright { dict["Copyright"] = v }
        if let v = exif.artist { dict["Artist"] = v }
        if let v = exif.lensModel { dict["LensModel"] = v }
        if let v = exif.orientation { dict["Orientation"] = Int(v) }
        if let v = exif.isoSpeed { dict["ISO"] = Int(v) }

        if let v = exif.exposureTime {
            if v.denominator != 0 {
                dict["ExposureTime"] = "\(v.numerator)/\(v.denominator)"
            }
        }
        if let v = exif.fNumber {
            if v.denominator != 0 {
                dict["FNumber"] = Double(v.numerator) / Double(v.denominator)
            }
        }
        if let v = exif.focalLength {
            if v.denominator != 0 {
                dict["FocalLength"] = Double(v.numerator) / Double(v.denominator)
            }
        }

        // Numeric Exif fields (raw values for PrintConverter)
        if let entry = exif.exifIFD?.entry(for: ExifTag.exposureProgram),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ExposureProgram"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.meteringMode),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["MeteringMode"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.flash),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["Flash"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.colorSpace),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ColorSpace"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.whiteBalance),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["WhiteBalance"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.sceneCaptureType),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["SceneCaptureType"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.exposureMode),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ExposureMode"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.customRendered),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["CustomRendered"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.lightSource),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["LightSource"] = Int(v) }
        if let entry = exif.exifIFD?.entry(for: ExifTag.sensingMethod),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["SensingMethod"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: ExifTag.resolutionUnit),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["ResolutionUnit"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: ExifTag.compression),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["Compression"] = Int(v) }

        // Standard TIFF structural tags (present in TIFF/DNG/RAW IFD0).
        if let entry = exif.ifd0?.entry(for: ExifTag.bitsPerSample),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["BitsPerSample"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: ExifTag.photometricInterpretation),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["PhotometricInterpretation"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: ExifTag.samplesPerPixel),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["SamplesPerPixel"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: 0x011C),
           let v = entry.uint16Value(endian: exif.byteOrder) { dict["PlanarConfiguration"] = Int(v) }
        if let entry = exif.ifd0?.entry(for: 0x00FE),
           let v = entry.uint32Value(endian: exif.byteOrder) { dict["SubfileType"] = Int(v) }

        if let lat = exif.gpsLatitude { dict["GPSLatitude"] = lat }
        if let lon = exif.gpsLongitude { dict["GPSLongitude"] = lon }
        if let alt = exif.gpsAltitude { dict["GPSAltitude"] = alt }

        // Additional Exif fields
        if let w = exif.pixelXDimension { dict["PixelXDimension"] = Int(w) }
        if let h = exif.pixelYDimension { dict["PixelYDimension"] = Int(h) }
        if let fl35 = exif.focalLengthIn35mmFilm { dict["FocalLengthIn35mmFilm"] = Int(fl35) }
        if let lm = exif.lensMake { dict["LensMake"] = lm }

        // DateTimeDigitized
        if let entry = exif.exifIFD?.entry(for: ExifTag.dateTimeDigitized),
           let v = entry.stringValue(endian: exif.byteOrder) {
            dict["DateTimeDigitized"] = v
        }

        // SubSecond time tags
        if let v = exif.subSecTime { dict["SubSecTime"] = v }
        if let v = exif.subSecTimeOriginal { dict["SubSecTimeOriginal"] = v }
        if let v = exif.subSecTimeDigitized { dict["SubSecTimeDigitized"] = v }

        // Timezone offset tags (EXIF 2.31+)
        if let v = exif.offsetTime { dict["OffsetTime"] = v }
        if let v = exif.offsetTimeOriginal { dict["OffsetTimeOriginal"] = v }
        if let v = exif.offsetTimeDigitized { dict["OffsetTimeDigitized"] = v }

        // Image dimensions
        if let entry = exif.ifd0?.entry(for: ExifTag.imageWidth) {
            if let v = entry.uint32Value(endian: exif.byteOrder) { dict["ImageWidth"] = Int(v) }
            else if let v = entry.uint16Value(endian: exif.byteOrder) { dict["ImageWidth"] = Int(v) }
        }
        if let entry = exif.ifd0?.entry(for: ExifTag.imageHeight) {
            if let v = entry.uint32Value(endian: exif.byteOrder) { dict["ImageHeight"] = Int(v) }
            else if let v = entry.uint16Value(endian: exif.byteOrder) { dict["ImageHeight"] = Int(v) }
        }

        // Lens & body identity (ExifTool emits these under EXIF group)
        if let v = exif.bodySerialNumber { dict["SerialNumber"] = v }
        if let v = exif.lensSerialNumber { dict["LensSerialNumber"] = v }
        if let v = exif.cameraOwnerName { dict["CameraOwnerName"] = v }

        // LensSpecification (tag 0xA432): four rationals (minFL, maxFL, minF, maxF).
        // ExifTool labels this "LensInfo" and renders it as "70-200mm f/2.8".
        if let entry = exif.exifIFD?.entry(for: ExifTag.lensSpecification),
           entry.type == .rational, entry.count >= 4 {
            var reader = BinaryReader(data: entry.valueData)
            var rats: [(UInt32, UInt32)] = []
            for _ in 0..<4 {
                guard let n = try? reader.readUInt32(endian: exif.byteOrder),
                      let d = try? reader.readUInt32(endian: exif.byteOrder) else { break }
                rats.append((n, d))
            }
            if rats.count == 4 {
                func fmt(_ r: (UInt32, UInt32)) -> String {
                    if r.1 == 0 { return "?" }
                    let v = Double(r.0) / Double(r.1)
                    if v == v.rounded() { return String(format: "%g", v) }
                    // %.10g preserves enough precision for Apple's high-resolution
                    // rationals (e.g. iPhone front camera reports 2.690000057mm).
                    return String(format: "%.10g", v)
                }
                let minFL = fmt(rats[0]); let maxFL = fmt(rats[1])
                let minF  = fmt(rats[2]); let maxF  = fmt(rats[3])
                let flStr = (minFL == maxFL) ? "\(minFL)mm" : "\(minFL)-\(maxFL)mm"
                let fStr  = (minF  == maxF)  ? "f/\(minF)"  : "f/\(minF)-\(maxF)"
                dict["LensInfo"] = "\(flStr) \(fStr)"
            }
        }
    }

    // MARK: - IPTC Fields

    private static func addIPTCFields(_ dict: inout [String: Any], _ iptc: IPTCData) {
        if let v = iptc.headline { dict["IPTC:Headline"] = v }
        if let v = iptc.caption { dict["IPTC:Caption-Abstract"] = v }
        if let v = iptc.byline { dict["IPTC:By-line"] = v }
        if let v = iptc.credit { dict["IPTC:Credit"] = v }
        if let v = iptc.source { dict["IPTC:Source"] = v }
        if let v = iptc.copyright { dict["IPTC:CopyrightNotice"] = v }
        if let v = iptc.city { dict["IPTC:City"] = v }
        if let v = iptc.sublocation { dict["IPTC:Sub-location"] = v }
        if let v = iptc.provinceState { dict["IPTC:Province-State"] = v }
        if let v = iptc.countryCode { dict["IPTC:Country-PrimaryLocationCode"] = v }
        if let v = iptc.countryName { dict["IPTC:Country-PrimaryLocationName"] = v }
        if let v = iptc.dateCreated { dict["IPTC:DateCreated"] = v }
        if let v = iptc.timeCreated { dict["IPTC:TimeCreated"] = v }
        if let v = iptc.specialInstructions { dict["IPTC:SpecialInstructions"] = v }
        if let v = iptc.objectName { dict["IPTC:ObjectName"] = v }
        if let v = iptc.writerEditor { dict["IPTC:Writer-Editor"] = v }
        if let v = iptc.jobId { dict["IPTC:OriginalTransmissionReference"] = v }
        if let v = iptc.bylineTitle { dict["IPTC:By-lineTitle"] = v }
        if let v = iptc.category { dict["IPTC:Category"] = v }
        if let v = iptc.editStatus { dict["IPTC:EditStatus"] = v }
        if let v = iptc.languageIdentifier { dict["IPTC:LanguageIdentifier"] = v }
        if let v = iptc.releaseDate { dict["IPTC:ReleaseDate"] = v }
        if let v = iptc.releaseTime { dict["IPTC:ReleaseTime"] = v }
        if let v = iptc.expirationDate { dict["IPTC:ExpirationDate"] = v }
        if let v = iptc.expirationTime { dict["IPTC:ExpirationTime"] = v }
        if let v = iptc.urgency { dict["IPTC:Urgency"] = v }

        let keywords = iptc.keywords
        if !keywords.isEmpty { dict["IPTC:Keywords"] = keywords }

        let bylines = iptc.bylines
        if bylines.count > 1 { dict["IPTC:By-line"] = bylines }

        let bylineTitles = iptc.bylineTitles
        if bylineTitles.count > 1 { dict["IPTC:By-lineTitle"] = bylineTitles }

        let categories = iptc.supplementalCategories
        if !categories.isEmpty { dict["IPTC:SupplementalCategories"] = categories }

        let contacts = iptc.contacts
        if !contacts.isEmpty { dict["IPTC:Contact"] = contacts }

        // Record 3 (News Photo) — wire-service / NewsML photo descriptors.
        if let v = iptc.iptcImageWidth { dict["IPTC:IPTCImageWidth"] = v }
        if let v = iptc.iptcImageHeight { dict["IPTC:IPTCImageHeight"] = v }
        if let v = iptc.iptcPixelWidth { dict["IPTC:IPTCPixelWidth"] = v }
        if let v = iptc.iptcPixelHeight { dict["IPTC:IPTCPixelHeight"] = v }
        if let v = iptc.supplementalType { dict["IPTC:SupplementalType"] = v }
        if let v = iptc.colorRepresentation { dict["IPTC:ColorRepresentation"] = v }
        if let v = iptc.interchangeColorSpace { dict["IPTC:InterchangeColorSpace"] = v }
        if let v = iptc.colorSequence { dict["IPTC:ColorSequence"] = v }
        if let v = iptc.iptcBitsPerSample { dict["IPTC:IPTCBitsPerSample"] = v }
        if let v = iptc.sampleStructure { dict["IPTC:SampleStructure"] = v }
        if let v = iptc.iptcImageRotation { dict["IPTC:IPTCImageRotation"] = v }
        if let v = iptc.dataCompressionMethod { dict["IPTC:DataCompressionMethod"] = v }
        if let v = iptc.bitsPerComponent { dict["IPTC:BitsPerComponent"] = v }
        if let v = iptc.iccProfileData { dict["IPTC:ICC_ProfileSize"] = v.count }

        // Record 7 (ObjectData preview) and Record 8 (Post-ObjectData trailer).
        if let v = iptc.objectDataPreviewFileFormat { dict["IPTC:ObjectPreviewFileFormat"] = v }
        if let v = iptc.objectDataPreviewFileFormatVersion { dict["IPTC:ObjectPreviewFileVersion"] = v }
        if let v = iptc.objectDataPreviewData { dict["IPTC:ObjectPreviewSize"] = v.count }
        if let v = iptc.confirmedDataSize { dict["IPTC:ConfirmedObjectSize"] = v }
    }

    // MARK: - XMP Fields

    private static func addXMPFields(_ dict: inout [String: Any], _ xmp: XMPData) {
        for key in xmp.allKeys.sorted() {
            guard let (prefix, localName) = resolveXMPKey(key) else { continue }
            let exportKey = "XMP-\(prefix):\(capitalizingFirst(localName))"

            if let value = xmp.value(namespace: extractNamespace(from: key), property: localName) {
                switch value {
                case .simple(let s):
                    dict[exportKey] = s
                case .array(let items):
                    dict[exportKey] = items
                case .langAlternative(let s):
                    dict[exportKey] = s
                case .languageAlternative(let items):
                    dict[exportKey] = items.map { ["language": $0.language, "value": $0.value] }
                case .structure(let fields):
                    dict[exportKey] = renderStructFields(fields)
                case .structuredArray(let items):
                    dict[exportKey] = items.map(renderStructFields)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func describeTRC(_ trc: ICCToneCurve) -> String {
        switch trc {
        case .identity:
            return "Identity"
        case .gamma(let g):
            return String(format: "Gamma %.4f", g)
        case .table(let n):
            return "Table (\(n) samples)"
        case .parametric(let fn):
            return "Parametric (function \(fn))"
        }
    }

    private static func describeLUT(_ lut: ICCLUTSummary) -> String {
        "\(lut.kind.rawValue) \(lut.inputChannels)→\(lut.outputChannels)"
    }

    private static func formatName(_ format: ImageFormat) -> String {
        switch format {
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        case .raw(let r): return r.rawValue.uppercased()
        case .jpegXL: return "JXL"
        case .png: return "PNG"
        case .avif: return "AVIF"
        case .heif: return "HEIF"
        case .webp: return "WebP"
        case .pdf: return "PDF"
        case .psd: return "PSD"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .svg: return "SVG"
        }
    }

    /// Render an XMP struct's fields as a JSON-friendly dictionary, recursively.
    /// Simple fields become strings; nested structures and arrays preserve their shape.
    private static func renderStructFields(_ fields: [String: XMPValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in fields {
            let key: String
            if let (prefix, ln) = resolveXMPKey(k) { key = "\(prefix):\(capitalizingFirst(ln))" }
            else { key = k }
            out[key] = renderXMPValue(v)
        }
        return out
    }

    /// ExifTool capitalizes the first character of XMP property local names
    /// (e.g. dc:creator → Creator). RDF allows either case; this matches
    /// ExifTool's output convention so downstream consumers see the same keys.
    private static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    private static func renderXMPValue(_ value: XMPValue) -> Any {
        switch value {
        case .simple(let s): return s
        case .langAlternative(let s): return s
        case .languageAlternative(let items):
            return items.map { ["language": $0.language, "value": $0.value] }
        case .array(let items): return items
        case .structure(let fields): return renderStructFields(fields)
        case .structuredArray(let items): return items.map(renderStructFields)
        }
    }

    private static func resolveXMPKey(_ key: String) -> (prefix: String, localName: String)? {
        for (ns, prefix) in XMPNamespace.prefixes.sorted(by: { $0.key.count > $1.key.count }) {
            if key.hasPrefix(ns) {
                let localName = String(key.dropFirst(ns.count))
                guard !localName.isEmpty && !localName.contains("/") else { continue }
                return (prefix, localName)
            }
        }
        return nil
    }

    private static func extractNamespace(from key: String) -> String {
        for ns in XMPNamespace.prefixes.keys.sorted(by: { $0.count > $1.count }) {
            if key.hasPrefix(ns) { return ns }
        }
        return ""
    }

    private static func escapeXMLTag(_ name: String) -> String {
        // Replace characters invalid in XML element names
        name.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func escapeXMLValue(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
