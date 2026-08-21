import CryptoKit
import Foundation

nonisolated enum DeliveryPlanningError: Error, Equatable, LocalizedError, Sendable {
    case emptySelection
    case stalePreflight
    case profileChangedAfterPreflight
    case preflightBlocked(count: Int)
    case unacceptedWarnings([String])
    case unexpectedAcceptedWarnings([String])
    case itemCountMismatch(expected: Int, found: Int)
    case preflightResultMismatch
    case sourceURLMismatch(itemIndex: Int)
    case invalidSourceRevision(itemIndex: Int)
    case sourceChangedAfterPreflight(itemIndex: Int)
    case metadataChangedAfterPreflight(itemIndex: Int)
    case developSettingsChangedAfterPreflight(itemIndex: Int)
    case invalidDevelopSnapshot(itemIndex: Int)
    case missingExportConfiguration
    case missingDestination
    case destinationMismatch
    case unresolvedDestinationPath
    case unsafeDestinationPath
    case missingRenamePlan
    case incompleteRenamePlan(itemIndex: Int)
    case invalidOutputFilename(itemIndex: Int)
    case duplicateOutputFilename(String)
    case duplicateSource(URL)
    case invalidFingerprint
    case exportSnapshotMismatch
    case writeSnapshotMismatch
    case persistedPlanInvalid

    var errorDescription: String? {
        switch self {
        case .emptySelection: "A delivery plan requires at least one selected image."
        case .stalePreflight: "The preflight result is stale. Run preflight again."
        case .profileChangedAfterPreflight:
            "The deadline profile changed after preflight. Run preflight again."
        case let .preflightBlocked(count):
            "The delivery plan cannot be frozen while preflight has \(count) blocker(s)."
        case let .unacceptedWarnings(ids):
            "Every warning must be accepted before freezing the plan: \(ids.joined(separator: ", "))."
        case let .unexpectedAcceptedWarnings(ids):
            "The warning acceptance contains stale or unknown issues: \(ids.joined(separator: ", "))."
        case let .itemCountMismatch(expected, found):
            "Preflight contains \(expected) item(s), but \(found) delivery input(s) were supplied."
        case .preflightResultMismatch:
            "The preflight result does not describe the supplied preflight request."
        case let .sourceURLMismatch(index):
            "The source identity for item \(index) does not match its preflight URL."
        case let .invalidSourceRevision(index):
            "The source revision for item \(index) is incomplete or invalid."
        case let .sourceChangedAfterPreflight(index):
            "The source bytes for item \(index) changed after preflight."
        case let .metadataChangedAfterPreflight(index):
            "Resolved metadata for item \(index) changed after preflight."
        case let .developSettingsChangedAfterPreflight(index):
            "Develop settings for item \(index) changed after preflight."
        case let .invalidDevelopSnapshot(index):
            "The Develop snapshot for item \(index) is incomplete."
        case .missingExportConfiguration:
            "The selected profile has no resolved export configuration."
        case .missingDestination: "The selected profile has no delivery destination."
        case .destinationMismatch:
            "The resolved destination does not match the selected profile."
        case .unresolvedDestinationPath:
            "The remote delivery path is not fully resolved."
        case .unsafeDestinationPath:
            "The resolved destination path is not a safe remote path."
        case .missingRenamePlan:
            "The selected profile requires rename output, but preflight has no rename plan."
        case let .incompleteRenamePlan(index):
            "The rename output for item \(index) is incomplete."
        case let .invalidOutputFilename(index):
            "The planned output filename for item \(index) is invalid."
        case let .duplicateOutputFilename(filename):
            "More than one staged output would be named \(filename)."
        case let .duplicateSource(url):
            "The source \(url.lastPathComponent) occurs more than once in the delivery plan."
        case .invalidFingerprint: "The delivery-plan fingerprint does not match its frozen inputs."
        case .exportSnapshotMismatch:
            "The frozen export settings do not match the selected profile."
        case .writeSnapshotMismatch:
            "The frozen metadata-write settings do not match the selected profile."
        case .persistedPlanInvalid: "The persisted delivery plan is structurally invalid."
        }
    }
}

/// Pure planner. It performs no filesystem reads, writes, rendering, metadata mutation, or upload.
nonisolated struct DeliveryPlanningService: Sendable {
    func makePlan(_ request: DeliveryPlanningRequest) throws -> DeliveryPlan {
        guard !request.items.isEmpty else { throw DeliveryPlanningError.emptySelection }
        guard request.publication.token == request.currentRevision else {
            throw DeliveryPlanningError.stalePreflight
        }
        guard request.currentProfile == request.preflightRequest.profile else {
            throw DeliveryPlanningError.profileChangedAfterPreflight
        }
        try DeadlineProfileIO().validate(request.currentProfile)

        let report = request.publication.report
        guard !report.isBlocked else {
            throw DeliveryPlanningError.preflightBlocked(count: report.blockerCount)
        }
        try validateWarningAcceptance(
            report: report,
            acceptedWarningIDs: request.acceptedWarningIDs
        )
        try validatePreflightShape(request)

        let export = try resolvedExport(in: request.preflightRequest)
        let destination = try resolvedDestination(in: request.preflightRequest)
        let renderAndWrite = DeliveryRenderWriteSnapshot(
            export: export,
            metadataWriteStrategy: request.currentProfile.metadataWriteStrategy,
            gpsPolicy: request.currentProfile.gpsPolicy,
            verificationFields: IPTCMetadataVerificationField.writableFields
        )

        var frozenItems: [DeliveryPlanStageItem] = []
        var sourceURLs = Set<URL>()
        var outputNames = Set<String>()
        for index in request.items.indices {
            let itemInput = request.items[index]
            let preflightItem = request.preflightRequest.items[index]
            try validate(
                itemInput,
                against: preflightItem,
                itemIndex: index
            )

            let sourceURL = itemInput.currentSourceRevision.canonicalURL.standardizedFileURL
            guard sourceURLs.insert(sourceURL).inserted else {
                throw DeliveryPlanningError.duplicateSource(sourceURL)
            }
            let outputFilename = try outputFilename(
                itemIndex: index,
                sourceURL: preflightItem.sourceURL,
                isHDR: preflightItem.source.isHDR,
                export: export,
                renameConfiguration: request.currentProfile.rename,
                renamePlan: report.renamePlan
            )
            let outputKey = outputFilename.precomposedStringWithCanonicalMapping.lowercased()
            guard outputNames.insert(outputKey).inserted else {
                throw DeliveryPlanningError.duplicateOutputFilename(outputFilename)
            }

            var metadata = itemInput.resolvedMetadata
            // Camera Raw state belongs to the independently validated Develop snapshot, and EXIF
            // orientation is source technical state. Neither belongs in descriptive write input.
            metadata.cameraRaw = nil
            metadata.exifOrientation = nil
            if request.currentProfile.gpsPolicy == .remove {
                metadata.latitude = nil
                metadata.longitude = nil
            }

            let draft = DeliveryPlanStageItem(
                itemIndex: index,
                sourceRevision: itemInput.currentSourceRevision,
                resolvedMetadata: metadata,
                outputFilename: outputFilename,
                stagedRelativePath: outputFilename,
                isHDR: preflightItem.source.isHDR,
                developSnapshot: itemInput.currentDevelopSnapshot,
                stageInputFingerprint: ""
            )
            let stageFingerprint = try Self.stageFingerprint(
                for: draft,
                renderAndWrite: renderAndWrite
            )
            frozenItems.append(DeliveryPlanStageItem(
                itemIndex: draft.itemIndex,
                sourceRevision: draft.sourceRevision,
                resolvedMetadata: draft.resolvedMetadata,
                outputFilename: draft.outputFilename,
                stagedRelativePath: draft.stagedRelativePath,
                isHDR: draft.isHDR,
                developSnapshot: draft.developSnapshot,
                stageInputFingerprint: stageFingerprint
            ))
        }

        let preflight = DeliveryPreflightResultSnapshot(publication: request.publication)
        let acceptedWarningIDs = request.acceptedWarningIDs.sorted()
        let draft = DeliveryPlan(
            fingerprint: "",
            profile: request.currentProfile,
            preflight: preflight,
            renderAndWrite: renderAndWrite,
            destination: destination,
            acceptedWarningIDs: acceptedWarningIDs,
            items: frozenItems
        )
        let plan = DeliveryPlan(
            fingerprint: try Self.planFingerprint(for: draft),
            profile: draft.profile,
            preflight: draft.preflight,
            renderAndWrite: draft.renderAndWrite,
            destination: draft.destination,
            acceptedWarningIDs: draft.acceptedWarningIDs,
            items: draft.items
        )
        try Self.validateFrozenPlan(plan)
        return plan
    }

    static func validateFrozenPlan(_ plan: DeliveryPlan) throws {
        guard plan.schemaVersion == DeliveryPlan.currentSchemaVersion,
              !plan.items.isEmpty,
              plan.preflight.blockerCount == 0 else {
            throw DeliveryPlanningError.persistedPlanInvalid
        }
        try DeadlineProfileIO().validate(plan.profile)
        guard plan.acceptedWarningIDs == plan.acceptedWarningIDs.sorted(),
              Set(plan.acceptedWarningIDs).count == plan.acceptedWarningIDs.count,
              Set(plan.acceptedWarningIDs) == Set(plan.preflight.warningIDs) else {
            throw DeliveryPlanningError.persistedPlanInvalid
        }
        guard let profileDestination = plan.profile.destination,
              profileDestination.connectionIdentifier == plan.destination.connectionIdentifier,
              isCanonicalConnectionIdentifier(plan.destination.connectionIdentifier),
              isSafeResolvedRemotePath(plan.destination.resolvedRemotePath) else {
            throw DeliveryPlanningError.destinationMismatch
        }
        let expectedExport: DeadlineExportSnapshot?
        if case let .snapshot(snapshot)? = plan.profile.export {
            expectedExport = snapshot
        } else {
            expectedExport = nil
        }
        if let expectedExport, expectedExport != plan.renderAndWrite.export {
            throw DeliveryPlanningError.exportSnapshotMismatch
        }
        guard plan.renderAndWrite.metadataWriteStrategy == plan.profile.metadataWriteStrategy,
              plan.renderAndWrite.gpsPolicy == plan.profile.gpsPolicy,
              (plan.renderAndWrite.export.maximumOutputByteCount.map { $0 > 0 } ?? true),
              plan.renderAndWrite.verificationFields
                == IPTCMetadataVerificationField.writableFields else {
            throw DeliveryPlanningError.writeSnapshotMismatch
        }

        var sources = Set<URL>()
        var outputs = Set<String>()
        for (expectedIndex, item) in plan.items.enumerated() {
            guard item.itemIndex == expectedIndex,
                  Self.isValidSourceRevision(item.sourceRevision),
                  item.outputFilename == item.stagedRelativePath,
                  isValidOutputFilename(item.outputFilename),
                  item.resolvedMetadata.cameraRaw == nil,
                  item.resolvedMetadata.exifOrientation == nil,
                  item.developSnapshot?.validate() != false else {
                throw DeliveryPlanningError.persistedPlanInvalid
            }
            if plan.renderAndWrite.gpsPolicy == .remove,
               item.resolvedMetadata.latitude != nil || item.resolvedMetadata.longitude != nil {
                throw DeliveryPlanningError.persistedPlanInvalid
            }
            guard sources.insert(item.sourceRevision.canonicalURL.standardizedFileURL).inserted,
                  outputs.insert(item.outputFilename.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  item.stageInputFingerprint == (try stageFingerprint(
                    for: item,
                    renderAndWrite: plan.renderAndWrite
                  )) else {
                throw DeliveryPlanningError.persistedPlanInvalid
            }
        }
        guard plan.preflight.imageResults.count == plan.items.count,
              plan.preflight.imageResults.enumerated().allSatisfy({ $0.offset == $0.element.imageIndex }),
              plan.fingerprint == (try planFingerprint(for: plan)) else {
            throw DeliveryPlanningError.invalidFingerprint
        }
    }

    private func validatePreflightShape(_ request: DeliveryPlanningRequest) throws {
        let expectedCount = request.preflightRequest.items.count
        guard request.items.count == expectedCount else {
            throw DeliveryPlanningError.itemCountMismatch(
                expected: expectedCount,
                found: request.items.count
            )
        }
        let reports = request.publication.report.imageReports
        guard reports.count == expectedCount,
              reports.enumerated().allSatisfy({ index, report in
                report.imageIndex == index
                    && Self.canonicalURL(report.imageURL)
                        == Self.canonicalURL(request.preflightRequest.items[index].sourceURL)
              }) else {
            throw DeliveryPlanningError.preflightResultMismatch
        }
        if request.currentProfile.rename != nil {
            guard let renamePlan = request.publication.report.renamePlan else {
                throw DeliveryPlanningError.missingRenamePlan
            }
            guard renamePlan.entries.count == expectedCount,
                  renamePlan.entries.enumerated().allSatisfy({ index, entry in
                    entry.itemIndex == index
                        && Self.canonicalURL(entry.sourceImageURL)
                            == Self.canonicalURL(request.preflightRequest.items[index].sourceURL)
                  }) else {
                throw DeliveryPlanningError.preflightResultMismatch
            }
        } else if request.publication.report.renamePlan != nil {
            throw DeliveryPlanningError.preflightResultMismatch
        }
    }

    private func validateWarningAcceptance(
        report: DeadlinePreflightReport,
        acceptedWarningIDs: Set<String>
    ) throws {
        let warningIDs = Set(report.issues.filter { $0.severity == .warning }.map(\.id))
        let missing = warningIDs.subtracting(acceptedWarningIDs).sorted()
        if !missing.isEmpty { throw DeliveryPlanningError.unacceptedWarnings(missing) }
        let unexpected = acceptedWarningIDs.subtracting(warningIDs).sorted()
        if !unexpected.isEmpty {
            throw DeliveryPlanningError.unexpectedAcceptedWarnings(unexpected)
        }
    }

    private func validate(
        _ input: DeliveryPlanningItemInput,
        against preflightItem: DeadlinePreflightItemSnapshot,
        itemIndex: Int
    ) throws {
        guard Self.isValidSourceRevision(input.preflightSourceRevision),
              Self.isValidSourceRevision(input.currentSourceRevision) else {
            throw DeliveryPlanningError.invalidSourceRevision(itemIndex: itemIndex)
        }
        let preflightURL = Self.canonicalURL(preflightItem.sourceURL)
        guard Self.canonicalURL(input.preflightSourceRevision.canonicalURL) == preflightURL,
              Self.canonicalURL(input.currentSourceRevision.canonicalURL) == preflightURL else {
            throw DeliveryPlanningError.sourceURLMismatch(itemIndex: itemIndex)
        }
        guard input.preflightSourceRevision.relationship(to: input.currentSourceRevision)
                == .exactRevision else {
            throw DeliveryPlanningError.sourceChangedAfterPreflight(itemIndex: itemIndex)
        }
        if let byteCount = preflightItem.source.byteCount,
           byteCount != input.currentSourceRevision.byteCount {
            throw DeliveryPlanningError.sourceChangedAfterPreflight(itemIndex: itemIndex)
        }
        guard input.resolvedMetadata == preflightItem.metadata else {
            throw DeliveryPlanningError.metadataChangedAfterPreflight(itemIndex: itemIndex)
        }
        guard input.preflightDevelopSnapshot == input.currentDevelopSnapshot else {
            throw DeliveryPlanningError.developSettingsChangedAfterPreflight(itemIndex: itemIndex)
        }
        guard input.currentDevelopSnapshot?.validate() != false else {
            throw DeliveryPlanningError.invalidDevelopSnapshot(itemIndex: itemIndex)
        }
        var expectedDevelopSettings = preflightItem.metadata.cameraRaw
        expectedDevelopSettings?.sourceHasHDRHeadroom = nil
        guard input.currentDevelopSnapshot?.settings == expectedDevelopSettings else {
            throw DeliveryPlanningError.invalidDevelopSnapshot(itemIndex: itemIndex)
        }
    }

    private func resolvedExport(
        in request: DeadlinePreflightRequest
    ) throws -> DeadlineExportSnapshot {
        switch request.profile.export {
        case let .snapshot(snapshot): return snapshot
        case let .reference(reference):
            guard let snapshot = request.resources.exportConfigurations[reference.identifier] else {
                throw DeliveryPlanningError.missingExportConfiguration
            }
            return snapshot
        case nil: throw DeliveryPlanningError.missingExportConfiguration
        }
    }

    private func resolvedDestination(
        in request: DeadlinePreflightRequest
    ) throws -> DeliveryDestinationSnapshot {
        guard let destination = request.profile.destination else {
            throw DeliveryPlanningError.missingDestination
        }
        guard Self.isCanonicalConnectionIdentifier(destination.connectionIdentifier) else {
            throw DeliveryPlanningError.destinationMismatch
        }
        guard case let .valid(resolvedPath)? = request.delivery.remotePathState else {
            throw DeliveryPlanningError.unresolvedDestinationPath
        }
        guard Self.isSafeResolvedRemotePath(resolvedPath) else {
            throw DeliveryPlanningError.unsafeDestinationPath
        }
        return DeliveryDestinationSnapshot(
            connectionIdentifier: destination.connectionIdentifier,
            resolvedRemotePath: resolvedPath
        )
    }

    private func outputFilename(
        itemIndex: Int,
        sourceURL: URL,
        isHDR: Bool,
        export: DeadlineExportSnapshot,
        renameConfiguration: DeadlineRenameConfiguration?,
        renamePlan: RenamePlan?
    ) throws -> String {
        let namedURL: URL
        if renameConfiguration != nil {
            guard let renamePlan, renamePlan.entries.indices.contains(itemIndex) else {
                throw DeliveryPlanningError.missingRenamePlan
            }
            let entry = renamePlan.entries[itemIndex]
            guard entry.disposition == .rename || entry.disposition == .unchanged,
                  let plannedURL = entry.plannedDestinationImageURL else {
                throw DeliveryPlanningError.incompleteRenamePlan(itemIndex: itemIndex)
            }
            namedURL = plannedURL
        } else {
            namedURL = sourceURL
        }

        let stem = namedURL.deletingPathExtension().lastPathComponent
        let fileExtension = isHDR ? Self.hdrExtension(export.hdrFormat) : Self.sdrExtension(export.sdrFormat)
        let filename = "\(stem).\(fileExtension)"
        guard Self.isValidOutputFilename(filename) else {
            throw DeliveryPlanningError.invalidOutputFilename(itemIndex: itemIndex)
        }
        return filename
    }

    private static func sdrExtension(_ format: DeadlineExportSnapshot.SDRFormat) -> String {
        switch format {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tiff"
        case .heic: "heic"
        case .avif, .avifFFmpeg: "avif"
        case .jxl: "jxl"
        }
    }

    private static func hdrExtension(_ format: DeadlineExportSnapshot.HDRFormat) -> String {
        switch format {
        case .jpegGainMap: "jpg"
        case .heic10bit: "heic"
        case .avif10bit, .avifFFmpeg10bit: "avif"
        case .jxl: "jxl"
        case .tiff16bit: "tiff"
        case .png16bit: "png"
        }
    }

    private static func isValidSourceRevision(_ revision: SourceImageRevision) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return revision.canonicalURL.isFileURL
            && revision.byteCount >= 0
            && revision.sha256.count == 64
            && revision.sha256.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    private static func isValidOutputFilename(_ filename: String) -> Bool {
        let normalized = filename.precomposedStringWithCanonicalMapping
        return !normalized.isEmpty
            && normalized != "."
            && normalized != ".."
            && normalized.utf8.count <= 255
            && !normalized.contains("/")
            && !normalized.contains(":")
            && !normalized.contains("\0")
            && normalized == normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCanonicalConnectionIdentifier(_ identifier: String) -> Bool {
        guard let id = UUID(uuidString: identifier) else { return false }
        return id.uuidString.lowercased() == identifier
    }

    private static func isSafeResolvedRemotePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == path,
              trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("//"),
              !trimmed.contains("\0"),
              !trimmed.contains("\r"),
              !trimmed.contains("\n"),
              !trimmed.contains("\\"),
              !trimmed.contains("://"),
              !trimmed.contains("?"),
              !trimmed.contains("#") else { return false }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            $0 != "." && $0 != ".."
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func stageFingerprint(
        for item: DeliveryPlanStageItem,
        renderAndWrite: DeliveryRenderWriteSnapshot
    ) throws -> String {
        try fingerprint(StageFingerprintPayload(
            itemIndex: item.itemIndex,
            sourceRevision: item.sourceRevision,
            resolvedMetadata: item.resolvedMetadata,
            outputFilename: item.outputFilename,
            stagedRelativePath: item.stagedRelativePath,
            isHDR: item.isHDR,
            developSnapshot: item.developSnapshot,
            renderAndWrite: renderAndWrite
        ))
    }

    private static func planFingerprint(for plan: DeliveryPlan) throws -> String {
        try fingerprint(PlanFingerprintPayload(
            schemaVersion: plan.schemaVersion,
            profile: plan.profile,
            preflight: plan.preflight,
            renderAndWrite: plan.renderAndWrite,
            destination: plan.destination,
            acceptedWarningIDs: plan.acceptedWarningIDs,
            items: plan.items
        ))
    }

    private static func fingerprint<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(value))).lowercaseHexString
    }
}

private nonisolated struct StageFingerprintPayload: Encodable {
    let itemIndex: Int
    let sourceRevision: SourceImageRevision
    let resolvedMetadata: IPTCMetadata
    let outputFilename: String
    let stagedRelativePath: String
    let isHDR: Bool
    let developSnapshot: DevelopVersionSnapshot?
    let renderAndWrite: DeliveryRenderWriteSnapshot
}

private nonisolated struct PlanFingerprintPayload: Encodable {
    let schemaVersion: Int
    let profile: DeadlineProfile
    let preflight: DeliveryPreflightResultSnapshot
    let renderAndWrite: DeliveryRenderWriteSnapshot
    let destination: DeliveryDestinationSnapshot
    let acceptedWarningIDs: [String]
    let items: [DeliveryPlanStageItem]
}
