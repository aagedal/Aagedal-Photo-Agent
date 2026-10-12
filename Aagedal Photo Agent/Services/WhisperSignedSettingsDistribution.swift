import Foundation

/// Explicit dependency for signed Settings installations. The application supplies its
/// own trust anchor and catalog; no server-provided key or compiled-catalog fallback
/// can authorize a signed release. Production provisioning remains a separate gate.
nonisolated struct WhisperSignedSettingsDistribution: Sendable {
    struct Entry: Sendable {
        let descriptorData: Data
        let signature: Data
        let lifecycle: WhisperSignedModelLifecycle
    }

    enum DistributionError: Error, Equatable {
        case invalidCatalog, unknownModel, inspectionRequired, changedRelease
    }

    let models: [WhisperDownloadableModel]
    private let controller: Controller

    init(trust: WhisperModelDistributionTrust, entries: [Entry]) throws {
        guard !entries.isEmpty, entries.count <= 32 else { throw DistributionError.invalidCatalog }
        var releases: [String: Controller.Release] = [:]
        var models: [WhisperDownloadableModel] = []
        for entry in entries {
            let receipt = try trust.verify(entry.descriptorData, signature: entry.signature)
            let model = receipt.downloadableModel
            guard releases[model.id] == nil else { throw DistributionError.invalidCatalog }
            models.append(model)
            releases[model.id] = .init(receipt: receipt, entry: entry)
        }
        self.models = models
        controller = Controller(releases: releases)
    }

    @MainActor
    func operations(admission: FFmpegWhisperArtifactAdmissionService,
                    admit: (@Sendable (URL, WhisperDownloadableModel) async throws -> FFmpegWhisperArtifactAdmissionService.Receipt)? = nil) -> ManagedWhisperSetupModel.Operations {
        let controller = controller
        return .init(installed: { try await controller.installed($0) },
                     download: { try await controller.download($0, progress: $1) },
                     remove: { try await controller.remove($0) },
                     admit: admit ?? { try await admission.admitBundled(modelURL: $0, model: $1) },
                     localModelIDs: { try await controller.localModelIDs() })
    }

    private actor Controller {
        struct Release: Sendable {
            let receipt: WhisperModelDescriptorReceipt
            let entry: Entry
        }
        struct Inspection: Sendable {
            let snapshot: WhisperModelDistributionStateStore.Snapshot?
        }
        let releases: [String: Release]
        var inspections: [String: Inspection] = [:]

        init(releases: [String: Release]) { self.releases = releases }

        func release(for model: WhisperDownloadableModel) throws -> Release {
            guard let release = releases[model.id], release.receipt.downloadableModel == model else {
                throw DistributionError.unknownModel
            }
            return release
        }

        func installed(_ model: WhisperDownloadableModel) async throws -> URL? {
            let release = try release(for: model)
            let snapshot = try await release.entry.lifecycle.snapshot()
            try Task.checkCancellation()
            inspections[model.id] = Inspection(snapshot: snapshot)
            guard let snapshot else { return nil }
            // A prior release remains retained for rollback, but never supplies bytes
            // to admission under the catalog's newer model identity.
            guard snapshot.release.current.descriptorSHA256 == release.receipt.descriptorSHA256 else { return nil }
            return try await release.entry.lifecycle.installedURL(expectedGeneration: snapshot.generation)
        }

        func localModelIDs() async throws -> Set<String> {
            var result: Set<String> = []
            for id in releases.keys.sorted() {
                let model = releases[id]!.receipt.downloadableModel
                if try await installed(model) != nil { result.insert(id) }
            }
            return result
        }

        func download(_ model: WhisperDownloadableModel,
                      progress: @escaping WhisperModelDownloadService.Progress) async throws -> URL {
            let release = try release(for: model)
            guard let inspection = inspections[model.id] else { throw DistributionError.inspectionRequired }
            let snapshot: WhisperModelDistributionStateStore.Snapshot
            if let current = inspection.snapshot,
               current.release.current.descriptorSHA256 == release.receipt.descriptorSHA256 {
                let url = try await release.entry.lifecycle.restoreCurrentModel(expectedGeneration: current.generation, progress: progress)
                return url
            } else {
                snapshot = try await release.entry.lifecycle.install(descriptorData: release.entry.descriptorData,
                    signature: release.entry.signature, expectedGeneration: inspection.snapshot?.generation, progress: progress)
            }
            // Keep the published generation even when cancellation raced publication.
            inspections[model.id] = Inspection(snapshot: snapshot)
            // Publication has completed. Finish read-only presence settlement even if
            // the caller cancelled at that boundary; Setup records presence and then
            // refuses artifact admission. No inference or mutation runs in this task.
            let lifecycle = release.entry.lifecycle
            let url = try await Task.detached {
                try await lifecycle.installedURL(expectedGeneration: snapshot.generation)
            }.value
            guard let url else { throw DistributionError.changedRelease }
            return url
        }

        func remove(_ model: WhisperDownloadableModel) async throws {
            let release = try release(for: model)
            guard let inspection = inspections[model.id], let snapshot = inspection.snapshot else {
                throw DistributionError.inspectionRequired
            }
            guard snapshot.release.current.descriptorSHA256 == release.receipt.descriptorSHA256 else {
                throw DistributionError.changedRelease
            }
            _ = try await release.entry.lifecycle.removeModels(expectedGeneration: snapshot.generation)
            inspections[model.id] = Inspection(snapshot: try await release.entry.lifecycle.snapshot())
        }
    }
}
