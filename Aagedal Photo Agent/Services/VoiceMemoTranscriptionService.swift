import AVFAudio
import Foundation
import Speech

nonisolated enum VoiceMemoTranscriptionAssetStatus: Equatable, Sendable {
    case unsupported
    case needsDownload
    case downloading
    case installed
}

nonisolated struct VoiceMemoTranscriptionAvailability: Equatable, Sendable {
    let selectedLocale: Locale?
    let supportedLocales: [Locale]
    let status: VoiceMemoTranscriptionAssetStatus
}

nonisolated struct VoiceMemoTranscriptDraft: Equatable, Sendable {
    let imageURL: URL
    let memoURL: URL
    let memoByteCount: Int64
    let memoSHA256: String
    let associationProfileIdentifier: String
    let localeIdentifier: String
    let provider: String
    let providerModel: String
    let generatedAt: Date
    let generatedText: String
    var reviewedText: String
}

nonisolated enum VoiceMemoTranscriptionError: LocalizedError, Equatable, Sendable {
    case unavailable
    case unsupportedLanguage
    case languageDownloadRequired
    case languageDownloadIncomplete
    case relationshipUnavailable
    case sourceChanged
    case emptyAudio
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device transcription is not available on this Mac. Voice-memo playback remains available."
        case .unsupportedLanguage:
            return "The selected language is not supported by Apple on-device speech on this Mac."
        case .languageDownloadRequired:
            return "Download the selected on-device language before transcribing."
        case .languageDownloadIncomplete:
            return "The language download did not finish. Check the network connection and try again."
        case .relationshipUnavailable:
            return "The saved voice-memo relationship is no longer available. Refresh it before transcribing."
        case .sourceChanged:
            return "The photo, voice memo, or relationship changed while transcribing. The result was discarded."
        case .emptyAudio:
            return "The associated WAV contains no audio samples."
        case .noSpeech:
            return "No speech was recognized in the voice memo."
        }
    }
}

/// Injectable Apple Speech boundary. Tests never inspect or install the developer Mac's assets.
nonisolated struct VoiceMemoTranscriptionRuntime: Sendable {
    let isAvailable: @Sendable () async -> Bool
    let supportedLocales: @Sendable () async -> [Locale]
    let resolveLocale: @Sendable (Locale) async -> Locale?
    let assetStatus: @Sendable (Locale) async -> VoiceMemoTranscriptionAssetStatus
    let installAssets: @Sendable (Locale) async throws -> Void
    let transcribe: @Sendable (URL, Locale) async throws -> String

    static let appleOnDevice = VoiceMemoTranscriptionRuntime(
        isAvailable: { SpeechTranscriber.isAvailable },
        supportedLocales: { await SpeechTranscriber.supportedLocales },
        resolveLocale: { await SpeechTranscriber.supportedLocale(equivalentTo: $0) },
        assetStatus: { locale in
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .unsupported: return .unsupported
            case .supported: return .needsDownload
            case .downloading: return .downloading
            case .installed: return .installed
            @unknown default: return .unsupported
            }
        },
        installAssets: { locale in
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            _ = try await AssetInventory.reserve(locale: locale)
            if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else {
                throw VoiceMemoTranscriptionError.languageDownloadIncomplete
            }
            try await request.downloadAndInstall()
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw VoiceMemoTranscriptionError.languageDownloadIncomplete
            }
        },
        transcribe: { url, locale in
            try await AppleVoiceMemoTranscriber.transcribe(url: url, locale: locale)
        }
    )
}

private nonisolated enum AppleVoiceMemoTranscriber {
    static func transcribe(url: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        let consumer = Task<[String], Error> {
            var finalSegments: [String] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { finalSegments.append(text) }
            }
            return finalSegments
        }

        do {
            let lastSample = try await withTaskCancellationHandler {
                try await analyzer.analyzeSequence(from: audioFile)
            } onCancel: {
                consumer.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            guard let lastSample else {
                consumer.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await consumer.value
                throw VoiceMemoTranscriptionError.emptyAudio
            }
            try await analyzer.finalizeAndFinish(through: lastSample)
            let segments = try await consumer.value
            try Task.checkCancellation()
            let text = segments.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw VoiceMemoTranscriptionError.noSpeech }
            return text
        } catch {
            consumer.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await consumer.value
            throw error
        }
    }
}

/// Owns source verification and security-scoped access around one local recognition request.
/// Generation or review never mutates metadata or the voice-memo relationship.
actor VoiceMemoTranscriptionService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    typealias Lookup = @Sendable (URL) throws -> VoiceMemoCompanionRepository.Lookup
    typealias CaptureRevision = @Sendable (URL) async throws -> SourceImageRevision

    private let runtime: VoiceMemoTranscriptionRuntime
    private let lookup: Lookup
    private let captureRevision: CaptureRevision
    private let now: @Sendable () -> Date
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(
        runtime: VoiceMemoTranscriptionRuntime = .appleOnDevice,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.voice-memo-transcription", qos: .utility
        ),
        lookup: @escaping Lookup = { try VoiceMemoCompanionRepository().lookup(for: $0) },
        captureRevision: @escaping CaptureRevision = { try await SourceImageRevision.capture(at: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.runtime = runtime
        self.filesystemQueue = filesystemQueue
        self.lookup = lookup
        self.captureRevision = captureRevision
        self.now = now
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func availability(preferredLocale: Locale) async -> VoiceMemoTranscriptionAvailability {
        guard !Task.isCancelled, await runtime.isAvailable() else {
            return .init(selectedLocale: nil, supportedLocales: [], status: .unsupported)
        }
        let supported = await runtime.supportedLocales().sorted {
            let lhs = Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
            let rhs = Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        guard !Task.isCancelled,
              let selected = await runtime.resolveLocale(preferredLocale) else {
            return .init(selectedLocale: nil, supportedLocales: supported, status: .unsupported)
        }
        let status = await runtime.assetStatus(selected)
        return .init(selectedLocale: selected, supportedLocales: supported, status: status)
    }

    func downloadLanguage(_ locale: Locale) async throws -> VoiceMemoTranscriptionAvailability {
        try Task.checkCancellation()
        guard await runtime.isAvailable(),
              let selected = await runtime.resolveLocale(locale) else {
            throw VoiceMemoTranscriptionError.unsupportedLanguage
        }
        try await runtime.installAssets(selected)
        try Task.checkCancellation()
        let result = await availability(preferredLocale: selected)
        guard result.status == .installed else {
            throw VoiceMemoTranscriptionError.languageDownloadIncomplete
        }
        return result
    }

    func transcribe(imageURL: URL, locale: Locale) async throws -> VoiceMemoTranscriptDraft {
        try Task.checkCancellation()
        let image = imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        let didAccess = startAccess(folder)
        defer { if didAccess { stopAccess(folder) } }

        guard case .available(let association) = try lookup(image),
              association.memoURL.pathExtension.lowercased() == "wav" else {
            throw VoiceMemoTranscriptionError.relationshipUnavailable
        }
        let readiness = await availability(preferredLocale: locale)
        guard let selected = readiness.selectedLocale else {
            throw VoiceMemoTranscriptionError.unsupportedLanguage
        }
        switch readiness.status {
        case .installed: break
        case .needsDownload, .downloading:
            throw VoiceMemoTranscriptionError.languageDownloadRequired
        case .unsupported:
            throw VoiceMemoTranscriptionError.unavailable
        }

        let before = try await captureRevision(association.memoURL)
        try Task.checkCancellation()
        let text = try await runtime.transcribe(association.memoURL, selected)
        try Task.checkCancellation()
        let after = try await captureRevision(association.memoURL)
        guard before.relationship(to: after) == .exactRevision,
              try lookup(image) == .available(association) else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw VoiceMemoTranscriptionError.noSpeech }
        return VoiceMemoTranscriptDraft(
            imageURL: image,
            memoURL: association.memoURL,
            memoByteCount: before.byteCount,
            memoSHA256: before.sha256,
            associationProfileIdentifier: association.profileIdentifier,
            localeIdentifier: selected.identifier,
            provider: "Apple on-device speech",
            providerModel: "System managed; exact version unavailable",
            generatedAt: now(),
            generatedText: normalized,
            reviewedText: normalized
        )
    }
}
