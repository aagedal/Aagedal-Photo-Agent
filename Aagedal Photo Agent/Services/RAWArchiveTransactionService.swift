import Foundation

nonisolated struct RAWArchiveTransactionRequest: Sendable {
    typealias Render = @Sendable (_ sourceURL: URL, _ stagingDirectory: URL) async throws -> URL
    typealias Sign = @Sendable (_ stagedArchiveURL: URL, _ sourceURL: URL) async throws -> Void

    let requestID: UUID
    let sourceURL: URL
    let destinationFolder: URL
    let fileExtension: String
    let render: Render
    let sign: Sign?

    init(
        requestID: UUID = UUID(),
        sourceURL: URL,
        destinationFolder: URL,
        fileExtension: String,
        render: @escaping Render,
        sign: Sign? = nil
    ) {
        self.requestID = requestID
        self.sourceURL = sourceURL.standardizedFileURL
        self.destinationFolder = destinationFolder.standardizedFileURL
        self.fileExtension = fileExtension
        self.render = render
        self.sign = sign
    }
}

nonisolated struct RAWArchiveTransactionReceipt: Equatable, Sendable {
    let requestID: UUID
    let archiveURL: URL
    let artifactURLs: [URL]
    let cleanupResidualURLs: [URL]
    let cancellationObservedAfterCommit: Bool
}

nonisolated enum RAWArchiveTransactionFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidFileExtension
    case invalidSourceSidecar(String)
    case invalidRenderedArtifact(String)
    case invalidStagedCompanion(String)
    case destinationChanged(String)
    case rollbackFailed([String])
    case cleanupFailed(path: String, originalError: String)

    var errorDescription: String? {
        switch self {
        case .invalidFileExtension:
            return "The RAW archive format has an invalid filename extension."
        case .invalidSourceSidecar(let path):
            return "The source XMP sidecar is not a safe regular file and was left untouched: \(path)"
        case .invalidRenderedArtifact(let path):
            return "The RAW archive renderer returned an unsafe or incomplete artifact: \(path)"
        case .invalidStagedCompanion(let path):
            return "RAW archive preparation produced an unsafe voice-memo companion: \(path)"
        case .destinationChanged(let filename):
            return "The archive destination changed while the file was being prepared: \(filename)"
        case .rollbackFailed(let paths):
            return "RAW archive installation failed and these partial files could not be removed: \(paths.joined(separator: ", "))"
        case .cleanupFailed(let path, let originalError):
            return "RAW archive preparation failed and its private staging folder could not be removed: \(path). Original error: \(originalError)"
        }
    }
}

nonisolated struct RAWArchiveTransactionIO: Sendable {
    let fileExists: @Sendable (URL) -> Bool
    let createDirectory: @Sendable (URL) throws -> Void
    let moveItem: @Sendable (URL, URL) throws -> Void
    let removeItem: @Sendable (URL) throws -> Void
    let isRegularFile: @Sendable (URL) -> Bool

    static let system = Self(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        createDirectory: {
            try FileManager.default.createDirectory(
                at: $0,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        isRegularFile: {
            guard let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    )
}

/// Owns rendering, optional signing, voice-memo preparation, and installation as one archive
/// operation. Everything is staged on the destination volume. The source and its relationship
/// are revalidated after rendering/signing; once installation begins, rollback completes without
/// suspension so cancellation cannot expose a half-reported bundle.
actor RAWArchiveTransactionService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = RAWArchiveTransactionService()

    private let repository: VoiceMemoCompanionRepository
    private let io: RAWArchiveTransactionIO

    init(
        repository: VoiceMemoCompanionRepository = VoiceMemoCompanionRepository(),
        io: RAWArchiveTransactionIO = .system,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.raw-archive-transaction",
            qos: .utility
        )
    ) {
        self.repository = repository
        self.io = io
        self.filesystemQueue = filesystemQueue
    }

    func archive(_ request: RAWArchiveTransactionRequest) async throws -> RAWArchiveTransactionReceipt {
        let ext = request.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty, !ext.contains("/"), !ext.contains("\\"), !ext.contains(".") else {
            throw RAWArchiveTransactionFailure.invalidFileExtension
        }
        try Task.checkCancellation()

        let source = try repository.captureArchiveSource(for: request.sourceURL)
        let sourceSidecarURL = XMPSidecarService().sidecarURL(for: request.sourceURL)
        let sourceSidecar = try captureOptionalFile(
            at: sourceSidecarURL,
            unsafeFailure: .invalidSourceSidecar(sourceSidecarURL.path)
        )
        let destination = availableDestination(
            for: request.sourceURL,
            in: request.destinationFolder,
            extension: ext,
            memoExtension: source.memoPathExtension
        )
        let staging = request.destinationFolder.appendingPathComponent(
            ".raw-archive-\(request.requestID.uuidString)",
            isDirectory: true
        )
        guard !io.fileExists(staging) else {
            throw RAWArchiveTransactionFailure.destinationChanged(staging.lastPathComponent)
        }
        try io.createDirectory(staging)

        do {
            try Task.checkCancellation()
            let rendererOutput = try await request.render(request.sourceURL, staging)
            let rendered = try normalizeRenderedArtifacts(
                rendererOutput,
                toMatch: destination,
                in: staging,
                extension: ext
            )
            let renderedSidecar = XMPSidecarService().sidecarURL(for: rendered)
            let renderedSidecarWasPresent = io.fileExists(renderedSidecar)

            if let sign = request.sign {
                try Task.checkCancellation()
                try await sign(rendered, request.sourceURL)
                try validateRendered(rendered, in: staging, extension: ext)
                guard !renderedSidecarWasPresent || io.fileExists(renderedSidecar) else {
                    throw RAWArchiveTransactionFailure.invalidRenderedArtifact(renderedSidecar.path)
                }
                try validateOptionalRenderedSidecar(renderedSidecar)
            }
            guard let renderedEvidence = try captureOptionalFile(
                at: rendered,
                unsafeFailure: .invalidRenderedArtifact(rendered.path)
            ) else {
                throw RAWArchiveTransactionFailure.invalidRenderedArtifact(rendered.path)
            }
            let renderedSidecarEvidence = try captureOptionalFile(
                at: renderedSidecar,
                unsafeFailure: .invalidRenderedArtifact(renderedSidecar.path)
            )

            let companion = try repository.stageArchiveCompanion(
                from: source,
                for: destination,
                in: staging
            )
            guard try optionalFileMatches(sourceSidecar, at: sourceSidecarURL) else {
                throw VoiceMemoCompanionRepository.RepositoryError.copySourceChanged
            }
            guard try optionalFileMatches(renderedEvidence, at: rendered) else {
                throw RAWArchiveTransactionFailure.invalidRenderedArtifact(rendered.path)
            }
            guard try optionalFileMatches(renderedSidecarEvidence, at: renderedSidecar) else {
                throw RAWArchiveTransactionFailure.invalidRenderedArtifact(renderedSidecar.path)
            }
            for stagedCompanion in [companion.stagedMemoURL, companion.stagedRecordURL].compactMap({ $0 }) {
                guard io.isRegularFile(stagedCompanion) else {
                    throw RAWArchiveTransactionFailure.invalidStagedCompanion(stagedCompanion.path)
                }
            }
            try Task.checkCancellation()

            var installations: [(staged: URL, destination: URL)] = [(rendered, destination)]
            let destinationSidecar = XMPSidecarService().sidecarURL(for: destination)
            if io.fileExists(renderedSidecar) {
                installations.append((renderedSidecar, destinationSidecar))
            }
            if let stagedMemo = companion.stagedMemoURL,
               let destinationMemo = companion.destinationMemoURL {
                installations.append((stagedMemo, destinationMemo))
            }
            if let stagedRecord = companion.stagedRecordURL {
                installations.append((stagedRecord, companion.destinationRecordURL))
            }

            let reservedDestinations = [destination, destinationSidecar, companion.destinationRecordURL]
                + [companion.destinationMemoURL].compactMap { $0 }
            guard Set(reservedDestinations.map(\.standardizedFileURL)).count == reservedDestinations.count else {
                throw RAWArchiveTransactionFailure.destinationChanged(destination.lastPathComponent)
            }
            if let occupied = reservedDestinations.first(where: io.fileExists) {
                throw RAWArchiveTransactionFailure.destinationChanged(occupied.lastPathComponent)
            }

            var installed: [URL] = []
            do {
                for item in installations {
                    try io.moveItem(item.staged, item.destination)
                    installed.append(item.destination)
                }
                // An archive without a relationship must not adopt an orphan record that arrived
                // after admission. It is foreign state, so rollback never removes that record.
                if !source.hasAssociation, io.fileExists(companion.destinationRecordURL) {
                    throw RAWArchiveTransactionFailure.destinationChanged(
                        companion.destinationRecordURL.lastPathComponent
                    )
                }
            } catch {
                var residuals: [String] = []
                for url in installed.reversed() {
                    do { try io.removeItem(url) }
                    catch { residuals.append(url.path) }
                }
                if !residuals.isEmpty {
                    throw RAWArchiveTransactionFailure.rollbackFailed(residuals)
                }
                throw error
            }

            let artifactURLs = installations.map(\.destination)
            var cleanupResiduals: [URL] = []
            do { try io.removeItem(staging) }
            catch { cleanupResiduals.append(staging) }
            return RAWArchiveTransactionReceipt(
                requestID: request.requestID,
                archiveURL: destination,
                artifactURLs: artifactURLs,
                cleanupResidualURLs: cleanupResiduals,
                cancellationObservedAfterCommit: Task.isCancelled
            )
        } catch {
            let originalError = error
            guard io.fileExists(staging) else { throw originalError }
            do {
                try io.removeItem(staging)
            } catch let cleanupError {
                throw RAWArchiveTransactionFailure.cleanupFailed(
                    path: staging.path,
                    originalError: "\(originalError.localizedDescription) Cleanup error: \(cleanupError.localizedDescription)"
                )
            }
            throw originalError
        }
    }

    private struct OptionalFileEvidence {
        let snapshot: SourceImageRevisionFileSnapshot
        let digest: Data
    }

    private func captureOptionalFile(
        at url: URL,
        unsafeFailure: RAWArchiveTransactionFailure
    ) throws -> OptionalFileEvidence? {
        guard io.fileExists(url) else { return nil }
        guard io.isRegularFile(url) else {
            throw unsafeFailure
        }
        let snapshot = try SourceImageRevisionCaptureIO.system.snapshot(url)
        let digest = try SourceImageRevisionCaptureIO.system.hash(url)
        guard snapshot.matches(try SourceImageRevisionCaptureIO.system.snapshot(url)) else {
            throw VoiceMemoCompanionRepository.RepositoryError.copySourceChanged
        }
        return OptionalFileEvidence(snapshot: snapshot, digest: digest)
    }

    private func optionalFileMatches(_ evidence: OptionalFileEvidence?, at url: URL) throws -> Bool {
        guard let evidence else { return !io.fileExists(url) }
        guard io.fileExists(url), io.isRegularFile(url) else { return false }
        let before = try SourceImageRevisionCaptureIO.system.snapshot(url)
        let digest = try SourceImageRevisionCaptureIO.system.hash(url)
        let after = try SourceImageRevisionCaptureIO.system.snapshot(url)
        return evidence.snapshot.matches(before) && before.matches(after) && evidence.digest == digest
    }

    private func availableDestination(
        for sourceURL: URL,
        in folder: URL,
        extension fileExtension: String,
        memoExtension: String?
    ) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let suffix = counter == 1 ? "" : " \(counter)"
            let candidate = folder.appendingPathComponent(base + suffix)
                .appendingPathExtension(fileExtension)
            let destinations = [
                candidate,
                XMPSidecarService().sidecarURL(for: candidate),
                repository.recordURL(for: candidate)
            ] + (memoExtension.map {
                [candidate.deletingPathExtension().appendingPathExtension($0)]
            } ?? [])
            if !destinations.contains(where: io.fileExists) { return candidate }
            counter += 1
        }
    }

    private func validateRendered(_ url: URL, in staging: URL, extension fileExtension: String) throws {
        let rendered = url.standardizedFileURL
        guard rendered.deletingLastPathComponent() == staging.standardizedFileURL,
              rendered.pathExtension.lowercased() == fileExtension.lowercased(),
              io.isRegularFile(rendered) else {
            throw RAWArchiveTransactionFailure.invalidRenderedArtifact(url.path)
        }
    }

    /// The archive is signed under its final basename. This matters when a destination collision
    /// adds a suffix: a basename-sensitive manifest must not be created for a temporary old name
    /// and then moved to a differently named archive.
    private func normalizeRenderedArtifacts(
        _ rendererOutput: URL,
        toMatch destination: URL,
        in staging: URL,
        extension fileExtension: String
    ) throws -> URL {
        try validateRendered(rendererOutput, in: staging, extension: fileExtension)
        let source = rendererOutput.standardizedFileURL
        let sourceSidecar = XMPSidecarService().sidecarURL(for: source)
        try validateOptionalRenderedSidecar(sourceSidecar)

        let normalized = staging.appendingPathComponent(destination.lastPathComponent)
            .standardizedFileURL
        guard normalized != source else { return source }
        let normalizedSidecar = XMPSidecarService().sidecarURL(for: normalized)
        guard !io.fileExists(normalized), !io.fileExists(normalizedSidecar) else {
            throw RAWArchiveTransactionFailure.invalidRenderedArtifact(normalized.path)
        }
        try io.moveItem(source, normalized)
        if io.fileExists(sourceSidecar) {
            try io.moveItem(sourceSidecar, normalizedSidecar)
        }
        try validateRendered(normalized, in: staging, extension: fileExtension)
        try validateOptionalRenderedSidecar(normalizedSidecar)
        return normalized
    }

    private func validateOptionalRenderedSidecar(_ url: URL) throws {
        if io.fileExists(url), !io.isRegularFile(url) {
            throw RAWArchiveTransactionFailure.invalidRenderedArtifact(url.path)
        }
    }
}
