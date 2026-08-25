import Foundation

/// The physical destination selected for a descriptive-metadata write.
nonisolated enum DescriptiveMetadataWriteTarget: Sendable, Equatable {
    case historyOnly
    case embedded
    case xmpSidecar
    case embeddedAndXMPSidecar

    nonisolated var writesEmbedded: Bool {
        switch self {
        case .embedded, .embeddedAndXMPSidecar: return true
        case .historyOnly, .xmpSidecar: return false
        }
    }

    nonisolated var writesXMPSidecar: Bool {
        switch self {
        case .xmpSidecar, .embeddedAndXMPSidecar: return true
        case .historyOnly, .embedded: return false
        }
    }
}

/// Central target policy for descriptive metadata. Proprietary RAW containers are a hard safety
/// boundary: a request to embed (including a dual write) is reduced to one adjacent XMP write.
nonisolated struct DescriptiveMetadataWriteTargetResolver: Sendable {
    nonisolated init() {}

    nonisolated func resolve(
        sourceURL: URL,
        requestedMode: MetadataWriteMode
    ) -> DescriptiveMetadataWriteTarget {
        if SupportedImageFormats.isRaw(url: sourceURL) {
            switch requestedMode {
            case .historyOnly:
                return .historyOnly
            case .writeToFile, .writeToXMPSidecar, .writeToFileAndXMPSidecar:
                return .xmpSidecar
            }
        }

        switch requestedMode {
        case .historyOnly: return .historyOnly
        case .writeToFile: return .embedded
        case .writeToXMPSidecar: return .xmpSidecar
        case .writeToFileAndXMPSidecar: return .embeddedAndXMPSidecar
        }
    }
}

nonisolated enum DescriptiveMetadataWriteSemantics: Sendable, Equatable {
    /// Overlay only populated values. Empty values don't clear an existing record.
    case merge
    /// Treat the supplied descriptive record as authoritative. nil/empty values explicitly clear.
    case replace
}

/// Exact XMP bytes observed before editing. Passing a snapshot back as a precondition prevents a
/// delayed task from overwriting a newer Adobe/app save made after the edit began.
nonisolated struct XMPSidecarWriteSnapshot: Sendable, Equatable {
    let data: Data?

    nonisolated init(data: Data?) {
        self.data = data
    }
}

nonisolated enum DescriptiveMetadataWriteError: LocalizedError, Sendable, Equatable {
    case staleXMPSidecar(URL)

    nonisolated var errorDescription: String? {
        switch self {
        case .staleXMPSidecar(let url):
            return "The XMP sidecar changed before metadata could be saved: \(url.lastPathComponent)"
        }
    }
}

nonisolated struct DescriptiveMetadataWriteResult: Sendable, Equatable {
    let sourceURL: URL
    let target: DescriptiveMetadataWriteTarget
    let xmpSidecarURL: URL?
}

/// Non-UI execution boundary for descriptive writes. It combines target resolution with the two
/// established backends so no caller can accidentally ask SwiftExif to rewrite a proprietary RAW.
nonisolated struct DescriptiveMetadataWriteBoundary: Sendable {
    private let writeEngine: any MetadataWriteEngine
    private let xmpSidecarService: XMPSidecarService
    private let targetResolver: DescriptiveMetadataWriteTargetResolver

    nonisolated init(
        writeEngine: any MetadataWriteEngine,
        xmpSidecarService: XMPSidecarService = XMPSidecarService(),
        targetResolver: DescriptiveMetadataWriteTargetResolver = DescriptiveMetadataWriteTargetResolver()
    ) {
        self.writeEngine = writeEngine
        self.xmpSidecarService = xmpSidecarService
        self.targetResolver = targetResolver
    }

    nonisolated func xmpSnapshot(for sourceURL: URL) -> XMPSidecarWriteSnapshot {
        XMPSidecarWriteSnapshot(data: xmpSidecarService.sidecarDataIfExists(for: sourceURL))
    }

    /// Writes one complete or partial descriptive record. Camera Raw settings are deliberately not
    /// taken from `metadata`: descriptive writes preserve the existing sidecar's develop block.
    func write(
        metadata: IPTCMetadata,
        for sourceURL: URL,
        requestedMode: MetadataWriteMode,
        semantics: DescriptiveMetadataWriteSemantics,
        expectedXMPSnapshot: XMPSidecarWriteSnapshot? = nil
    ) async throws -> DescriptiveMetadataWriteResult {
        try Task.checkCancellation()
        let target = targetResolver.resolve(sourceURL: sourceURL, requestedMode: requestedMode)
        let isReplacement: Bool
        switch semantics {
        case .merge: isReplacement = false
        case .replace: isReplacement = true
        }
        let writesEmbedded: Bool
        let writesXMPSidecar: Bool
        switch target {
        case .historyOnly:
            writesEmbedded = false
            writesXMPSidecar = false
        case .embedded:
            writesEmbedded = true
            writesXMPSidecar = false
        case .xmpSidecar:
            writesEmbedded = false
            writesXMPSidecar = true
        case .embeddedAndXMPSidecar:
            writesEmbedded = true
            writesXMPSidecar = true
        }

        if writesEmbedded {
            let fields = isReplacement
                ? metadata.toOverwriteFields()
                : metadata.toWriteFields()
            let structured = structuredEditorial(from: metadata, semantics: semantics)
            try await writeEngine.writeFields(fields, to: [sourceURL], structuredData: structured)
        }

        var writtenSidecarURL: URL?
        if writesXMPSidecar {
            try Task.checkCancellation()
            let sidecarURL = xmpSidecarService.sidecarURL(for: sourceURL)
            // The service owns the complete read/merge/revision-check/install transaction. Keeping
            // the merge inside the URL boundary is what prevents a face-name write from racing a
            // caption/keyword write that was prepared from an older sidecar revision.
            var record = metadata
            record.cameraRaw = nil
            try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                metadata: record,
                for: sourceURL,
                mergeWithExisting: !isReplacement,
                expectedSnapshot: expectedXMPSnapshot
            )
            writtenSidecarURL = sidecarURL
        }

        return DescriptiveMetadataWriteResult(
            sourceURL: sourceURL,
            target: target,
            xmpSidecarURL: writtenSidecarURL
        )
    }

    nonisolated private func structuredEditorial(
        from metadata: IPTCMetadata,
        semantics: DescriptiveMetadataWriteSemantics
    ) -> StructuredWriteData {
        let hasStructuredContent = metadata.localizedTitles != nil
            || metadata.creatorContactInfo?.isEmpty == false
            || metadata.locationsCreated.contains(where: { !$0.isEmpty })
            || metadata.locationsShown.contains(where: { !$0.isEmpty })
            || !metadata.imageSuppliers.isEmpty
        let isReplacement: Bool
        switch semantics {
        case .merge: isReplacement = false
        case .replace: isReplacement = true
        }
        guard isReplacement || hasStructuredContent else { return .empty }
        return StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: metadata))
    }
}
