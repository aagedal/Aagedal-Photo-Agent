import CryptoKit
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

    private actor AdmissionAttempts {
        private(set) var count = 0
        func next() -> Int { count += 1; return count }
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

    @Test("Relaunch exposes removal for corrupt regular weights without admitting them", arguments: [false, true])
    func corruptInstallationRecovery(checksumMismatch: Bool) async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("model fixture".utf8)
        let artifact = WhisperDownloadableModel(id: "fixture", title: "Fixture", byteCount: Int64(expected.count),
            sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/model.bin")!)
        let target = root.appendingPathComponent("ggml-fixture.bin")
        let corrupt = checksumMismatch ? Data(repeating: 0, count: expected.count) : Data([0])
        try corrupt.write(to: target)
        let downloads = WhisperModelDownloadService(directory: root, fetch: { _, _, _ in
            throw URLError(.notConnectedToInternet)
        })
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in try await downloads.installedURL(for: artifact) },
            download: { _, progress in try await downloads.download(artifact, progress: progress) },
            remove: { _ in try await downloads.remove(artifact) },
            admit: { _, _ in await calls.admitted(); throw URLError(.unsupportedURL) })
        // A fresh setup instance discovers only local filesystem state, as on relaunch.
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        await setup.refresh()
        #expect(setup.canRemoveModel && !setup.isInstalled && !setup.isReady)
        #expect(setup.errorMessage != nil)
        #expect(setup.provider(language: "auto", useGPU: false, translate: false) == nil)
        #expect(await calls.admissions == 0)
        setup.downloadSelectedModel()
        try await waitUntil { !setup.isDownloading }
        #expect(setup.canRemoveModel && !setup.isInstalled && !setup.isReady)
        #expect(try Data(contentsOf: target) == corrupt)
        await setup.removeSelectedModel()
        #expect(!setup.canRemoveModel && !setup.isInstalled && !setup.isReady)
        #expect(setup.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: root.appendingPathComponent("model")) == expected)
        await setup.refresh()
        #expect(!setup.canRemoveModel && setup.errorMessage == nil)
    }

    @Test("Replacement verifies new weights before readiness; cancellation preserves corrupt weights", arguments: [false, true])
    func replaceCorruptWeights(cancel: Bool) async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("model fixture".utf8)
        let artifact = WhisperDownloadableModel(id: "fixture", title: "Fixture", byteCount: Int64(expected.count),
            sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/model.bin")!)
        let target = root.appendingPathComponent("ggml-fixture.bin")
        let corrupt = Data([0])
        try corrupt.write(to: target)
        let gate = Gate()
        let calls = Calls()
        let downloads = WhisperModelDownloadService(directory: root, fetch: { _, destination, _ in
            await calls.downloaded()
            try expected.prefix(4).write(to: destination)
            await gate.pause()
            try Task.checkCancellation()
            try expected.write(to: destination)
        })
        let admission = FFmpegWhisperArtifactAdmissionService()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in try await downloads.installedURL(for: artifact) },
            download: { _, progress in try await downloads.download(artifact, progress: progress) },
            remove: { _ in try await downloads.remove(artifact) },
            admit: { url, _ in
                await calls.admitted()
                return try await admission.admitCustom(executableURL: root.appendingPathComponent("ffmpeg"), modelURL: url)
            })
        let setup = ManagedWhisperSetupModel(defaults: preferences, admission: admission, operations: operations)
        await setup.refresh()
        #expect(setup.needsModelReplacement && setup.canRemoveModel && !setup.isReady)
        setup.downloadSelectedModel()
        try await waitUntil { await gate.started }
        #expect(try Data(contentsOf: target) == corrupt)
        #expect(!setup.isInstalled && !setup.isReady && setup.needsModelReplacement)
        #expect(await calls.admissions == 0)
        if cancel { setup.cancelDownload() }
        await gate.resume()
        try await waitUntil { !setup.isDownloading }
        #expect(setup.errorMessage == nil)
        #expect(setup.needsModelReplacement == cancel)
        #expect(setup.isInstalled == !cancel && setup.isReady == !cancel)
        #expect(try Data(contentsOf: target) == (cancel ? corrupt : expected))
        #expect(await calls.admissions == (cancel ? 0 : 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["ffmpeg", "ggml-fixture.bin", "model"])
        #expect(try Data(contentsOf: root.appendingPathComponent("model")) == expected)
        let relaunched = ManagedWhisperSetupModel(defaults: preferences, admission: admission, operations: operations)
        await relaunched.refresh()
        #expect(relaunched.needsModelReplacement == cancel && relaunched.isReady == !cancel)
        #expect(await calls.downloads == 1)
    }

    @Test("Unsafe storage failures do not advertise corrupt-model removal")
    func unsafeStorageRecovery() async {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in throw WhisperModelDownloadService.DownloadError.unsafeStorage },
            download: { _, _ in throw URLError(.unsupportedURL) }, remove: { _ in },
            admit: { _, _ in throw URLError(.unsupportedURL) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        await setup.refresh()
        #expect(!setup.canRemoveModel && !setup.isInstalled && !setup.isReady)
        #expect(setup.errorMessage != nil)
    }

    @Test("Failed corrupt-model removal retains recovery, while model changes clear it")
    func failedCorruptRemoval() async {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in throw WhisperModelDownloadService.DownloadError.checksumMismatch },
            download: { _, _ in throw URLError(.unsupportedURL) },
            remove: { _ in throw CocoaError(.fileWriteNoPermission) },
            admit: { _, _ in throw URLError(.unsupportedURL) })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        await setup.refresh()
        await setup.removeSelectedModel()
        #expect(setup.canRemoveModel && !setup.isInstalled && !setup.isReady)
        #expect(setup.errorMessage == CocoaError(.fileWriteNoPermission).localizedDescription)
        setup.selectModel("tiny")
        #expect(!setup.canRemoveModel && setup.errorMessage == nil)
    }

    @Test("Inventory separates local models from downloads without granting readiness")
    func inventoryGroups() async {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in nil }, download: { _, _ in await calls.downloaded(); throw URLError(.unsupportedURL) },
            remove: { _ in }, admit: { _, _ in await calls.admitted(); throw URLError(.unsupportedURL) },
            localModelIDs: { ["base", "tiny", "unknown"] })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        await setup.refreshCatalog()
        #expect(setup.downloadedModels.map(\.id) == ["tiny", "base"])
        #expect(Set(setup.downloadableModels.map(\.id)) == Set(WhisperDownloadableModel.catalog.map(\.id)).subtracting(["tiny", "base"]))
        #expect(!setup.isInstalled && !setup.isReady && !setup.canRemoveModel)
        #expect(await calls.downloads == 0)
        #expect(await calls.admissions == 0)
        await setup.removeSelectedModel()
        #expect(setup.localModelIDs == ["tiny"])
    }

    @Test("A late inventory refresh cannot overwrite a newer snapshot")
    func staleInventory() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let attempts = AdmissionAttempts()
        let gate = Gate()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in nil }, download: { _, _ in throw URLError(.unsupportedURL) },
            remove: { _ in }, admit: { _, _ in throw URLError(.unsupportedURL) },
            localModelIDs: {
                if await attempts.next() == 1 { await gate.pause(); return ["base"] }
                return ["tiny"]
            })
        let setup = ManagedWhisperSetupModel(defaults: preferences, operations: operations)
        let old = Task { await setup.refreshCatalog() }
        try await waitUntil { await gate.started }
        await setup.refreshCatalog()
        await gate.resume()
        await old.value
        #expect(setup.localModelIDs == ["tiny"] && setup.catalogErrorMessage == nil)
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

    @Test("Retrying setup admits an installed model without downloading it again")
    func retryInstalledAdmission() async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = FFmpegWhisperArtifactAdmissionService()
        let receipt = try await admission.admitCustom(
            executableURL: root.appendingPathComponent("ffmpeg"),
            modelURL: root.appendingPathComponent("model"))
        let attempts = AdmissionAttempts()
        let calls = Calls()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in receipt.model.url },
            download: { _, _ in await calls.downloaded(); throw URLError(.unsupportedURL) },
            remove: { _ in },
            admit: { _, _ in
                if await attempts.next() == 1 { throw URLError(.cannotOpenFile) }
                return receipt
            })
        let setup = ManagedWhisperSetupModel(defaults: preferences, admission: admission, operations: operations)
        await setup.refresh()
        #expect(setup.isInstalled && !setup.isReady && setup.errorMessage != nil)
        await setup.refresh()
        #expect(setup.isInstalled && setup.isReady && setup.errorMessage == nil)
        #expect(await attempts.count == 2)
        #expect(await calls.downloads == 0)
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

    @Test("Removal serializes destructive actions and discards stale failure reconciliation", arguments: [false, true])
    func removalExclusionAndStaleRecovery(corrupt: Bool) async throws {
        let (preferences, suite) = defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let calls = Calls()
        let gate = Gate()
        let operations = ManagedWhisperSetupModel.Operations(
            installed: { _ in
                await gate.pause()
                if corrupt { throw WhisperModelDownloadService.DownloadError.checksumMismatch }
                return URL(fileURLWithPath: "/tmp/unused-model")
            },
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
        #expect(!setup.canRemoveModel)
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
