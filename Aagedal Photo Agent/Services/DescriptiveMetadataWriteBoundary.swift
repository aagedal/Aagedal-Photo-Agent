import Foundation

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

nonisolated struct DescriptiveMetadataPasteSummary: Sendable {
    var written: [URL] = []
    var historyOnlySkipped: [URL] = []
    var failures: [(url: URL, message: String)] = []

    /// A user-facing message for anything that did not get written, or nil when all succeeded.
    var problemMessage: String? {
        var parts: [String] = []
        if let first = failures.first {
            parts.append(failures.count == 1
                ? "Failed to paste IPTC to \(first.url.lastPathComponent): \(first.message)"
                : "Failed to paste IPTC to \(failures.count) photos (first: \(first.url.lastPathComponent): \(first.message))")
        }
        if !historyOnlySkipped.isEmpty {
            parts.append("\(historyOnlySkipped.count) photo(s) use Save History Only and were not changed.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
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

    /// Merges one copied descriptive record into many photos (Paste IPTC), resolving the
    /// destination per photo. RAW always lands in its XMP sidecar; an embedded write also
    /// refreshes an existing sidecar so its stale copy cannot shadow the file on read/export.
    /// History-only photos are left untouched and reported, never silently embedded.
    func pasteMerging(
        _ metadata: IPTCMetadata,
        into targets: [(url: URL, mode: MetadataWriteMode)]
    ) async -> DescriptiveMetadataPasteSummary {
        var summary = DescriptiveMetadataPasteSummary()
        for target in targets {
            guard !Task.isCancelled else { break }
            var mode = target.mode
            if mode == .writeToFile, xmpSidecarService.sidecarExists(for: target.url) {
                mode = .writeToFileAndXMPSidecar
            }
            if targetResolver.resolve(sourceURL: target.url, requestedMode: mode) == .historyOnly {
                summary.historyOnlySkipped.append(target.url)
                continue
            }
            do {
                _ = try await write(metadata: metadata, for: target.url, requestedMode: mode, semantics: .merge)
                summary.written.append(target.url)
            } catch {
                summary.failures.append((target.url, error.localizedDescription))
            }
        }
        return summary
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
