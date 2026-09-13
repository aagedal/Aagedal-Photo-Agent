import CoreGraphics
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Caption voice memo playback")
struct CaptionVoiceMemoPlaybackTests {
    private let association = VoiceMemoAssociation(
        profileIdentifier: "test-only", imageURL: URL(fileURLWithPath: "/caption/a.jpg"),
        memoURL: URL(fileURLWithPath: "/caption/a.WAV")
    )
    private let revision = CaptionVoiceMemoFileRevision(size: 10, modified: .distantPast, device: 1, inode: 2)

    @Test("Leaving the photo cancels a playback command blocked in source validation", arguments: [false, true])
    @MainActor
    func navigationCancelsPendingPlay(loadNext: Bool) async throws {
        let probe = CaptionVoiceMemoProbe()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let found = association
        let version = revision
        let service = CaptionVoiceMemoPlaybackService(
            lookup: { _ in
                probe.record("lookup")
                if probe.events.filter({ $0 == "lookup" }).count == 3 {
                    probe.record("blocked")
                    _ = gate.wait(timeout: .now() + 10)
                }
                return .available(found)
            },
            makePlayer: { _ in CaptionVoiceMemoTestPlayer(probe: probe) },
            readRevision: { _ in version }
        )
        let model = CaptionVoiceMemoPlaybackModel(service: service)
        await model.load(found.imageURL)
        let playing = Task { await model.toggle() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !probe.events.contains("blocked"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.events.contains("blocked"))
        if loadNext {
            let transition = Task { await model.load(nil) }
            while model.state != .loading, ContinuousClock.now < deadline { await Task.yield() }
            gate.signal()
            await transition.value
            #expect(model.state == .none)
        } else {
            model.stop()
            gate.signal()
            #expect(model.state == .idle)
        }
        await playing.value
        #expect(!probe.events.contains("play"))
        #expect(!model.isChangingPlayback)
    }

    @Test("Pre-cancelled load cannot supersede a newer selected photo")
    @MainActor
    func cancelledModelLoadPreservesSelection() async {
        let service = CaptionVoiceMemoPlaybackService(lookup: { _ in .none })
        let model = CaptionVoiceMemoPlaybackModel(service: service)
        await model.load(association.imageURL)
        #expect(model.state == .none)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(nil)
        }
        await cancelled.value
        #expect(model.state == .none)
    }

    @Test("Player teardown happens before releasing folder access")
    func playerTeardownPrecedesAccessRelease() async throws {
        let probe = CaptionVoiceMemoProbe()
        let found = association
        let version = revision
        var service: CaptionVoiceMemoPlaybackService? = CaptionVoiceMemoPlaybackService(
            lookup: { _ in .available(found) },
            makePlayer: { _ in CaptionVoiceMemoTestPlayer(probe: probe) },
            readRevision: { _ in version },
            startAccess: { _ in true },
            stopAccess: { _ in probe.record("release") }
        )
        _ = await service?.load(imageURL: found.imageURL, generation: 1)
        service = nil
        let deadline = ContinuousClock.now + .seconds(5)
        while !probe.events.contains("release"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.events == ["stop", "destroy", "release"])
    }

    @Test("Persisted WAV loads without playing or changing any source bytes")
    func realWAVPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.JPG")
        let memo = root.appendingPathComponent("photo.WAV")
        let imageBytes = Data("synthetic photo identity".utf8)
        try imageBytes.write(to: image)
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func word(_ value: UInt32, count: Int) {
            for offset in 0..<count { wav.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
        }
        text("RIFF"); word(36 + 1600, count: 4); text("WAVEfmt ")
        word(16, count: 4); word(1, count: 2); word(1, count: 2)
        word(8000, count: 4); word(16000, count: 4); word(2, count: 2); word(16, count: 2)
        text("data"); word(1600, count: 4); wav.append(Data(repeating: 0, count: 1600))
        try wav.write(to: memo)
        let association = VoiceMemoAssociation(profileIdentifier: "synthetic-wav", imageURL: image, memoURL: memo)
        let repository = VoiceMemoCompanionRepository()
        try repository.save(association)
        let recordBefore = try Data(contentsOf: repository.recordURL(for: image))
        let service = CaptionVoiceMemoPlaybackService()
        guard case .available(let ready) = await service.load(imageURL: image, generation: 1) else {
            Issue.record("A persisted PCM WAV should prepare for explicit playback")
            return
        }
        #expect(ready.association == association)
        #expect(abs(ready.duration - 0.1) < 0.001)
        #expect(!ready.isPlaying)
        #expect(try Data(contentsOf: image) == imageBytes)
        #expect(try Data(contentsOf: memo) == wav)
        #expect(try Data(contentsOf: repository.recordURL(for: image)) == recordBefore)
        await service.clear(generation: 2)
    }

    @Test("Worker retains task context, balances access, and ignores stale controls")
    func playbackOwnership() async {
        let probe = CaptionVoiceMemoProbe()
        let found = association
        let version = revision
        let service = CaptionVoiceMemoPlaybackService(
            lookup: { _ in
                probe.record("lookup")
                #expect(!Thread.isMainThread)
                #expect(CaptionVoiceMemoTestContext.marker == "caption-request")
                return .available(found)
            },
            makePlayer: { _ in CaptionVoiceMemoTestPlayer(probe: probe) },
            readRevision: { _ in version },
            startAccess: { _ in probe.record("access"); return true },
            stopAccess: { _ in probe.record("release") }
        )
        await CaptionVoiceMemoTestContext.$marker.withValue("caption-request") {
            _ = await service.load(imageURL: found.imageURL, generation: 2)
            #expect(!probe.events.contains("play"))
            #expect(await service.load(imageURL: found.imageURL, generation: 1) == nil)
            #expect(await service.toggle(generation: 1) == nil)
            guard case .available(let playing) = await service.toggle(generation: 2) else {
                Issue.record("Expected explicit playback"); return
            }
            #expect(playing.isPlaying)
            await service.clear(generation: 1)
            guard case .available(let paused) = await service.toggle(generation: 2) else {
                Issue.record("Stale clear must not destroy current playback"); return
            }
            #expect(!paused.isPlaying)
        }
        await service.clear(generation: 3)
        #expect(await service.progress(generation: 2) == nil)
        #expect(probe.events.filter { $0 == "access" }.count == 1)
        #expect(probe.events.filter { $0 == "release" }.count == 1)
        #expect(probe.events.filter { $0 == "play" }.count == 1)
    }

    @Test("Cancellation before and during relationship lookup never creates a player", arguments: [false, true])
    func cancellationSkipsAudio(before: Bool) async {
        let probe = CaptionVoiceMemoProbe()
        let found = association
        let version = revision
        let service = CaptionVoiceMemoPlaybackService(
            lookup: { _ in
                probe.record("lookup")
                withUnsafeCurrentTask { $0?.cancel() }
                return .available(found)
            },
            makePlayer: { _ in probe.record("prepare"); return CaptionVoiceMemoTestPlayer(probe: probe) },
            readRevision: { _ in version },
            startAccess: { _ in probe.record("access"); return true },
            stopAccess: { _ in probe.record("release") }
        )
        let task = Task {
            if before { withUnsafeCurrentTask { $0?.cancel() } }
            return await service.load(imageURL: found.imageURL, generation: 1)
        }
        #expect(await task.value == nil)
        #expect(!probe.events.contains("prepare"))
        #expect(probe.events.filter { $0 == "access" }.count == (before ? 0 : 1))
        #expect(probe.events.filter { $0 == "release" }.count == (before ? 0 : 1))
    }

    @Test("Missing, unknown-schema, unassociated and unsupported audio do not prepare playback", arguments: [0, 1, 2, 3])
    func unavailableStates(kind: Int) async {
        let probe = CaptionVoiceMemoProbe()
        let found = association
        let service = CaptionVoiceMemoPlaybackService(
            lookup: { _ in
                switch kind {
                case 0: return .none
                case 1: return .missing(VoiceMemoCompanionRecord(profileIdentifier: "test", imageFilename: "a.jpg", memoFilename: "a.WAV"))
                case 2: throw VoiceMemoCompanionRepository.RepositoryError.unsupportedSchema(99)
                default: return .available(VoiceMemoAssociation(profileIdentifier: "test", imageURL: found.imageURL, memoURL: URL(fileURLWithPath: "/caption/a.mp3")))
                }
            },
            makePlayer: { _ in probe.record("prepare"); return CaptionVoiceMemoTestPlayer(probe: probe) }
        )
        let state = await service.load(imageURL: found.imageURL, generation: 1)
        if kind == 0 { #expect(state == CaptionVoiceMemoState.none) }
        else if kind == 1 { #expect(state == .missing("a.WAV")) }
        else { guard case .unavailable = state else { Issue.record("Expected unavailable state"); return } }
        #expect(probe.events.isEmpty)
    }

    @Test("Changing either source after preparation blocks playback", arguments: ["image", "memo", "association"])
    func sourceChangeBlocksPlayback(changed: String) async {
        let probe = CaptionVoiceMemoProbe()
        let found = association
        let version = revision
        let service = CaptionVoiceMemoPlaybackService(
            lookup: { _ in
                if changed == "association", probe.events.contains("changed") { return .none }
                return .available(found)
            },
            makePlayer: { _ in CaptionVoiceMemoTestPlayer(probe: probe) },
            readRevision: { url in
                if probe.events.contains("changed"),
                   (changed == "image" && url == found.imageURL) || (changed == "memo" && url == found.memoURL) {
                    return CaptionVoiceMemoFileRevision(size: 11, modified: .now, device: 1, inode: 3)
                }
                return version
            }
        )
        _ = await service.load(imageURL: found.imageURL, generation: 1)
        probe.record("changed")
        guard case .unavailable = await service.toggle(generation: 1) else {
            Issue.record("Changed source must require refresh"); return
        }
        #expect(!probe.events.contains("play"))
        #expect(probe.events.contains("stop"))
    }

    @Test("Recovery worker stays off MainActor and balances picker and folder access")
    func recoveryWorkerOwnership() async throws {
        let probe = CaptionVoiceMemoRecoveryProbe()
        let candidate = URL(fileURLWithPath: "/selected/original.WAV")
        let image = association.imageURL
        let assessment = VoiceMemoCompanionRepository.RecoveryAssessment(
            candidateURL: candidate,
            destinationURL: association.memoURL,
            kind: .exactRecovery,
            invalidatesTranscriptApproval: false
        )
        let service = CaptionVoiceMemoRecoveryService(
            assessCandidate: { selected, owner in
                #expect(!Thread.isMainThread)
                probe.record("assess:\(selected.lastPathComponent):\(owner.lastPathComponent)")
                return assessment
            },
            recoverCandidate: { selected, owner, confirmed in
                #expect(!Thread.isMainThread)
                probe.record("recover:\(confirmed)")
                return .init(
                    association: VoiceMemoAssociation(
                        profileIdentifier: "test", imageURL: owner, memoURL: assessment.destinationURL
                    ),
                    kind: .exactRecovery,
                    invalidatedTranscriptApproval: false
                )
            },
            startAccess: { url in probe.record("access:\(url.path)"); return true },
            stopAccess: { url in probe.record("release:\(url.path)") }
        )

        #expect(try await service.assess(candidateURL: candidate, imageURL: image) == assessment)
        _ = try await service.recover(
            candidateURL: candidate, imageURL: image, confirmingReplacement: false
        )
        #expect(probe.events.filter { $0.hasPrefix("access:") }.count == 4)
        #expect(probe.events.filter { $0.hasPrefix("release:") }.count == 4)
        #expect(probe.events.contains("recover:false"))
    }

    @Test("Recovery model pauses changed audio for confirmation")
    @MainActor
    func recoveryModelRequiresConfirmation() async {
        let probe = CaptionVoiceMemoRecoveryProbe()
        let candidate = URL(fileURLWithPath: "/selected/replacement.WAV")
        let image = association.imageURL
        let assessment = VoiceMemoCompanionRepository.RecoveryAssessment(
            candidateURL: candidate,
            destinationURL: association.memoURL,
            kind: .explicitReplacement(previousIdentityAvailable: true),
            invalidatesTranscriptApproval: true
        )
        let service = CaptionVoiceMemoRecoveryService(
            assessCandidate: { _, _ in assessment },
            recoverCandidate: { _, owner, confirmed in
                probe.record("recover:\(confirmed)")
                return .init(
                    association: VoiceMemoAssociation(
                        profileIdentifier: "test", imageURL: owner, memoURL: assessment.destinationURL
                    ),
                    kind: .explicitReplacement(previousIdentityAvailable: true),
                    invalidatedTranscriptApproval: true
                )
            }
        )
        let model = CaptionVoiceMemoRecoveryModel(service: service)

        #expect(!(await model.select(candidateURL: candidate, for: image)))
        #expect(model.pendingReplacement == assessment)
        #expect(probe.events.isEmpty)
        #expect(await model.confirmReplacement())
        #expect(model.pendingReplacement == nil)
        #expect(probe.events == ["recover:true"])
    }

    @Test("Leaving a photo during candidate hashing cannot publish or commit recovery")
    @MainActor
    func recoveryNavigationCancellation() async throws {
        let probe = CaptionVoiceMemoRecoveryProbe()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let candidate = URL(fileURLWithPath: "/selected/original.WAV")
        let found = association
        let assessment = VoiceMemoCompanionRepository.RecoveryAssessment(
            candidateURL: candidate,
            destinationURL: association.memoURL,
            kind: .exactRecovery,
            invalidatesTranscriptApproval: false
        )
        let service = CaptionVoiceMemoRecoveryService(
            assessCandidate: { _, _ in
                probe.record("blocked")
                _ = gate.wait(timeout: .now() + 10)
                return assessment
            },
            recoverCandidate: { _, _, _ in
                probe.record("recover")
                return .init(
                    association: found,
                    kind: .exactRecovery,
                    invalidatedTranscriptApproval: false
                )
            }
        )
        let model = CaptionVoiceMemoRecoveryModel(service: service)
        let selection = Task { await model.select(candidateURL: candidate, for: found.imageURL) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !probe.events.contains("blocked"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.events.contains("blocked"))
        model.cancel()
        gate.signal()

        #expect(!(await selection.value))
        #expect(!probe.events.contains("recover"))
        #expect(model.pendingReplacement == nil)
        #expect(!model.isWorking)
    }

    @Test("Moved-relationship search stays off MainActor and balances both scopes")
    func reassociationWorkerOwnership() async throws {
        let probe = CaptionVoiceMemoRecoveryProbe()
        let location = URL(fileURLWithPath: "/selected/folder", isDirectory: true)
        let image = association.imageURL
        let service = CaptionVoiceMemoReassociationService(
            discover: { selected, owner in
                #expect(!Thread.isMainThread)
                probe.record("discover:\(selected.lastPathComponent):\(owner.lastPathComponent)")
                return .sourceChanged([selected.appendingPathComponent(".old.voice-memo.json")])
            },
            commit: { _, _ in
                Issue.record("Changed discovery must never commit")
                throw CancellationError()
            },
            startAccess: { url in probe.record("access:\(url.path)"); return true },
            stopAccess: { url in probe.record("release:\(url.path)") }
        )

        #expect(try await service.reassociate(searchLocation: location, imageURL: image)
                == .sourceChanged(relationshipCount: 1))
        #expect(probe.events.filter { $0.hasPrefix("access:") }.count == 2)
        #expect(probe.events.filter { $0.hasPrefix("release:") }.count == 2)
        #expect(probe.events.contains("discover:folder:a.jpg"))
    }

    @Test("Leaving a photo during moved-relationship discovery cannot publish or commit")
    @MainActor
    func reassociationNavigationCancellation() async throws {
        let probe = CaptionVoiceMemoRecoveryProbe()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let location = URL(fileURLWithPath: "/selected/folder", isDirectory: true)
        let image = association.imageURL
        let service = CaptionVoiceMemoReassociationService(
            discover: { _, _ in
                probe.record("blocked")
                _ = gate.wait(timeout: .now() + 10)
                return .notFound
            },
            commit: { _, _ in
                probe.record("commit")
                throw CancellationError()
            }
        )
        let model = CaptionVoiceMemoReassociationModel(service: service)
        let search = Task { await model.search(location, for: image) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !probe.events.contains("blocked"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.events.contains("blocked"))
        model.cancel()
        gate.signal()

        #expect(!(await search.value))
        #expect(!probe.events.contains("commit"))
        #expect(model.result == nil)
        #expect(!model.isWorking)
    }
}

@Suite("Caption voice memo transcription")
struct CaptionVoiceMemoTranscriptionTests {
    private let imageURL = URL(fileURLWithPath: "/caption/transcription.jpg")
    private let memoURL = URL(fileURLWithPath: "/caption/transcription.wav")
    private let locale = Locale(identifier: "en-US")

    @Test("availability distinguishes installed and download-required language assets")
    func availabilityStates() async {
        let installed = service(status: .installed)
        let downloadable = service(status: .needsDownload)

        let ready = await installed.availability(preferredLocale: locale)
        let missing = await downloadable.availability(preferredLocale: locale)

        #expect(ready.selectedLocale?.identifier == locale.identifier)
        #expect(ready.supportedLocales.map(\.identifier) == [locale.identifier])
        #expect(ready.status == .installed)
        #expect(missing.status == .needsDownload)
    }

    @Test("explicit asset download is rechecked before it becomes ready")
    func explicitDownload() async throws {
        let probe = VoiceMemoTranscriptionProbe(status: .needsDownload)
        let service = service(probe: probe)

        let result = try await service.downloadLanguage(locale)

        #expect(result.status == .installed)
        #expect(probe.installCount == 1)
    }

    @Test("reservation capacity blocks download until an explicit language release")
    func reservationCapacity() async throws {
        let selectedLocale = locale
        let reservedLocale = Locale(identifier: "nb-NO")
        let probe = VoiceMemoLanguageReservationProbe(
            status: .needsDownload,
            reservedLocales: [reservedLocale]
        )
        let service = VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale, reservedLocale] },
                resolveLocale: { requested in requested },
                assetStatus: { _ in probe.status },
                reservedLocales: { probe.reservedLocales },
                maximumReservedLocales: { 1 },
                reserveLocale: { probe.reserve($0) },
                releaseLocale: { probe.release($0) },
                installAssets: { _ in probe.install() },
                transcribe: { _, _ in "Transcript" }
            ),
            startAccess: { _ in false }
        )

        let full = await service.availability(preferredLocale: selectedLocale)
        #expect(full.status == .reservationLimitReached)
        #expect(full.reservedLocales.map(\.identifier) == [reservedLocale.identifier])
        await #expect(throws: VoiceMemoTranscriptionError.languageReservationLimitReached(maximum: 1)) {
            _ = try await service.downloadLanguage(selectedLocale)
        }
        #expect(probe.installCount == 0)

        let released = await service.releaseLanguage(
            reservedLocale,
            preferredLocale: selectedLocale
        )
        #expect(released.status == .needsDownload)
        let installed = try await service.downloadLanguage(selectedLocale)
        #expect(installed.status == .installed)
        #expect(probe.releasedLocaleIdentifiers == [reservedLocale.identifier])
        #expect(probe.installCount == 1)
    }

    @Test("offline asset failure and incomplete installation stay explicit")
    func assetInstallationFailures() async {
        let selectedLocale = locale
        let failed = VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale] },
                resolveLocale: { _ in selectedLocale },
                assetStatus: { _ in .needsDownload },
                installAssets: { _ in throw VoiceMemoTranscriptionTestError.injected },
                transcribe: { _, _ in "Unused" }
            ),
            startAccess: { _ in false }
        )
        await #expect(throws: VoiceMemoTranscriptionError.languageDownloadFailed) {
            _ = try await failed.downloadLanguage(selectedLocale)
        }

        let incomplete = service(status: .needsDownload)
        await #expect(throws: VoiceMemoTranscriptionError.languageDownloadIncomplete) {
            _ = try await incomplete.downloadLanguage(selectedLocale)
        }
    }

    @Test("cancelling a language install cannot advance into a later state")
    func cancelledAssetInstallation() async throws {
        let selectedLocale = locale
        let gate = VoiceMemoTranscriptionGate()
        defer { Task { await gate.open() } }
        let service = VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale] },
                resolveLocale: { _ in selectedLocale },
                assetStatus: { _ in .needsDownload },
                installAssets: { _ in await gate.wait() },
                transcribe: { _, _ in "Must never run" }
            ),
            startAccess: { _ in false }
        )

        let task = Task { try await service.downloadLanguage(selectedLocale) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.hasWaiter), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasWaiter)
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("empty analysis cancels and drains its result consumer")
    func emptyAnalysis() async {
        let probe = VoiceMemoRecognitionLifecycleProbe()
        let session = VoiceMemoRecognitionSession(
            consumeFinalSegments: {
                try await Task.sleep(for: .seconds(30))
                return []
            },
            analyze: { nil },
            cancelAndFinish: { probe.cancel() }
        )

        await #expect(throws: VoiceMemoTranscriptionError.emptyAudio) {
            _ = try await VoiceMemoRecognitionPipeline.transcribe(session: session)
        }
        #expect(probe.cancelCount == 1)
    }

    @Test("consumer and finalization failures become privacy-safe recognition failures", arguments: [false, true])
    func recognitionFailures(consumerFails: Bool) async {
        let probe = VoiceMemoRecognitionLifecycleProbe()
        let session = VoiceMemoRecognitionSession(
            consumeFinalSegments: {
                if consumerFails { throw VoiceMemoTranscriptionTestError.injected }
                return ["Not publishable"]
            },
            analyze: {
                VoiceMemoRecognitionSession.AnalysisCompletion {
                    probe.finalize()
                    if !consumerFails { throw VoiceMemoTranscriptionTestError.injected }
                }
            },
            cancelAndFinish: { probe.cancel() }
        )

        await #expect(throws: VoiceMemoTranscriptionError.recognitionFailed) {
            _ = try await VoiceMemoRecognitionPipeline.transcribe(session: session)
        }
        #expect(probe.finalizeCount == 1)
        #expect(probe.cancelCount == 1)
    }

    @Test("long recognition cancellation finishes the analyzer before returning")
    func longRecognitionCancellation() async throws {
        let probe = VoiceMemoRecognitionLifecycleProbe()
        let gate = VoiceMemoTranscriptionGate()
        defer { Task { await gate.open() } }
        let session = VoiceMemoRecognitionSession(
            consumeFinalSegments: {
                try await Task.sleep(for: .seconds(30))
                return ["Late result"]
            },
            analyze: {
                await gate.wait()
                try Task.checkCancellation()
                return VoiceMemoRecognitionSession.AnalysisCompletion { probe.finalize() }
            },
            cancelAndFinish: {
                probe.cancel()
                await gate.open()
            }
        )

        let task = Task { try await VoiceMemoRecognitionPipeline.transcribe(session: session) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.hasWaiter), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasWaiter)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(probe.cancelCount == 1)
        #expect(probe.finalizeCount == 0)
    }

    @Test("malformed audio is an explicit non-destructive service failure")
    func malformedAudio() async {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let selectedLocale = locale
        let service = VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale] },
                resolveLocale: { _ in selectedLocale },
                assetStatus: { _ in .installed },
                installAssets: { _ in },
                makeRecognitionSession: { _, _ in
                    throw VoiceMemoTranscriptionError.audioUnreadable
                }
            ),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            startAccess: { _ in false }
        )

        await #expect(throws: VoiceMemoTranscriptionError.audioUnreadable) {
            _ = try await service.transcribe(imageURL: imageURL, locale: selectedLocale)
        }
    }

    @Test("transcription binds a trimmed draft to exact WAV identity and runs off MainActor")
    @MainActor
    func exactDraft() async throws {
        let found = association
        let revision = self.revision(hash: String(repeating: "a", count: 64))
        let selectedLocale = locale
        let queue = DispatchSerialQueue(label: "test.voice-memo.transcription")
        let runtime = VoiceMemoTranscriptionRuntime(
            isAvailable: { true },
            supportedLocales: { [selectedLocale] },
            resolveLocale: { _ in selectedLocale },
            assetStatus: { _ in .installed },
            installAssets: { _ in },
            transcribe: { url, selected in
                #expect(queue.isIsolatingCurrentContext() == true)
                #expect(url == found.memoURL)
                #expect(selected.identifier == selectedLocale.identifier)
                return "  A verified local transcript.  "
            }
        )
        let service = VoiceMemoTranscriptionService(
            runtime: runtime,
            filesystemQueue: queue,
            lookup: { _ in .available(found) },
            captureRevision: { _ in revision },
            now: { Date(timeIntervalSince1970: 123) },
            startAccess: { _ in false }
        )

        let draft = try await service.transcribe(imageURL: imageURL, locale: locale)

        #expect(draft.generatedText == "A verified local transcript.")
        #expect(draft.reviewedText == draft.generatedText)
        #expect(draft.memoSHA256 == revision.sha256)
        #expect(draft.memoByteCount == revision.byteCount)
        #expect(draft.provider == "Apple on-device speech")
        #expect(draft.providerModel == "System managed; exact version unavailable")
        #expect(draft.generatedAt == Date(timeIntervalSince1970: 123))
    }

    @Test("changed WAV bytes discard the generated result")
    func changedSourceIsRejected() async {
        let found = association
        let revisions = VoiceMemoRevisionSequence([
            revision(hash: String(repeating: "a", count: 64)),
            revision(hash: String(repeating: "b", count: 64)),
        ])
        let service = VoiceMemoTranscriptionService(
            runtime: runtime(status: .installed, transcript: "Must be discarded"),
            lookup: { _ in .available(found) },
            captureRevision: { _ in revisions.next() },
            startAccess: { _ in false }
        )

        await #expect(throws: VoiceMemoTranscriptionError.sourceChanged) {
            _ = try await service.transcribe(imageURL: imageURL, locale: locale)
        }
    }

    @Test("navigation cancellation rejects a late transcription result")
    @MainActor
    func navigationRejectsLateResult() async throws {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let selectedLocale = locale
        let gate = VoiceMemoTranscriptionGate()
        defer { Task { await gate.open() } }
        let service = VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale] },
                resolveLocale: { _ in selectedLocale },
                assetStatus: { _ in .installed },
                installAssets: { _ in },
                transcribe: { _, _ in
                    await gate.wait()
                    return "Late transcript"
                }
            ),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            startAccess: { _ in false }
        )
        let model = CaptionVoiceMemoTranscriptModel(service: service)
        await model.load(imageURL)
        let request = Task { await model.transcribe() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.hasWaiter), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasWaiter)
        model.cancel(resetDraft: true)
        await gate.open()
        await request.value

        #expect(model.draft == nil)
        #expect(!model.isTranscribing)
    }

    @Test("Caption presents draft review without metadata or relationship writes")
    func presentationContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Metadata/CaptionVoiceMemoPlayerView.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("caption.voiceMemo.transcriptionLanguage"))
        #expect(source.contains("caption.voiceMemo.downloadLanguage"))
        #expect(source.contains("caption.voiceMemo.releaseLanguage"))
        #expect(source.contains("caption.voiceMemo.cancelTranscription"))
        #expect(source.contains("caption.voiceMemo.transcriptDraft"))
        #expect(source.contains("caption.voiceMemo.approveTranscript"))
        #expect(source.contains("It does not change Description or any other IPTC field"))
    }

    @Test("approval and edit revocation persist generated and reviewed provenance")
    @MainActor
    func approvalRoundTrip() async throws {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let storage = VoiceMemoTranscriptStorageProbe()
        let service = VoiceMemoTranscriptionService(
            runtime: runtime(status: .installed, transcript: "Generated words"),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            loadTranscript: { _, _ in await storage.load() },
            saveTranscript: { record, _, _ in await storage.save(record) },
            now: { Date(timeIntervalSince1970: 500) },
            startAccess: { _ in false }
        )
        var draft = try await service.transcribe(imageURL: imageURL, locale: locale)
        draft.reviewedText = "Human-reviewed words"

        let approved = try await service.approve(draft)
        #expect(approved.approvedAt == Date(timeIntervalSince1970: 500))
        #expect(approved.generatedText == "Generated words")
        #expect(approved.reviewedText == "Human-reviewed words")
        #expect((await storage.load())?.approvedAt == approved.approvedAt)
        #expect(try await service.loadPersistedDraft(imageURL: imageURL) == approved)

        let model = CaptionVoiceMemoTranscriptModel(service: service)
        await model.load(imageURL)
        model.updateReviewedText("Edited after approval")
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isSavingReview, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.draft?.isApproved == false)
        #expect(model.draft?.reviewedText == "Edited after approval")
        #expect((await storage.load())?.reviewedText == "Edited after approval")
        #expect((await storage.load())?.approvedAt == nil)
    }

    @Test("metadata variable context requires and revalidates exact approval")
    func approvedVariableContext() async throws {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let approval = Date(timeIntervalSince1970: 200)
        let storage = VoiceMemoTranscriptStorageProbe(record: VoiceMemoTranscriptRecord(
            sourceImageFilename: imageURL.lastPathComponent,
            sourceMemoFilename: memoURL.lastPathComponent,
            memoByteCount: stable.byteCount,
            memoSHA256: stable.sha256,
            associationProfileIdentifier: found.profileIdentifier,
            localeIdentifier: locale.identifier,
            provider: "Apple on-device speech",
            providerModel: "System managed; exact version unavailable",
            generatedAt: Date(timeIntervalSince1970: 100),
            generatedText: "Generated text",
            reviewedText: "  Approved reviewed text  ",
            approvedAt: approval
        ))
        let service = VoiceMemoTranscriptionService(
            runtime: runtime(status: .installed),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            loadTranscript: { _, _ in await storage.load() },
            saveTranscript: { record, _, _ in await storage.save(record) },
            startAccess: { _ in false }
        )

        let context = try await service.approvedVariableContext(imageURL: imageURL)
        #expect(context.reviewedText == "Approved reviewed text")
        #expect(context.approvedAt == approval)
        try await service.validateVariableContext(context, imageURL: imageURL)

        var changed = try #require(await storage.load())
        changed.reviewedText = "A later approved edit"
        _ = await storage.save(changed)
        await #expect(throws: VoiceMemoTranscriptVariableError.approvalChanged) {
            try await service.validateVariableContext(context, imageURL: imageURL)
        }
    }

    @Test("unapproved transcript cannot authorize a metadata variable")
    func unapprovedVariableContext() async throws {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let storage = VoiceMemoTranscriptStorageProbe(record: VoiceMemoTranscriptRecord(
            sourceImageFilename: imageURL.lastPathComponent,
            sourceMemoFilename: memoURL.lastPathComponent,
            memoByteCount: stable.byteCount,
            memoSHA256: stable.sha256,
            associationProfileIdentifier: found.profileIdentifier,
            localeIdentifier: locale.identifier,
            provider: "Apple on-device speech",
            providerModel: "System managed; exact version unavailable",
            generatedAt: Date(timeIntervalSince1970: 100),
            generatedText: "Generated text",
            reviewedText: "Edited but not approved"
        ))
        let service = VoiceMemoTranscriptionService(
            runtime: runtime(status: .installed),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            loadTranscript: { _, _ in await storage.load() },
            startAccess: { _ in false }
        )

        await #expect(throws: VoiceMemoTranscriptVariableError.notApproved) {
            _ = try await service.approvedVariableContext(imageURL: imageURL)
        }
    }

    @Test("a failed replacement leaves the previously approved transcript visible")
    @MainActor
    func failedReplacementRetainsApprovedRecord() async throws {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let storage = VoiceMemoTranscriptStorageProbe(record: VoiceMemoTranscriptRecord(
            sourceImageFilename: imageURL.lastPathComponent,
            sourceMemoFilename: memoURL.lastPathComponent,
            memoByteCount: stable.byteCount,
            memoSHA256: stable.sha256,
            associationProfileIdentifier: found.profileIdentifier,
            localeIdentifier: locale.identifier,
            provider: "Apple on-device speech",
            providerModel: "System managed; exact version unavailable",
            generatedAt: Date(timeIntervalSince1970: 100),
            generatedText: "Original generated text",
            reviewedText: "Approved review",
            approvedAt: Date(timeIntervalSince1970: 200)
        ))
        let service = VoiceMemoTranscriptionService(
            runtime: runtime(status: .installed, transcript: "   "),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            loadTranscript: { _, _ in await storage.load() },
            saveTranscript: { record, _, _ in await storage.save(record) },
            startAccess: { _ in false }
        )
        let model = CaptionVoiceMemoTranscriptModel(service: service)
        await model.load(imageURL)
        #expect(model.draft?.isApproved == true)

        await model.transcribe()

        #expect(model.draft?.reviewedText == "Approved review")
        #expect(model.draft?.isApproved == true)
        #expect(model.errorMessage != nil)
        #expect((await storage.load())?.reviewedText == "Approved review")
    }

    @Test("cancelling a replacement retains the previously approved transcript")
    @MainActor
    func cancelledReplacementRetainsApprovedRecord() async throws {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let gate = VoiceMemoTranscriptionGate()
        defer { Task { await gate.open() } }
        let storage = VoiceMemoTranscriptStorageProbe(record: VoiceMemoTranscriptRecord(
            sourceImageFilename: imageURL.lastPathComponent,
            sourceMemoFilename: memoURL.lastPathComponent,
            memoByteCount: stable.byteCount,
            memoSHA256: stable.sha256,
            associationProfileIdentifier: found.profileIdentifier,
            localeIdentifier: locale.identifier,
            provider: "Apple on-device speech",
            providerModel: "System managed; exact version unavailable",
            generatedAt: Date(timeIntervalSince1970: 100),
            generatedText: "Original generated text",
            reviewedText: "Approved review",
            approvedAt: Date(timeIntervalSince1970: 200)
        ))
        let selectedLocale = locale
        let service = VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale] },
                resolveLocale: { _ in selectedLocale },
                assetStatus: { _ in .installed },
                installAssets: { _ in },
                transcribe: { _, _ in
                    await gate.wait()
                    return "Cancelled replacement"
                }
            ),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            loadTranscript: { _, _ in await storage.load() },
            saveTranscript: { record, _, _ in await storage.save(record) },
            startAccess: { _ in false }
        )
        let model = CaptionVoiceMemoTranscriptModel(service: service)
        await model.load(imageURL)
        let replacement = Task { await model.transcribe() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.hasWaiter), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.cancel()
        await gate.open()
        await replacement.value

        #expect(model.draft?.reviewedText == "Approved review")
        #expect(model.draft?.isApproved == true)
        #expect((await storage.load())?.reviewedText == "Approved review")
        #expect((await storage.load())?.approvedAt != nil)
    }

    private var association: VoiceMemoAssociation {
        VoiceMemoAssociation(
            profileIdentifier: "sony-test",
            imageURL: imageURL,
            memoURL: memoURL
        )
    }

    private func service(status: VoiceMemoTranscriptionAssetStatus) -> VoiceMemoTranscriptionService {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        return VoiceMemoTranscriptionService(
            runtime: runtime(status: status),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            startAccess: { _ in false }
        )
    }

    private func service(probe: VoiceMemoTranscriptionProbe) -> VoiceMemoTranscriptionService {
        let found = association
        let stable = revision(hash: String(repeating: "a", count: 64))
        let selectedLocale = locale
        return VoiceMemoTranscriptionService(
            runtime: VoiceMemoTranscriptionRuntime(
                isAvailable: { true },
                supportedLocales: { [selectedLocale] },
                resolveLocale: { _ in selectedLocale },
                assetStatus: { _ in probe.status },
                installAssets: { _ in probe.install() },
                transcribe: { _, _ in "Transcript" }
            ),
            lookup: { _ in .available(found) },
            captureRevision: { _ in stable },
            startAccess: { _ in false }
        )
    }

    private func runtime(
        status: VoiceMemoTranscriptionAssetStatus,
        transcript: String = "Transcript"
    ) -> VoiceMemoTranscriptionRuntime {
        let selectedLocale = locale
        return VoiceMemoTranscriptionRuntime(
            isAvailable: { true },
            supportedLocales: { [selectedLocale] },
            resolveLocale: { _ in selectedLocale },
            assetStatus: { _ in status },
            installAssets: { _ in },
            transcribe: { _, _ in transcript }
        )
    }

    private func revision(hash: String) -> SourceImageRevision {
        SourceImageRevision(
            canonicalURL: memoURL,
            fileResourceIdentifier: nil,
            filenameAtCreation: memoURL.lastPathComponent,
            byteCount: 42,
            contentModificationDate: .distantPast,
            pixelWidth: nil,
            pixelHeight: nil,
            exifOrientation: nil,
            sha256: hash,
            hashCompletedAt: .distantPast
        )
    }
}

nonisolated private final class VoiceMemoTranscriptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: VoiceMemoTranscriptionAssetStatus
    private var storedInstallCount = 0

    init(status: VoiceMemoTranscriptionAssetStatus) {
        storedStatus = status
    }

    var status: VoiceMemoTranscriptionAssetStatus { lock.withLock { storedStatus } }
    var installCount: Int { lock.withLock { storedInstallCount } }

    func install() {
        lock.withLock {
            storedInstallCount += 1
            storedStatus = .installed
        }
    }
}

nonisolated private enum VoiceMemoTranscriptionTestError: Error {
    case injected
}

nonisolated private final class VoiceMemoLanguageReservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: VoiceMemoTranscriptionAssetStatus
    private var storedReservedLocales: [Locale]
    private var storedReleasedLocaleIdentifiers: [String] = []
    private var storedInstallCount = 0

    init(status: VoiceMemoTranscriptionAssetStatus, reservedLocales: [Locale]) {
        storedStatus = status
        storedReservedLocales = reservedLocales
    }

    var status: VoiceMemoTranscriptionAssetStatus { lock.withLock { storedStatus } }
    var reservedLocales: [Locale] { lock.withLock { storedReservedLocales } }
    var releasedLocaleIdentifiers: [String] { lock.withLock { storedReleasedLocaleIdentifiers } }
    var installCount: Int { lock.withLock { storedInstallCount } }

    func reserve(_ locale: Locale) {
        lock.withLock {
            if !storedReservedLocales.contains(where: { $0.identifier == locale.identifier }) {
                storedReservedLocales.append(locale)
            }
        }
    }

    func release(_ locale: Locale) -> Bool {
        lock.withLock {
            guard let index = storedReservedLocales.firstIndex(where: {
                $0.identifier == locale.identifier
            }) else { return false }
            storedReservedLocales.remove(at: index)
            storedReleasedLocaleIdentifiers.append(locale.identifier)
            return true
        }
    }

    func install() {
        lock.withLock {
            storedInstallCount += 1
            storedStatus = .installed
        }
    }
}

nonisolated private final class VoiceMemoRecognitionLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCancelCount = 0
    private var storedFinalizeCount = 0

    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var finalizeCount: Int { lock.withLock { storedFinalizeCount } }

    func cancel() { lock.withLock { storedCancelCount += 1 } }
    func finalize() { lock.withLock { storedFinalizeCount += 1 } }
}

nonisolated private final class VoiceMemoRevisionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [SourceImageRevision]

    init(_ revisions: [SourceImageRevision]) { self.revisions = revisions }

    func next() -> SourceImageRevision {
        lock.withLock {
            if revisions.count > 1 { return revisions.removeFirst() }
            return revisions[0]
        }
    }
}

private actor VoiceMemoTranscriptionGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var hasWaiter = false

    func wait() async {
        hasWaiter = true
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
        hasWaiter = false
    }
}

private actor VoiceMemoTranscriptStorageProbe {
    private var record: VoiceMemoTranscriptRecord?

    init(record: VoiceMemoTranscriptRecord? = nil) {
        self.record = record
    }

    func load() -> VoiceMemoTranscriptRecord? { record }

    func save(_ replacement: VoiceMemoTranscriptRecord) -> VoiceMemoTranscriptRecord {
        record = replacement
        return replacement
    }
}

nonisolated private enum CaptionVoiceMemoTestContext {
    @TaskLocal static var marker: String?
}

nonisolated private final class CaptionVoiceMemoProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] { lock.withLock { storage } }
    func record(_ event: String) { lock.withLock { storage.append(event) } }
}

nonisolated private final class CaptionVoiceMemoRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var events: [String] { lock.withLock { storage } }
    func record(_ event: String) { lock.withLock { storage.append(event) } }
}

nonisolated private final class CaptionVoiceMemoTestPlayer: CaptionVoiceMemoAudioPlayer {
    let probe: CaptionVoiceMemoProbe
    let duration: TimeInterval = 10
    var currentTime: TimeInterval = 0
    var isPlaying = false
    init(probe: CaptionVoiceMemoProbe) { self.probe = probe }
    deinit { probe.record("destroy") }
    func play() -> Bool { probe.record("play"); isPlaying = true; return true }
    func pause() { probe.record("pause"); isPlaying = false }
    func stop() { probe.record("stop"); isPlaying = false }
}

@Suite("Caption Workspace speed tools")
@MainActor
struct CaptionWorkspaceSpeedToolsTests {
    @Test("confirmed people require named groups and valid geometry, then sort left to right")
    func confirmedPersonOrdering() {
        let imageURL = URL(fileURLWithPath: "/caption/a.jpg")
        let otherURL = URL(fileURLWithPath: "/caption/b.jpg")
        let leftGroup = FaceGroup(
            id: UUID(), name: "Left Person", representativeFaceID: UUID(), faceIDs: []
        )
        let rightGroup = FaceGroup(
            id: UUID(), name: "Right Person", representativeFaceID: UUID(), faceIDs: []
        )
        let unnamedGroup = FaceGroup(
            id: UUID(), name: nil, representativeFaceID: UUID(), faceIDs: []
        )
        let faces = [
            face(imageURL, CGRect(x: 0.65, y: 0.25, width: 0.2, height: 0.3), rightGroup.id),
            face(imageURL, CGRect(x: 0.10, y: 0.30, width: 0.2, height: 0.3), leftGroup.id),
            face(imageURL, CGRect(x: 0.40, y: 0.30, width: 0.2, height: 0.3), unnamedGroup.id),
            face(imageURL, CGRect(x: -0.1, y: 0.30, width: 0.2, height: 0.3), leftGroup.id),
            face(otherURL, CGRect(x: 0.05, y: 0.20, width: 0.2, height: 0.3), leftGroup.id),
        ]
        let data = FolderFaceData(
            folderURL: imageURL.deletingLastPathComponent(),
            faces: faces,
            groups: [rightGroup, unnamedGroup, leftGroup],
            lastScanDate: .distantPast,
            scanComplete: true
        )

        let people = CaptionConfirmedPersonOrdering.people(for: imageURL, in: data)
        #expect(people.map(\.name) == ["Left Person", "Right Person"])
    }

    @Test("priority fields preserve profile order and separate technical fields")
    func fieldLayout() {
        let configuration = DeadlineCaptionFieldConfiguration(
            orderedFieldIDs: [.countryCode, .description, .headline, .personShown, .urgency],
            visibleFieldIDs: [.countryCode, .description, .headline, .personShown, .urgency]
        )
        let layout = CaptionWorkspaceFieldLayout.make(configuration: configuration)
        #expect(layout.priority == [.description, .headline, .personShown])
        #expect(layout.secondary == [.countryCode, .urgency])
    }

    @Test("non-Deadline layout and keyboard path preserve global customization order")
    func customizedGlobalFieldLayout() {
        let configuration = DeadlineCaptionFieldConfiguration(
            orderedFieldIDs: [.countryCode, .headline, .urgency, .description],
            visibleFieldIDs: [.countryCode, .headline, .urgency, .description]
        )
        let layout = CaptionWorkspaceFieldLayout.make(
            configuration: configuration,
            groupsSecondaryFields: false
        )

        #expect(layout.priority == [.countryCode, .headline, .urgency, .description])
        #expect(layout.secondary.isEmpty)
        #expect(CaptionKeyboardOrder(priorityFields: layout.priority).surfaces.prefix(4) == [
            .priorityField(.countryCode),
            .priorityField(.headline),
            .priorityField(.urgency),
            .priorityField(.description),
        ])
    }

    @Test("headline and caption counts use the narrowest optional profile limit")
    func fieldCountsAndLimits() {
        let profile = MetadataValidationProfile(name: "Caption", rules: [
            MetadataValidationRule(
                id: "headline-max-80",
                severity: .warning,
                requirement: .maximumLength(field: .headline, count: 80)
            ),
            MetadataValidationRule(
                id: "headline-max-64",
                severity: .blocker,
                requirement: .maximumLength(field: .headline, count: 64)
            ),
        ])
        var metadata = IPTCMetadata()
        metadata.title = "Four"
        #expect(CaptionWorkspaceValidationSummary.characterCount(
            for: .headline,
            metadata: metadata
        ) == 4)
        #expect(CaptionWorkspaceValidationSummary.maximumCharacterCount(
            for: .headline,
            profile: profile
        ) == 64)
    }

    @Test("compact checklist keeps shared readiness and next-issue ordering")
    func compactChecklistSummary() {
        let imageURL = URL(fileURLWithPath: "/caption/a.jpg")
        let warning = MetadataValidationIssue(
            id: "description.warning",
            imageURL: imageURL,
            field: .description,
            severity: .warning,
            message: "Description needs attention.",
            technicalDetail: nil
        )
        let firstBlocker = MetadataValidationIssue(
            id: "headline.blocker",
            imageURL: imageURL,
            field: .headline,
            severity: .blocker,
            message: "Headline is required.",
            technicalDetail: nil
        )
        let laterBlocker = MetadataValidationIssue(
            id: "creator.blocker",
            imageURL: imageURL,
            field: .creator,
            severity: .blocker,
            message: "Creator is required.",
            technicalDetail: nil
        )

        let blocked = CaptionWorkspaceChecklistSummary.make(report: MetadataValidationReport(
            issues: [warning, firstBlocker, laterBlocker]
        ))
        #expect(blocked.readiness == .blocked)
        #expect(blocked.blockerCount == 2)
        #expect(blocked.warningCount == 1)
        #expect(blocked.informationCount == 0)
        #expect(blocked.nextIssue == firstBlocker)

        let visibleOnly = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [firstBlocker, warning]),
            actionableFields: [.description]
        )
        #expect(visibleOnly.readiness == .blocked)
        #expect(visibleOnly.blockerCount == 1)
        #expect(visibleOnly.nextIssue == warning)

        let noVisibleIssue = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [firstBlocker]),
            actionableFields: []
        )
        #expect(noVisibleIssue.readiness == .blocked)
        #expect(noVisibleIssue.blockerCount == 1)
        #expect(noVisibleIssue.nextIssue == nil)

        let warnings = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [warning])
        )
        #expect(warnings.readiness == .warnings)
        #expect(warnings.nextIssue == warning)

        let ready = CaptionWorkspaceChecklistSummary.make(
            report: MetadataValidationReport(issues: [])
        )
        #expect(ready.readiness == .ready)
        #expect(ready.nextIssue == nil)
    }

    @Test("face rectangles convert from Vision bottom-left to preview top-left coordinates")
    func previewGeometry() {
        let fitted = CaptionPreviewGeometry.fittedImageRect(
            imageSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 300, height: 300)
        )
        #expect(fitted == CGRect(x: 0, y: 75, width: 300, height: 150))
        let face = CaptionPreviewGeometry.displayRect(
            forVisionRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            in: fitted
        )
        #expect(face == CGRect(x: 75, y: 112.5, width: 150, height: 75))
    }

    @Test("write and next advances only after success for the unchanged image")
    func writeAndNextGate() {
        let current = URL(fileURLWithPath: "/caption/a.jpg")
        #expect(CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: current,
            currentURL: current,
            writeSucceeded: true, hasPendingChanges: false, hasUnpersistedEditorChanges: false
        ))
        #expect(!CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: current,
            currentURL: URL(fileURLWithPath: "/caption/b.jpg"),
            writeSucceeded: true, hasPendingChanges: false, hasUnpersistedEditorChanges: false
        ))
        #expect(!CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: current,
            currentURL: current,
            writeSucceeded: false, hasPendingChanges: false, hasUnpersistedEditorChanges: false
        ))
        for (pending, unpersisted) in [(true, false), (false, true), (true, true)] {
            #expect(!CaptionWriteAndNextGate.shouldAdvance(pendingURL: current, currentURL: current,
                writeSucceeded: true, hasPendingChanges: pending, hasUnpersistedEditorChanges: unpersisted))
        }
    }

    @Test("caption advance shortcuts persist and cannot remain ambiguous")
    func captionShortcutRegistry() throws {
        let suiteName = "CaptionWorkspaceSpeedToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = CaptionAdvanceShortcutRegistry(defaults: defaults, storageKey: "advance")
        let chord = KeyboardShortcutChord(key: "return", modifiers: [.command, .option])

        registry.assign(chord, to: .saveAndNext)
        registry.assign(chord, to: .writeAndNext)
        #expect(registry.chord(for: .saveAndNext) == nil)
        #expect(registry.chord(for: .writeAndNext) == chord)

        let reopened = CaptionAdvanceShortcutRegistry(defaults: defaults, storageKey: "advance")
        #expect(reopened.bindings == registry.bindings)
        #expect(CaptionAdvanceShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: "\r",
            modifiers: [.command, .option],
            textEditorOwnsInput: true,
            imeHasMarkedText: false,
            isRepeat: false
        ), bindings: reopened.bindings) == .writeAndNext)
        #expect(CaptionAdvanceShortcutRouter.resolve(KeyboardShortcutRouteInput(
            key: "\r",
            modifiers: [.command, .option],
            textEditorOwnsInput: true,
            imeHasMarkedText: true,
            isRepeat: false
        ), bindings: reopened.bindings) == nil)
    }

    @Test("Tab order is deterministic across priority fields and actions in both directions")
    func keyboardTraversalOrder() {
        let order = CaptionKeyboardOrder(priorityFields: [.description, .headline])
        #expect(order.surfaces.prefix(3) == [
            .priorityField(.description),
            .priorityField(.headline),
            .action(.previous),
        ])
        #expect(order.adjacent(to: .priorityField(.description), reverse: false)
            == .priorityField(.headline))
        #expect(order.adjacent(to: .priorityField(.description), reverse: true)
            == .action(.close))
        #expect(order.adjacent(to: .action(.close), reverse: false)
            == .priorityField(.description))
        #expect(CaptionKeyboardOrder(priorityFields: []).adjacent(
            to: nil,
            reverse: false
        ) == .action(.previous))
    }

    @Test("completion announcements are fixed and contain no editorial or path placeholders")
    func privacySafeAnnouncements() {
        #expect(AppAccessibilityAnnouncement.success(.captionSavedAndAdvanced).spokenText
            == "Saved and moved to the next photo.")
        #expect(AppAccessibilityAnnouncement.success(.captionWroteAndAdvanced).spokenText
            == "Wrote metadata and moved to the next photo.")
        for announcement in [
            AppAccessibilityAnnouncement.success(.captionSavedAndAdvanced),
            .success(.captionWroteAndAdvanced),
        ] {
            #expect(!announcement.spokenText.contains("/"))
            #expect(!announcement.spokenText.contains("{"))
            #expect(!announcement.spokenText.contains("%"))
        }
    }

    @Test("Caption Workspace exposes the sticky speed tools and prose-only spelling boundary")
    func staticViewAudit() throws {
        let caption = try source("Aagedal Photo Agent/Views/Metadata/CaptionWorkspaceView.swift")
        for label in [
            "Previous", "Save & Next", "Write & Next", "Apply Template", "Copy Previous",
            "Fix Next", "Full Screen", "Faces", "Metadata checks", "All metadata fields",
            "Secondary & Technical",
        ] {
            #expect(caption.contains(label), "Missing \(label)")
        }
        #expect(caption.contains("@State private var showsAllFields = false"))
        #expect(caption.contains("actionableFields: Set(layout.priority + layout.secondary)"))
        #expect(caption.contains("settingsViewModel.orderedIPTCMetadataFields"))
        #expect(caption.contains("settingsViewModel.visibleIPTCMetadataFieldsInOrder"))
        #expect(caption.contains("caption.metadataChecklist.nextIssue"))
        #expect(caption.contains("caption.metadataChecklist.noActionableIssue"))
        #expect(caption.contains("caption.metadataChecklist.ready"))
        #expect(caption.contains("caption.metadataChecklist.disclosure"))
        #expect(caption.contains("Additional IPTC fields can be enabled in Settings → Metadata."))
        #expect(caption.contains("Button(\"Metadata Settings…\")"))
        #expect(caption.contains("settingsViewModel.requestedDestination = .metadata"))
        #expect(caption.contains("openSettings()"))
        #expect(caption.contains("caption.metadataSettings"))
        #expect(caption.contains("CaptionWorkspaceFlushCoordinator.shared.flush()"))
        #expect(caption.contains("preservingEditorFocus"))
        #expect(caption.contains("CaptionAdvanceShortcutRouter.resolve"))
        #expect(caption.contains("imeHasMarkedText: inputState.imeHasMarkedText"))
        #expect(caption.contains("event.keyCode == 48"))
        #expect(caption.contains("moveCaptionFocus(reverse:"))
        #expect(caption.contains("moveCaptionFocus(from: field, reverse: reverse)"))
        #expect(caption.contains("AccessibilityAnnouncementCenter.post(.success(.captionSavedAndAdvanced))"))
        #expect(caption.contains("AccessibilityAnnouncementCenter.post(.success(.captionWroteAndAdvanced))"))
        #expect(caption.contains("onDismiss: restoreLastEditorFocus"))
        #expect(caption.contains(".labelsHidden()"))
        #expect(caption.contains(".frame(height: 92)"))

        let panel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        #expect(panel.contains("let proseFields: Set<MetadataFieldID> = [.headline, .description, .extendedDescription]"))
        #expect(panel.contains("editor.isContinuousSpellCheckingEnabled = enabled"))
        #expect(panel.contains("editor.isGrammarCheckingEnabled = enabled"))
        #expect(panel.contains("restoreCaptionAutocompleteFocus()"))
        #expect(panel.contains(".restoreCaptionEditorFocus"))
        #expect(panel.contains(".onKeyPress(.tab)"))
        #expect(panel.contains("handleTab(reverse: true)"))
        #expect(panel.contains("!editor.hasMarkedText()"))

        let autocomplete = try source("Aagedal Photo Agent/Views/Metadata/CaptionAutocompletePopover.swift")
        let codeReplacement = try source("Aagedal Photo Agent/Views/Metadata/CodeReplacementSettingsView.swift")
        let template = try source("Aagedal Photo Agent/Views/Templates/TemplatePaletteView.swift")
        #expect(autocomplete.contains(".onKeyPress(.escape)"))
        #expect(codeReplacement.components(separatedBy: ".onKeyPress(.escape)").count >= 3)
        #expect(template.contains(".onKeyPress(.escape)"))

        let settings = try source("Aagedal Photo Agent/Views/Settings/SettingsView.swift")
        #expect(settings.contains(".onChange(of: settingsViewModel.requestedDestination)"))
        #expect(settings.contains("case .metadata: selection = .metadata"))
        #expect(settings.contains("settingsViewModel.requestedDestination = nil"))
        #expect(settings.contains("RequiredMetadataFieldsSection(settingsViewModel: settingsViewModel)"))

        let customization = try source("Aagedal Photo Agent/Views/Settings/RequiredMetadataFieldsSection.swift")
        #expect(customization.contains("settingsViewModel.orderedIPTCMetadataFields"))
        #expect(customization.contains(".draggable(field.rawValue)"))
        #expect(customization.contains(".dropDestination(for: String.self)"))
        #expect(customization.contains("Validation for \\(field.displayName)"))
        #expect(customization.contains("Move \\(field.displayName) up"))
        #expect(customization.contains("Move \\(field.displayName) down"))
        #expect(customization.contains("Warn and Require continue to validate hidden fields"))

        #expect(panel.contains("settingsViewModel.visibleIPTCMetadataFieldsInOrder"))
        #expect(panel.contains("editablePrimaryMetadataField(field)"))
        #expect(panel.contains("editableAdditionalMetadataField(field)"))
    }

    @Test("every stable IPTC field has concise localized guidance")
    func metadataFieldGuidanceCoverage() {
        #expect(MetadataFieldID.allCases.count == 33)
        for field in MetadataFieldID.allCases {
            let guidance = field.guidance
            #expect(!guidance.commonUse.isEmpty, "Missing common use for \(field)")
            #expect(!guidance.example.isEmpty, "Missing example for \(field)")
            #expect(guidance.commonUse.count <= 100, "Common use is not concise for \(field)")
            #expect(guidance.example.count <= 90, "Example is not concise for \(field)")
            #expect(guidance.helpText.contains(guidance.commonUse))
            #expect(guidance.helpText.contains(guidance.example))
        }
    }

    @Test("Metadata panel shares field guidance across hover and accessibility")
    func metadataPanelGuidanceAudit() throws {
        let model = try source("Aagedal Photo Agent/Models/MetadataFieldID.swift")
        let panel = try source("Aagedal Photo Agent/Views/Metadata/MetadataPanel.swift")
        let supplier = try source("Aagedal Photo Agent/Views/Metadata/ImageSupplierMetadataEditor.swift")

        #expect(model.contains("String(localized:"))
        #expect(panel.contains("private struct MetadataFieldGuidanceModifier"))
        #expect(panel.contains(".help(helpText)"))
        #expect(panel.contains(".accessibilityElement(children: .contain)"))
        #expect(panel.contains(".accessibilityHint(helpText)"))
        #expect(panel.contains(".metadataField(field)"))

        let directlyComposedFields = [
            "headline", "description", "extendedDescription", "keywords", "personShown",
            "organisationShownName", "organisationShownCode", "copyright", "creator",
            "rightsUsageTerms", "webStatementOfRights", "digitalImageGUID",
            "imageSupplierImageID", "jobId", "dateCreated", "digitalSourceType", "urgency",
            "sceneCode", "subjectCode", "mediaTopic", "genre", "credit", "city", "country",
            "countryCode", "event",
        ]
        for field in directlyComposedFields {
            #expect(panel.contains(".metadataField(.\(field))"), "Missing panel guidance for \(field)")
        }

        for field in [
            "creatorJobTitle", "descriptionWriter", "source", "sublocation", "provinceState",
            "instructions",
        ] {
            let inlineCall = "simpleAdditionalField(.\(field)"
            let multilineArgument = ".\(field),"
            #expect(
                panel.contains(inlineCall) || panel.contains(multilineArgument),
                "Missing simple editor for \(field)"
            )
        }
        #expect(supplier.contains(".metadataField(.imageSupplier)"))
    }

    private func face(
        _ imageURL: URL,
        _ rect: CGRect,
        _ groupID: UUID?
    ) -> DetectedFace {
        DetectedFace(
            id: UUID(),
            imageURL: imageURL,
            faceRect: rect,
            featurePrintData: Data(),
            groupID: groupID,
            detectedAt: .distantPast
        )
    }

    private func source(_ relativePath: String) throws -> String {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: workspace.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
