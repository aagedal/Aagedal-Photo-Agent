import Foundation

/// Bridges the process runner into the existing draft/review lifecycle. Deliberately has no
/// default configuration or authorization: the installer must verify curated build/signature,
/// patched output format, model compatibility and licensing before authorizing these identities.
nonisolated struct FFmpegWhisperTranscriptionProvider: Sendable {
    struct Configuration: Equatable, Sendable {
        let executable: FFmpegWhisperJobInput
        let buildIdentifier: String
        let model: FFmpegWhisperJobInput
        let modelIdentifier: String
        let language: String
        let useGPU: Bool
        let timeoutSeconds: Double
    }

    struct Result: Sendable {
        let text: String
        let provenance: FFmpegWhisperTranscriptProvenance
    }

    typealias AuthorizeArtifacts = @Sendable (Configuration) async throws -> Void
    typealias Run = @Sendable (FFmpegWhisperJobRequest) async throws -> FFmpegWhisperJobResult
    private let configuration: Configuration
    private let authorizeArtifacts: AuthorizeArtifacts
    private let run: Run

    init(configuration: Configuration, authorizeArtifacts: @escaping AuthorizeArtifacts,
         run: @escaping Run = { try await FFmpegWhisperJobRunner().run($0) }) {
        self.configuration = configuration
        self.authorizeArtifacts = authorizeArtifacts
        self.run = run
    }

    func transcribe(audio: FFmpegWhisperJobInput) async throws -> Result {
        try Task.checkCancellation()
        guard configuration.timeoutSeconds.isFinite, configuration.timeoutSeconds > 0,
              configuration.timeoutSeconds <= 3600 else { throw FFmpegWhisperJobError.invalidRequest }
        // Validate identity metadata before executing; output segments are validated after the run.
        try FFmpegWhisperTranscriptProvenance(configuration: configuration,
            segments: [.init(start: 0, end: 0, text: "")]).validate()
        try await authorizeArtifacts(configuration)
        try Task.checkCancellation()
        let request = FFmpegWhisperJobRequest(
            executable: configuration.executable, audio: audio, model: configuration.model,
            language: configuration.language, useGPU: configuration.useGPU,
            timeoutSeconds: configuration.timeoutSeconds
        )
        let result = try await run(request)
        try Task.checkCancellation()
        guard result.request == request else { throw FFmpegWhisperJobError.identityMismatch }
        let provenance = FFmpegWhisperTranscriptProvenance(
            configuration: configuration, segments: result.transcript.segments
        )
        try provenance.validate()
        let text = result.transcript.editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == provenance.editableText else { throw FFmpegWhisperJobError.identityMismatch }
        guard !text.isEmpty else { throw VoiceMemoTranscriptionError.noSpeech }
        guard text.utf8.count <= FFmpegWhisperJSONParser.maximumTextBytes else {
            throw FFmpegWhisperJSONError.textTooLarge
        }
        // Inference can outlive an artifact authorization or installation. Revalidate the
        // caller's authority before publishing even an unapproved draft.
        try await authorizeArtifacts(configuration)
        try Task.checkCancellation()
        return Result(text: text, provenance: provenance)
    }
}

nonisolated extension FFmpegWhisperTranscriptProvenance {
    init(configuration: FFmpegWhisperTranscriptionProvider.Configuration,
         segments: [FFmpegWhisperTranscript.Segment]) {
        self.init(buildIdentifier: configuration.buildIdentifier,
                  executableSHA256: configuration.executable.sha256,
                  executableByteCount: configuration.executable.byteCount,
                  modelIdentifier: configuration.modelIdentifier,
                  modelSHA256: configuration.model.sha256,
                  modelByteCount: configuration.model.byteCount,
                  requestedLanguage: configuration.language, useGPU: configuration.useGPU,
                  segments: segments.map { .init(start: $0.start, end: $0.end, text: $0.text) })
    }
}
