import Foundation
import Combine
import CoreML
import CryptoKit

nonisolated struct AuraFaceDistributionDescriptor: Codable, Equatable, Sendable {
    struct PackageFile: Codable, Equatable, Sendable {
        let byteCount: Int64
        let sha256: String
    }

    struct Archive: Codable, Equatable, Sendable {
        let fileName: String
        let byteCount: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let componentID: String
    let modelVersion: String
    let embeddingVersion: Int
    let packageDirectory: String
    let packageFiles: [String: PackageFile]
    let archive: Archive
    let downloadURL: URL

    /// Schema 2 signs precisely these compact UTF-8 bytes, with no trailing newline.
    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

nonisolated struct AuraFaceHTTPPayload: Sendable {
    let data: Data
    let statusCode: Int
}

nonisolated enum AuraFaceComponentError: LocalizedError, Equatable {
    case invalidServerResponse
    case redirectedResponse
    case responseTooLarge
    case invalidDescriptorSignature
    case invalidDescriptor(String)
    case incompatibleEmbeddingVersion(required: Int, supported: Int)
    case archiveSizeMismatch
    case archiveHashMismatch
    case packageFileSetMismatch
    case packageHashMismatch(String)
    case invalidArchive
    case unsafeArchive
    case io
    case installationFailed

    var errorDescription: String? {
        switch self {
        case .invalidServerResponse:
            "The AuraFace download server returned an invalid response."
        case .redirectedResponse:
            "The AuraFace server redirected a fixed download URL."
        case .responseTooLarge:
            "The AuraFace response exceeded its allowed size."
        case .invalidDescriptorSignature:
            "The AuraFace manifest signature is invalid. The model was not installed."
        case .invalidDescriptor(let reason):
            "The AuraFace manifest is invalid: \(reason)"
        case .incompatibleEmbeddingVersion(let required, let supported):
            "AuraFace embedding version \(required) is not compatible with this app (version \(supported))."
        case .archiveSizeMismatch:
            "The AuraFace download size did not match its signed manifest."
        case .archiveHashMismatch:
            "The AuraFace download hash did not match its signed manifest."
        case .packageFileSetMismatch:
            "The AuraFace package contains an unexpected file set."
        case .packageHashMismatch(let path):
            "The AuraFace package hash did not match for \(path)."
        case .invalidArchive:
            "The AuraFace archive is not a valid bounded ZIP32 package."
        case .unsafeArchive:
            "The AuraFace archive contains an unsafe entry or destination."
        case .io:
            "The AuraFace archive could not be accessed safely."
        case .installationFailed:
            "AuraFace could not be installed. The previous version was restored."
        }
    }
}

/// Injectable file/network boundary used by focused tests to force failures at every
/// destructive edge. Production uses a private staging directory on the same volume as
/// the installed component, so directory moves are atomic.
nonisolated struct AuraFaceComponentIO: @unchecked Sendable {
    var fetch: @Sendable (URL) async throws -> AuraFaceHTTPPayload
    var createDirectory: @Sendable (URL) throws -> Void
    var write: @Sendable (Data, URL) throws -> Void
    var read: @Sendable (URL) throws -> Data
    var move: @Sendable (URL, URL) throws -> Void
    var remove: @Sendable (URL) throws -> Void
    var fileExists: @Sendable (URL) -> Bool
    var regularFiles: @Sendable (URL) throws -> [URL]
    var extractArchive: @Sendable (URL, URL) throws -> Void
    var compileModel: @Sendable (URL, URL) throws -> Void

    static let live = AuraFaceComponentIO(
        fetch: { url in
            try await AuraFaceBoundedHTTP.fetch(url)
        },
        createDirectory: { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        write: { data, url in try data.write(to: url, options: [.atomic]) },
        read: { try Data(contentsOf: $0, options: [.mappedIfSafe]) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        regularFiles: { root in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else { return [] }
            var files: [URL] = []
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw AuraFaceComponentError.packageFileSetMismatch
                }
                if values.isRegularFile == true { files.append(url) }
            }
            return files
        },
        extractArchive: { archive, destination in
            let admitted = try AuraFaceZIPArchive(url: archive)
            try admitted.extract(to: destination)
        },
        compileModel: { package, destination in
            let compiled = try MLModel.compileModel(at: package)
            try FileManager.default.moveItem(at: compiled, to: destination)
        }
    )
}

nonisolated enum AuraFaceComponentStore {
    static let maximumDescriptorBytes = 16_384
    static let maximumPackageFileBytes: Int64 = 192 * 1_048_576
    static let maximumArchiveBytes: Int64 = 256 * 1_048_576
    static let componentID = "auraface-r100-coreml"
    static let packageDirectory = "AuraFaceR100.mlpackage"
    static let compiledDirectory = "AuraFaceR100.mlmodelc"
    static let descriptorFile = "distribution.json"
    static let signatureFile = "distribution.json.sig"
    static let expectedPackageFiles: Set<String> = [
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
        "Manifest.json",
    ]
    static let descriptorURL = URL(
        string: "https://aagedal.me/models/auraface/AuraFaceR100.distribution.json"
    )!
    static let signatureURL = URL(
        string: "https://aagedal.me/models/auraface/AuraFaceR100.distribution.json.sig"
    )!

    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? AppPaths.applicationSupport
            .appendingPathComponent("Components/AuraFace", isDirectory: true)
    }

    static var current: URL { root.appendingPathComponent("current", isDirectory: true) }
    static var rollback: URL { root.appendingPathComponent("rollback", isDirectory: true) }

    static func productionPublicKeyData(bundle: Bundle = .main) -> Data? {
        publicKeyData(infoDictionary: bundle.infoDictionary ?? [:])
    }

    static func publicKeyData(infoDictionary: [String: Any]) -> Data? {
        guard let encoded = infoDictionary["AuraFaceDistributionPublicEd25519Key"] as? String,
              let data = Data(base64Encoded: encoded), data.count == 32 else { return nil }
        return data
    }

    static func verifySignedDescriptor(
        _ descriptorData: Data,
        signatureData: Data,
        publicKeyData: Data
    ) throws -> AuraFaceDistributionDescriptor {
        guard !descriptorData.isEmpty, descriptorData.count <= maximumDescriptorBytes else {
            throw AuraFaceComponentError.invalidDescriptor("descriptor exceeds size limit")
        }
        var encodedSignature = signatureData
        if encodedSignature.last == 10 { encodedSignature.removeLast() }
        guard encodedSignature.count == 88,
              let signature = Data(base64Encoded: encodedSignature), signature.count == 64,
              signature.base64EncodedData() == encodedSignature,
              publicKeyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: descriptorData) else {
            throw AuraFaceComponentError.invalidDescriptorSignature
        }

        let descriptor: AuraFaceDistributionDescriptor
        do {
            descriptor = try JSONDecoder().decode(AuraFaceDistributionDescriptor.self, from: descriptorData)
        } catch {
            throw AuraFaceComponentError.invalidDescriptor("values could not be decoded")
        }
        // Typed re-encoding rejects unknown/duplicate keys at every nesting level,
        // alternate escapes/numeric spellings, whitespace and URL normalization.
        guard try descriptor.canonicalData() == descriptorData else {
            throw AuraFaceComponentError.invalidDescriptor("descriptor must use exact canonical JSON")
        }
        try validate(descriptor)
        return descriptor
    }

    static func validate(_ descriptor: AuraFaceDistributionDescriptor) throws {
        guard descriptor.schemaVersion == 2,
              descriptor.componentID == componentID,
              !descriptor.modelVersion.isEmpty,
              descriptor.modelVersion.utf8.count <= 128,
              descriptor.embeddingVersion > 0,
              descriptor.packageDirectory == packageDirectory,
              Set(descriptor.packageFiles.keys) == expectedPackageFiles,
              descriptor.packageFiles.values.allSatisfy({
                  $0.byteCount > 0 && $0.byteCount <= maximumPackageFileBytes
                      && isLowercaseSHA256($0.sha256)
              }),
              descriptor.archive.fileName == "AuraFaceR100.mlpackage.zip",
              descriptor.archive.byteCount > 0,
              descriptor.archive.byteCount <= maximumArchiveBytes,
              isLowercaseSHA256(descriptor.archive.sha256),
              isAllowedDownloadURL(descriptor.downloadURL) else {
            throw AuraFaceComponentError.invalidDescriptor("identity, hashes, size, or HTTPS URL is invalid")
        }
        // Per-file bounds above make this sum safe from overflow.
        guard descriptor.packageFiles.values.reduce(Int64(0), { $0 + $1.byteCount }) <= maximumArchiveBytes else {
            throw AuraFaceComponentError.invalidDescriptor("package exceeds size limit")
        }
        guard descriptor.embeddingVersion == FaceRecognitionDefaults.embeddingVersion else {
            throw AuraFaceComponentError.incompatibleEmbeddingVersion(
                required: descriptor.embeddingVersion,
                supported: FaceRecognitionDefaults.embeddingVersion
            )
        }
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        let value = url.absoluteString
        guard let prefix = ["https://aagedal.me/", "https://www.aagedal.me/"]
            .first(where: { value.hasPrefix($0) }) else { return false }
        let path = "/" + String(value.dropFirst(prefix.count))
        guard !path.hasSuffix("/"),
              let lastComponent = path.split(separator: "/").last,
              lastComponent == "AuraFaceR100.mlpackage.zip" else { return false }
        // Match the producer's literal ASCII URL policy. In particular, ports,
        // credentials, alternate host spellings, query/fragment and backslashes fail.
        let pattern = #"\A(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})+\z"#
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    static func verifyPackage(
        at package: URL,
        descriptor: AuraFaceDistributionDescriptor,
        io: AuraFaceComponentIO
    ) throws {
        let packagePath = package.standardizedFileURL.path
        let files = try io.regularFiles(package)
        let relativeFiles = Set(files.map { file -> String in
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(packagePath + "/") else { return "" }
            return String(path.dropFirst(packagePath.count + 1))
        })
        guard relativeFiles == expectedPackageFiles else {
            throw AuraFaceComponentError.packageFileSetMismatch
        }
        for relative in expectedPackageFiles.sorted() {
            let data = try io.read(package.appendingPathComponent(relative))
            let actual = Data(SHA256.hash(data: data)).lowercaseHexString
            guard let declaration = descriptor.packageFiles[relative],
                  Int64(data.count) == declaration.byteCount,
                  actual == declaration.sha256 else {
                throw AuraFaceComponentError.packageHashMismatch(relative)
            }
        }
    }

    fileprivate static func verifyInstalledDirectory(
        _ directory: URL,
        publicKeyData: Data,
        io: AuraFaceComponentIO
    ) throws -> AuraFaceDistributionDescriptor {
        let descriptorData = try io.read(directory.appendingPathComponent(descriptorFile))
        let signatureData = try io.read(directory.appendingPathComponent(signatureFile))
        let descriptor = try verifySignedDescriptor(
            descriptorData,
            signatureData: signatureData,
            publicKeyData: publicKeyData
        )
        try verifyPackage(
            at: directory.appendingPathComponent(packageDirectory, isDirectory: true),
            descriptor: descriptor,
            io: io
        )
        return descriptor
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

actor AuraFaceComponentInstaller {
    private let io: AuraFaceComponentIO
    private let publicKeyData: Data
    private let root: URL

    init(
        io: AuraFaceComponentIO = .live,
        publicKeyData: Data? = AuraFaceComponentStore.productionPublicKeyData(),
        root: URL = AuraFaceComponentStore.root
    ) throws {
        guard let publicKeyData, publicKeyData.count == 32 else {
            throw AuraFaceComponentError.invalidDescriptorSignature
        }
        self.io = io
        self.publicKeyData = publicKeyData
        self.root = root
    }

    func downloadAndInstall() async throws -> AuraFaceDistributionDescriptor {
        try Task.checkCancellation()
        let descriptorPayload = try await fetch(AuraFaceComponentStore.descriptorURL)
        let signaturePayload = try await fetch(AuraFaceComponentStore.signatureURL)
        let descriptor = try AuraFaceComponentStore.verifySignedDescriptor(
            descriptorPayload.data,
            signatureData: signaturePayload.data,
            publicKeyData: publicKeyData
        )
        let archivePayload = try await fetch(descriptor.downloadURL)
        return try install(
            descriptorData: descriptorPayload.data,
            signatureData: signaturePayload.data,
            archiveData: archivePayload.data
        )
    }

    func install(
        descriptorData: Data,
        signatureData: Data,
        archiveData: Data
    ) throws -> AuraFaceDistributionDescriptor {
        try Task.checkCancellation()
        let descriptor = try AuraFaceComponentStore.verifySignedDescriptor(
            descriptorData,
            signatureData: signatureData,
            publicKeyData: publicKeyData
        )
        guard archiveData.count == descriptor.archive.byteCount else {
            throw AuraFaceComponentError.archiveSizeMismatch
        }
        let archiveHash = Data(SHA256.hash(data: archiveData)).lowercaseHexString
        guard archiveHash == descriptor.archive.sha256 else {
            throw AuraFaceComponentError.archiveHashMismatch
        }

        try io.createDirectory(root)
        let transaction = root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try io.createDirectory(transaction)
        defer { try? io.remove(transaction) }

        let archive = transaction.appendingPathComponent(descriptor.archive.fileName)
        try io.write(archiveData, archive)
        let extracted = transaction.appendingPathComponent("extracted", isDirectory: true)
        try io.extractArchive(archive, extracted)
        try Task.checkCancellation()
        let package = extracted.appendingPathComponent(descriptor.packageDirectory, isDirectory: true)
        try AuraFaceComponentStore.verifyPackage(at: package, descriptor: descriptor, io: io)

        let candidate = transaction.appendingPathComponent("candidate", isDirectory: true)
        try io.createDirectory(candidate)
        try io.move(package, candidate.appendingPathComponent(AuraFaceComponentStore.packageDirectory))
        try io.compileModel(
            candidate.appendingPathComponent(AuraFaceComponentStore.packageDirectory),
            candidate.appendingPathComponent(AuraFaceComponentStore.compiledDirectory)
        )
        try Task.checkCancellation()
        try io.write(descriptorData, candidate.appendingPathComponent(AuraFaceComponentStore.descriptorFile))
        try io.write(signatureData, candidate.appendingPathComponent(AuraFaceComponentStore.signatureFile))

        try commit(candidate: candidate)
        return descriptor
    }

    func removeInstalledComponent() throws {
        let current = root.appendingPathComponent("current", isDirectory: true)
        let rollback = root.appendingPathComponent("rollback", isDirectory: true)
        if io.fileExists(current) { try io.remove(current) }
        if io.fileExists(rollback) { try io.remove(rollback) }
    }

    private func fetch(_ url: URL) async throws -> AuraFaceHTTPPayload {
        try Task.checkCancellation()
        let limit = try AuraFaceBoundedHTTP.limit(for: url)
        let payload = try await io.fetch(url)
        try Task.checkCancellation()
        guard payload.data.count <= limit else { throw AuraFaceComponentError.responseTooLarge }
        guard (200..<300).contains(payload.statusCode) else {
            throw AuraFaceComponentError.invalidServerResponse
        }
        return payload
    }

    private func commit(candidate: URL) throws {
        let current = root.appendingPathComponent("current", isDirectory: true)
        let rollback = root.appendingPathComponent("rollback", isDirectory: true)
        let priorRollback = candidate.deletingLastPathComponent()
            .appendingPathComponent("prior-rollback", isDirectory: true)
        var movedPriorRollback = false
        var movedCurrent = false
        do {
            if io.fileExists(rollback) {
                try io.move(rollback, priorRollback)
                movedPriorRollback = true
            }
            if io.fileExists(current) {
                try io.move(current, rollback)
                movedCurrent = true
            }
            try io.move(candidate, current)
        } catch {
            if movedCurrent, io.fileExists(rollback), !io.fileExists(current) {
                try? io.move(rollback, current)
            }
            if movedPriorRollback, io.fileExists(priorRollback), !io.fileExists(rollback) {
                try? io.move(priorRollback, rollback)
            }
            throw AuraFaceComponentError.installationFailed
        }
    }
}

nonisolated enum AuraFaceComponentSource: Equatable, Sendable {
    case none
    case bundled
    case downloaded
}

nonisolated struct AuraFaceComponentSnapshot: Equatable, Sendable {
    let availability: FaceRecognitionModelAvailability
    let source: AuraFaceComponentSource
}

/// One immutable answer from the model-component filesystem boundary. The model URL is
/// published to the embedder only after the signed downloaded component (or bundled fallback)
/// has been resolved completely.
nonisolated struct AuraFaceComponentResolution: Equatable, Sendable {
    let snapshot: AuraFaceComponentSnapshot
    let modelURL: URL?

    static let checking = AuraFaceComponentResolution(
        snapshot: AuraFaceComponentSnapshot(availability: .checking, source: .none),
        modelURL: nil
    )

    static func current(
        bundle: Bundle = .main,
        publicKeyData: Data? = AuraFaceComponentStore.productionPublicKeyData(),
        io: AuraFaceComponentIO = .live
    ) -> AuraFaceComponentResolution {
        if let publicKeyData,
           let descriptor = try? AuraFaceComponentStore.verifyInstalledDirectory(
               AuraFaceComponentStore.current,
               publicKeyData: publicKeyData,
               io: io
           ) {
            let compiled = AuraFaceComponentStore.current.appendingPathComponent(
                AuraFaceComponentStore.compiledDirectory,
                isDirectory: true
            )
            if io.fileExists(compiled) {
                return AuraFaceComponentResolution(
                    snapshot: AuraFaceComponentSnapshot(
                        availability: .ready(version: descriptor.modelVersion),
                        source: .downloaded
                    ),
                    modelURL: compiled
                )
            }
        }
        if let bundled = CoreMLFaceEmbedder.bundledModelURL(bundle: bundle) {
            return AuraFaceComponentResolution(
                snapshot: AuraFaceComponentSnapshot(
                    availability: .ready(version: CoreMLFaceEmbedder.modelVersion),
                    source: .bundled
                ),
                modelURL: bundled
            )
        }
        return AuraFaceComponentResolution(
            snapshot: AuraFaceComponentSnapshot(availability: .notInstalled, source: .none),
            modelURL: nil
        )
    }
}

/// Serializes potentially expensive installed-package enumeration, reads, and hashes away from
/// MainActor callers. Cancellation is sampled around the synchronous resolver; a cancelled probe
/// never publishes its result.
actor AuraFaceComponentProbeService {
    typealias Resolver = @Sendable () -> AuraFaceComponentResolution

    private let resolver: Resolver

    init(resolver: @escaping Resolver = { AuraFaceComponentResolution.current() }) {
        self.resolver = resolver
    }

    func resolve() throws -> AuraFaceComponentResolution {
        try Task.checkCancellation()
        let resolution = resolver()
        try Task.checkCancellation()
        return resolution
    }
}

@MainActor
final class AuraFaceComponentManager: ObservableObject {
    static let shared = AuraFaceComponentManager()

    @Published private(set) var availability: FaceRecognitionModelAvailability
    @Published private(set) var source: AuraFaceComponentSource
    @Published private(set) var lastError: String?

    private let installerFactory: () throws -> AuraFaceComponentInstaller
    private let probeService: AuraFaceComponentProbeService
    private let modelPublisher: @MainActor @Sendable (URL?) -> Void
    private var requestID = UUID()
    private var operationTask: Task<Void, Never>?

    init(
        installerFactory: @escaping () throws -> AuraFaceComponentInstaller = {
            try AuraFaceComponentInstaller()
        },
        initialSnapshot: AuraFaceComponentSnapshot? = nil,
        probeService: AuraFaceComponentProbeService = AuraFaceComponentProbeService(),
        modelPublisher: @escaping @MainActor @Sendable (URL?) -> Void = {
            CoreMLFaceEmbedder.shared.publishResolvedModelURL($0)
        }
    ) {
        self.installerFactory = installerFactory
        self.probeService = probeService
        self.modelPublisher = modelPublisher
        let snapshot = initialSnapshot ?? AuraFaceComponentResolution.checking.snapshot
        availability = snapshot.availability
        source = snapshot.source
        if initialSnapshot == nil {
            startProbe()
        }
    }

    var canDownload: Bool {
        guard source == .none else { return false }
        switch availability {
        case .notInstalled, .offline, .verificationFailed:
            return true
        case .checking, .downloading, .ready, .updateAvailable, .incompatible:
            return false
        }
    }

    var canRemove: Bool {
        source == .downloaded && availability.isAvailable
    }

    /// Re-resolves installed state without blocking the main actor. Replacement requests cancel
    /// and identity-invalidate older probes so a late result cannot roll back newer state.
    func refresh() {
        availability = .checking
        source = .none
        lastError = nil
        startProbe()
    }

    private func startProbe() {
        operationTask?.cancel()
        let id = UUID()
        requestID = id
        operationTask = Task { [weak self, probeService] in
            do {
                let resolution = try await probeService.resolve()
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.publish(resolution)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.source = .none
                self.availability = .verificationFailed
                self.lastError = error.localizedDescription
            }
        }
    }

    private func publish(_ resolution: AuraFaceComponentResolution) {
        modelPublisher(resolution.modelURL)
        availability = resolution.snapshot.availability
        source = resolution.snapshot.source
        lastError = nil
    }

    func downloadConfirmed() {
        guard canDownload else { return }
        operationTask?.cancel()
        let id = UUID()
        requestID = id
        availability = .downloading(progress: 0)
        lastError = nil
        operationTask = Task { [weak self, probeService] in
            do {
                guard let self else { return }
                _ = try await self.installerFactory().downloadAndInstall()
                let resolution = try await probeService.resolve()
                guard self.requestID == id, !Task.isCancelled else { return }
                guard resolution.snapshot.source == .downloaded else {
                    throw AuraFaceComponentError.installationFailed
                }
                self.publish(resolution)
                KnownPeopleService.shared.reloadAfterStorageChange()
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.lastError = error.localizedDescription
                if let urlError = error as? URLError,
                   [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost]
                    .contains(urlError.code) {
                    self.availability = .offline
                } else {
                    self.availability = .verificationFailed
                }
            }
        }
    }

    func removeConfirmed() {
        guard canRemove else { return }
        operationTask?.cancel()
        let id = UUID()
        requestID = id
        operationTask = Task { [weak self, probeService] in
            do {
                guard let self else { return }
                try await self.installerFactory().removeInstalledComponent()
                let resolution = try await probeService.resolve()
                guard self.requestID == id, !Task.isCancelled else { return }
                self.publish(resolution)
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.lastError = error.localizedDescription
            }
        }
    }
}
