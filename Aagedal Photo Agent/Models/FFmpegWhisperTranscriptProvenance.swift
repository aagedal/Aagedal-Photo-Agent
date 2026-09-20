import Foundation

/// Immutable evidence about the exact inference request. A hash is identity, not authorization.
nonisolated struct FFmpegWhisperTranscriptProvenance: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let buildIdentifier: String
    let executableSHA256: String
    let executableByteCount: Int64
    let modelIdentifier: String
    let modelSHA256: String
    let modelByteCount: Int64
    let requestedLanguage: String
    let useGPU: Bool
    let translate: Bool
    let segments: [Segment]

    // The attributed FFmpeg JSON emitter supplies no detected-language evidence.
    var detectedLanguage: String? { nil }

    struct Segment: Codable, Equatable, Sendable {
        let start: Int64
        let end: Int64
        let text: String

        var startMilliseconds: Int64 { start }
        var endMilliseconds: Int64 { end }

        init(start: Int64, end: Int64, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        private enum CodingKeys: String, CodingKey { case start, end, text }

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: ProvenanceKey.self)
            guard Set(raw.allKeys.map(\.stringValue)) == Set(["start", "end", "text"]) else {
                throw ValidationError.invalidProvenance
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            start = try values.decode(Int64.self, forKey: .start)
            end = try values.decode(Int64.self, forKey: .end)
            text = try values.decode(String.self, forKey: .text)
        }
    }

    enum ValidationError: Error, Equatable, Sendable { case invalidProvenance }

    init(schemaVersion: Int = 1, buildIdentifier: String, executableSHA256: String,
         executableByteCount: Int64, modelIdentifier: String, modelSHA256: String,
         modelByteCount: Int64, requestedLanguage: String, useGPU: Bool, segments: [Segment]) {
        self.schemaVersion = schemaVersion
        self.buildIdentifier = buildIdentifier
        self.executableSHA256 = executableSHA256
        self.executableByteCount = executableByteCount
        self.modelIdentifier = modelIdentifier
        self.modelSHA256 = modelSHA256
        self.modelByteCount = modelByteCount
        self.requestedLanguage = requestedLanguage
        self.useGPU = useGPU
        self.translate = false
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, buildIdentifier, executableSHA256, executableByteCount
        case modelIdentifier, modelSHA256, modelByteCount, requestedLanguage, useGPU, translate, segments
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: ProvenanceKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw ValidationError.invalidProvenance
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        buildIdentifier = try values.decode(String.self, forKey: .buildIdentifier)
        executableSHA256 = try values.decode(String.self, forKey: .executableSHA256)
        executableByteCount = try values.decode(Int64.self, forKey: .executableByteCount)
        modelIdentifier = try values.decode(String.self, forKey: .modelIdentifier)
        modelSHA256 = try values.decode(String.self, forKey: .modelSHA256)
        modelByteCount = try values.decode(Int64.self, forKey: .modelByteCount)
        requestedLanguage = try values.decode(String.self, forKey: .requestedLanguage)
        useGPU = try values.decode(Bool.self, forKey: .useGPU)
        translate = try values.decode(Bool.self, forKey: .translate)
        segments = try values.decode([Segment].self, forKey: .segments)
        try validate()
    }

    var editableText: String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "[blank_audio]" }
            .joined(separator: " ")
    }

    func validate() throws {
        let hashes = [executableSHA256, modelSHA256]
        guard schemaVersion == 1, !translate,
              !buildIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              buildIdentifier.utf8.count <= 1024, modelIdentifier.utf8.count <= 1024,
              executableByteCount > 0, executableByteCount <= 512 * 1024 * 1024,
              modelByteCount > 0, modelByteCount <= Int64(4) * 1024 * 1024 * 1024,
              hashes.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (97...102).contains($0)
              } }),
              requestedLanguage == "auto" || (requestedLanguage.utf8.count == 2 &&
                  requestedLanguage.utf8.allSatisfy { (97...122).contains($0) }),
              !segments.isEmpty, segments.count <= 20_000 else {
            throw ValidationError.invalidProvenance
        }
        var previous: Int64 = 0
        var total = 0
        for segment in segments {
            guard segment.start >= previous, segment.end >= segment.start,
                  segment.text.utf8.count <= 64 * 1024 else {
                throw ValidationError.invalidProvenance
            }
            previous = segment.start
            total += segment.text.utf8.count
            guard total <= 8 * 1024 * 1024 else {
                throw ValidationError.invalidProvenance
            }
        }
    }
}


private nonisolated struct ProvenanceKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
