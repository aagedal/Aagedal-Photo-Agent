import Foundation
import MLX
import MLXLLM
import MLXVLM
import MLXLMCommon
import Observation

/// A single model owner shared by interactive requests and a future sequential batch worker.
/// Busy admission spans every await, so actor reentrancy cannot overlap GPU inference/loading.
actor DescriptionAssistantService {
    static let shared = DescriptionAssistantService()
    private var container: ModelContainer?
    private var loadedDirectory: URL?
    private var busy = false
    private let appleGenerator: @Sendable (String, DescriptionAssistantLanguage) async throws -> String
    private let textGenerator: (@Sendable (String, URL) async throws -> String)?
    private let vlmFactory = VLMModelFactory(
        typeRegistry: ModelTypeRegistry(creators: ["gemma3": { sourceData in
            let data = try BorealisModelConfiguration.adapted(sourceData)
            return MLXVLM.Gemma3(try JSONDecoder().decode(MLXVLM.Gemma3Configuration.self, from: data))
        }]), processorRegistry: VLMProcessorTypeRegistry.shared, modelRegistry: VLMRegistry.shared)
    private let llmFactory = LLMModelFactory(
        typeRegistry: ModelTypeRegistry(creators: [
            "gemma3": { sourceData in
                let data = try BorealisModelConfiguration.adapted(sourceData)
                return Gemma3TextModel(try JSONDecoder().decode(MLXLLM.Gemma3TextConfiguration.self, from: data))
            },
            "gemma3_text": { sourceData in
                let data = try BorealisModelConfiguration.adapted(sourceData)
                return Gemma3TextModel(try JSONDecoder().decode(MLXLLM.Gemma3TextConfiguration.self, from: data))
            }
        ]), modelRegistry: LLMRegistry.shared)

    init(appleGenerator: @escaping @Sendable (String, DescriptionAssistantLanguage) async throws -> String = {
        try await AppleFoundationDescriptionBackend.generate(prompt: $0, language: $1)
    }, textGenerator: (@Sendable (String, URL) async throws -> String)? = nil) {
        self.appleGenerator = appleGenerator
        self.textGenerator = textGenerator
    }

    func install(model: DescriptionAssistantDownloadModel = .recommended, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard !busy else { throw DescriptionAssistantError.busy }
        busy = true
        defer { busy = false }
        // Runtime ships with the app. Only the pinned Q4 GGUF is downloaded.
        return try await LlamaCPPDescriptionBackend.install(model: model, progress: progress)
    }

    func unload() throws {
        guard !busy else { throw DescriptionAssistantError.busy }
        container = nil
        loadedDirectory = nil
    }

    func generate(_ request: DescriptionAssistantRequest, modelDirectory: URL) async throws -> DescriptionAssistantProposal {
        try await generate(request, backend: .localModel(modelDirectory))
    }

    func generate(_ request: DescriptionAssistantRequest, backend: DescriptionAssistantBackend) async throws -> DescriptionAssistantProposal {
        let prompt = try request.prompt()
        guard !busy else { throw DescriptionAssistantError.busy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let text: String
        let modelName: String
        switch backend {
        case .localModel(let modelDirectory):
            modelName = modelDirectory.lastPathComponent
            if let textGenerator {
                text = try await textGenerator(prompt, modelDirectory)
            } else {
                text = try await generateText(prompt: prompt, modelDirectory: modelDirectory)
            }
        case .appleFoundationModels:
            container = nil
            loadedDirectory = nil
            modelName = "Apple Foundation Models (on-device)"
            text = try await appleGenerator(prompt, request.language)
        }
        try Task.checkCancellation()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw DescriptionAssistantError.emptyOutput }
        let reviewedText = request.personListing.map { cleaned + "\n\n" + $0 } ?? cleaned
        return DescriptionAssistantProposal(request: request, text: reviewedText,
                                            model: modelName)
    }

    private func generateText(prompt: String, modelDirectory: URL) async throws -> String {
        if modelDirectory.pathExtension.lowercased() == "gguf" {
            container = nil
            loadedDirectory = nil
            return try await LlamaCPPDescriptionBackend.generate(prompt: prompt, model: modelDirectory)
        }
        let accessing = modelDirectory.startAccessingSecurityScopedResource()
        defer { if accessing { modelDirectory.stopAccessingSecurityScopedResource() } }
        if loadedDirectory != modelDirectory || container == nil {
            // Release the previous model before allocating a replacement's weights.
            container = nil
            loadedDirectory = nil
            let config = ModelConfiguration(directory: modelDirectory, extraEOSTokens: ["<end_of_turn>"])
            let data = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if json?["vision_config"] != nil {
                container = try await vlmFactory.loadContainer(configuration: config)
            } else {
                container = try await llmFactory.loadContainer(configuration: config)
            }
            loadedDirectory = modelDirectory
        }
        guard let container else { throw DescriptionAssistantError.modelNotInstalled }
        // Return a String across actor boundaries, never MLX arrays or ModelContext.
        return try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            guard input.text.tokens.size <= 3_072 else { throw DescriptionAssistantError.inputTooLong }
            // The synchronous visitor keeps model ownership until GPU iteration actually
            // stops, including cancellation. An AsyncStream consumer can terminate earlier
            // than its producer and release our admission guard while the GPU is still busy.
            let result = try MLXLMCommon.generate(input: input,
                parameters: GenerateParameters(maxTokens: 768, temperature: 0.1), context: context) { tokens in
                Task.isCancelled || tokens.count >= 768 ? .stop : .more
            }
            try Task.checkCancellation()
            guard result.tokens.count < 768 else { throw DescriptionAssistantError.outputLimit }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Explicitly configured local directory: caption generation never starts a network download.
@MainActor @Observable
final class DescriptionAssistantModelSetup {
    static let shared = DescriptionAssistantModelSetup()
    private static let bookmarkKey = "descriptionAssistantModelBookmark"
    static let providerKey = "descriptionAssistantProvider"
    @ObservationIgnored private let defaults: UserDefaults
    var provider: DescriptionAssistantProvider {
        didSet { defaults.set(provider.rawValue, forKey: Self.providerKey) }
    }
    private(set) var appleAvailability = AppleFoundationDescriptionBackend.availability
    private(set) var appleSupportedLanguages = Set(DescriptionAssistantLanguage.allCases.filter { AppleFoundationDescriptionBackend.supports($0) })
    var backend: DescriptionAssistantBackend? {
        switch provider {
        case .localModel: directory.map { .localModel($0) }
        case .appleFoundationModels: appleAvailability.isAvailable ? .appleFoundationModels : nil
        }
    }
    func generationIssue(for language: DescriptionAssistantLanguage) -> String? {
        switch provider {
        case .localModel: return directory == nil ? DescriptionAssistantError.modelNotInstalled.localizedDescription : nil
        case .appleFoundationModels:
            if !appleAvailability.isAvailable { return appleAvailability.message }
            return appleSupportedLanguages.contains(language) ? nil
                : DescriptionAssistantError.appleUnsupportedLanguage(language.rawValue).localizedDescription
        }
    }
    var directory: URL?
    var downloadedModels: Set<DescriptionAssistantDownloadModel> = []
    var isInstalling = false
    var progress: Double = 0
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? FFmpegWhisperSetupModel.sessionDefaults
        self.defaults = defaults
        provider = defaults.string(forKey: Self.providerKey).flatMap(DescriptionAssistantProvider.init(rawValue:)) ?? .localModel
        refreshDownloadedModels()
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        do {
            directory = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                bookmarkDataIsStale: &stale)
            if stale, let directory { try select(directory, activateProvider: false) }
        } catch { message = error.localizedDescription }
    }

    func select(_ url: URL, activateProvider: Bool = true) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "gguf" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Choose a valid instruction-tuned GGUF model file."])
            }
        } else {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path),
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("tokenizer_config.json").path),
                  try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .contains(where: { $0.pathExtension == "safetensors" }) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Choose a GGUF model file or a converted MLX model folder."])
            }
        }
        let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                           includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        directory = url
        if activateProvider { provider = .localModel }
        message = "Model selected. It will be loaded when you generate a description."
    }

    func refreshDownloadedModels() {
        downloadedModels = Set(DescriptionAssistantDownloadModel.allCases.filter {
            FileManager.default.fileExists(atPath: $0.installedFile.path)
        })
    }

    func refreshAppleAvailability() {
        appleAvailability = AppleFoundationDescriptionBackend.availability
        appleSupportedLanguages = Set(DescriptionAssistantLanguage.allCases.filter { AppleFoundationDescriptionBackend.supports($0) })
    }

    func install(_ model: DescriptionAssistantDownloadModel = .recommended) {
        guard !isInstalling else { return }
        isInstalling = true
        progress = 0
        message = nil
        task = Task {
            defer { isInstalling = false; task = nil; refreshDownloadedModels() }
            do {
                let url = try await DescriptionAssistantService.shared.install(model: model) { value in
                    Task { @MainActor in self.progress = value }
                }
                try Task.checkCancellation()
                try select(url)
                message = "\(model.title) is ready. Descriptions are processed locally."
            } catch is CancellationError { message = "Download cancelled. You can retry when ready." }
            catch { message = error.localizedDescription }
        }
    }

    func cancelInstall() { task?.cancel() }
}
