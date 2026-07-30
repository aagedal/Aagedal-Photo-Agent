import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SourceFactsAnalyzer: AnalysisAnalyzer {
    static let analyzerIdentifier = "source-facts-metadata"

    let identifier = Self.analyzerIdentifier
    let version = 1
    let displayName = "Source facts and metadata"
    let cost = AnalysisAnalyzerCost.fast
    let sourceRepresentation = AnalysisInputRepresentation.originalBytes

    private let readService = SwiftExifReadService()

    func analyze(
        context: AnalysisAnalyzerContext,
        parameters: [String: String],
        progress: @MainActor @Sendable (Double) -> Void
    ) async throws -> AnalysisAnalyzerOutput {
        progress(0.05)
        let draft = try await Task.detached(priority: .userInitiated) {
            try SourceFactsExtractor.extract(
                at: context.sourceURL,
                revision: context.sourceRevision
            )
        }.value
        try Task.checkCancellation()
        progress(0.35)

        async let technicalRead = readService.readTechnicalMetadata(url: context.sourceURL)
        async let descriptiveRead = readService.readFullMetadata(url: context.sourceURL)
        let (technical, descriptive) = try await (technicalRead, descriptiveRead)
        try Task.checkCancellation()
        progress(0.62)

        let c2paIsPresent = technical.hasC2PA
        let validation: C2PAValidationResult
        if !c2paIsPresent {
            validation = C2PAValidationResult(
                status: .notPresent,
                message: "No C2PA manifest was found."
            )
        } else if C2PASigningService.isAvailable {
            do {
                validation = try await C2PASigningService.validate(imageURL: context.sourceURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                validation = C2PAValidationResult(
                    status: .validationFailed,
                    message: "C2PA validation could not complete: \(error.localizedDescription)"
                )
            }
        } else {
            validation = .unavailable
        }
        try Task.checkCancellation()
        progress(0.80)

        let c2paEvidence = AnalysisC2PAEvidence(
            isPresent: c2paIsPresent,
            result: validation
        )
        let gpsTimestamp = draft.rawMetadata.first {
            let key = $0.key.lowercased()
            return key.contains("gpstimestamp") || key.contains("gpsdatestamp")
        }?.value
        let captureDate = descriptive.captureDate ?? technical.captureDate

        let facts = AnalysisSourceFacts(
            filename: draft.filename,
            canonicalPath: draft.canonicalPath,
            sha256: context.sourceRevision.sha256,
            byteCount: context.sourceRevision.byteCount,
            fileExtension: draft.fileExtension,
            detectedTypeIdentifier: draft.detectedTypeIdentifier,
            detectedMIMEType: draft.detectedMIMEType,
            pixelWidth: technical.imageWidth ?? draft.pixelWidth,
            pixelHeight: technical.imageHeight ?? draft.pixelHeight,
            orientation: draft.orientation,
            bitDepth: technical.bitDepth ?? draft.bitDepth,
            hasAlpha: draft.hasAlpha,
            colorProfile: technical.colorSpace ?? draft.colorProfile,
            frameCount: draft.frameCount,
            isAnimated: draft.frameCount > 1,
            isHDR: draft.isHDR,
            fileCreationDate: draft.fileCreationDate,
            fileModificationDate: draft.fileModificationDate,
            captureDate: captureDate,
            captureTimezoneKnown: Self.hasExplicitTimezone(captureDate),
            camera: technical.camera,
            lens: technical.lens,
            focalLength: technical.focalLength,
            aperture: technical.aperture,
            shutterSpeed: technical.shutterSpeed,
            iso: technical.iso,
            serialNumber: technical.serialNumber,
            software: technical.software,
            latitude: descriptive.latitude,
            longitude: descriptive.longitude,
            gpsTimestamp: gpsTimestamp,
            digitalSourceType: descriptive.digitalSourceType,
            sidecarPath: draft.sidecarPath,
            sidecarModificationDate: draft.sidecarModificationDate,
            c2pa: c2paEvidence
        )

        let findings = MetadataConsistencyRuleEngine.evaluate(
            facts: facts,
            rawMetadata: draft.rawMetadata,
            analyzerID: identifier,
            analyzerVersion: version
        )
        progress(1)
        return AnalysisAnalyzerOutput(
            sourceFacts: facts,
            rawMetadata: draft.rawMetadata,
            findings: findings
        )
    }

    nonisolated private static func hasExplicitTimezone(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(
            of: #"(Z|[+-]\d{2}:?\d{2})$"#,
            options: .regularExpression
        ) != nil
    }
}

nonisolated private enum SourceFactsExtractor {
    struct Draft: Sendable {
        let filename: String
        let canonicalPath: String
        let fileExtension: String
        let detectedTypeIdentifier: String?
        let detectedMIMEType: String?
        let pixelWidth: Int?
        let pixelHeight: Int?
        let orientation: Int?
        let bitDepth: Int?
        let hasAlpha: Bool?
        let colorProfile: String?
        let frameCount: Int
        let isHDR: Bool
        let fileCreationDate: Date?
        let fileModificationDate: Date?
        let sidecarPath: String?
        let sidecarModificationDate: Date?
        let rawMetadata: [AnalysisRawMetadataEntry]
    }

    static func extract(at url: URL, revision: SourceImageRevision) throws -> Draft {
        try Task.checkCancellation()
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: canonicalURL.path)
        let source = CGImageSourceCreateWithURL(canonicalURL as CFURL, nil)
        let properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any]
        } ?? [:]
        let typeIdentifier = source.flatMap { CGImageSourceGetType($0) as String? }
        let type = typeIdentifier.flatMap(UTType.init)
        let sidecarURL = canonicalURL.deletingPathExtension().appendingPathExtension("xmp")
        let sidecarAttributes = try? FileManager.default.attributesOfItem(atPath: sidecarURL.path)
        let sidecarExists = sidecarAttributes != nil

        var entries = rawEntries(from: properties)
        entries.append(AnalysisRawMetadataEntry(
            id: "filesystem.filename",
            namespace: "File System",
            key: "Filename",
            value: canonicalURL.lastPathComponent,
            origin: .fileSystem
        ))
        entries.append(AnalysisRawMetadataEntry(
            id: "filesystem.byte-count",
            namespace: "File System",
            key: "ByteCount",
            value: String(revision.byteCount),
            origin: .fileSystem
        ))
        if sidecarExists {
            entries.append(AnalysisRawMetadataEntry(
                id: "sidecar.path",
                namespace: "XMP Sidecar",
                key: "Path",
                value: sidecarURL.path,
                origin: .sidecar
            ))
        }

        return Draft(
            filename: canonicalURL.lastPathComponent,
            canonicalPath: canonicalURL.path,
            fileExtension: canonicalURL.pathExtension.lowercased(),
            detectedTypeIdentifier: typeIdentifier,
            detectedMIMEType: type?.preferredMIMEType,
            pixelWidth: integer(properties[kCGImagePropertyPixelWidth as String]),
            pixelHeight: integer(properties[kCGImagePropertyPixelHeight as String]),
            orientation: integer(properties[kCGImagePropertyOrientation as String]),
            bitDepth: integer(properties[kCGImagePropertyDepth as String]),
            hasAlpha: boolean(properties[kCGImagePropertyHasAlpha as String]),
            colorProfile: properties[kCGImagePropertyProfileName as String] as? String,
            frameCount: source.map(CGImageSourceGetCount) ?? 0,
            isHDR: SupportedImageFormats.isHDR(url: canonicalURL),
            fileCreationDate: attributes[.creationDate] as? Date,
            fileModificationDate: attributes[.modificationDate] as? Date,
            sidecarPath: sidecarExists ? sidecarURL.path : nil,
            sidecarModificationDate: sidecarAttributes?[.modificationDate] as? Date,
            rawMetadata: entries
        )
    }

    private static func rawEntries(
        from properties: [String: Any]
    ) -> [AnalysisRawMetadataEntry] {
        var pending: [(namespace: String, key: String, value: Any, origin: AnalysisMetadataOrigin)] = []

        for key in properties.keys.sorted() {
            guard let value = properties[key] else { continue }
            let descriptor = namespaceDescriptor(for: key)
            if let dictionary = value as? [String: Any], descriptor.origin != .container {
                appendLeaves(
                    dictionary,
                    namespace: descriptor.namespace,
                    prefix: "",
                    origin: descriptor.origin,
                    to: &pending
                )
            } else {
                appendValue(
                    value,
                    namespace: "Container",
                    key: key,
                    origin: .container,
                    to: &pending
                )
            }
        }

        return pending.enumerated().map { index, item in
            AnalysisRawMetadataEntry(
                id: "\(item.origin.rawValue).\(item.namespace).\(item.key).\(index)",
                namespace: item.namespace,
                key: item.key,
                value: stringValue(item.value),
                origin: item.origin
            )
        }
    }

    private static func appendLeaves(
        _ dictionary: [String: Any],
        namespace: String,
        prefix: String,
        origin: AnalysisMetadataOrigin,
        to pending: inout [(namespace: String, key: String, value: Any, origin: AnalysisMetadataOrigin)]
    ) {
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key] else { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                appendLeaves(
                    nested,
                    namespace: namespace,
                    prefix: path,
                    origin: origin,
                    to: &pending
                )
            } else {
                appendValue(
                    value,
                    namespace: namespace,
                    key: path,
                    origin: origin,
                    to: &pending
                )
            }
        }
    }

    private static func appendValue(
        _ value: Any,
        namespace: String,
        key: String,
        origin: AnalysisMetadataOrigin,
        to pending: inout [(namespace: String, key: String, value: Any, origin: AnalysisMetadataOrigin)]
    ) {
        pending.append((namespace, key, value, origin))
    }

    private static func namespaceDescriptor(
        for key: String
    ) -> (namespace: String, origin: AnalysisMetadataOrigin) {
        if key == (kCGImagePropertyExifDictionary as String) { return ("EXIF", .exif) }
        if key == (kCGImagePropertyTIFFDictionary as String) { return ("TIFF", .tiff) }
        if key == (kCGImagePropertyIPTCDictionary as String) { return ("IPTC", .iptc) }
        if key == (kCGImagePropertyGPSDictionary as String) { return ("GPS", .gps) }
        if key == (kCGImagePropertyJFIFDictionary as String) { return ("JFIF", .jfif) }
        if key == (kCGImagePropertyPNGDictionary as String) { return ("PNG", .png) }
        return (key, key.lowercased().contains("xmp") ? .xmp : .container)
    }

    private static func stringValue(_ value: Any) -> String {
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let array = value as? [Any] {
            return array.map(stringValue).joined(separator: ", ")
        }
        if let data = value as? Data {
            return "<\(data.count) bytes>"
        }
        return String(describing: value)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}

nonisolated enum MetadataConsistencyRuleEngine {
    static func evaluate(
        facts: AnalysisSourceFacts,
        rawMetadata: [AnalysisRawMetadataEntry],
        analyzerID: String,
        analyzerVersion: Int,
        now: Date = Date()
    ) -> [AnalysisFinding] {
        var findings: [AnalysisFinding] = []

        func finding(
            _ id: String,
            category: AnalysisFindingCategory = .metadata,
            severity: AnalysisFindingSeverity,
            evidenceClass: AnalysisEvidenceClass = .fact,
            title: String,
            explanation: String,
            technicalDetail: String,
            alternatives: [String] = []
        ) -> AnalysisFinding {
            AnalysisFinding(
                id: id,
                analyzerID: analyzerID,
                analyzerVersion: analyzerVersion,
                category: category,
                severity: severity,
                evidenceClass: evidenceClass,
                title: title,
                explanation: explanation,
                technicalDetail: technicalDetail,
                alternatives: alternatives,
                confidence: 1,
                sourceRepresentation: .originalBytes,
                computedAt: now,
                includeInReport: true
            )
        }

        if let mime = facts.detectedMIMEType,
           !extensionMatches(facts.fileExtension, mime: mime) {
            findings.append(finding(
                "metadata.extension-container-mismatch",
                category: .encoding,
                severity: .caution,
                title: "Filename extension and detected container differ",
                explanation: "The file's extension does not match the container identified from its bytes.",
                technicalDetail: "Extension: .\(facts.fileExtension); detected MIME type: \(mime).",
                alternatives: [
                    "A file can be renamed without changing its contents.",
                    "Transport or publishing systems sometimes assign an incorrect extension.",
                ]
            ))
        }

        if facts.camera != nil, facts.captureDate == nil {
            findings.append(finding(
                "metadata.camera-without-capture-time",
                severity: .notable,
                title: "Camera information is present without a capture time",
                explanation: "The file identifies a camera but does not provide an available capture timestamp.",
                technicalDetail: "Camera: \(facts.camera ?? "unknown"); capture timestamp: absent.",
                alternatives: ["Metadata may have been selectively stripped or omitted by the camera or export software."]
            ))
        }

        if facts.captureTimezoneKnown,
           let captureDate = parseCaptureDate(facts.captureDate),
           let modificationDate = facts.fileModificationDate,
           captureDate > modificationDate {
            findings.append(finding(
                "metadata.capture-after-file-modification",
                category: .time,
                severity: .caution,
                title: "Capture time is later than file modification time",
                explanation: "The timezone-qualified capture timestamp occurs after the file-system modification timestamp.",
                technicalDetail: "Capture: \(facts.captureDate ?? "unknown"); file modification: \(modificationDate.ISO8601Format()).",
                alternatives: ["File-system clocks, restored timestamps, or an incorrect camera clock can produce this order."]
            ))
        }

        if facts.latitude != nil, facts.longitude != nil, facts.gpsTimestamp == nil {
            findings.append(finding(
                "metadata.gps-without-time",
                category: .location,
                severity: .informational,
                title: "GPS coordinates have no GPS timestamp",
                explanation: "Coordinates are embedded, but no separate GPS date or time was found.",
                technicalDetail: "Latitude and longitude are present; GPSDateStamp/GPSTimeStamp are absent.",
                alternatives: ["Many cameras and phones legitimately omit a separate GPS timestamp."]
            ))
        }

        if let software = facts.software, !software.isEmpty {
            findings.append(finding(
                "metadata.editing-software",
                severity: .informational,
                title: "Software is recorded in metadata",
                explanation: "The file records software that created or processed this representation.",
                technicalDetail: "Software: \(software).",
                alternatives: ["Software metadata does not by itself establish deceptive manipulation."]
            ))
        }

        if let sourceType = facts.digitalSourceType {
            let isSynthetic = sourceType == .trainedAlgorithmicMedia
                || sourceType == .compositeSynthetic
                || sourceType == .compositeWithTrainedAlgorithmicMedia
                || sourceType == .compositeCapture
            findings.append(finding(
                "metadata.digital-source-type",
                category: .provenance,
                severity: isSynthetic ? .notable : .informational,
                title: "The file declares \(sourceType.displayName)",
                explanation: "IPTC Digital Source Type is an explicit provenance declaration stored with the file.",
                technicalDetail: "DigitalSourceType: \(sourceType.rawValue).",
                alternatives: ["The declaration reports what the metadata says; analysis does not independently prove that declaration."]
            ))
        }

        if facts.c2pa.isPresent {
            let severity: AnalysisFindingSeverity = facts.c2pa.validity == .invalid
                ? .caution
                : (facts.c2pa.trust == .untrusted ? .notable : .informational)
            findings.append(finding(
                "provenance.c2pa-manifest",
                category: .provenance,
                severity: severity,
                title: "C2PA manifest is present",
                explanation: "Credential validity and signer trust are reported separately; one is not substituted for the other.",
                technicalDetail: "Validity: \(facts.c2pa.validity.rawValue); trust: \(facts.c2pa.trust.rawValue); validator status: \(facts.c2pa.validationStatus.rawValue). \(facts.c2pa.message)",
                alternatives: ["A missing or untrusted credential does not establish that image pixels are inauthentic."]
            ))
        }

        if facts.camera == nil {
            findings.append(finding(
                "metadata.no-camera-information",
                severity: .informational,
                title: "No camera information was found",
                explanation: "The available metadata does not identify a camera body.",
                technicalDetail: "Camera make and model were absent from the parsed metadata.",
                alternatives: [
                    "Messaging, publishing, screenshot, scanning, and export workflows commonly remove or never create camera metadata."
                ]
            ))
        }

        if facts.fileExtension == "png", facts.camera != nil {
            findings.append(finding(
                "metadata.png-with-camera-information",
                category: .encoding,
                severity: .notable,
                title: "PNG contains camera-style metadata",
                explanation: "The PNG container also carries camera-identifying metadata.",
                technicalDetail: "Container: PNG; camera: \(facts.camera ?? "unknown").",
                alternatives: ["Edited photographs and conversion workflows can legitimately preserve EXIF when exporting PNG."]
            ))
        }

        findings.append(contentsOf: conflictFindings(
            rawMetadata,
            analyzerID: analyzerID,
            analyzerVersion: analyzerVersion,
            now: now
        ))
        return findings.sorted { $0.id < $1.id }
    }

    private static func extensionMatches(_ fileExtension: String, mime: String) -> Bool {
        let accepted: [String: Set<String>] = [
            "image/jpeg": ["jpg", "jpeg"],
            "image/png": ["png"],
            "image/tiff": ["tif", "tiff"],
            "image/heic": ["heic"],
            "image/heif": ["heif", "heic"],
            "image/gif": ["gif"],
            "image/webp": ["webp"],
            "image/avif": ["avif"],
            "image/jxl": ["jxl"],
            "image/bmp": ["bmp"],
        ]
        guard let extensions = accepted[mime.lowercased()] else { return true }
        return extensions.contains(fileExtension.lowercased())
    }

    private static func parseCaptureDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        for format in ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ssXX"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func conflictFindings(
        _ entries: [AnalysisRawMetadataEntry],
        analyzerID: String,
        analyzerVersion: Int,
        now: Date
    ) -> [AnalysisFinding] {
        let grouped = Dictionary(grouping: entries) { semanticField(for: $0.key) }
        return grouped.compactMap { semantic, values in
            guard let semantic,
                  Set(values.map(\.namespace)).count > 1,
                  Set(values.map { normalizedValue($0.value) }).count > 1
            else { return nil }
            let detail = values
                .map { "\($0.namespace).\($0.key) = \($0.value)" }
                .sorted()
                .joined(separator: "; ")
            return AnalysisFinding(
                id: "metadata.namespace-conflict.\(semantic)",
                analyzerID: analyzerID,
                analyzerVersion: analyzerVersion,
                category: .metadata,
                severity: semantic == "orientation" || semantic.hasPrefix("dimension")
                    ? .caution
                    : .notable,
                evidenceClass: .fact,
                title: "Metadata namespaces disagree on \(semantic.replacingOccurrences(of: "-", with: " "))",
                explanation: "More than one metadata namespace carries a different value for the same field.",
                technicalDetail: detail,
                alternatives: ["Different applications may update one namespace while leaving another unchanged."],
                confidence: 1,
                sourceRepresentation: .originalBytes,
                computedAt: now,
                includeInReport: true
            )
        }
    }

    private static func semanticField(for key: String) -> String? {
        let key = key.lowercased()
        if key.contains("datetimeoriginal") || key.hasSuffix("createdate") { return "capture-time" }
        if key.hasSuffix("orientation") { return "orientation" }
        if key.contains("pixelxdimension") || key.hasSuffix("imagewidth") || key.hasSuffix("pixelwidth") {
            return "dimension-width"
        }
        if key.contains("pixelydimension") || key.hasSuffix("imageheight") || key.hasSuffix("pixelheight") {
            return "dimension-height"
        }
        if key.hasSuffix("software") || key.hasSuffix("creatortool") { return "software" }
        return nil
    }

    private static func normalizedValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
