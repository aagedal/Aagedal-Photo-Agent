import Foundation
import SwiftMediaMetadata

nonisolated enum DevelopVersionPromotionStep: String, Equatable, Sendable {
    case recoveryCatalogWrite
    case xmpWrite
    case xmpReadBack
    case finalCatalogWrite
}

nonisolated enum DevelopVersionPromotionError: Error, Equatable, LocalizedError, Sendable {
    case stepFailed(DevelopVersionPromotionStep, String)
    case readBackMismatch

    var step: DevelopVersionPromotionStep {
        switch self {
        case let .stepFailed(step, _): step
        case .readBackMismatch: .xmpReadBack
        }
    }

    /// Once the first catalog write succeeds, the previous Primary is recoverable even when a
    /// later XMP or catalog boundary fails.
    var recoveryCatalogWasSaved: Bool { step != .recoveryCatalogWrite }

    var errorDescription: String? {
        switch self {
        case let .stepFailed(.recoveryCatalogWrite, detail):
            "Couldn't make this version the main edit. Your main edit and other versions are unchanged. \(detail) Try again."
        case let .stepFailed(.xmpWrite, detail):
            "Couldn't make this version the main edit. Your previous main edit was kept as the version \"Primary before promotion\", and your other versions are unchanged. \(detail) Try again."
        case let .stepFailed(.xmpReadBack, detail):
            "This version was saved as the main edit, but couldn't be checked afterwards. Your previous main edit was kept as the version \"Primary before promotion\". Reopen the photo to check the result. \(detail)"
        case let .stepFailed(.finalCatalogWrite, detail):
            "This version is now the main edit, but the version list couldn't be updated. Your previous main edit and other versions are still available. \(detail)"
        case .readBackMismatch:
            "Couldn't confirm that this version became the main edit: the saved result didn't match. Your previous main edit was kept as the version \"Primary before promotion\"."
        }
    }
}

/// A promotion refused before any write (no recovery version, no Primary change).
nonisolated struct DevelopVersionPromotionRefusal: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct DevelopVersionPromotionResult: Equatable, Sendable {
    let catalog: DevelopVersionCatalog
    let storage: DevelopVersionCatalogStorage
    let promotedSettings: CameraRawSettings?
    let recoveryVersionID: UUID
}

/// Coordinates the deliberate JSON-to-XMP promotion boundary. The injected operations make the
/// four durable steps independently testable and keep file I/O out of the Develop view.
nonisolated struct DevelopVersionPromotionService: Sendable {
    typealias CatalogSave = @Sendable (DevelopVersionCatalog) async throws -> DevelopVersionCatalogStorage
    typealias PrimaryWrite = @Sendable (CameraRawSettings?) async throws -> Void
    typealias PrimaryRead = @Sendable () async throws -> CameraRawSettings?

    private let saveCatalog: CatalogSave
    private let writePrimary: PrimaryWrite
    private let readPrimary: PrimaryRead
    private let orientation: Int?
    /// Set when this source has no safe Primary destination for a promotion; checked before
    /// anything (including the recovery catalog) is written.
    private let refusal: String?

    init(
        saveCatalog: @escaping CatalogSave,
        writePrimary: @escaping PrimaryWrite,
        readPrimary: @escaping PrimaryRead,
        orientation: Int? = nil,
        refusal: String? = nil
    ) {
        self.saveCatalog = saveCatalog
        self.writePrimary = writePrimary
        self.readPrimary = readPrimary
        self.orientation = orientation
        self.refusal = refusal
    }

    /// The JPEG of a RAW+JPEG pair keeps its Primary Develop in its own embedded XMP, and the
    /// shared stem sidecar's crs belongs to the RAW. Promotion writes Primary through the sidecar,
    /// so it is refused for such a JPEG rather than writing a recovery version it can't complete.
    nonisolated static func pairedJPEGRefusal(for imageURL: URL) -> String? {
        guard !SupportedImageFormats.isRaw(url: imageURL),
              let raw = PhotoSidecarOwnership.developOwningRawSibling(of: imageURL, requiringFreshListing: true) else { return nil }
        return "\(imageURL.lastPathComponent) shares its XMP sidecar with \(raw.lastPathComponent) and keeps its Primary Develop settings in the file itself, "
            + "so named versions can't be promoted to Primary on it. Nothing was changed. Switch to the version and keep editing, or promote on the RAW file."
    }

    init(
        repository: DevelopVersionCatalogRepository,
        imageURL: URL,
        orientation: Int?
    ) {
        let sidecars = XMPSidecarService()
        self.init(
            saveCatalog: { try await repository.save($0) },
            writePrimary: { settings in
                try await sidecars.saveCameraRawOnlySerialized(
                    settings,
                    orientation: orientation,
                    for: imageURL
                )
            },
            readPrimary: { sidecars.loadDevelopSettings(for: imageURL) },
            orientation: orientation,
            refusal: Self.pairedJPEGRefusal(for: imageURL)
        )
    }

    func promote(
        _ preparation: DevelopVersionPromotionPreparation
    ) async throws -> DevelopVersionPromotionResult {
        if let refusal { throw DevelopVersionPromotionRefusal(message: refusal) }
        do {
            _ = try await saveCatalog(preparation.catalog)
        } catch {
            throw DevelopVersionPromotionError.stepFailed(
                .recoveryCatalogWrite,
                UserFacingErrorCause.sentence(for: error)
            )
        }

        let settingsToWrite = preparation.promotedSettings.isEmpty
            ? nil
            : preparation.promotedSettings
        do {
            try await writePrimary(settingsToWrite)
        } catch {
            throw DevelopVersionPromotionError.stepFailed(.xmpWrite, UserFacingErrorCause.sentence(for: error))
        }

        let readBack: CameraRawSettings?
        do {
            readBack = try await readPrimary()
        } catch {
            throw DevelopVersionPromotionError.stepFailed(
                .xmpReadBack,
                UserFacingErrorCause.sentence(for: error)
            )
        }
        guard Self.readBackMatches(
            expected: settingsToWrite,
            actual: readBack,
            orientation: orientation
        ) else {
            throw DevelopVersionPromotionError.readBackMismatch
        }

        var finalCatalog = preparation.catalog
        do {
            try finalCatalog.setActiveVersion(nil)
        } catch {
            // `nil` is always valid, but retain an explicit failure boundary if catalog invariants
            // evolve in a later schema.
            throw DevelopVersionPromotionError.stepFailed(
                .finalCatalogWrite,
                UserFacingErrorCause.sentence(for: error)
            )
        }

        let finalStorage: DevelopVersionCatalogStorage
        do {
            finalStorage = try await saveCatalog(finalCatalog)
        } catch {
            throw DevelopVersionPromotionError.stepFailed(
                .finalCatalogWrite,
                UserFacingErrorCause.sentence(for: error)
            )
        }

        return DevelopVersionPromotionResult(
            catalog: finalCatalog,
            storage: finalStorage,
            promotedSettings: settingsToWrite,
            recoveryVersionID: preparation.recoveryVersionID
        )
    }

    /// Compare the canonical managed XMP payload instead of raw model equality. XMP intentionally
    /// supplies defaults and fixed numeric precision, so a successful read-back may not retain the
    /// exact optional/numeric spelling of the in-memory value even though every persisted field is
    /// equivalent. Re-serializing both sides still detects missing or altered managed fields.
    static func readBackMatches(
        expected: CameraRawSettings?,
        actual: CameraRawSettings?,
        orientation: Int? = nil
    ) -> Bool {
        func canonicalManagedXMP(_ value: CameraRawSettings?) -> XMPData? {
            guard var value, !value.isEmpty else { return nil }
            value.sourceHasHDRHeadroom = nil
            value.asShotNeutralTemperature = nil
            value.asShotNeutralTint = nil

            // Mask/watermark UUIDs are app-side identities and the ACR correction codec may
            // regenerate them on decode. Remap both payloads and layer references to stable local
            // IDs so verification compares ordering/content rather than incidental identities.
            var identityMap: [UUID: UUID] = [:]
            if var masks = value.localAdjustments {
                for index in masks.indices {
                    let oldID = masks[index].id
                    let stableID = UUID(uuidString: String(
                        format: "00000000-0000-0000-0000-%012x",
                        index + 1
                    ))!
                    masks[index].id = stableID
                    identityMap[oldID] = stableID
                }
                value.localAdjustments = masks
            }
            if var watermarks = value.watermarkLayers {
                for index in watermarks.indices {
                    let oldID = watermarks[index].id
                    let stableID = UUID(uuidString: String(
                        format: "00000000-0000-0000-0001-%012x",
                        index + 1
                    ))!
                    watermarks[index].id = stableID
                    identityMap[oldID] = stableID
                }
                value.watermarkLayers = watermarks
            }
            value.layerOrder = value.layerOrder?.compactMap { reference in
                switch reference {
                case .global:
                    .global
                case let .mask(id):
                    identityMap[id].map(LayerRef.mask)
                case let .watermark(id):
                    identityMap[id].map(LayerRef.watermark)
                }
            }
            var xmp = XMPData()
            XMPDataBuilder.applyCameraRaw(value, imageAspect: nil, into: &xmp)
            if let corrections = xmp.value(
                namespace: XMPNamespace.crs,
                property: "MaskGroupBasedCorrections"
            ) {
                func removingIncidentalSyncIDs(_ value: XMPValue) -> XMPValue {
                    switch value {
                    case .simple, .array, .langAlternative, .languageAlternative:
                        value
                    case let .structure(fields):
                        .structure(fields.reduce(into: [:]) { result, entry in
                            guard !entry.key.hasSuffix("SyncID") else { return }
                            result[entry.key] = removingIncidentalSyncIDs(entry.value)
                        })
                    case let .structuredArray(items):
                        .structuredArray(items.map { fields in
                            fields.reduce(into: [:]) { result, entry in
                                guard !entry.key.hasSuffix("SyncID") else { return }
                                result[entry.key] = removingIncidentalSyncIDs(entry.value)
                            }
                        })
                    }
                }
                xmp.setValue(
                    removingIncidentalSyncIDs(corrections),
                    namespace: XMPNamespace.crs,
                    property: "MaskGroupBasedCorrections"
                )
            }
            return xmp
        }

        func normalizedThroughCanonicalCodec(_ value: CameraRawSettings?) -> XMPData? {
            guard let xmp = canonicalManagedXMP(value) else { return nil }
            var packet = xmp
            if let orientation {
                let encoded = String(orientation)
                packet.setValue(.simple(encoded), namespace: XMPNamespace.tiff, property: "Orientation")
                packet.setValue(.simple(encoded), namespace: XMPNamespace.exif, property: "Orientation")
            }
            let data = Data(XMPWriter.generateXML(packet).utf8)
            let decoded = XMPSidecarService().loadSidecar(fromData: data)?.cameraRaw
            return canonicalManagedXMP(decoded)
        }

        let expectedXMP = normalizedThroughCanonicalCodec(expected)
        let actualXMP = normalizedThroughCanonicalCodec(actual)
        return expectedXMP == actualXMP
    }
}
