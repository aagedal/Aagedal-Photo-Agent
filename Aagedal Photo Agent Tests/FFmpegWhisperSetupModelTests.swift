import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Custom Whisper provider setup")
@MainActor
struct FFmpegWhisperSetupModelTests {
    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore,
                                                   seconds: Double = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    private nonisolated static func hasSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    @Test("An outstanding settings file picker cannot replace files during a transcription")
    func fileSelectionRefusesWhileTranscribing() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: preferences)
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        await setup.prepare()
        #expect(setup.isReady)
        let bookmark = preferences.data(forKey: FFmpegWhisperSetupModel.executableBookmarkKey)
        #expect(setup.beginTranscription())
        #expect(!setup.beginTranscription())
        await setup.select(folder.appendingPathComponent("replacement"), executable: true)
        #expect(setup.isReady && setup.executionConsent)
        #expect(setup.executableURL?.lastPathComponent == "ffmpeg")
        #expect(preferences.data(forKey: FFmpegWhisperSetupModel.executableBookmarkKey) == bookmark)
        #expect(setup.errorMessage != nil)
        setup.finishTranscription()
        #expect(!setup.isTranscribing)
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "WhisperSetupTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func fixture() throws -> URL {
        let root = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(root) }
        let folder = URL(fileURLWithPath: String(cString: root)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("never executed fixture".utf8).write(to: folder.appendingPathComponent("ffmpeg"))
        try Data("custom model fixture".utf8).write(to: folder.appendingPathComponent("model"))
        #expect(chmod(folder.appendingPathComponent("ffmpeg").path, 0o700) == 0)
        return folder
    }

    @Test("provider choice persists without granting execution consent")
    func persistence() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        #expect(setup.choice == .appleSpeech)
        setup.choice = .customWhisper
        let reopened = FFmpegWhisperSetupModel(defaults: defaults)
        #expect(reopened.choice == .customWhisper)
        #expect(!reopened.isReady)
        #expect(!reopened.executionConsent)
        #expect(reopened.provider() == nil)
        #expect(reopened.executableURL == nil)
        #expect(reopened.modelURL == nil)
    }

    @Test("inference settings persist while malformed language never becomes a process option")
    func inferenceSettingsPersistence() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en:destination=/tmp/unsafe", forKey: FFmpegWhisperSetupModel.languageKey)
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        #expect(setup.language == "auto")
        #expect(!setup.translate)
        #expect(!setup.useGPU)
        setup.language = " NO "
        setup.translate = true
        setup.useGPU = true
        #expect(setup.language == "no")
        setup.language = String(repeating: "x", count: 1000)
        #expect(setup.language.count == 16)
        #expect(!setup.isLanguageValid)
        let reopened = FFmpegWhisperSetupModel(defaults: defaults)
        #expect(reopened.language == "no")
        #expect(reopened.translate)
        #expect(reopened.useGPU)
        #expect(!reopened.executionConsent)
        #expect(reopened.provider() == nil)
    }

    @Test("enabled custom provider snapshots settings and preserves exact translated provenance")
    func configuredProvider() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.language = "no"
        setup.translate = true
        setup.useGPU = true
        #expect(setup.provider() == nil)
        setup.executionConsent = true
        await setup.prepare()
        let candidate = setup.provider(run: { request in
            #expect(request.language == "no")
            #expect(request.translate)
            #expect(request.useGPU)
            #expect(FFmpegWhisperJobRunner.arguments(request).contains(
                "whisper=model=model.bin:language=no:use_gpu=true:translate=true:max_len=0:destination=output.json:format=json"))
            return .init(request: request, transcript: .init(
                segments: [.init(start: 0, end: 50, text: "English translation")],
                editableText: "English translation"))
        })
        let provider = try #require(candidate)
        setup.language = "en"
        setup.translate = false
        setup.useGPU = false
        let result = try await provider.transcribe(audio: .init(
            url: folder.appendingPathComponent("memo.wav"), byteCount: 1,
            sha256: String(repeating: "a", count: 64)))
        #expect(result.provenance.requestedLanguage == "no")
        #expect(result.provenance.translate)
        #expect(result.provenance.useGPU)
        #expect(result.provenance.schemaVersion == 2)
        let decoded = try JSONDecoder().decode(FFmpegWhisperTranscriptProvenance.self,
                                               from: JSONEncoder().encode(result.provenance))
        #expect(decoded == result.provenance)
        var oldSchema = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(result.provenance)) as? [String: Any])
        oldSchema["schemaVersion"] = 1
        let unsafeUpgrade = try JSONSerialization.data(withJSONObject: oldSchema)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FFmpegWhisperTranscriptProvenance.self, from: unsafeUpgrade)
        }
        setup.language = "no:translate=true"
        #expect(setup.provider() == nil)
        setup.language = "auto"
        #expect(setup.provider() != nil)
        setup.executionConsent = false
        #expect(setup.provider() == nil)
    }

    @Test("selection never admits or executes files and explicit consent gates readiness")
    func consent() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        await setup.prepare()
        #expect(!setup.isReady)
        #expect(setup.provider() == nil)
        setup.executionConsent = true
        await setup.prepare()
        #expect(setup.isReady)
        #expect(setup.provider() != nil)
        // The deliberately non-runnable bytes above demonstrate setup only captures identity.
        setup.executionConsent = false
        #expect(!setup.isReady)
        #expect(setup.provider() == nil)
    }

    @Test("replacing even the same selected file revokes consent and requires new admission")
    func reselection() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        setup.choice = .customWhisper
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        await setup.prepare()
        #expect(setup.isReady)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        #expect(!setup.executionConsent)
        #expect(setup.provider() == nil)
        setup.clear()
        #expect(setup.executableURL == nil)
        #expect(setup.modelURL == nil)
        #expect(setup.choice == .customWhisper)
    }

    @Test("failed admission remains unavailable without switching providers")
    func admissionFailure() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        setup.choice = .customWhisper
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("missing"), executable: false)
        setup.executionConsent = true
        await setup.prepare()
        #expect(setup.errorMessage != nil)
        #expect(!setup.isPreparing)
        #expect(setup.provider() == nil)
        #expect(setup.choice == .customWhisper)
    }

    @Test("cancelled setup publishes no usable provider")
    func cancellation() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        let work = Task { await setup.prepare() }
        work.cancel()
        await work.value
        #expect(!setup.isReady)
        #expect(setup.provider() == nil)
    }

    @Test("retained selections restore without consent and require fresh identity admission")
    func restoreAndReadmit() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        await setup.prepare()
        #expect(setup.isReady)
        setup.endSession()
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.modelBookmarkKey) != nil)
        let reopened = FFmpegWhisperSetupModel(defaults: defaults)
        await reopened.restoreSelections()
        #expect(reopened.executableURL == folder.appendingPathComponent("ffmpeg"))
        #expect(reopened.modelURL == folder.appendingPathComponent("model"))
        #expect(!reopened.executionConsent)
        await reopened.prepare()
        #expect(reopened.provider() == nil)
        // Restored access is not an admission receipt: a now-empty model is rejected.
        try Data().write(to: folder.appendingPathComponent("model"))
        reopened.executionConsent = true
        await reopened.prepare()
        #expect(!reopened.isReady)
        #expect(reopened.errorMessage != nil)
    }

    @Test("stale bookmarks refresh while missing files remain recoverable and Clear forgets them")
    func staleMissingAndClear() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("ffmpeg")
        let old = Data("old".utf8)
        let refreshed = Data("refreshed".utf8)
        let missing = Data("missing".utf8)
        defaults.set(old, forKey: FFmpegWhisperSetupModel.executableBookmarkKey)
        defaults.set(missing, forKey: FFmpegWhisperSetupModel.modelBookmarkKey)
        var dependencies = FFmpegWhisperBookmarkService.Dependencies()
        dependencies.resolve = { data in
            (data == old ? executable : folder.appendingPathComponent("absent"), true)
        }
        dependencies.create = { _ in refreshed }
        let setup = FFmpegWhisperSetupModel(defaults: defaults,
            bookmarks: FFmpegWhisperBookmarkService(dependencies: dependencies))
        await setup.restoreSelections()
        #expect(setup.executableURL == executable)
        #expect(setup.modelURL == nil)
        #expect(setup.errorMessage != nil)
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.executableBookmarkKey) == refreshed)
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.modelBookmarkKey) == missing)
        #expect(!setup.executionConsent)
        setup.clear()
        await setup.restoreSelections()
        #expect(setup.executableURL == nil)
        #expect(setup.modelURL == nil)
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.executableBookmarkKey) == nil)
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.modelBookmarkKey) == nil)
    }

    @Test("failed stale refresh retains original bookmark without publishing access")
    func failedRefresh() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Data("old".utf8)
        defaults.set(old, forKey: FFmpegWhisperSetupModel.modelBookmarkKey)
        var dependencies = FFmpegWhisperBookmarkService.Dependencies()
        dependencies.resolve = { _ in (folder.appendingPathComponent("model"), true) }
        dependencies.create = { _ in throw CocoaError(.fileReadNoPermission) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults,
            bookmarks: FFmpegWhisperBookmarkService(dependencies: dependencies))
        await setup.restoreSelections()
        #expect(setup.modelURL == nil)
        #expect(setup.errorMessage != nil)
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.modelBookmarkKey) == old)
    }


    @Test("Clear during bookmark creation rejects late publication and balances access")
    func clearDuringSelection() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        var dependencies = FFmpegWhisperBookmarkService.Dependencies()
        dependencies.access = { url in
            WhisperArtifactAccess(url, start: { _ in true }, stop: { _ in released.signal() })
        }
        dependencies.create = { _ in
            entered.signal()
            _ = resume.wait(timeout: .now() + 10)
            return Data("retained".utf8)
        }
        let setup = FFmpegWhisperSetupModel(defaults: defaults,
            bookmarks: FFmpegWhisperBookmarkService(dependencies: dependencies))
        let selection = Task { await setup.select(URL(fileURLWithPath: "/custom/model"), executable: false) }
        let started = await Self.waitForSignal(entered)
        #expect(started)
        setup.clear()
        resume.signal()
        await selection.value
        #expect(setup.modelURL == nil)
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.modelBookmarkKey) == nil)
        #expect(await Self.waitForSignal(released, seconds: 1))
    }


    @Test("ending a session during restore cannot publish either saved file")
    func endSessionDuringRestore() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        defaults.set(Data("executable".utf8), forKey: FFmpegWhisperSetupModel.executableBookmarkKey)
        defaults.set(Data("model".utf8), forKey: FFmpegWhisperSetupModel.modelBookmarkKey)
        var dependencies = FFmpegWhisperBookmarkService.Dependencies()
        dependencies.resolve = { data in
            entered.signal()
            _ = resume.wait(timeout: .now() + 10)
            return (URL(fileURLWithPath: "/custom/" + String(decoding: data, as: UTF8.self)), false)
        }
        dependencies.exists = { _ in true }
        dependencies.access = { url in
            WhisperArtifactAccess(url, start: { _ in true }, stop: { _ in released.signal() })
        }
        let setup = FFmpegWhisperSetupModel(defaults: defaults,
            bookmarks: FFmpegWhisperBookmarkService(dependencies: dependencies))
        let restoration = Task { await setup.restoreSelections() }
        let started = await Self.waitForSignal(entered)
        #expect(started)
        setup.endSession()
        resume.signal()
        await restoration.value
        #expect(setup.executableURL == nil)
        #expect(setup.modelURL == nil)
        #expect(!setup.executionConsent)
        #expect(await Self.waitForSignal(released, seconds: 1))
        #expect(!Self.hasSignal(entered))
        #expect(defaults.data(forKey: FFmpegWhisperSetupModel.modelBookmarkKey) != nil)
    }

    @Test("a provider retains both security scopes after setup is cleared")
    func providerScopeLifetime() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let released = DispatchSemaphore(value: 0)
        var dependencies = FFmpegWhisperBookmarkService.Dependencies()
        dependencies.create = { _ in Data("retained".utf8) }
        dependencies.access = { url in
            WhisperArtifactAccess(url, start: { _ in true }, stop: { _ in released.signal() })
        }
        let setup = FFmpegWhisperSetupModel(defaults: defaults,
            bookmarks: FFmpegWhisperBookmarkService(dependencies: dependencies))
        await setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        await setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        await setup.prepare()
        var provider = setup.provider()
        #expect(provider != nil)
        setup.clear()
        withExtendedLifetime(provider) {
            #expect(!Self.hasSignal(released))
        }
        provider = nil
        #expect(await Self.waitForSignal(released, seconds: 1))
        #expect(await Self.waitForSignal(released, seconds: 1))
    }

}
