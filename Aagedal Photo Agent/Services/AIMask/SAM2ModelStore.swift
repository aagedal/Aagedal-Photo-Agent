import CoreML
import Foundation
import Observation

/// Apple's Core ML conversion of SAM 2.1 Small (Apache-2.0, `apple/coreml-sam2.1-small`), fetched
/// on demand for the experimental AI-mask engine. Every file is pinned to an immutable revision,
/// byte count and SHA-256 and downloaded through `WhisperModelDownloadService`'s verified transfer.
/// The three `.mlpackage`s are then reassembled from those flat files and compiled locally; only
/// the compiled `.mlmodelc`s are kept.
nonisolated enum SAM2ModelStore {
    enum Component: String, CaseIterable, Sendable {
        case imageEncoder
        case promptEncoder
        case maskDecoder

        var packageName: String {
            switch self {
            case .imageEncoder: return "SAM2_1SmallImageEncoderFLOAT16"
            case .promptEncoder: return "SAM2_1SmallPromptEncoderFLOAT16"
            case .maskDecoder: return "SAM2_1SmallMaskDecoderFLOAT16"
            }
        }

        fileprivate var idStem: String {
            switch self {
            case .imageEncoder: return "encoder"
            case .promptEncoder: return "prompt"
            case .maskDecoder: return "decoder"
            }
        }
    }

    struct PinnedFile: Sendable {
        let component: Component
        /// Path inside the `.mlpackage`, exactly as published.
        let packagePath: String
        let byteCount: Int64
        let sha256: String

        /// Flat download name; the service stores files side by side in one directory.
        var artifact: WhisperDownloadableModel {
            let kind = (packagePath as NSString).lastPathComponent
                .replacingOccurrences(of: ".", with: "-")
                .lowercased()
            let id = "sam21s-\(component.idStem)-\(kind)"
            var url = URL(string: "https://huggingface.co/\(SAM2ModelStore.repository)/resolve/\(SAM2ModelStore.revision)")!
                .appendingPathComponent("\(component.packageName).mlpackage")
            for part in packagePath.split(separator: "/") {
                url.appendPathComponent(String(part))
            }
            return WhisperDownloadableModel(
                id: id,
                title: "SAM 2.1 \(component.idStem) \(kind)",
                byteCount: byteCount,
                sha256: sha256,
                url: url,
                fileName: "\(id).bin"
            )
        }
    }

    static let repository = "apple/coreml-sam2.1-small"
    static let revision = "883f5787eb0be35ce6965907a8bc1f5320a5a02e"
    static let files: [PinnedFile] = [
        PinnedFile(component: .imageEncoder, packagePath: "Manifest.json", byteCount: 617,
                   sha256: "442f9102d1a37c2699fce89b1f5257d35ebd0a7096f1773501cb0aba94fe95b6"),
        PinnedFile(component: .imageEncoder, packagePath: "Data/com.apple.CoreML/model.mlmodel", byteCount: 203_631,
                   sha256: "736602a3130875072f843df123ce3ceff41ec2f917a867da56f7c2264d81a567"),
        PinnedFile(component: .imageEncoder, packagePath: "Data/com.apple.CoreML/weights/weight.bin", byteCount: 81_268_288,
                   sha256: "6128a58f10cbcb7797bd12a7ec1e05ab4e9f8c80bd14ed05bbc43a9c9935a9c3"),
        PinnedFile(component: .promptEncoder, packagePath: "Manifest.json", byteCount: 617,
                   sha256: "b368a8e831599464347890a79c054df143c163d9928e3e0a2ab6ef7c00a425d4"),
        PinnedFile(component: .promptEncoder, packagePath: "Data/com.apple.CoreML/model.mlmodel", byteCount: 20_618,
                   sha256: "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3"),
        PinnedFile(component: .promptEncoder, packagePath: "Data/com.apple.CoreML/weights/weight.bin", byteCount: 2_101_056,
                   sha256: "e29c6c65ef7754f8f6ed26155ca39ea703de3a7f576be5a7d3b8e29545059f31"),
        PinnedFile(component: .maskDecoder, packagePath: "Manifest.json", byteCount: 617,
                   sha256: "d95d732931f590dbf6a08ea1fe58a6659ced8971c5b2a671d79091be1a63b9e1"),
        PinnedFile(component: .maskDecoder, packagePath: "Data/com.apple.CoreML/model.mlmodel", byteCount: 75_167,
                   sha256: "3536b71674dc706381f42833b55627fd3d1f2c1b68a365b49255284b4f7b55c7"),
        PinnedFile(component: .maskDecoder, packagePath: "Data/com.apple.CoreML/weights/weight.bin", byteCount: 10_222_400,
                   sha256: "dbc4910c434fee657ed9f001da7abcb467d2a37ac235099c6aa47628b122ec4e"),
    ]

    static var totalByteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aagedal Photo Agent/SAM2Models", isDirectory: true)
    }
    static var downloadDirectory: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    static var compiledDirectory: URL { root.appendingPathComponent("Compiled", isDirectory: true) }
    private static var revisionStamp: URL { compiledDirectory.appendingPathComponent("revision.txt") }

    static func compiledModelURL(_ component: Component) -> URL {
        compiledDirectory.appendingPathComponent("\(component.packageName).mlmodelc", isDirectory: true)
    }

    /// Cheap presence check: the stamp is written last, so a half-finished install never counts.
    static var isInstalled: Bool {
        guard let stamp = try? String(contentsOf: revisionStamp, encoding: .utf8),
              stamp.trimmingCharacters(in: .whitespacesAndNewlines) == revision else { return false }
        return Component.allCases.allSatisfy {
            FileManager.default.fileExists(atPath: compiledModelURL($0).path)
        }
    }

    /// Downloads, verifies, reassembles and compiles the three models, then publishes them in one
    /// directory swap. `progress` covers the download (0...0.95) and compilation (to 1).
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let service = WhisperModelDownloadService(directory: downloadDirectory, maximumModelByteCount: 200_000_000)
        let total = Double(totalByteCount)
        var completed: Int64 = 0
        var downloaded: [(PinnedFile, URL)] = []
        for file in files {
            let base = Double(completed)
            let size = Double(file.byteCount)
            let url = try await service.download(file.artifact) { fraction in
                progress((base + fraction * size) / total * 0.95)
            }
            downloaded.append((file, url))
            completed += file.byteCount
        }

        let manager = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        let stagedCompiled = staging.appendingPathComponent("Compiled", isDirectory: true)
        try manager.createDirectory(at: stagedCompiled, withIntermediateDirectories: true)

        for component in Component.allCases {
            try Task.checkCancellation()
            let package = staging.appendingPathComponent("\(component.packageName).mlpackage", isDirectory: true)
            for (file, source) in downloaded where file.component == component {
                let destination = package.appendingPathComponent(file.packagePath)
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try manager.copyItem(at: source, to: destination)
            }
            let compiled = try await MLModel.compileModel(at: package)
            try manager.moveItem(
                at: compiled,
                to: stagedCompiled.appendingPathComponent("\(component.packageName).mlmodelc", isDirectory: true)
            )
        }
        try Data(revision.utf8).write(to: stagedCompiled.appendingPathComponent("revision.txt"))

        SAM2Segmenter.shared.unloadModels()
        if manager.fileExists(atPath: compiledDirectory.path) {
            try manager.removeItem(at: compiledDirectory)
        }
        try manager.moveItem(at: stagedCompiled, to: compiledDirectory)

        // Only the compiled models are loaded; the verified downloads are no longer needed.
        for file in files {
            try? await service.remove(file.artifact)
        }
        progress(1)
    }

    static func remove() throws {
        SAM2Segmenter.shared.unloadModels()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}

/// Settings/Develop-facing install state for the SAM 2.1 models.
@MainActor
@Observable
final class SAM2ModelManager {
    static let shared = SAM2ModelManager()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        state = SAM2ModelStore.isInstalled ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    var downloadSizeText: String {
        ByteCountFormatter.string(fromByteCount: SAM2ModelStore.totalByteCount, countStyle: .decimal)
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                try await SAM2ModelStore.install { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                self?.state = .installed
            } catch is CancellationError {
                self?.state = SAM2ModelStore.isInstalled ? .installed : .notInstalled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    func remove() {
        guard task == nil else { return }
        do {
            try SAM2ModelStore.remove()
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
