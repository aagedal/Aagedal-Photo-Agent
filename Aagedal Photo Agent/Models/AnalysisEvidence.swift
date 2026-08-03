import Foundation

nonisolated enum AnalysisEvidenceClass: String, Codable, CaseIterable, Sendable {
    case fact
    case derivedObservation
    case heuristic
    case userAssertion
    case unavailable
}

nonisolated enum AnalysisFindingCategory: String, Codable, CaseIterable, Sendable {
    case source
    case provenance
    case metadata
    case encoding
    case pixels
    case time
    case location
    case limitation
}

nonisolated enum AnalysisFindingSeverity: String, Codable, CaseIterable, Sendable {
    case informational
    case notable
    case caution
}

nonisolated enum AnalysisInputRepresentation: String, Codable, Sendable {
    case originalBytes
    case decodedOriginal
    case developedRendering
}

nonisolated struct AnalysisFinding: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let analyzerID: String
    let analyzerVersion: Int
    let category: AnalysisFindingCategory
    let severity: AnalysisFindingSeverity
    let evidenceClass: AnalysisEvidenceClass
    let title: String
    let explanation: String
    let technicalDetail: String
    let alternatives: [String]
    let confidence: Double?
    let sourceRepresentation: AnalysisInputRepresentation
    let computedAt: Date
    var includeInReport: Bool
}

nonisolated enum AnalysisMetadataOrigin: String, Codable, CaseIterable, Sendable {
    case container
    case exif
    case tiff
    case iptc
    case xmp
    case gps
    case jfif
    case png
    case fileSystem
    case sidecar
    case other
}

/// One raw metadata value with its namespace and origin intact.
///
/// Values are deliberately not keyed into a dictionary: multiple namespaces may carry
/// conflicting values for the same field and every one must survive analysis and reporting.
nonisolated struct AnalysisRawMetadataEntry: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let namespace: String
    let key: String
    let value: String
    let origin: AnalysisMetadataOrigin
}

nonisolated enum C2PAValidityState: String, Codable, Sendable {
    case absent
    case valid
    case invalid
    case unknown
}

nonisolated enum C2PATrustState: String, Codable, Sendable {
    case trusted
    case untrusted
    case notConfigured
    case notApplicable
    case unknown
}

/// C2PA cryptographic validity and signer trust are separate axes.
nonisolated struct AnalysisC2PAEvidence: Codable, Equatable, Sendable {
    let isPresent: Bool
    let validity: C2PAValidityState
    let trust: C2PATrustState
    let validationStatus: C2PAValidationStatus
    let signer: String?
    let issuer: String?
    let message: String
    let rawValidationCodes: [String]
    let trustSource: C2PATrustSource?

    init(isPresent: Bool, result: C2PAValidationResult) {
        self.isPresent = isPresent
        validationStatus = result.status
        signer = result.signer
        issuer = result.issuer
        message = result.message
        rawValidationCodes = result.rawValidationCodes
        trustSource = result.trustSource

        switch result.status {
        case .trusted:
            validity = .valid
            trust = .trusted
        case .untrusted:
            validity = .valid
            trust = .untrusted
        case .trustNotConfigured:
            validity = .valid
            trust = .notConfigured
        case .invalid:
            validity = .invalid
            trust = .notApplicable
        case .notPresent:
            validity = .absent
            trust = .notApplicable
        case .unsupported, .validationFailed:
            validity = isPresent ? .unknown : .absent
            trust = isPresent ? .unknown : .notApplicable
        }
    }
}

nonisolated struct AnalysisSourceFacts: Codable, Equatable, Sendable {
    let filename: String
    let canonicalPath: String
    let sha256: String
    let byteCount: Int64
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
    let isAnimated: Bool
    let isHDR: Bool
    let fileCreationDate: Date?
    let fileModificationDate: Date?
    let captureDate: String?
    let captureTimezoneKnown: Bool
    let camera: String?
    let lens: String?
    let focalLength: String?
    let aperture: String?
    let shutterSpeed: String?
    let iso: String?
    let serialNumber: String?
    let software: String?
    let latitude: Double?
    let longitude: Double?
    let gpsTimestamp: String?
    let digitalSourceType: DigitalSourceType?
    let sidecarPath: String?
    let sidecarModificationDate: Date?
    var c2pa: AnalysisC2PAEvidence
}

nonisolated struct AnalysisAnalyzerOutput: Codable, Equatable, Sendable {
    var sourceFacts: AnalysisSourceFacts?
    var rawMetadata: [AnalysisRawMetadataEntry]
    var findings: [AnalysisFinding]

    init(
        sourceFacts: AnalysisSourceFacts? = nil,
        rawMetadata: [AnalysisRawMetadataEntry] = [],
        findings: [AnalysisFinding] = []
    ) {
        self.sourceFacts = sourceFacts
        self.rawMetadata = rawMetadata
        self.findings = findings
    }
}

nonisolated enum AnalysisAnalyzerRunStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed
}

nonisolated struct AnalysisAnalyzerRun: Identifiable, Codable, Equatable, Sendable {
    var id: String { analyzerID }

    let analyzerID: String
    let analyzerVersion: Int
    let cacheKey: String
    let sourceRepresentation: AnalysisInputRepresentation
    var status: AnalysisAnalyzerRunStatus
    var progress: Double
    var startedAt: Date?
    var completedAt: Date?
    var errorMessage: String?
    var output: AnalysisAnalyzerOutput?
}

nonisolated struct AnalysisCacheKey: Hashable, Sendable {
    let value: String

    init(
        sourceSHA256: String,
        analyzerID: String,
        analyzerVersion: Int,
        parameters: [String: String]
    ) {
        let serializedParameters = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        value = [
            "sha256:\(sourceSHA256)",
            analyzerID,
            "v\(analyzerVersion)",
            serializedParameters,
        ].joined(separator: "|")
    }
}
