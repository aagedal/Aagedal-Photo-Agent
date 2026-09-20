import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Managed Whisper setup lifecycle")
@MainActor
struct ManagedWhisperSetupModelTests {
    private actor Calls {
        var downloads = 0
        var admissions = 0
        var removals = 0
        func downloaded() { downloads += 1 }
        func admitted() { admissions += 1 }
        func removed() { removals += 1 }
    }

    private actor Gate {
        var started = false
        var pauses = 0
        private var continuation: CheckedContinuation<Void, Never>?
        func pause() async {
            started = true
            pauses += 1
            await withCheckedContinuation { continuation = $0 }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "ManagedWhisperSetupTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func fixture() throws -> URL {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("never executed fixture".utf8).write(to: root.appendingPathComponent("ffmpeg"))
        try Data("model fixture".utf8).write(to: root.appendingPathComponent("model"))
        #expect(chmod(root.appendingPathComponent("ffmpeg").path, 0o700) == 0)
        return root
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for setup state")
        throw URLError(.timedOut)
    }

    @Test("Initialization, model selection and refresh never download implicitly")
    func explicitDownloadOnly() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("unknown", forKey: ManagedWhisperSetupModel.modelPreferenceKey)
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in nil },
            download: { _, _ in await calls.downloaded(); throw URLError(.notConnectedToInternet) },
            remove: { _ in await calls.removed() },
            admit: { _, _ in await calls.admitted(); throw URLError(.badServerResponse) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        #expect(setup.selectedModelID == "base")
        setup.selectModel("small")
        setup.selectModel("invalid")
        await setup.refresh()
        #expect(setup.selectedModelID == "small")
        #expect(!setup.isInstalled && !setup.isReady && !setup.isRefreshing)
        #expect(setup.provider(language: "auto", useGPU: false, translate: false) == nil)
        #expect(await calls.downloads == 0)
        #expect(await calls.admissions == 0)
        #expect(ManagedWhisperSetupModel(defaults: preferences, operations: operations).selectedModelID == "small")
        setup.downloadSelectedModel()
        try await waitUntil { !setup.isDownloading }
        #expect(await calls.downloads == 1)
        #expect(setup.errorMessage != nil)
    }

    @Test("Switching models discards a delayed installed-file lookup")
    func staleLookup() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = Gate()
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in await gate.pause(); return URL(fileURLWithPath: "/tmp/unused-model") },
            download: { _, _ in throw URLError(.unsupportedURL) }, remove: { _ in },
            admit: { _, _ in await calls.admitted(); throw URLError(.badServerResponse) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        let refresh = Task { await setup.refresh() }
        try await waitUntil { await gate.started }
        #expect(setup.isRefreshing)
        setup.selectModel("tiny")
        await gate.resume()
        await refresh.value
        #expect(setup.selectedModelID == "tiny")
        #expect(!setup.isInstalled && !setup.isReady && !setup.isRefreshing)
        #expect(setup.errorMessage == nil)
        #expect(await calls.admissions == 0)
    }

    @Test("Switching models revokes a receipt returned by an obsolete admission")
    func staleAdmission() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await admission.admitCustom(executableURL: root.appendingPathComponent("ffmpeg"), modelURL: root.appendingPathComponent("model"))
        let gate = Gate()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in receipt.model.url },
            download: { _, _ in throw URLError(.unsupportedURL) }, remove: { _ in },
            admit: { _, _ in await gate.pause(); return receipt })
        let setup = ManagedWhisperSetupModel(defaults: preferences, admission: admission, operations: operations)
        let refresh = Task { await setup.refresh() }
        try await waitUntil { await gate.started }
        setup.selectModel("tiny")
        await gate.resume()
        await refresh.value
        #expect(!setup.isReady && !setup.isInstalled)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.revoked) {
            try await admission.authorizer(for: receipt)(receipt.configuration())
        }
    }

    @Test("Cancellation suppresses noncooperative download completion and permits retry")
    func cancelledDownload() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = Gate()
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in nil },
            download: { _, progress in
                await calls.downloaded()
                progress(0.4)
                await gate.pause()
                return URL(fileURLWithPath: "/tmp/unused-model")
            }, remove: { _ in },
            admit: { _, _ in await calls.admitted(); throw URLError(.badServerResponse) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        setup.downloadSelectedModel()
        try await waitUntil { await gate.started }
        setup.downloadSelectedModel()
        #expect(await calls.downloads == 1)
        setup.cancelDownload()
        await gate.resume()
        try await waitUntil { !setup.isDownloading }
        #expect(!setup.isReady && !setup.isInstalled)
        #expect(setup.errorMessage == nil)
        #expect(await calls.admissions == 0)
        setup.downloadSelectedModel()
        try await waitUntil { await gate.pauses == 2 }
        setup.cancelDownload()
        await gate.resume()
        try await waitUntil { !setup.isDownloading }
        #expect(setup.errorMessage == nil)
    }

    @Test("An installed model is not ready when bundled artifact admission fails")
    func failedAdmission() async {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in URL(fileURLWithPath: "/tmp/unused-model") },
            download: { _, _ in throw URLError(.unsupportedURL) }, remove: { _ in },
            admit: { _, _ in throw FFmpegWhisperArtifactAdmissionService.AdmissionError.artifactChanged })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        await setup.refresh()
        #expect(setup.isInstalled && !setup.isReady && !setup.isRefreshing)
        #expect(setup.errorMessage != nil)
        #expect(setup.provider(language: "auto", useGPU: false, translate: false) == nil)
    }

    @Test("Successful admission gates readiness and snapshots exact provenance; removal revokes readiness")
    func readinessAndProvenance() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await admission.admitCustom(executableURL: root.appendingPathComponent("ffmpeg"), modelURL: root.appendingPathComponent("model"))
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in receipt.model.url },
            download: { _, progress in await calls.downloaded(); progress(0.8); return receipt.model.url },
            remove: { _ in await calls.removed() },
            admit: { _, _ in await calls.admitted(); return receipt })
        let setup = ManagedWhisperSetupModel(defaults: preferences, admission: admission, operations: operations)
        #expect(setup.provider(language: "no", useGPU: true, translate: true) == nil)
        setup.downloadSelectedModel()
        try await waitUntil { !setup.isDownloading }
        #expect(setup.isReady && setup.isInstalled && setup.progress == 1)
        let candidate = setup.provider(language: "no", useGPU: true, translate: true, run: { request in
            #expect(request.language == "no" && request.useGPU && request.translate)
            return .init(request: request, transcript: .init(segments: [.init(start: 0, end: 10, text: "Translated memo")], editableText: "Translated memo"))
        })
        let provider = try #require(candidate)
        // Reopening Settings while this provider is retained must not replace/revoke its receipt.
        await setup.refresh()
        let result = try await provider.transcribe(audio: .init(url: root.appendingPathComponent("memo.wav"), byteCount: 1, sha256: String(repeating: "a", count: 64)))
        #expect(result.provenance.requestedLanguage == "no")
        #expect(result.provenance.useGPU && result.provenance.translate)
        #expect(result.provenance.modelIdentifier == receipt.modelIdentifier)
        #expect(result.provenance.modelSHA256 == receipt.model.sha256)
        await setup.removeSelectedModel()
        #expect(!setup.isReady && !setup.isInstalled && !setup.isRefreshing)
        #expect(await calls.removals == 1)
        #expect(setup.provider(language: "auto", useGPU: false, translate: false) == nil)
    }

    @Test("UI-test launches without a valid model root never use the production cache")
    func isolatedUITestStorage() throws {
        #expect(ManagedWhisperSetupModel.uiTestModelDirectory(arguments: []) == nil)
        #expect(ManagedWhisperSetupModel.uiTestModelDirectory(arguments: ["--ui-test-whisper-model-root", "/tmp/ignored"]) == nil)
        for arguments in [["--ui-testing"], ["--ui-testing", "--ui-test-whisper-model-root"],
                          ["--ui-testing", "--ui-test-whisper-model-root", "relative"]] {
            let root = try #require(ManagedWhisperSetupModel.uiTestModelDirectory(arguments: arguments))
            #expect(root.lastPathComponent.hasPrefix("WhisperUITests-"))
            #expect(root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
        }
        #expect(ManagedWhisperSetupModel.uiTestModelDirectory(arguments: ["--ui-testing", "--ui-test-whisper-model-root", "/tmp/fixture"])?.path == "/tmp/fixture")
    }

    @Test("User cancellation suppresses URLSession cancellation errors and delayed progress")
    func cancelledTransportError() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let gate = Gate()
        let progressGate = Gate()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in nil },
            download: { _, progress in
                progress(0.2)
                await gate.pause()
                progress(0.9)
                await progressGate.pause()
                throw URLError(.cancelled)
            }, remove: { _ in },
            admit: { _, _ in throw URLError(.unsupportedURL) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        setup.downloadSelectedModel()
        try await waitUntil { await gate.started && setup.progress == 0.2 }
        setup.cancelDownload()
        await gate.resume()
        try await waitUntil { await progressGate.started }
        await progressGate.resume()
        try await waitUntil { !setup.isDownloading }
        #expect(setup.progress == 0.2)
        #expect(setup.errorMessage == nil)
        #expect(!setup.isReady && !setup.isInstalled)
    }

    @Test("Failed removal preserves installed recovery controls without restoring readiness")
    func failedRemovalCanRetry() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in URL(fileURLWithPath: "/tmp/unused-model") },
            download: { _, _ in throw URLError(.unsupportedURL) },
            remove: { _ in
                await calls.removed()
                if await calls.removals == 1 { throw CocoaError(.fileWriteNoPermission) }
            },
            admit: { _, _ in throw URLError(.unsupportedURL) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        await setup.refresh()
        await setup.removeSelectedModel()
        #expect(setup.isInstalled && !setup.isReady && !setup.isRefreshing)
        #expect(setup.errorMessage != nil)
        #expect(setup.provider(language: "auto", useGPU: false, translate: false) == nil)
        await setup.removeSelectedModel()
        #expect(await calls.removals == 2)
        #expect(!setup.isInstalled && !setup.isReady && !setup.isRefreshing)
        #expect(setup.errorMessage == nil)
    }

    @Test("Removal serializes destructive actions and discards stale failure reconciliation")
    func removalExclusionAndStaleRecovery() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let calls = Calls()
        let gate = Gate()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in await gate.pause(); return URL(fileURLWithPath: "/tmp/unused-model") },
            download: { _, _ in await calls.downloaded(); throw URLError(.unsupportedURL) },
            remove: { _ in await calls.removed(); throw CocoaError(.fileWriteNoPermission) },
            admit: { _, _ in throw URLError(.unsupportedURL) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        let removal = Task { await setup.removeSelectedModel() }
        try await waitUntil { await gate.started }
        setup.downloadSelectedModel()
        await setup.removeSelectedModel()
        #expect(await calls.downloads == 0)
        #expect(await calls.removals == 1)
        setup.selectModel("tiny")
        await gate.resume()
        await removal.value
        #expect(!setup.isInstalled && !setup.isReady && !setup.isRefreshing)
        #expect(setup.errorMessage == nil)
    }


    @Test("Cancelling during admission revokes the late receipt while retaining installed-model recovery")
    func cancelledAdmissionReceipt() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await admission.admitCustom(executableURL: root.appendingPathComponent("ffmpeg"), modelURL: root.appendingPathComponent("model"))
        let gate = Gate()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in receipt.model.url },
            download: { _, _ in receipt.model.url }, remove: { _ in },
            admit: { _, _ in await gate.pause(); return receipt })
        let setup = ManagedWhisperSetupModel(defaults: preferences, admission: admission, operations: operations)
        setup.downloadSelectedModel()
        try await waitUntil { await gate.started }
        setup.cancelDownload()
        await gate.resume()
        try await waitUntil { !setup.isDownloading }
        #expect(setup.isInstalled && !setup.isReady)
        #expect(setup.errorMessage == nil)
        #expect(setup.provider(language: "auto", useGPU: false, translate: false) == nil)
        await #expect(throws: FFmpegWhisperArtifactAdmissionService.AdmissionError.revoked) {
            try await admission.authorizer(for: receipt)(receipt.configuration())
        }
    }

}
