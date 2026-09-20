import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Custom Whisper provider setup")
@MainActor
struct FFmpegWhisperSetupModelTests {
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

    @Test("provider choice persists but artifacts and execution consent never do")
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

    @Test("selection never admits or executes files and explicit consent gates readiness")
    func consent() async throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = FFmpegWhisperSetupModel(defaults: defaults)
        setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        setup.select(folder.appendingPathComponent("model"), executable: false)
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
        setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        await setup.prepare()
        #expect(setup.isReady)
        setup.select(folder.appendingPathComponent("model"), executable: false)
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
        setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        setup.select(folder.appendingPathComponent("missing"), executable: false)
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
        setup.select(folder.appendingPathComponent("ffmpeg"), executable: true)
        setup.select(folder.appendingPathComponent("model"), executable: false)
        setup.executionConsent = true
        let work = Task { await setup.prepare() }
        work.cancel()
        await work.value
        #expect(!setup.isReady)
        #expect(setup.provider() == nil)
    }
}
