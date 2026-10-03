import SwiftUI
import UniformTypeIdentifiers

struct DescriptionAssistantModelSetupView: View {
    @State private var setup = DescriptionAssistantModelSetup.shared
    @State private var choosingModel = false
    @State private var choosingMLX = false
    @State private var downloadModel: DescriptionAssistantDownloadModel = .borealis
    var body: some View {
        Section("Description Model") {
            Text(setup.directory.map { $0.pathExtension.lowercased() != "gguf" } == true
                ? "Local MLX inference" : "Local llama.cpp inference • Metal")
            Text("llama.cpp is included with the app and uses Metal on Apple Silicon. Choose a 4B model with 4-bit quantization (2.49 GB each), or select an existing Gemma 3 or Borealis GGUF file.")
                .font(.caption).foregroundStyle(.secondary)
            if let directory = setup.directory {
                LabeledContent("Active model", value: directory.lastPathComponent)
            }
            Picker("Download or switch to", selection: $downloadModel) {
                ForEach(DescriptionAssistantDownloadModel.allCases) { model in
                    Text(model.title).tag(model)
                }
            }.disabled(setup.isInstalling)
            Text(downloadModel.purpose).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(setup.downloadedModels.contains(downloadModel)
                    ? "Use Downloaded Model" : "Download Model (2.49 GB)") { setup.install(downloadModel) }
                    .disabled(setup.isInstalling)
                Button("Choose GGUF…") { choosingModel = true }
                    .disabled(setup.isInstalling)
            }
            if setup.isInstalling {
                ProgressView(value: setup.progress)
                Button("Cancel Download") { setup.cancelInstall() }
            }
            if let message = setup.message { Text(message).font(.caption).textSelection(.enabled) }
            Link("Model and license", destination: downloadModel.sourceURL)
            DisclosureGroup("Advanced: MLX model") {
                Button("Choose MLX Folder…") { choosingMLX = true }.disabled(setup.isInstalling)
                Text("Use an existing converted MLX folder. GGUF is the default download.").font(.caption)
            }

        }
        .onAppear {
            setup.refreshDownloadedModels()
            if let current = setup.directory,
               let model = DescriptionAssistantDownloadModel.allCases.first(where: { $0.artifact.fileName == current.lastPathComponent }) {
                downloadModel = model
            }
        }
        .fileImporter(isPresented: $choosingModel, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            do { try setup.select(result.get()) }
            catch { setup.message = error.localizedDescription }
        }
        .fileImporter(isPresented: $choosingMLX, allowedContentTypes: [.folder]) { result in
            do { try setup.select(result.get()) }
            catch { setup.message = error.localizedDescription }
        }

    }
}

struct DescriptionAssistantView: View {
    let source: DescriptionAssistantRequest
    /// Checks and applies to the editor's captured load, never whichever photo is selected later.
    let apply: (DescriptionAssistantProposal, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var setup = DescriptionAssistantModelSetup.shared
    @State private var action: DescriptionAssistantAction = .grammar
    @State private var language: DescriptionAssistantLanguage = .bokmal
    @State private var includePeople = false
    @State private var people: [CaptionConfirmedPerson] = []
    @State private var loadingPeople = true
    @State private var faceNotice: String?
    @State private var proposal: DescriptionAssistantProposal?
    @State private var reviewedText = ""
    @State private var errorMessage: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Improve Description").font(.title2)
                Spacer()
                Button("Model Setup") { showSetup.toggle() }
            }
            if showSetup || setup.directory == nil {
                Form { DescriptionAssistantModelSetupView() }
                    .formStyle(.grouped).frame(height: 390)
            }
            HStack {
                Picker("Action", selection: $action) {
                    ForEach(DescriptionAssistantAction.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Language", selection: $language) {
                    ForEach(DescriptionAssistantLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
            }.disabled(generationTask != nil)
            Toggle("Append named people from left to right", isOn: $includePeople)
                .disabled(loadingPeople || people.isEmpty || generationTask != nil)
            if loadingPeople { ProgressView("Loading face context…") }
            else if !people.isEmpty {
                Text(people.map(\.name).joined(separator: " → "))
                    .font(.caption).textSelection(.enabled)
                Text("Order uses the upright original photo. Unnamed and excluded faces are omitted; review identities before applying.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text(faceNotice ?? "No named faces are available for this photo.") .font(.caption).foregroundStyle(.secondary) }
            Text("Original").font(.headline)
            ScrollView { Text(source.originalDescription).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 110)
            if proposal != nil {
                Text("Suggested description — review and edit").font(.headline)
                TextEditor(text: $reviewedText).frame(minHeight: 130)
                    .accessibilityLabel("Suggested description")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Close") { generationTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if generationTask != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel Generation") { generationTask?.cancel() }
                } else {
                    Button(proposal == nil ? "Generate Suggestion" : "Generate Again") { generate() }
                        .disabled(setup.directory == nil || loadingPeople || setup.isInstalling)
                }
                Button("Apply to Description") {
                    guard let proposal else { return }
                    if apply(proposal, reviewedText) { dismiss() }
                    else { errorMessage = "The selected photo or description changed. Close this window and generate a new suggestion." }
                }
                .disabled(proposal == nil || generationTask != nil || reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 720)
        .task { await loadPeople() }
        .onDisappear { generationTask?.cancel() }
    }

    private func loadPeople() async {
        defer { loadingPeople = false }
        let context = await DescriptionAssistantFaceContext.load(for: source.imageURL)
        guard !Task.isCancelled else { return }
        people = context.people
        faceNotice = context.notice
    }

    private func generate() {
        guard let directory = setup.directory, generationTask == nil else { return }
        errorMessage = nil
        proposal = nil
        reviewedText = ""
        let request = DescriptionAssistantRequest(imageURL: source.imageURL, editorLoadID: source.editorLoadID,
            originalDescription: source.originalDescription, action: action, language: language,
            people: includePeople ? people : [])
        generationTask = Task {
            defer { generationTask = nil }
            do {
                let result = try await DescriptionAssistantService.shared.generate(request, modelDirectory: directory)
                try Task.checkCancellation()
                proposal = result
                reviewedText = result.text
            } catch is CancellationError { errorMessage = "Generation cancelled." }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
