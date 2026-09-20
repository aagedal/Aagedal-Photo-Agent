import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("FFmpeg Whisper draft integration")
struct FFmpegWhisperTranscriptionProviderTests {
    private let image = URL(fileURLWithPath: "/photos/a.jpg")
    private let memo = URL(fileURLWithPath: "/photos/a.wav")

    private var configuration: FFmpegWhisperTranscriptionProvider.Configuration {
        .init(executable: .init(url: URL(fileURLWithPath: "/curated/ffmpeg"), byteCount: 10,
                                sha256: String(repeating: "a", count: 64)),
              buildIdentifier: "patched-test-build", model: .init(
                url: URL(fileURLWithPath: "/curated/model.bin"), byteCount: 20,
                sha256: String(repeating: "b", count: 64)),
              modelIdentifier: "test-model", language: "auto", useGPU: false, timeoutSeconds: 30)
    }

    private func revision(_ hash: String = "c") -> SourceImageRevision {
        .init(canonicalURL: memo, fileResourceIdentifier: nil, filenameAtCreation: "a.wav",
              byteCount: 42, contentModificationDate: .distantPast, pixelWidth: nil,
              pixelHeight: nil, exifOrientation: nil, sha256: String(repeating: hash, count: 64),
              hashCompletedAt: .distantPast)
    }

    @Test("authorized runner evidence reaches an unapproved draft and survives record roundtrip")
    func draftAndPersistence() async throws {
        let association = VoiceMemoAssociation(profileIdentifier: "test", imageURL: image, memoURL: memo)
        let stable = revision()
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in }, run: { request in
                .init(request: request, transcript: try FFmpegWhisperJSONParser.parse(Data(
                    "{\"start\":0,\"end\":25,\"text\":\" hello \"}\n".utf8)))
            })
        let service = VoiceMemoTranscriptionService(lookup: { _ in .available(association) },
            captureRevision: { _ in stable }, saveTranscript: { record, _, _ in record },
            startAccess: { _ in false })
        let draft = try await service.transcribe(imageURL: image, provider: provider)
        #expect(draft.generatedText == "hello")
        #expect(draft.reviewedText == "hello")
        #expect(!draft.isApproved)
        let approved = try await service.approve(draft)
        #expect(approved.isApproved)
        #expect(approved.whisperProvenance == draft.whisperProvenance)
        let revoked = try await service.revokeApproval(approved)
        #expect(!revoked.isApproved)
        #expect(revoked.whisperProvenance == draft.whisperProvenance)
        let evidence = try #require(draft.whisperProvenance)
        #expect(evidence.segments.first?.text == " hello ")
        #expect(evidence.segments.first?.endMilliseconds == 25)
        #expect(evidence.requestedLanguage == "auto")
        #expect(evidence.detectedLanguage == nil)
        let record = VoiceMemoTranscriptRecord(sourceImageFilename: "a.jpg", sourceMemoFilename: "a.wav",
            memoByteCount: 42, memoSHA256: stable.sha256, associationProfileIdentifier: "test",
            localeIdentifier: draft.localeIdentifier, provider: draft.provider,
            providerModel: draft.providerModel, generatedAt: draft.generatedAt,
            generatedText: draft.generatedText, reviewedText: "edited", whisperProvenance: evidence)
        let decoded = try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.whisperProvenance == evidence)
        #expect(!decoded.isApproved)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let validJSON = json
        var futureEvidence = try #require(json["whisperProvenance"] as? [String: Any])
        futureEvidence["futureBuildEvidence"] = "must not be lost"
        json["whisperProvenance"] = futureEvidence
        let unknownEvidence = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: unknownEvidence) }
        json = validJSON
        json["providerModel"] = "conflicting-model"
        let conflictingEvidence = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: conflictingEvidence) }
        json = validJSON
        var invalid = try #require(json["whisperProvenance"] as? [String: Any])
        invalid["schemaVersion"] = 2
        json["whisperProvenance"] = invalid
        let invalidData = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: invalidData) }
        invalid["schemaVersion"] = 1
        invalid["segments"] = [["start": -1, "end": 25, "text": "hello"]]
        json["whisperProvenance"] = invalid
        let badTiming = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: badTiming) }
        json.removeValue(forKey: "whisperProvenance")
        let missingEvidence = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: missingEvidence) }
        json["provider"] = "Apple on-device speech"
        let legacy = try JSONDecoder().decode(VoiceMemoTranscriptRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.whisperProvenance == nil)
    }

    @Test("Whisper review approval and revocation survive real sidecar merges and fresh service reloads")
    func actualSidecarReviewLifecycle() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperReview-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("photo.JPG")
        let memoURL = folder.appendingPathComponent("photo.WAV")
        let imageBytes = Data("synthetic photo identity".utf8)
        try imageBytes.write(to: imageURL)
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func word(_ value: UInt32, count: Int) {
            for offset in 0..<count { wav.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        text("RIFF"); word(36 + 1600, count: 4); text("WAVEfmt ")
        word(16, count: 4); word(1, count: 2); word(1, count: 2)
        word(8000, count: 4); word(16000, count: 4); word(2, count: 2); word(16, count: 2)
        text("data"); word(1600, count: 4); wav.append(Data(repeating: 0, count: 1600))
        try wav.write(to: memoURL)
        let repository = VoiceMemoCompanionRepository()
        try repository.save(.init(profileIdentifier: "synthetic-wav", imageURL: imageURL, memoURL: memoURL))
        let relationshipBytes = try Data(contentsOf: repository.recordURL(for: imageURL))
        let metadataService = MetadataSidecarService()
        try metadataService.saveSidecar(.init(sourceFile: imageURL.lastPathComponent,
            pendingChanges: true, metadata: IPTCMetadata(title: "Editorial title")),
            for: imageURL, in: folder)
        let carrier = folder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
            .appendingPathComponent("\(imageURL.lastPathComponent).meta.json")
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in }, run: { request in
                .init(request: request, transcript: try FFmpegWhisperJSONParser.parse(Data(
                    "{\"start\":0,\"end\":25,\"text\":\" generated speech \"}\n".utf8)))
            })
        let service = VoiceMemoTranscriptionService(now: { Date(timeIntervalSince1970: 500) })
        var generated = try await service.transcribe(imageURL: imageURL, provider: provider)
        let evidence = try #require(generated.whisperProvenance)
        generated.reviewedText = "First human review"
        // Review edits use revokeApproval as their save boundary, also for unapproved drafts.
        _ = try await service.revokeApproval(generated)
        let firstReload = try await VoiceMemoTranscriptionService().loadPersistedDraft(imageURL: imageURL)
        let reviewed = try #require(firstReload)
        #expect(reviewed.reviewedText == "First human review")
        #expect(!reviewed.isApproved)
        #expect(reviewed.whisperProvenance == evidence)
        var graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: carrier)) as? [String: Any])
        graph["futureEditorialExtension"] = ["keep": true]
        var transcript = try #require(graph[MetadataSidecarService.voiceMemoTranscriptFieldName] as? [String: Any])
        transcript["futureTranscriptExtension"] = "preserve"
        graph[MetadataSidecarService.voiceMemoTranscriptFieldName] = transcript
        try JSONSerialization.data(withJSONObject: graph).write(to: carrier, options: .atomic)
        _ = try await service.approve(reviewed)
        let approvedReload = try await VoiceMemoTranscriptionService().loadPersistedDraft(imageURL: imageURL)
        var approved = try #require(approvedReload)
        #expect(approved.isApproved)
        #expect(approved.whisperProvenance == evidence)
        let variable = try await VoiceMemoTranscriptionService().approvedVariableContext(imageURL: imageURL)
        #expect(variable.reviewedText == "First human review")
        approved.reviewedText = "Corrected human review"
        _ = try await service.revokeApproval(approved)
        let finalReload = try await VoiceMemoTranscriptionService().loadPersistedDraft(imageURL: imageURL)
        let final = try #require(finalReload)
        #expect(!final.isApproved)
        #expect(final.reviewedText == "Corrected human review")
        #expect(final.generatedText == "generated speech")
        #expect(final.whisperProvenance == evidence)
        await #expect(throws: VoiceMemoTranscriptVariableError.notApproved) {
            _ = try await VoiceMemoTranscriptionService().approvedVariableContext(imageURL: imageURL)
        }
        let savedGraph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: carrier)) as? [String: Any])
        #expect((savedGraph["futureEditorialExtension"] as? [String: Bool])?["keep"] == true)
        let savedTranscript = try #require(savedGraph[MetadataSidecarService.voiceMemoTranscriptFieldName] as? [String: Any])
        #expect(savedTranscript["futureTranscriptExtension"] as? String == "preserve")
        let editorial = try #require(metadataService.loadSidecar(for: imageURL, in: folder))
        #expect(editorial.metadata.title == "Editorial title")
        #expect(editorial.pendingChanges)
        #expect(try Data(contentsOf: imageURL) == imageBytes)
        #expect(try Data(contentsOf: memoURL) == wav)
        #expect(try Data(contentsOf: repository.recordURL(for: imageURL)) == relationshipBytes)
    }

    @Test("Caption custom provider produces an unapproved draft or retains the exact review without Apple fallback",
          arguments: [false, true])
    @MainActor
    func captionProviderBridge(fails: Bool) async throws {
        let association = VoiceMemoAssociation(profileIdentifier: "test", imageURL: image, memoURL: memo)
        let stable = revision()
        let locale = Locale(identifier: "en-US")
        let existing = VoiceMemoTranscriptRecord(
            sourceImageFilename: image.lastPathComponent, sourceMemoFilename: memo.lastPathComponent,
            memoByteCount: stable.byteCount, memoSHA256: stable.sha256,
            associationProfileIdentifier: association.profileIdentifier,
            localeIdentifier: locale.identifier, provider: "Apple on-device speech",
            providerModel: "System managed; exact version unavailable",
            generatedAt: Date(timeIntervalSince1970: 100), generatedText: "Original draft",
            reviewedText: "Existing approved human review", approvedAt: Date(timeIntervalSince1970: 200))
        let runtime = VoiceMemoTranscriptionRuntime(
            isAvailable: { true }, supportedLocales: { [locale] }, resolveLocale: { _ in locale },
            assetStatus: { _ in .installed },
            installAssets: { _ in Issue.record("Custom transcription must not download Apple assets") },
            transcribe: { _, _ in
                Issue.record("Custom transcription must not fall back to Apple Speech")
                return "Unexpected Apple result"
            })
        let service = VoiceMemoTranscriptionService(runtime: runtime,
            lookup: { _ in .available(association) }, captureRevision: { _ in stable },
            loadTranscript: { _, _ in existing },
            saveTranscript: { record, _, _ in
                Issue.record("Generating a replacement draft must not persist or approve it")
                return record
            }, startAccess: { _ in false })
        let model = CaptionVoiceMemoTranscriptModel(service: service)
        await model.load(image)
        let original = try #require(model.draft)
        #expect(original.isApproved)
        let custom = configuration
        let provider = FFmpegWhisperTranscriptionProvider(configuration: custom,
            authorizeArtifacts: { _ in }, run: { request in
                if fails { throw FFmpegWhisperJobError.timedOut }
                return .init(request: request, transcript: .init(
                    segments: [.init(start: 0, end: 25, text: "Custom replacement")],
                    editableText: "Custom replacement"))
            })

        await model.transcribe(provider: provider)

        #expect(!model.isTranscribing)
        if fails {
            #expect(model.draft == original)
            #expect(model.errorMessage == "Whisper exceeded the transcription time limit. Try a smaller compatible model or a shorter voice memo. The existing review was kept. Apple Speech was not used.")
        } else {
            let draft = try #require(model.draft)
            #expect(draft.generatedText == "Custom replacement")
            #expect(draft.reviewedText == draft.generatedText)
            #expect(draft.provider == "FFmpeg Whisper")
            #expect(draft.memoSHA256 == stable.sha256)
            #expect(!draft.isApproved)
            #expect(draft.whisperProvenance?.buildIdentifier == custom.buildIdentifier)
            #expect(draft.whisperProvenance?.modelSHA256 == custom.model.sha256)
            #expect(draft.whisperProvenance?.segments.first?.endMilliseconds == 25)
            #expect(model.errorMessage == nil)
        }
        let persisted = try await service.loadPersistedDraft(imageURL: image)
        #expect(persisted == original)
    }

    @Test("artifact authorization failure cannot reach the runner")
    func authorizationFailure() async {
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in throw FFmpegWhisperJobError.identityMismatch },
            run: { _ in Issue.record("Unauthorized process launch"); throw FFmpegWhisperJobError.launchFailed })
        await #expect(throws: FFmpegWhisperJobError.identityMismatch) {
            _ = try await provider.transcribe(audio: .init(url: memo, byteCount: 42, sha256: revision().sha256))
        }
    }

    @Test("artifact authorization revoked during inference discards the draft")
    func authorizationRevokedDuringInference() async {
        let state = WhisperDraftTestState()
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in
                if state.complete { throw FFmpegWhisperJobError.identityMismatch }
            }, run: { request in
                state.markComplete()
                return .init(request: request, transcript: .init(
                    segments: [.init(start: 0, end: 1, text: "hello")], editableText: "hello"))
            })
        await #expect(throws: FFmpegWhisperJobError.identityMismatch) {
            _ = try await provider.transcribe(audio: .init(url: memo, byteCount: 42, sha256: revision().sha256))
        }
        #expect(state.complete)
    }

    @Test("changed WAV bytes or removed relationship discard completed inference")
    func sourceRevalidation() async throws {
        for changeRelationship in [false, true] {
            let state = WhisperDraftTestState()
            let association = VoiceMemoAssociation(profileIdentifier: "test", imageURL: image, memoURL: memo)
            let stable = revision()
            let changed = revision("d")
            let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
                authorizeArtifacts: { _ in }, run: { request in
                    state.markComplete()
                    return .init(request: request, transcript: .init(
                        segments: [.init(start: 0, end: 1, text: "hello")], editableText: "hello"))
                })
            let service = VoiceMemoTranscriptionService(
                lookup: { _ in
                    if changeRelationship && state.complete { throw VoiceMemoTranscriptionError.sourceChanged }
                    return .available(association)
                }, captureRevision: { _ in !changeRelationship && state.complete ? changed : stable },
                startAccess: { _ in false })
            await #expect(throws: VoiceMemoTranscriptionError.sourceChanged) {
                _ = try await service.transcribe(imageURL: image, provider: provider)
            }
        }
    }

    @Test("cancellation after inference discards the result")
    func cancellation() async {
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in }, run: { request in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(request: request, transcript: .init(
                    segments: [.init(start: 0, end: 1, text: "hello")], editableText: "hello"))
            })
        let input = FFmpegWhisperJobInput(url: memo, byteCount: 42, sha256: revision().sha256)
        let task = Task { try await provider.transcribe(audio: input) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("mismatched runner request cannot become provenance")
    func requestIdentity() async {
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in }, run: { request in
                let other = FFmpegWhisperJobRequest(executable: request.executable,
                    audio: request.audio, model: request.model, language: "en",
                    useGPU: request.useGPU, timeoutSeconds: request.timeoutSeconds)
                return .init(request: other, transcript: .init(
                    segments: [.init(start: 0, end: 1, text: "hello")], editableText: "hello"))
            })
        await #expect(throws: FFmpegWhisperJobError.identityMismatch) {
            _ = try await provider.transcribe(audio: .init(url: memo, byteCount: 42, sha256: revision().sha256))
        }
    }

    @Test("runner failure remains explicit and cannot produce a draft")
    func runnerFailure() async {
        let provider = FFmpegWhisperTranscriptionProvider(configuration: configuration,
            authorizeArtifacts: { _ in }, run: { _ in throw FFmpegWhisperJobError.timedOut })
        await #expect(throws: FFmpegWhisperJobError.timedOut) {
            _ = try await provider.transcribe(audio: .init(url: memo, byteCount: 42, sha256: revision().sha256))
        }
    }
}

nonisolated private final class WhisperDraftTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedComplete = false
    var complete: Bool { lock.withLock { storedComplete } }
    func markComplete() { lock.withLock { storedComplete = true } }
}
