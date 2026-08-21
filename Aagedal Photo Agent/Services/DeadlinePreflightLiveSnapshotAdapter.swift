import Foundation

/// Stable identifiers exposed by the production Deadline resource inventories.
///
/// UUID-backed resources retain their persisted UUID identity. The two process-wide resources
/// have namespaced identifiers so an imported profile can refer to them without depending on a
/// display name or a filesystem path.
nonisolated enum DeadlineLiveResourceIdentifier {
    static let approvedKeywords = "photo-agent.approved-list.keywords.v1"
    static let currentExportConfiguration = "photo-agent.export.current.v1"

    static func persisted(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

nonisolated struct DeadlineLiveExportConfiguration: Equatable, Sendable {
    let identifier: String
    let snapshot: DeadlineExportSnapshot

    init(identifier: String, snapshot: DeadlineExportSnapshot) {
        self.identifier = identifier
        self.snapshot = snapshot
    }
}

/// Values already owned by application stores. Adapting them is pure: filesystem and network
/// state are deliberately absent from this inventory.
nonisolated struct DeadlineLiveResourceInventory: Equatable, Sendable {
    var validationProfiles: [MetadataValidationProfile]
    var metadataTemplateIdentifiers: Set<String>
    var availableRequiredListIdentifiers: Set<String>
    var renamePresets: [BatchRenameRecipePreset]
    var exportConfigurations: [DeadlineLiveExportConfiguration]

    init(
        validationProfiles: [MetadataValidationProfile] = [],
        metadataTemplateIdentifiers: Set<String> = [],
        availableRequiredListIdentifiers: Set<String> = [],
        renamePresets: [BatchRenameRecipePreset] = [],
        exportConfigurations: [DeadlineLiveExportConfiguration] = []
    ) {
        self.validationProfiles = validationProfiles
        self.metadataTemplateIdentifiers = metadataTemplateIdentifiers
        self.availableRequiredListIdentifiers = availableRequiredListIdentifiers
        self.renamePresets = renamePresets
        self.exportConfigurations = exportConfigurations
    }
}

nonisolated struct DeadlineLiveRequiredListCandidate: Equatable, Sendable {
    let identifier: String
}

nonisolated struct DeadlineLiveSourceItem: Equatable, Sendable {
    let sourceURL: URL
    let metadata: IPTCMetadata
    let sidecarState: DeadlineSidecarStateSnapshot
    let renameContext: BatchRenameContext
    let byteCount: Int64?
    let isICloudDownloadPending: Bool
    let isSupportedFormat: Bool
    let isHDR: Bool
    let hasC2PA: Bool
    let exifOrientation: Int
}

nonisolated struct DeadlinePreflightLiveCaptureRequest: Equatable, Sendable {
    let profile: DeadlineProfile
    let items: [DeadlineLiveSourceItem]
    let inventory: DeadlineLiveResourceInventory
    let requiredListCandidates: [DeadlineLiveRequiredListCandidate]
    let renameDirectoryURL: URL?
    let stagingRootURL: URL?
    let useDefaultApplicationStagingRoot: Bool
    let estimatedRequiredBytes: Int64?
    let connectionIdentifiers: Set<String>
    let selectionSourceRevision: UInt64
    let metadataRevision: UInt64
    let profileRevision: UInt64
    let developSnapshots: [DevelopVersionSnapshot?]
}

nonisolated struct DeadlinePreflightLiveProjection: Equatable, Sendable {
    let resources: DeadlinePreflightResourceSnapshot
    let renameEnvironment: RenamePlanningEnvironment
    let exportCapabilities: DeadlineExportCapabilitySnapshot
    let delivery: DeadlineBatchDeliverySnapshot
    let resourceRevision: UInt64
    let renameEnvironmentRevision: UInt64
    let exportCapabilityRevision: UInt64
    let deliverySnapshotRevision: UInt64
}

nonisolated struct DeadlinePreflightLiveProjectionRequest: Equatable, Sendable {
    let profile: DeadlineProfile
    let inventory: DeadlineLiveResourceInventory
    let renameDirectoryURL: URL?
    let stagingRootURL: URL?
    let estimatedRequiredBytes: Int64?
    let connectionIdentifiers: Set<String>

    init(
        profile: DeadlineProfile,
        inventory: DeadlineLiveResourceInventory,
        renameDirectoryURL: URL?,
        stagingRootURL: URL?,
        estimatedRequiredBytes: Int64? = nil,
        connectionIdentifiers: Set<String> = []
    ) {
        self.profile = profile
        self.inventory = inventory
        self.renameDirectoryURL = renameDirectoryURL
        self.stagingRootURL = stagingRootURL
        self.estimatedRequiredBytes = estimatedRequiredBytes
        self.connectionIdentifiers = connectionIdentifiers
    }
}

private nonisolated struct DeadlineLiveResourceRevisionPayload: Encodable {
    let validationProfiles: [MetadataValidationProfile]
    let metadataTemplateIdentifiers: [String]
    let availableRequiredListIdentifiers: [String]
    let renamePresets: [BatchRenameRecipePreset]
    let exportConfigurations: [DeadlineLiveExportConfigurationRevisionPayload]
}

private nonisolated struct DeadlineLiveExportConfigurationRevisionPayload: Encodable {
    let identifier: String
    let snapshot: DeadlineExportSnapshot
}

nonisolated enum DeadlineLiveSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case directoryUnavailable(URL)
    case directoryCaseSensitivityUnknown(URL)
    case stagingRootUnavailable
    case stagingCapacityUnknown(URL)
    case stagingWriteVerificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            "The rename destination could not be inventoried."
        case .directoryCaseSensitivityUnknown:
            "The rename destination's filename case sensitivity could not be determined."
        case .stagingRootUnavailable:
            "No application staging root is configured."
        case .stagingCapacityUnknown:
            "The staging volume's available capacity could not be measured."
        case .stagingWriteVerificationFailed:
            "The application could not verify write access to its staging root."
        }
    }
}

/// Production filesystem seams. The adapter never starts or stops security-scoped access: a
/// browser folder must already be held by the browser session, while the staging root must be an
/// application-owned location. This avoids unbalancing a caller's security-scope lifetime.
nonisolated struct DeadlineLiveFileSystem: Sendable {
    var itemExists: @Sendable (URL) -> Bool
    var itemIsReadable: @Sendable (URL) -> Bool
    var nativePixelSize: @Sendable (URL) -> CGSize?
    var requiredListExists: @Sendable (String) -> Bool
    var defaultApplicationStagingRoot: @Sendable () -> URL?
    var directoryExists: @Sendable (URL) -> Bool
    var directoryContents: @Sendable (URL) throws -> [URL]
    var volumeIsCaseSensitive: @Sendable (URL) throws -> Bool?
    var availableCapacity: @Sendable (URL) throws -> Int64?
    var prepareAndVerifyApplicationStagingRoot: @Sendable (URL) throws -> Void

    static let live = Self(
        itemExists: { FileManager.default.fileExists(atPath: $0.path) },
        itemIsReadable: { FileManager.default.isReadableFile(atPath: $0.path) },
        nativePixelSize: { FullScreenImageCache.nativePixelSize(of: $0) },
        requiredListExists: { identifier in
            guard identifier == DeadlineLiveResourceIdentifier.approvedKeywords else { return false }
            let fileManager = FileManager.default
            let localBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let local = localBase?
                .appendingPathComponent("Aagedal Photo Agent/Lists/approved/keywords.txt")
            if UserDefaults.standard.bool(forKey: UserDefaultsKeys.keywordListsICloudEnabled),
               let cloud = fileManager.url(
                   forUbiquityContainerIdentifier: AppPaths.iCloudContainerID
               )?.appendingPathComponent("Documents/Lists/approved/keywords.txt") {
                return fileManager.fileExists(atPath: cloud.path)
            }
            return local.map { fileManager.fileExists(atPath: $0.path) } ?? false
        },
        defaultApplicationStagingRoot: {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Aagedal Photo Agent/DeliveryStaging", isDirectory: true)
        },
        directoryExists: { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        directoryContents: { url in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        },
        volumeIsCaseSensitive: { url in
            try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames
        },
        availableCapacity: { url in
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return Int64(important)
            }
            return values.volumeAvailableCapacity.map(Int64.init)
        },
        prepareAndVerifyApplicationStagingRoot: { root in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(
                ".deadline-write-probe-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(at: probe, withIntermediateDirectories: false)
                try fileManager.removeItem(at: probe)
            } catch {
                try? fileManager.removeItem(at: probe)
                throw DeadlineLiveSnapshotError.stagingWriteVerificationFailed(root)
            }
        }
    )
}

nonisolated struct DeadlineLiveSourceRevisionCapture: Sendable {
    let capture: @Sendable (URL, Int?, Int?, Int?) async throws -> SourceImageRevision

    static let live = Self { url, width, height, orientation in
        try await SourceImageRevision.capture(
            at: url,
            pixelWidth: width,
            pixelHeight: height,
            exifOrientation: orientation
        )
    }
}

/// Converts live application/store facts into one immutable request projection. It performs no
/// network probe and does not inspect or expose connection credentials.
nonisolated struct DeadlinePreflightLiveSnapshotAdapter: Sendable {
    private let fileSystem: DeadlineLiveFileSystem
    private let productionExportCapabilities: @Sendable () -> DeadlineExportCapabilitySnapshot
    private let sourceRevisionCapture: DeadlineLiveSourceRevisionCapture

    init(
        fileSystem: DeadlineLiveFileSystem = .live,
        sourceRevisionCapture: DeadlineLiveSourceRevisionCapture = .live,
        productionExportCapabilities: @escaping @Sendable () -> DeadlineExportCapabilitySnapshot = {
            DeliveryStagingProductionCapabilities.deadlinePreflightSnapshot
        }
    ) {
        self.fileSystem = fileSystem
        self.sourceRevisionCapture = sourceRevisionCapture
        self.productionExportCapabilities = productionExportCapabilities
    }

    func capture(_ request: DeadlinePreflightLiveCaptureRequest) async throws -> DeadlineWorkspaceInput {
        try Task.checkCancellation()
        var inventory = request.inventory
        for candidate in request.requiredListCandidates {
            if fileSystem.requiredListExists(candidate.identifier) {
                inventory.availableRequiredListIdentifiers.insert(candidate.identifier)
            }
        }
        let stagingRoot = request.stagingRootURL
            ?? (request.useDefaultApplicationStagingRoot
                ? fileSystem.defaultApplicationStagingRoot()
                : nil)
        let projection = project(.init(
            profile: request.profile,
            inventory: inventory,
            renameDirectoryURL: request.renameDirectoryURL,
            stagingRootURL: stagingRoot,
            estimatedRequiredBytes: request.estimatedRequiredBytes,
            connectionIdentifiers: request.connectionIdentifiers
        ))
        let items = try request.items.map { item in
            try Task.checkCancellation()
            return sourceSnapshot(item, profile: request.profile)
        }
        var sourceRevisions: [SourceImageRevision?] = []
        sourceRevisions.reserveCapacity(items.count)
        for index in items.indices {
            try Task.checkCancellation()
            let item = items[index]
            guard item.source.isAvailable, item.source.isReadable else {
                sourceRevisions.append(nil)
                continue
            }
            do {
                sourceRevisions.append(try await sourceRevisionCapture.capture(
                    item.sourceURL,
                    item.source.pixelWidth,
                    item.source.pixelHeight,
                    request.items[index].exifOrientation
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                sourceRevisions.append(nil)
            }
        }
        let preflightRequest = DeadlinePreflightRequest(
            profile: request.profile,
            items: items,
            resources: projection.resources,
            renameEnvironment: projection.renameEnvironment,
            exportCapabilities: projection.exportCapabilities,
            delivery: projection.delivery
        )
        return DeadlineWorkspaceInput(
            request: preflightRequest,
            revisionToken: DeadlinePreflightRevisionToken(
                selectionSourceRevision: request.selectionSourceRevision,
                metadataRevision: request.metadataRevision,
                profileRevision: request.profileRevision,
                resourceRevision: projection.resourceRevision,
                renameEnvironmentRevision: projection.renameEnvironmentRevision,
                exportCapabilityRevision: projection.exportCapabilityRevision,
                deliverySnapshotRevision: projection.deliverySnapshotRevision
            ),
            developSnapshots: request.developSnapshots,
            sourceRevisions: sourceRevisions,
            // Source permission and remote reachability still lack event-backed revisions.
            cachePolicy: .bypass
        )
    }

    func project(_ request: DeadlinePreflightLiveProjectionRequest) -> DeadlinePreflightLiveProjection {
        let resources = resourceSnapshot(request.inventory)
        let renameEnvironment = renameSnapshot(at: request.renameDirectoryURL)
        let capabilities = exportCapabilitySnapshot()
        let delivery = deliverySnapshot(request)
        return DeadlinePreflightLiveProjection(
            resources: resources,
            renameEnvironment: renameEnvironment,
            exportCapabilities: capabilities,
            delivery: delivery,
            resourceRevision: resourceRevision(request.inventory),
            renameEnvironmentRevision: renameRevision(renameEnvironment),
            exportCapabilityRevision: exportRevision(capabilities),
            deliverySnapshotRevision: deliveryRevision(delivery)
        )
    }

    private func resourceSnapshot(
        _ inventory: DeadlineLiveResourceInventory
    ) -> DeadlinePreflightResourceSnapshot {
        var validations: [String: MetadataValidationProfile] = [:]
        for profile in inventory.validationProfiles {
            install(profile, id: profile.id, into: &validations)
        }
        var recipes: [String: BatchRenameRecipe] = [:]
        for preset in inventory.renamePresets {
            install(preset.recipe, id: preset.id, into: &recipes)
        }
        var exports: [String: DeadlineExportSnapshot] = [:]
        for configuration in inventory.exportConfigurations {
            exports[configuration.identifier] = configuration.snapshot
        }
        return DeadlinePreflightResourceSnapshot(
            validationProfiles: validations,
            metadataTemplateIdentifiers: inventory.metadataTemplateIdentifiers,
            listIdentifiers: inventory.availableRequiredListIdentifiers,
            renameRecipes: recipes,
            exportConfigurations: exports
        )
    }

    private func install<Value>(_ value: Value, id: UUID, into values: inout [String: Value]) {
        // Existing profiles exported before canonicalization can contain either UUID spelling.
        // Both keys point to one immutable value; newly created references use lowercase.
        values[id.uuidString] = value
        values[DeadlineLiveResourceIdentifier.persisted(id)] = value
    }

    private func renameSnapshot(at directoryURL: URL?) -> RenamePlanningEnvironment {
        guard let directoryURL else {
            return RenamePlanningEnvironment(caseSensitivity: .caseInsensitive, isComplete: false)
        }
        let standardized = directoryURL.standardizedFileURL
        guard fileSystem.directoryExists(standardized) else {
            return RenamePlanningEnvironment(caseSensitivity: .caseInsensitive, isComplete: false)
        }
        do {
            guard let isCaseSensitive = try fileSystem.volumeIsCaseSensitive(standardized) else {
                return RenamePlanningEnvironment(caseSensitivity: .caseInsensitive, isComplete: false)
            }
            var existing = Set(try fileSystem.directoryContents(standardized).map(\.standardizedFileURL))
            let registry = RenameArtifactRegistry.standard
            let relativeDirectories = Set(registry.rules.compactMap { rule -> String? in
                guard !rule.relativeDirectoryComponents.isEmpty else { return nil }
                return rule.relativeDirectoryComponents.joined(separator: "/")
            })
            for relativeDirectory in relativeDirectories {
                let child = standardized.appendingPathComponent(relativeDirectory, isDirectory: true)
                guard fileSystem.directoryExists(child) else { continue }
                existing.formUnion(try fileSystem.directoryContents(child).map(\.standardizedFileURL))
            }
            return RenamePlanningEnvironment(
                caseSensitivity: isCaseSensitive ? .caseSensitive : .caseInsensitive,
                existingURLs: existing,
                isComplete: true
            )
        } catch {
            return RenamePlanningEnvironment(caseSensitivity: .caseInsensitive, isComplete: false)
        }
    }

    private func exportCapabilitySnapshot() -> DeadlineExportCapabilitySnapshot {
        productionExportCapabilities()
    }

    private func sourceSnapshot(
        _ item: DeadlineLiveSourceItem,
        profile: DeadlineProfile
    ) -> DeadlinePreflightItemSnapshot {
        let available = !item.isICloudDownloadPending && fileSystem.itemExists(item.sourceURL)
        let readable = available && fileSystem.itemIsReadable(item.sourceURL)
        let nativeSize = readable ? fileSystem.nativePixelSize(item.sourceURL) : nil
        let dimensions: (width: Int?, height: Int?)
        if let nativeSize {
            let width = Int(nativeSize.width.rounded())
            let height = Int(nativeSize.height.rounded())
            dimensions = (5...8).contains(item.exifOrientation) ? (height, width) : (width, height)
        } else {
            dimensions = (nil, nil)
        }
        return DeadlinePreflightItemSnapshot(
            sourceURL: item.sourceURL,
            metadata: item.metadata,
            renameContext: item.renameContext,
            sidecarState: item.sidecarState,
            source: DeadlineSourceSnapshot(
                isAvailable: available,
                isReadable: readable,
                isWritable: false,
                isWritabilityKnown: false,
                isSupportedFormat: item.isSupportedFormat,
                canDecode: nativeSize != nil,
                byteCount: item.byteCount,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                isHDR: item.isHDR
            ),
            c2paConsequence: c2paConsequence(hasC2PA: item.hasC2PA, profile: profile)
        )
    }

    private func c2paConsequence(
        hasC2PA: Bool,
        profile: DeadlineProfile
    ) -> DeadlineC2PAConsequence {
        guard hasC2PA else { return .none }
        return switch profile.metadataWriteStrategy {
        case .originals: .originalWriteInvalidatesManifest
        case .xmpSidecars: .preserved
        case .stagedCopies where profile.export != nil: .derivedOutputDropsManifest
        case .stagedCopies: .requiresResigning
        }
    }

    private func deliverySnapshot(
        _ request: DeadlinePreflightLiveProjectionRequest
    ) -> DeadlineBatchDeliverySnapshot {
        var connections: [String: DeadlineConnectionStateSnapshot] = [:]
        for candidate in request.connectionIdentifiers {
            guard let id = UUID(uuidString: candidate) else { continue }
            let identifier = DeadlineLiveResourceIdentifier.persisted(id)
            // Configuration is a local credential-store fact. Reachability remains unknown until
            // an explicit user-authorized probe or an upload attempt observes the network.
            connections[identifier] = .configuredReachabilityUnknown
        }

        let staging: DeadlineStagingStateSnapshot
        var stagingRoot: URL?
        var stagingCapacity: Int64?
        if request.profile.metadataWriteStrategy == .stagedCopies {
            guard let root = request.stagingRootURL?.standardizedFileURL else {
                return DeadlineBatchDeliverySnapshot(
                    estimatedRequiredBytes: request.estimatedRequiredBytes,
                    stagingState: .unavailable(reason: DeadlineLiveSnapshotError.stagingRootUnavailable.localizedDescription),
                    connections: connections,
                    remotePathState: remotePathState(request.profile.destination?.remotePathTemplate),
                    supportedMetadataWriteStrategies:
                        DeliveryStagingProductionCapabilities.supportedMetadataWriteStrategies
                )
            }
            stagingRoot = root
            do {
                try fileSystem.prepareAndVerifyApplicationStagingRoot(root)
                guard fileSystem.directoryExists(root) else {
                    throw DeadlineLiveSnapshotError.stagingRootUnavailable
                }
                guard let available = try fileSystem.availableCapacity(root) else {
                    throw DeadlineLiveSnapshotError.stagingCapacityUnknown(root)
                }
                stagingCapacity = available
                if let required = request.estimatedRequiredBytes, required > available {
                    staging = .insufficientSpace(requiredBytes: required, availableBytes: available)
                } else {
                    staging = .ready
                }
            } catch {
                staging = .unavailable(reason: "The application staging root could not be verified.")
            }
        } else {
            staging = .notRequired
        }

        return DeadlineBatchDeliverySnapshot(
            estimatedRequiredBytes: request.estimatedRequiredBytes,
            stagingState: staging,
            connections: connections,
            remotePathState: remotePathState(request.profile.destination?.remotePathTemplate),
            stagingRootURL: stagingRoot,
            stagingAvailableBytes: stagingCapacity,
            supportedMetadataWriteStrategies:
                DeliveryStagingProductionCapabilities.supportedMetadataWriteStrategies
        )
    }

    private func remotePathState(_ path: String?) -> DeadlineRemotePathStateSnapshot? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid(reason: "The remote path is empty.") }
        let variables = variables(in: trimmed)
        if !variables.isEmpty { return .unresolvedVariables(variables) }
        guard trimmed == path,
              trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("//"),
              !trimmed.contains("\\"),
              !trimmed.contains("://"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              trimmed.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  $0 != "." && $0 != ".."
              }) else {
            return .invalid(reason: "The remote path is not a safe absolute directory.")
        }
        return .valid(resolvedPath: trimmed)
    }

    private func variables(in value: String) -> [String] {
        var variables: [String] = []
        var remainder = value[...]
        while let opening = remainder.firstIndex(of: "{") {
            let afterOpening = remainder.index(after: opening)
            guard let closing = remainder[afterOpening...].firstIndex(of: "}") else { break }
            let variable = remainder[afterOpening..<closing]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !variable.isEmpty { variables.append(variable) }
            remainder = remainder[remainder.index(after: closing)...]
        }
        return Array(Set(variables)).sorted()
    }

    private func resourceRevision(_ inventory: DeadlineLiveResourceInventory) -> UInt64 {
        let payload = DeadlineLiveResourceRevisionPayload(
            validationProfiles: inventory.validationProfiles.sorted {
                $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            },
            metadataTemplateIdentifiers: inventory.metadataTemplateIdentifiers.sorted(),
            availableRequiredListIdentifiers: inventory.availableRequiredListIdentifiers.sorted(),
            renamePresets: inventory.renamePresets.sorted {
                $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            },
            exportConfigurations: inventory.exportConfigurations
                .sorted { $0.identifier < $1.identifier }
                .map {
                    DeadlineLiveExportConfigurationRevisionPayload(
                        identifier: $0.identifier,
                        snapshot: $0.snapshot
                    )
                }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return 0 }
        return stableRevision(data)
    }

    private func renameRevision(_ environment: RenamePlanningEnvironment) -> UInt64 {
        stableRevision([
            environment.caseSensitivity.rawValue,
            String(environment.isComplete),
        ] + environment.existingURLs.map { $0.standardizedFileURL.path }.sorted())
    }

    private func exportRevision(_ capabilities: DeadlineExportCapabilitySnapshot) -> UInt64 {
        stableRevision([
            String(capabilities.isKnown),
            capabilities.availableSDRFormats.map(\.rawValue).joined(separator: ","),
            capabilities.availableHDRFormats.map(\.rawValue).joined(separator: ","),
            capabilities.availableSDRGamuts.map(\.rawValue).joined(separator: ","),
            capabilities.availableHDRGamuts.map(\.rawValue).joined(separator: ","),
        ])
    }

    private func deliveryRevision(_ delivery: DeadlineBatchDeliverySnapshot) -> UInt64 {
        stableRevision([
            String(describing: delivery.estimatedRequiredBytes),
            String(describing: delivery.stagingState),
            delivery.connections.keys.sorted().map {
                "\($0)=\(String(describing: delivery.connections[$0]!))"
            }.joined(separator: ","),
            String(describing: delivery.remotePathState),
            delivery.stagingRootURL?.standardizedFileURL.path ?? "",
            String(describing: delivery.stagingAvailableBytes),
            delivery.supportedMetadataWriteStrategies.map(\.rawValue).joined(separator: ","),
        ])
    }

    private func stableRevision(_ data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private func stableRevision(_ values: [String]) -> UInt64 {
        stableRevision(Data(values.joined(separator: "\n").utf8))
    }
}
