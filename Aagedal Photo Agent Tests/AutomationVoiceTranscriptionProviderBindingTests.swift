import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Immutable native transcription provider binding")
struct AutomationVoiceTranscriptionProviderBindingTests {
    private typealias Binding = AutomationVoiceTranscriptionProviderBinding

    private func intent(provider: String = "whisper", language: String = "auto",
                        translate: Bool = false, useGPU: Bool = false,
                        planID: String = "00000000-0000-0000-0000-000000000001",
                        photoPath: String = "/photos/frame.jpg") throws -> MCPVoiceTranscriptionReviewRequestStore.Intent {
        var photo = Dictionary(uniqueKeysWithValues: MCPVoiceTranscriptionPlanStore.Request.photoKeys
            .subtracting(["path"]).map { ($0, MCPJSONValue.string(String(repeating: "a", count: 64))) })
        photo["canonicalPath"] = .string(photoPath)
        photo["rootID"] = .string("00000000-0000-0000-0000-000000000002")
        photo["photoIdentity"] = .string(String(repeating: "b", count: 64))
        photo["audioIdentity"] = .string(String(repeating: "c", count: 64))
        return try .init(preview: .object([
            "schemaVersion": .integer(1), "previewOnly": .bool(true),
            "executionAvailable": .bool(false), "commitAvailable": .bool(false), "consentGranted": .bool(false),
            "planID": .string(planID), "createdAt": .string("2026-10-02T10:00:00Z"),
            "expiresAt": .string("2026-10-02T10:05:00Z"),
            "options": .object(["provider": .string(provider), "language": .string(language),
                                "translate": .bool(translate), "useGPU": .bool(useGPU)]),
            "photos": .array([.object(photo)])
        ]))
    }

    private func configuration(executableURL: URL = URL(fileURLWithPath: "/native/ffmpeg"),
        executableByteCount: Int64 = 100, executableHash: String = String(repeating: "d", count: 64),
        build: String = "reviewed-build", modelURL: URL = URL(fileURLWithPath: "/native/model.bin"),
        modelByteCount: Int64 = 200, modelHash: String = String(repeating: "e", count: 64),
        model: String = "reviewed-model", language: String = "auto", useGPU: Bool = false,
        timeout: Double = 30, translate: Bool = false) -> FFmpegWhisperTranscriptionProvider.Configuration {
        .init(executable: .init(url: executableURL, byteCount: executableByteCount, sha256: executableHash),
              buildIdentifier: build, model: .init(url: modelURL, byteCount: modelByteCount, sha256: modelHash),
              modelIdentifier: model, language: language, useGPU: useGPU, timeoutSeconds: timeout, translate: translate)
    }

    private func provider(_ configuration: FFmpegWhisperTranscriptionProvider.Configuration)
        -> AutomationVoiceTranscriptionBatchService.Provider {
        .whisper(.init(configuration: configuration, authorizeArtifacts: { _ in
            Issue.record("Provider binding must not invoke authorization or readiness")
            throw FFmpegWhisperJobError.invalidRequest
        }, run: { _ in
            Issue.record("Provider binding must not run inference")
            throw FFmpegWhisperJobError.invalidRequest
        }))
    }

    @Test("Apple binding compares the concrete Foundation locale identifier with exact requested language")
    func appleLocale() throws {
        let requested = try intent(provider: "appleSpeech", language: "EN-us")
        let retained = try Binding.bind(intent: requested, provider: .apple(Locale(identifier: "en_US")))
        #expect(retained.identity == .apple(localeIdentifier: "en-us"))
        #expect(retained.intentSHA256 == (try requested.sha256))
        try retained.requireMatches(intent: requested)
        for locale in ["en_GB", "en", "nb_NO", "en_Cyrl_US"] {
            #expect(throws: Binding.Failure.providerMismatch) {
                try Binding.bind(intent: requested, provider: .apple(Locale(identifier: locale)))
            }
        }
        #expect(throws: Binding.Failure.providerMismatch) {
            try Binding.bind(intent: requested, provider: .apple(Locale(identifier: "en_US")), whisperKind: .curated)
        }
        // Foundation removes the default Latin script before the provider is passed
        // to binding. Its actual identifier is en_US, identical to the retained locale.
        let defaultScript = Locale(identifier: "en_Latn_US")
        #expect(defaultScript.identifier == "en_US")
        #expect(try Binding.bind(intent: requested, provider: .apple(defaultScript)).identity == retained.identity)

        let scriptedIntent = try intent(provider: "appleSpeech", language: "sr-Latn-RS")
        let scripted = try Binding.bind(intent: scriptedIntent, provider: .apple(Locale(identifier: "sr_Latn_RS")))
        #expect(scripted.identity == .apple(localeIdentifier: "sr-latn-rs"))
        #expect(throws: Binding.Failure.providerMismatch) {
            try Binding.bind(intent: scriptedIntent, provider: .apple(Locale(identifier: "sr_Cyrl_RS")))
        }
    }

    @Test("Whisper retains all exact configuration fields without performing effects")
    func whisperSnapshot() throws {
        let requested = try intent(language: "nb", translate: true, useGPU: true)
        let configured = configuration(language: "nb", useGPU: true, timeout: 49.5, translate: true)
        let retained = try Binding.bind(intent: requested, provider: provider(configured), whisperKind: .curated)
        #expect(retained.identity == .whisper(kind: .curated, configuration: configured))
        try retained.requireMatches(intent: requested)
        guard case .whisper(let native) = retained.provider else { Issue.record("Concrete provider was not retained"); return }
        #expect(native.configurationSnapshot == configured)
        let changes = [configuration(executableURL: URL(fileURLWithPath: "/other/ffmpeg"), language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(executableByteCount: 101, language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(executableHash: String(repeating: "f", count: 64), language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(build: "other-build", language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(modelURL: URL(fileURLWithPath: "/other/model.bin"), language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(modelByteCount: 201, language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(modelHash: String(repeating: "f", count: 64), language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(model: "other-model", language: "nb", useGPU: true, timeout: 49.5, translate: true),
            configuration(language: "nb", useGPU: true, timeout: 50, translate: true)]
        for changed in changes {
            let other = try Binding.bind(intent: requested, provider: provider(changed), whisperKind: .curated)
            #expect(other.identity != retained.identity)
        }
        // Independent subsequent native selection cannot mutate the retained configuration.
        #expect(native.configurationSnapshot == configured)
        try retained.requireMatches(intent: requested)
    }

    @Test("Explicit native classification is mandatory; artifact names confer no trust")
    func explicitClassification() throws {
        let curated = try intent(), custom = try intent(provider: "customWhisper")
        let native = provider(configuration(build: "curated-looking-name", model: "curated-looking-model"))
        #expect(throws: Binding.Failure.providerMismatch) { try Binding.bind(intent: curated, provider: native) }
        #expect(throws: Binding.Failure.providerMismatch) { try Binding.bind(intent: curated, provider: native, whisperKind: .custom) }
        #expect(throws: Binding.Failure.providerMismatch) { try Binding.bind(intent: custom, provider: native, whisperKind: .curated) }
        let bound = try Binding.bind(intent: custom, provider: native, whisperKind: .custom)
        #expect(bound.identity == .whisper(kind: .custom, configuration: configuration(build: "curated-looking-name", model: "curated-looking-model")))
        #expect(throws: Binding.Failure.providerMismatch) {
            try Binding.bind(intent: curated, provider: .apple(Locale(identifier: "en_US")))
        }
        #expect(throws: Binding.Failure.providerMismatch) {
            try Binding.bind(intent: intent(provider: "appleSpeech", language: "en-US"), provider: native, whisperKind: .curated)
        }
    }

    @Test("Every provider option mismatch refuses the binding")
    func mismatchedOptions() throws {
        let requested = try intent(language: "nb", translate: true, useGPU: true)
        for changed in [configuration(language: "en", useGPU: true, translate: true),
                        configuration(language: "nb", useGPU: false, translate: true),
                        configuration(language: "nb", useGPU: true, translate: false)] {
            #expect(throws: Binding.Failure.providerMismatch) {
                try Binding.bind(intent: requested, provider: provider(changed), whisperKind: .curated)
            }
        }
    }

    @Test("Configuration metadata, URLs, hashes, sizes and timeout are bounded")
    func invalidConfiguration() throws {
        let requested = try intent()
        let invalid = [configuration(executableURL: URL(string: "https://example.com/ffmpeg")!),
            configuration(executableURL: URL(string: "file://remote-host/ffmpeg")!),
            configuration(executableURL: URL(string: "file:///native/ffmpeg?options=1")!),
            configuration(executableURL: URL(fileURLWithPath: "/native/" + String(repeating: "x", count: 4097))),
            configuration(executableByteCount: 0), configuration(executableByteCount: 512 * 1024 * 1024 + 1),
            configuration(executableHash: String(repeating: "A", count: 64)), configuration(build: " "),
            configuration(build: String(repeating: "x", count: 1025)), configuration(build: "build\ncontrol"),
            configuration(modelByteCount: 0), configuration(modelByteCount: Int64(4) * 1024 * 1024 * 1024 + 1),
            configuration(modelHash: "missing"), configuration(model: ""),
            configuration(model: String(repeating: "x", count: 1025)), configuration(language: "EN"),
            configuration(timeout: .nan), configuration(timeout: .infinity), configuration(timeout: 0),
            configuration(timeout: -1), configuration(timeout: 3600.01)]
        for invalid in invalid {
            #expect(throws: Binding.Failure.invalidProvider) {
                try Binding.bind(intent: requested, provider: provider(invalid), whisperKind: .curated)
            }
        }
        _ = try Binding.bind(intent: requested, provider: provider(configuration(timeout: 3600)), whisperKind: .curated)
    }

    @Test("Revalidation binds the exact plan and ordered photo intent")
    func exactIntent() throws {
        let requested = try intent()
        let retained = try Binding.bind(intent: requested, provider: provider(configuration()), whisperKind: .curated)
        #expect(throws: Binding.Failure.intentMismatch) {
            try retained.requireMatches(intent: intent(planID: "00000000-0000-0000-0000-000000000003"))
        }
        #expect(throws: Binding.Failure.intentMismatch) {
            try retained.requireMatches(intent: intent(photoPath: "/photos/another.jpg"))
        }
        #expect(throws: Binding.Failure.providerMismatch) {
            try retained.requireMatches(intent: intent(useGPU: true))
        }
        try retained.requireMatches(intent: requested)
    }

    @Test("Decoded malformed intent cannot acquire a native binding", arguments: ["options", "planID", "dates", "rootID", "photoIdentity", "audioIdentity", "schemaVersion"])
    func invalidIntent(kind: String) throws {
        let requested = try intent()
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(requested)) as? [String: Any])
        switch kind {
        case "options":
            var options = try #require(raw["options"] as? [String: Any])
            options["extra"] = "unbounded-option"; raw["options"] = options
        case "planID": raw["planID"] = "invalid-plan"
        case "dates": raw["planExpiresAt"] = "2026-10-02T10:06:00Z"
        case "schemaVersion": raw["schemaVersion"] = 2
        default:
            var photos = try #require(raw["photos"] as? [[String: Any]])
            photos[0][kind] = "invalid-identity"; raw["photos"] = photos
        }
        let malformed = try JSONDecoder().decode(MCPVoiceTranscriptionReviewRequestStore.Intent.self,
            from: JSONSerialization.data(withJSONObject: raw))
        #expect(throws: Binding.Failure.invalidIntent) {
            try Binding.bind(intent: malformed, provider: provider(configuration()), whisperKind: .curated)
        }
    }
}
