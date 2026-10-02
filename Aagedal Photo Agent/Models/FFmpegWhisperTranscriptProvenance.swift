import Foundation

/// Language identifiers accepted by Whisper, shared by Settings and Caption.
nonisolated enum WhisperTranscriptionLanguage {
    struct Option: Identifiable, Sendable {
        let id: String
        let title: String
    }

    static let options: [Option] = {
        let names = "en:English|zh:Chinese|de:German|es:Spanish|ru:Russian|ko:Korean|fr:French|ja:Japanese|pt:Portuguese|tr:Turkish|pl:Polish|ca:Catalan|nl:Dutch|ar:Arabic|sv:Swedish|it:Italian|id:Indonesian|hi:Hindi|fi:Finnish|vi:Vietnamese|he:Hebrew|uk:Ukrainian|el:Greek|ms:Malay|cs:Czech|ro:Romanian|da:Danish|hu:Hungarian|ta:Tamil|no:Norwegian|th:Thai|ur:Urdu|hr:Croatian|bg:Bulgarian|lt:Lithuanian|la:Latin|mi:Maori|ml:Malayalam|cy:Welsh|sk:Slovak|te:Telugu|fa:Persian|lv:Latvian|bn:Bengali|sr:Serbian|az:Azerbaijani|sl:Slovenian|kn:Kannada|et:Estonian|mk:Macedonian|br:Breton|eu:Basque|is:Icelandic|hy:Armenian|ne:Nepali|mn:Mongolian|bs:Bosnian|kk:Kazakh|sq:Albanian|sw:Swahili|gl:Galician|mr:Marathi|pa:Punjabi|si:Sinhala|km:Khmer|sn:Shona|yo:Yoruba|so:Somali|af:Afrikaans|oc:Occitan|ka:Georgian|be:Belarusian|tg:Tajik|sd:Sindhi|gu:Gujarati|am:Amharic|yi:Yiddish|lo:Lao|uz:Uzbek|fo:Faroese|ht:Haitian Creole|ps:Pashto|tk:Turkmen|nn:Norwegian Nynorsk|mt:Maltese|sa:Sanskrit|lb:Luxembourgish|my:Myanmar|bo:Tibetan|tl:Tagalog|mg:Malagasy|as:Assamese|tt:Tatar|haw:Hawaiian|ln:Lingala|ha:Hausa|ba:Bashkir|jw:Javanese|su:Sundanese|yue:Cantonese"
        let languages = names.split(separator: "|").map { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            return Option(id: parts[0], title: parts[1])
        }
        let preferred = ["no", "nn"]
        return [Option(id: "auto", title: "Detect Automatically")]
            + preferred.compactMap { code in languages.first { $0.id == code } }
            + languages.filter { !preferred.contains($0.id) }.sorted { $0.title < $1.title }
    }()

    static func title(for code: String) -> String {
        options.first { $0.id == code }?.title
            ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func isValid(_ code: String) -> Bool {
        code == "auto" || code == "haw" || code == "yue"
            || (code.utf8.count == 2 && code.utf8.allSatisfy { (97...122).contains($0) })
    }
}


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

    init(schemaVersion: Int? = nil, buildIdentifier: String, executableSHA256: String,
         executableByteCount: Int64, modelIdentifier: String, modelSHA256: String,
         modelByteCount: Int64, requestedLanguage: String, useGPU: Bool, translate: Bool = false, segments: [Segment]) {
        // Schema 1 guarantees untranslated output. Older versions must fail closed when
        // opening translated evidence, rather than treating English text as the input language.
        self.schemaVersion = schemaVersion ?? (translate ? 2 : 1)
        self.buildIdentifier = buildIdentifier
        self.executableSHA256 = executableSHA256
        self.executableByteCount = executableByteCount
        self.modelIdentifier = modelIdentifier
        self.modelSHA256 = modelSHA256
        self.modelByteCount = modelByteCount
        self.requestedLanguage = requestedLanguage
        self.useGPU = useGPU
        self.translate = translate
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
        guard (schemaVersion == 1 && !translate) || (schemaVersion == 2 && translate),
              !buildIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              buildIdentifier.utf8.count <= 1024, modelIdentifier.utf8.count <= 1024,
              executableByteCount > 0, executableByteCount <= 512 * 1024 * 1024,
              modelByteCount > 0, modelByteCount <= Int64(4) * 1024 * 1024 * 1024,
              hashes.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (97...102).contains($0)
              } }),
              WhisperTranscriptionLanguage.isValid(requestedLanguage),
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
