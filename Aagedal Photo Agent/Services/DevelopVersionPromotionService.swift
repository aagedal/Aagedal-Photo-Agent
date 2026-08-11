import Foundation
import SwiftExif

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
            "The previous Primary could not be saved as a recovery version. XMP was not changed. \(detail)"
        case let .stepFailed(.xmpWrite, detail):
            "The recovery version was saved, but Primary XMP could not be written. \(detail)"
        case let .stepFailed(.xmpReadBack, detail):
            "Primary XMP was written, but it could not be read back. The previous Primary remains available as a recovery version. \(detail)"
        case let .stepFailed(.finalCatalogWrite, detail):
            "Primary XMP was verified, but the catalog could not mark Primary active. The recovery and source versions remain available. \(detail)"
        case .readBackMismatch:
            "Primary XMP did not match the promoted version after read-back. The previous Primary remains available as a recovery version."
        }
    }
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

    init(
        saveCatalog: @escaping CatalogSave,
        writePrimary: @escaping PrimaryWrite,
        readPrimary: @escaping PrimaryRead,
        orientation: Int? = nil
    ) {
        self.saveCatalog = saveCatalog
        self.writePrimary = writePrimary
        self.readPrimary = readPrimary
        self.orientation = orientation
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
                try await MainActor.run {
                    try sidecars.saveCameraRawOnly(
                        settings,
                        orientation: orientation,
                        for: imageURL
                    )
                }
            },
            readPrimary: { sidecars.loadSidecar(for: imageURL)?.cameraRaw },
            orientation: orientation
        )
    }

    func promote(
        _ preparation: DevelopVersionPromotionPreparation
    ) async throws -> DevelopVersionPromotionResult {
        do {
            _ = try await saveCatalog(preparation.catalog)
        } catch {
            throw DevelopVersionPromotionError.stepFailed(
                .recoveryCatalogWrite,
                error.localizedDescription
            )
        }

        let settingsToWrite = preparation.promotedSettings.isEmpty
            ? nil
            : preparation.promotedSettings
        do {
            try await writePrimary(settingsToWrite)
        } catch {
            throw DevelopVersionPromotionError.stepFailed(.xmpWrite, error.localizedDescription)
        }

        let readBack: CameraRawSettings?
        do {
            readBack = try await readPrimary()
        } catch {
            throw DevelopVersionPromotionError.stepFailed(
                .xmpReadBack,
                error.localizedDescription
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
                error.localizedDescription
            )
        }

        let finalStorage: DevelopVersionCatalogStorage
        do {
            finalStorage = try await saveCatalog(finalCatalog)
        } catch {
            throw DevelopVersionPromotionError.stepFailed(
                .finalCatalogWrite,
                error.localizedDescription
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
                    case .simple, .array, .langAlternative:
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
