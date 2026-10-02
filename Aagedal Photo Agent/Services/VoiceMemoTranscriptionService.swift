import AVFAudio
import Foundation
import CryptoKit
import Darwin
import Speech

/// Session-only exact relationship carrier evidence, separate from portable source content identity.
/// Bounded no-follow reads include inode and nanosecond mtime/ctime so even equal-byte replacement
/// invalidates native confirmation. This token is never consent or helper root authority.
nonisolated struct VoiceMemoRelationshipRevision: Equatable, Sendable {
    let url: URL
    let revision: String

    static func capture(for image: URL) throws -> Self {
        try capture(at: VoiceMemoCompanionRepository().recordURL(for: image))
    }

    private static func capture(at url: URL) throws -> Self {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw VoiceMemoTranscriptionError.sourceChanged }
        defer { Darwin.close(descriptor) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= 1_048_576 else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= 1_048_576 - bytes.count else { throw VoiceMemoTranscriptionError.sourceChanged }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        func facts(_ value: stat) -> [String] {
            [String(value.st_dev), String(value.st_ino), String(value.st_mode), String(value.st_nlink),
             String(value.st_size), String(value.st_mtimespec.tv_sec), String(value.st_mtimespec.tv_nsec),
             String(value.st_ctimespec.tv_sec), String(value.st_ctimespec.tv_nsec)]
        }
        guard fstat(descriptor, &after) == 0, lstat(url.path, &named) == 0,
              facts(before) == facts(after), facts(after) == facts(named), bytes.count == before.st_size else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let evidence = try JSONEncoder().encode([url.standardizedFileURL.path, digest] + facts(after))
        return Self(url: url.standardizedFileURL,
                    revision: SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined())
    }

    func requireUnchanged() throws {
        guard try Self.capture(at: url) == self else { throw VoiceMemoTranscriptionError.sourceChanged }
    }
}

nonisolated enum VoiceMemoTranscriptionAssetStatus: Equatable, Sendable {
    case unsupported
    case needsDownload
    case reservationLimitReached
    case downloading
    case installed
}

nonisolated struct VoiceMemoTranscriptionAvailability: Equatable, Sendable {
    let selectedLocale: Locale?
    let supportedLocales: [Locale]
    let status: VoiceMemoTranscriptionAssetStatus
    let reservedLocales: [Locale]
    let maximumReservedLocales: Int

    init(
        selectedLocale: Locale?,
        supportedLocales: [Locale],
        status: VoiceMemoTranscriptionAssetStatus,
        reservedLocales: [Locale] = [],
        maximumReservedLocales: Int = 0
    ) {
        self.selectedLocale = selectedLocale
        self.supportedLocales = supportedLocales
        self.status = status
        self.reservedLocales = reservedLocales
        self.maximumReservedLocales = maximumReservedLocales
    }
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
    var approvedAt: Date?
    var whisperProvenance: FFmpegWhisperTranscriptProvenance? = nil

    var isApproved: Bool { approvedAt != nil }
}

/// The complete immutable authority used by metadata-variable processing. Keeping the reviewed
/// text together with its approval and WAV identity lets a retained write revalidate the same
/// approval immediately before a retry rather than trusting a filename or previously loaded text.
nonisolated struct VoiceMemoTranscriptVariableContext: Equatable, Sendable {
    let reviewedText: String
    let approvedAt: Date
    let memoByteCount: Int64
    let memoSHA256: String
    let associationProfileIdentifier: String
}

nonisolated enum VoiceMemoTranscriptVariableError: LocalizedError, Equatable, Sendable {
    case missing
    case notApproved
    case sourceChanged
    case approvalChanged
    case incompatibleDestinations([MetadataFieldID])

    var errorDescription: String? {
        switch self {
        case .missing:
            return "This photo has no reviewed voice-memo transcript. Transcribe and approve it before processing {voiceMemoTranscript}."
        case .notApproved:
            return "This photo's voice-memo transcript is not approved. Review and approve it before processing {voiceMemoTranscript}."
        case .sourceChanged:
            return "The approved voice-memo transcript no longer matches the current WAV relationship and bytes. No transcript text was applied."
        case .approvalChanged:
            return "The approved voice-memo transcript changed before metadata could be written. No transcript text was applied; review the current approval and try again."
        case .incompatibleDestinations(let fields):
            let names = fields.map(\.displayName).joined(separator: ", ")
            return "The voice-memo transcript cannot be inserted into: \(names). Choose Description, Extended Description, Headline, or Instructions."
        }
    }
}

nonisolated enum VoiceMemoTranscriptionError: LocalizedError, Equatable, Sendable {
    case unavailable
    case unsupportedLanguage
    case languageDownloadRequired
    case languageDownloadIncomplete
    case languageDownloadFailed
    case languageReservationLimitReached(maximum: Int)
    case relationshipUnavailable
    case sourceChanged
    case existingTranscript
    case invalidGeneratedDraft
    case audioUnreadable
    case emptyAudio
    case noSpeech
    case recognitionFailed

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
        case .languageDownloadFailed:
            return "The on-device language could not be downloaded. Check the network connection and try again."
        case .languageReservationLimitReached(let maximum):
            return "Apple on-device speech can reserve at most \(maximum) language\(maximum == 1 ? "" : "s") for this app. Release an unused language, then try again."
        case .relationshipUnavailable:
            return "The saved voice-memo relationship is no longer available. Refresh it before transcribing."
        case .sourceChanged:
            return "The photo, voice memo, or relationship changed while transcribing. The result was discarded."
        case .existingTranscript:
            return "This photo already has a saved transcript. Its draft or human review was kept."
        case .invalidGeneratedDraft:
            return "A generated transcript draft must be unapproved before it can be saved by automation."
        case .audioUnreadable:
            return "The associated WAV could not be opened as supported audio. Playback remains available."
        case .emptyAudio:
            return "The associated WAV contains no audio samples."
        case .noSpeech:
            return "No speech was recognized in the voice memo."
        case .recognitionFailed:
            return "Apple on-device speech could not finish this transcription. The existing reviewed transcript was not changed."
        }
    }
}

/// One analyzer run split into independently injectable lifecycle operations. The result consumer
/// begins before audio analysis; finalization runs only when analysis reports a last sample; and
/// every failure or cancellation drains the shared teardown operation.
nonisolated struct VoiceMemoRecognitionSession: Sendable {
    struct AnalysisCompletion: Sendable {
        let finalize: @Sendable () async throws -> Void
    }

    let consumeFinalSegments: @Sendable () async throws -> [String]
    let analyze: @Sendable () async throws -> AnalysisCompletion?
    let cancelAndFinish: @Sendable () async -> Void
}

private actor VoiceMemoRecognitionCleanup {
    private var task: Task<Void, Never>?

    func run(_ cancelAndFinish: @escaping @Sendable () async -> Void) async {
        if let task {
            await task.value
            return
        }
        // Cancellation starts teardown from an unstructured handler task. Retain its
        // completion so the error path also drains that same teardown before returning.
        let task = Task { await cancelAndFinish() }
        self.task = task
        await task.value
    }
}

nonisolated enum VoiceMemoRecognitionPipeline {
    static func transcribe(
        session: VoiceMemoRecognitionSession,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> String {
        let cleanup = VoiceMemoRecognitionCleanup()
        let consumer = Task<[String], Error> {
            try await session.consumeFinalSegments()
        }

        do {
            return try await withTaskCancellationHandler {
                let completion = try await session.analyze()
                try Task.checkCancellation()
                guard let completion else {
                    throw VoiceMemoTranscriptionError.emptyAudio
                }
                try await completion.finalize()
                let segments = try await consumer.value
                try Task.checkCancellation()
                let text = segments
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw VoiceMemoTranscriptionError.noSpeech }
                return text
            } onCancel: {
                consumer.cancel()
                Task { await cleanup.run(session.cancelAndFinish) }
            }
        } catch is CancellationError {
            consumer.cancel()
            await cleanup.run(session.cancelAndFinish)
            _ = try? await consumer.value
            throw CancellationError()
        } catch let error as VoiceMemoTranscriptionError {
            consumer.cancel()
            await cleanup.run(session.cancelAndFinish)
            _ = try? await consumer.value
            throw error
        } catch {
            consumer.cancel()
            await cleanup.run(session.cancelAndFinish)
            _ = try? await consumer.value
            throw VoiceMemoTranscriptionError.recognitionFailed
        }
    }
}

private actor VoiceMemoOneShotRecognitionBridge {
    private var result: Result<String, Error>?
    private var waiters: [CheckedContinuation<Result<String, Error>, Never>] = []

    func consume() async throws -> String {
        let value: Result<String, Error>
        if let result {
            value = result
        } else {
            value = await withCheckedContinuation { waiters.append($0) }
        }
        return try value.get()
    }

    func publish(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        waiters.forEach { $0.resume(returning: value) }
        waiters.removeAll()
    }
}

/// Injectable Apple Speech boundary. Tests never inspect or install the developer Mac's assets.
nonisolated struct VoiceMemoTranscriptionRuntime: Sendable {
    let isAvailable: @Sendable () async -> Bool
    let supportedLocales: @Sendable () async -> [Locale]
    let resolveLocale: @Sendable (Locale) async -> Locale?
    let assetStatus: @Sendable (Locale) async -> VoiceMemoTranscriptionAssetStatus
    let reservedLocales: @Sendable () async -> [Locale]
    let maximumReservedLocales: @Sendable () -> Int
    let reserveLocale: @Sendable (Locale) async throws -> Void
    let releaseLocale: @Sendable (Locale) async -> Bool
    let installAssets: @Sendable (Locale) async throws -> Void
    let makeRecognitionSession: @Sendable (URL, Locale) async throws -> VoiceMemoRecognitionSession

    init(
        isAvailable: @escaping @Sendable () async -> Bool,
        supportedLocales: @escaping @Sendable () async -> [Locale],
        resolveLocale: @escaping @Sendable (Locale) async -> Locale?,
        assetStatus: @escaping @Sendable (Locale) async -> VoiceMemoTranscriptionAssetStatus,
        reservedLocales: @escaping @Sendable () async -> [Locale] = { [] },
        maximumReservedLocales: @escaping @Sendable () -> Int = { .max },
        reserveLocale: @escaping @Sendable (Locale) async throws -> Void = { _ in },
        releaseLocale: @escaping @Sendable (Locale) async -> Bool = { _ in false },
        installAssets: @escaping @Sendable (Locale) async throws -> Void,
        makeRecognitionSession: @escaping @Sendable (
            URL, Locale
        ) async throws -> VoiceMemoRecognitionSession
    ) {
        self.isAvailable = isAvailable
        self.supportedLocales = supportedLocales
        self.resolveLocale = resolveLocale
        self.assetStatus = assetStatus
        self.reservedLocales = reservedLocales
        self.maximumReservedLocales = maximumReservedLocales
        self.reserveLocale = reserveLocale
        self.releaseLocale = releaseLocale
        self.installAssets = installAssets
        self.makeRecognitionSession = makeRecognitionSession
    }

    /// Convenience for service tests whose recognition boundary is intentionally one-shot. The
    /// production runtime and lifecycle tests use `makeRecognitionSession` so analysis,
    /// finalization, result consumption and cancellation remain independently observable.
    init(
        isAvailable: @escaping @Sendable () async -> Bool,
        supportedLocales: @escaping @Sendable () async -> [Locale],
        resolveLocale: @escaping @Sendable (Locale) async -> Locale?,
        assetStatus: @escaping @Sendable (Locale) async -> VoiceMemoTranscriptionAssetStatus,
        reservedLocales: @escaping @Sendable () async -> [Locale] = { [] },
        maximumReservedLocales: @escaping @Sendable () -> Int = { .max },
        reserveLocale: @escaping @Sendable (Locale) async throws -> Void = { _ in },
        releaseLocale: @escaping @Sendable (Locale) async -> Bool = { _ in false },
        installAssets: @escaping @Sendable (Locale) async throws -> Void,
        transcribe: @escaping @Sendable (URL, Locale) async throws -> String
    ) {
        self.init(
            isAvailable: isAvailable,
            supportedLocales: supportedLocales,
            resolveLocale: resolveLocale,
            assetStatus: assetStatus,
            reservedLocales: reservedLocales,
            maximumReservedLocales: maximumReservedLocales,
            reserveLocale: reserveLocale,
            releaseLocale: releaseLocale,
            installAssets: installAssets,
            makeRecognitionSession: { url, locale in
                let bridge = VoiceMemoOneShotRecognitionBridge()
                return VoiceMemoRecognitionSession(
                    consumeFinalSegments: {
                        [try await bridge.consume()]
                    },
                    analyze: {
                        do {
                            let text = try await transcribe(url, locale)
                            await bridge.publish(.success(text))
                            return VoiceMemoRecognitionSession.AnalysisCompletion(finalize: {})
                        } catch {
                            await bridge.publish(.failure(error))
                            throw error
                        }
                    },
                    cancelAndFinish: {
                        await bridge.publish(.failure(CancellationError()))
                    }
                )
            }
        )
    }

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
        reservedLocales: { await AssetInventory.reservedLocales },
        maximumReservedLocales: { AssetInventory.maximumReservedLocales },
        reserveLocale: { locale in _ = try await AssetInventory.reserve(locale: locale) },
        releaseLocale: { locale in await AssetInventory.release(reservedLocale: locale) },
        installAssets: { locale in
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
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
        makeRecognitionSession: { url, locale in
            do {
                return try AppleVoiceMemoRecognitionSession(url: url, locale: locale).session
            } catch {
                throw VoiceMemoTranscriptionError.audioUnreadable
            }
        }
    )
}

private nonisolated final class AppleVoiceMemoRecognitionSession: @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let audioFile: AVAudioFile

    init(url: URL, locale: Locale) throws {
        transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        audioFile = try AVAudioFile(forReading: url)
    }

    var session: VoiceMemoRecognitionSession {
        VoiceMemoRecognitionSession(
            consumeFinalSegments: { [self] in
                var finalSegments: [String] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { finalSegments.append(text) }
                }
                return finalSegments
            },
            analyze: { [self] in
                guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                    return nil
                }
                return VoiceMemoRecognitionSession.AnalysisCompletion { [self] in
                    try await analyzer.finalizeAndFinish(through: lastSample)
                }
            },
            cancelAndFinish: { [self] in await analyzer.cancelAndFinishNow() }
        )
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
    typealias LoadTranscript = @Sendable (URL, URL) async throws -> VoiceMemoTranscriptRecord?
    typealias SaveTranscript = @Sendable (
        VoiceMemoTranscriptRecord, URL, URL
    ) async throws -> VoiceMemoTranscriptRecord

    typealias CreateTranscript = @Sendable (VoiceMemoTranscriptRecord, URL, URL, SourceImageRevision, URL, VoiceMemoRelationshipRevision?) async throws -> VoiceMemoTranscriptRecord

    private let createTranscript: CreateTranscript
    private let runtime: VoiceMemoTranscriptionRuntime
    private let lookup: Lookup
    private let captureRevision: CaptureRevision
    private let loadTranscript: LoadTranscript
    private let saveTranscript: SaveTranscript
    private let now: @Sendable () -> Date
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(
        runtime: VoiceMemoTranscriptionRuntime = .appleOnDevice,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.voice-memo-transcription", qos: .utility
        ),
        lookup: @escaping Lookup = { try VoiceMemoTranscriptionService.lookupRegularAssociation(for: $0) },
        captureRevision: @escaping CaptureRevision = {
            try VoiceMemoTranscriptionService.requireRegularInput($0)
            return try await SourceImageRevision.capture(at: $0)
        },
        loadTranscript: @escaping LoadTranscript = { imageURL, folderURL in
            try await MetadataSidecarService().loadVoiceMemoTranscriptSerialized(
                for: imageURL, in: folderURL
            )
        },
        saveTranscript: @escaping SaveTranscript = { transcript, imageURL, folderURL in
            try await MetadataSidecarService().saveVoiceMemoTranscriptSerialized(
                transcript, for: imageURL, in: folderURL
            )
        },
        createTranscript: @escaping CreateTranscript = { record, image, folder, source, memo, relationship in
            try await MetadataSidecarService().createVoiceMemoTranscriptSerialized(
                record, for: image, in: folder, expectedSourceRevision: source, expectedMemoURL: memo,
                expectedRelationshipRevision: relationship
            )
        },
        now: @escaping @Sendable () -> Date = Date.init,
        startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.createTranscript = createTranscript
        self.runtime = runtime
        self.filesystemQueue = filesystemQueue
        self.lookup = lookup
        self.captureRevision = captureRevision
        self.loadTranscript = loadTranscript
        self.saveTranscript = saveTranscript
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
        let reserved = await runtime.reservedLocales()
        let maximum = max(0, runtime.maximumReservedLocales())
        let isReserved = await isEquivalentLocaleReserved(selected, in: reserved)
        var status = await runtime.assetStatus(selected)
        if status == .needsDownload, !isReserved, reserved.count >= maximum {
            status = .reservationLimitReached
        }
        return .init(
            selectedLocale: selected,
            supportedLocales: supported,
            status: status,
            reservedLocales: reserved,
            maximumReservedLocales: maximum
        )
    }

    func downloadLanguage(_ locale: Locale) async throws -> VoiceMemoTranscriptionAvailability {
        try Task.checkCancellation()
        let readiness = await availability(preferredLocale: locale)
        guard let selected = readiness.selectedLocale else {
            throw VoiceMemoTranscriptionError.unsupportedLanguage
        }
        if readiness.status == .reservationLimitReached {
            throw VoiceMemoTranscriptionError.languageReservationLimitReached(
                maximum: readiness.maximumReservedLocales
            )
        }
        do {
            try await runtime.reserveLocale(selected)
            try Task.checkCancellation()
            try await runtime.installAssets(selected)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VoiceMemoTranscriptionError {
            throw error
        } catch {
            throw VoiceMemoTranscriptionError.languageDownloadFailed
        }
        try Task.checkCancellation()
        let result = await availability(preferredLocale: selected)
        guard result.status == .installed else {
            throw VoiceMemoTranscriptionError.languageDownloadIncomplete
        }
        return result
    }

    func releaseLanguage(
        _ locale: Locale,
        preferredLocale: Locale
    ) async -> VoiceMemoTranscriptionAvailability {
        _ = await runtime.releaseLocale(locale)
        return await availability(preferredLocale: preferredLocale)
    }

    func transcribe(imageURL: URL, locale: Locale, requiresExactLocale: Bool = false) async throws -> VoiceMemoTranscriptDraft {
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
        if requiresExactLocale,
           selected.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            != locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased() {
            throw VoiceMemoTranscriptionError.unsupportedLanguage
        }
        switch readiness.status {
        case .installed: break
        case .needsDownload, .reservationLimitReached, .downloading:
            throw VoiceMemoTranscriptionError.languageDownloadRequired
        case .unsupported:
            throw VoiceMemoTranscriptionError.unavailable
        }

        let sourceBefore = try await captureRevision(image)
        let before = try await captureRevision(association.memoURL)
        try Task.checkCancellation()
        let session = try await runtime.makeRecognitionSession(association.memoURL, selected)
        let text = try await VoiceMemoRecognitionPipeline.transcribe(session: session)
        try Task.checkCancellation()
        let after = try await captureRevision(association.memoURL)
        let sourceAfter = try await captureRevision(image)
        guard sourceBefore.relationship(to: sourceAfter) == .exactRevision,
              before.relationship(to: after) == .exactRevision,
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
            reviewedText: normalized,
            approvedAt: nil
        )
    }

    /// Explicit opt-in only: authorization is supplied by curated or consented custom admission.
    /// No Apple fallback, persistence, approval, or metadata write happens here.
    func transcribe(
        imageURL: URL,
        provider: FFmpegWhisperTranscriptionProvider
    ) async throws -> VoiceMemoTranscriptDraft {
        try Task.checkCancellation()
        let image = imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        let didAccess = startAccess(folder)
        defer { if didAccess { stopAccess(folder) } }
        guard case .available(let association) = try lookup(image),
              association.memoURL.pathExtension.lowercased() == "wav" else {
            throw VoiceMemoTranscriptionError.relationshipUnavailable
        }
        let sourceBefore = try await captureRevision(image)
        let before = try await captureRevision(association.memoURL)
        let result = try await provider.transcribe(audio: .init(
            url: association.memoURL, byteCount: before.byteCount, sha256: before.sha256
        ))
        try Task.checkCancellation()
        let after = try await captureRevision(association.memoURL)
        let sourceAfter = try await captureRevision(image)
        guard sourceBefore.relationship(to: sourceAfter) == .exactRevision,
              before.relationship(to: after) == .exactRevision,
              try lookup(image) == .available(association) else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        try Task.checkCancellation()
        return VoiceMemoTranscriptDraft(
            imageURL: image, memoURL: association.memoURL,
            memoByteCount: before.byteCount, memoSHA256: before.sha256,
            associationProfileIdentifier: association.profileIdentifier,
            localeIdentifier: result.provenance.requestedLanguage,
            provider: "FFmpeg Whisper", providerModel: result.provenance.modelIdentifier,
            generatedAt: now(), generatedText: result.text, reviewedText: result.text,
            approvedAt: nil, whisperProvenance: result.provenance
        )
    }

    /// Automation may create an editable draft only when no transcript already exists.
    /// Human review and replacement remain explicit native actions.
    func persistGeneratedDraft(
        _ draft: VoiceMemoTranscriptDraft,
        expectedSourceRevision: SourceImageRevision,
        expectedRelationshipRevision: VoiceMemoRelationshipRevision? = nil
    ) async throws -> VoiceMemoTranscriptDraft {
        try Task.checkCancellation()
        guard !draft.isApproved else { throw VoiceMemoTranscriptionError.invalidGeneratedDraft }
        let image = draft.imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        let didAccess = startAccess(folder)
        defer { if didAccess { stopAccess(folder) } }
        let source = try await captureRevision(image)
        guard expectedSourceRevision.relationship(to: source) == .exactRevision else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        let association = try await validatedAssociation(for: image, memoSHA256: draft.memoSHA256,
            memoByteCount: draft.memoByteCount, profileIdentifier: draft.associationProfileIdentifier)
        guard association.memoURL == draft.memoURL.standardizedFileURL else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        let text = draft.generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceMemoTranscriptionError.noSpeech }
        let record = VoiceMemoTranscriptRecord(sourceImageFilename: image.lastPathComponent,
            sourceMemoFilename: association.memoURL.lastPathComponent, memoByteCount: draft.memoByteCount,
            memoSHA256: draft.memoSHA256, associationProfileIdentifier: draft.associationProfileIdentifier,
            localeIdentifier: draft.localeIdentifier, provider: draft.provider, providerModel: draft.providerModel,
            generatedAt: draft.generatedAt, generatedText: text, reviewedText: text, approvedAt: nil,
            whisperProvenance: draft.whisperProvenance)
        try Task.checkCancellation()
        let installed = try await createTranscript(record, image, folder, expectedSourceRevision, association.memoURL, expectedRelationshipRevision)
        // Creation verifies its saved bytes before returning. A cancellation after that durable
        // boundary must not turn the successful save into a no-effects cancellation claim.
        return VoiceMemoTranscriptDraft(imageURL: image, memoURL: association.memoURL,
            memoByteCount: installed.memoByteCount, memoSHA256: installed.memoSHA256,
            associationProfileIdentifier: installed.associationProfileIdentifier,
            localeIdentifier: installed.localeIdentifier, provider: installed.provider, providerModel: installed.providerModel,
            generatedAt: installed.generatedAt, generatedText: installed.generatedText,
            reviewedText: installed.reviewedText, approvedAt: installed.approvedAt,
            whisperProvenance: installed.whisperProvenance)
    }

    /// Repository lookup returns canonical URLs. Validate the original adjacent entries too,
    /// so canonicalization cannot conceal a linked source, relationship record or WAV.
    nonisolated static func lookupRegularAssociation(for image: URL) throws -> VoiceMemoCompanionRepository.Lookup {
        try requireRegularInput(image)
        let repository = VoiceMemoCompanionRepository()
        let result = try repository.lookup(for: image)
        guard case .available = result else { return result }
        let recordURL = repository.recordURL(for: image)
        try requireRegularInput(recordURL)
        let record = try JSONDecoder().decode(VoiceMemoCompanionRecord.self, from: Data(contentsOf: recordURL))
        let memoExtension = (record.memoFilename as NSString).pathExtension
        let memoName = record.imageFilename == image.lastPathComponent ? record.memoFilename
            : image.deletingPathExtension().lastPathComponent + (memoExtension.isEmpty ? "" : "." + memoExtension)
        try requireRegularInput(image.deletingLastPathComponent().appendingPathComponent(memoName))
        return result
    }

    nonisolated static func requireRegularInput(_ url: URL) throws {
        guard url.isFileURL,
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
    }

    func loadPersistedDraft(imageURL: URL) async throws -> VoiceMemoTranscriptDraft? {
        try Task.checkCancellation()
        let image = imageURL.standardizedFileURL
        let folder = image.deletingLastPathComponent()
        guard let record = try await loadTranscript(image, folder) else { return nil }
        let association = try await validatedAssociation(
            for: image,
            memoSHA256: record.memoSHA256,
            memoByteCount: record.memoByteCount,
            profileIdentifier: record.associationProfileIdentifier
        )
        return VoiceMemoTranscriptDraft(
            imageURL: image,
            memoURL: association.memoURL,
            memoByteCount: record.memoByteCount,
            memoSHA256: record.memoSHA256,
            associationProfileIdentifier: record.associationProfileIdentifier,
            localeIdentifier: record.localeIdentifier,
            provider: record.provider,
            providerModel: record.providerModel,
            generatedAt: record.generatedAt,
            generatedText: record.generatedText,
            reviewedText: record.reviewedText,
            approvedAt: record.approvedAt,
            whisperProvenance: record.whisperProvenance
        )
    }

    /// Loads only explicitly approved text after `loadPersistedDraft` has revalidated the exact
    /// current relationship and WAV bytes. Generated or merely edited drafts cannot resolve a
    /// metadata variable.
    func approvedVariableContext(imageURL: URL) async throws -> VoiceMemoTranscriptVariableContext {
        let loaded: VoiceMemoTranscriptDraft?
        do { loaded = try await loadPersistedDraft(imageURL: imageURL) }
        catch VoiceMemoTranscriptionError.sourceChanged {
            throw VoiceMemoTranscriptVariableError.sourceChanged
        }
        guard let draft = loaded else {
            throw VoiceMemoTranscriptVariableError.missing
        }
        guard let approvedAt = draft.approvedAt else {
            throw VoiceMemoTranscriptVariableError.notApproved
        }
        let reviewed = draft.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewed.isEmpty else { throw VoiceMemoTranscriptVariableError.notApproved }
        return .init(
            reviewedText: reviewed,
            approvedAt: approvedAt,
            memoByteCount: draft.memoByteCount,
            memoSHA256: draft.memoSHA256,
            associationProfileIdentifier: draft.associationProfileIdentifier
        )
    }

    func validateVariableContext(
        _ expected: VoiceMemoTranscriptVariableContext,
        imageURL: URL
    ) async throws {
        let current = try await approvedVariableContext(imageURL: imageURL)
        guard current == expected else { throw VoiceMemoTranscriptVariableError.approvalChanged }
    }

    func approve(_ draft: VoiceMemoTranscriptDraft) async throws -> VoiceMemoTranscriptDraft {
        let approvedAt = now()
        var approved = draft
        approved.approvedAt = approvedAt
        return try await persist(approved)
    }

    func revokeApproval(_ draft: VoiceMemoTranscriptDraft) async throws -> VoiceMemoTranscriptDraft {
        var revoked = draft
        revoked.approvedAt = nil
        return try await persist(revoked)
    }

    private func persist(_ draft: VoiceMemoTranscriptDraft) async throws -> VoiceMemoTranscriptDraft {
        try Task.checkCancellation()
        let image = draft.imageURL.standardizedFileURL
        let association = try await validatedAssociation(
            for: image,
            memoSHA256: draft.memoSHA256,
            memoByteCount: draft.memoByteCount,
            profileIdentifier: draft.associationProfileIdentifier
        )
        let normalizedReview = draft.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReview.isEmpty else { throw VoiceMemoTranscriptionError.noSpeech }
        let record = VoiceMemoTranscriptRecord(
            sourceImageFilename: image.lastPathComponent,
            sourceMemoFilename: association.memoURL.lastPathComponent,
            memoByteCount: draft.memoByteCount,
            memoSHA256: draft.memoSHA256,
            associationProfileIdentifier: draft.associationProfileIdentifier,
            localeIdentifier: draft.localeIdentifier,
            provider: draft.provider,
            providerModel: draft.providerModel,
            generatedAt: draft.generatedAt,
            generatedText: draft.generatedText,
            reviewedText: normalizedReview,
            approvedAt: draft.approvedAt,
            whisperProvenance: draft.whisperProvenance
        )
        let saved = try await saveTranscript(record, image, image.deletingLastPathComponent())
        try Task.checkCancellation()
        let currentAssociation = try await validatedAssociation(
            for: image,
            memoSHA256: saved.memoSHA256,
            memoByteCount: saved.memoByteCount,
            profileIdentifier: saved.associationProfileIdentifier
        )
        return VoiceMemoTranscriptDraft(
            imageURL: image,
            memoURL: currentAssociation.memoURL,
            memoByteCount: saved.memoByteCount,
            memoSHA256: saved.memoSHA256,
            associationProfileIdentifier: saved.associationProfileIdentifier,
            localeIdentifier: saved.localeIdentifier,
            provider: saved.provider,
            providerModel: saved.providerModel,
            generatedAt: saved.generatedAt,
            generatedText: saved.generatedText,
            reviewedText: saved.reviewedText,
            approvedAt: saved.approvedAt,
            whisperProvenance: saved.whisperProvenance
        )
    }

    private func validatedAssociation(
        for imageURL: URL,
        memoSHA256: String,
        memoByteCount: Int64,
        profileIdentifier: String
    ) async throws -> VoiceMemoAssociation {
        guard case .available(let association) = try lookup(imageURL),
              association.profileIdentifier == profileIdentifier else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        let revision = try await captureRevision(association.memoURL)
        guard revision.sha256 == memoSHA256,
              revision.byteCount == memoByteCount,
              case .available(association) = try lookup(imageURL) else {
            throw VoiceMemoTranscriptionError.sourceChanged
        }
        return association
    }

    private func isEquivalentLocaleReserved(_ selected: Locale, in reserved: [Locale]) async -> Bool {
        for locale in reserved {
            if locale.identifier == selected.identifier { return true }
            if let equivalent = await runtime.resolveLocale(locale),
               equivalent.identifier == selected.identifier {
                return true
            }
        }
        return false
    }
}
