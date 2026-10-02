import Foundation

/// Immutable native session evidence for one retained intent and its concrete provider.
/// This is deliberately not Codable or persisted. It grants no consent, root authority,
/// artifact trust or execution permission, and performs no readiness checks or effects.
nonisolated struct AutomationVoiceTranscriptionProviderBinding: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidIntent
        case invalidProvider
        case providerMismatch
        case intentMismatch
    }

    /// Classification comes from the native caller's explicit provider selection.
    /// A filename, path, identifier or hash never establishes curated trust.
    enum WhisperKind: Equatable, Sendable { case curated, custom }

    enum Identity: Equatable, Sendable {
        case apple(localeIdentifier: String)
        case whisper(kind: WhisperKind, configuration: FFmpegWhisperTranscriptionProvider.Configuration)
    }

    let intentSHA256: String
    let provider: AutomationVoiceTranscriptionBatchService.Provider
    let identity: Identity

    private init(intentSHA256: String, provider: AutomationVoiceTranscriptionBatchService.Provider,
                 identity: Identity) {
        self.intentSHA256 = intentSHA256
        self.provider = provider
        self.identity = identity
    }

    static func bind(intent: MCPVoiceTranscriptionReviewRequestStore.Intent,
                     provider: AutomationVoiceTranscriptionBatchService.Provider,
                     whisperKind: WhisperKind? = nil) throws -> Self {
        let options = try Options(intent: intent)
        let identity: Identity
        switch provider {
        case .apple(let locale):
            guard whisperKind == nil else { throw Failure.providerMismatch }
            guard options.provider == "appleSpeech", !options.translate, !options.useGPU else {
                throw Failure.providerMismatch
            }
            let normalized = try normalizedLocale(locale.identifier)
            guard normalized == (try normalizedLocale(options.language)) else { throw Failure.providerMismatch }
            identity = .apple(localeIdentifier: normalized)
        case .whisper(let native):
            guard let whisperKind,
                  options.provider == (whisperKind == .curated ? "whisper" : "customWhisper") else {
                throw Failure.providerMismatch
            }
            let configuration = native.configurationSnapshot
            try validate(configuration)
            guard configuration.language == options.language,
                  configuration.translate == options.translate,
                  configuration.useGPU == options.useGPU else { throw Failure.providerMismatch }
            identity = .whisper(kind: whisperKind, configuration: configuration)
        }
        return Self(intentSHA256: try intent.sha256, provider: provider, identity: identity)
    }

    /// Requires the entire same intent, including ordered photos and plan identity.
    /// Retaining the provider value prevents later settings changes substituting another
    /// locale, build, model, timeout or option. Fresh readiness/consent remains separate.
    func requireMatches(intent: MCPVoiceTranscriptionReviewRequestStore.Intent) throws {
        let kind: WhisperKind?
        switch identity {
        case .apple: kind = nil
        case .whisper(let retained, _): kind = retained
        }
        let current = try Self.bind(intent: intent, provider: provider, whisperKind: kind)
        guard current.intentSHA256 == intentSHA256, current.identity == identity else {
            throw Failure.intentMismatch
        }
    }

    private struct Options {
        let provider: String
        let language: String
        let translate: Bool
        let useGPU: Bool

        init(intent: MCPVoiceTranscriptionReviewRequestStore.Intent) throws {
            // Reuse complete bounded intent validation, without accessing any root or file.
            do { try intent.requireValid() }
            catch { throw Failure.invalidIntent }
            guard intent.schemaVersion == 1,
                  let provider = intent.options["provider"]?.stringValue,
                  let language = intent.options["language"]?.stringValue,
                  case .bool(let translate) = intent.options["translate"],
                  case .bool(let useGPU) = intent.options["useGPU"] else { throw Failure.invalidIntent }
            self.provider = provider; self.language = language
            self.translate = translate; self.useGPU = useGPU
        }
    }

    private static func normalizedLocale(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard value.utf8.count <= 64, normalized != "auto", !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 && $0.utf8.allSatisfy {
                  (97...122).contains($0) || (48...57).contains($0)
              } }), parts[0].utf8.count >= 2,
              parts[0].utf8.allSatisfy({ (97...122).contains($0) }) else { throw Failure.invalidProvider }
        return normalized
    }

    private static func validate(_ configuration: FFmpegWhisperTranscriptionProvider.Configuration) throws {
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.timeoutSeconds <= 3600,
              [configuration.buildIdentifier, configuration.modelIdentifier].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1024
                    && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else { throw Failure.invalidProvider }
        do {
            try FFmpegWhisperTranscriptProvenance(configuration: configuration,
                segments: [.init(start: 0, end: 0, text: "")]).validate()
        } catch { throw Failure.invalidProvider }
        for input in [configuration.executable, configuration.model] {
            let url = input.url
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
                  url.absoluteString.utf8.count <= 16_384, !url.path.utf8.contains(0),
                  !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw Failure.invalidProvider
            }
        }
    }
}
