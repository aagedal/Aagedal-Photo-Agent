import Foundation
import ImageIO
import SwiftMediaMetadata

/// Fail-closed reasons why a frozen plan cannot be executed by the live staging stack.
///
/// The current delivery-plan schema always carries an export snapshot. It has no exact-copy
/// discriminator, so this factory never guesses that a matching source extension permits a copy:
/// doing so would silently ignore frozen quality, gamut, resolution, and develop settings.
nonisolated enum DeliveryStagingProductionError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan
    case originalsNotSupported
    case sidecarsNotSupported
    case unsupportedSDRFormat(DeadlineExportSnapshot.SDRFormat)
    case unsupportedHDRFormat(DeadlineExportSnapshot.HDRFormat)
    case unsupportedHDRGamut(DeadlineExportSnapshot.ColorGamut)
    case unsafeDestination
    case outputAlreadyExists
    case rendererReturnedUnsafeURL
    case rendererReturnedWrongFormat
    case rendererReturnedWrongBitDepth
    case rendererReturnedWrongColorSpace
    case rendererReturnedNonHDR
    case renderedDimensionsUnavailable
    case sourceChangedDuringRender
    case stagingEstimateUnavailable(itemIndex: Int)
    case stagingEstimateOverflow

    var errorDescription: String? {
        switch self {
        case .invalidPlan:
            "The frozen delivery plan is invalid or has been modified."
        case .originalsNotSupported:
            "Delivery refuses to write or render over original files. Use staged copies."
        case .sidecarsNotSupported:
            "Delivery requires staged copies; an XMP-sidecar-only plan cannot produce upload bytes."
        case let .unsupportedSDRFormat(format):
            "The staged delivery metadata contract is not yet supported for SDR \(format.rawValue)."
        case let .unsupportedHDRFormat(format):
            "The staged delivery metadata contract is not yet supported for HDR \(format.rawValue)."
        case let .unsupportedHDRGamut(gamut):
            "The HDR renderer cannot encode the frozen \(gamut.rawValue) gamut without substitution."
        case .unsafeDestination:
            "The staged destination is not a safe local output file."
        case .outputAlreadyExists:
            "The staged output already exists."
        case .rendererReturnedUnsafeURL:
            "The renderer returned an output outside its isolated staging directory."
        case .rendererReturnedWrongFormat:
            "The renderer output does not match the frozen delivery format."
        case .rendererReturnedWrongBitDepth:
            "The renderer output bit depth does not match the frozen delivery format."
        case .rendererReturnedWrongColorSpace:
            "The renderer output color profile does not match the frozen delivery gamut."
        case .rendererReturnedNonHDR:
            "The renderer output does not contain the frozen HDR representation."
        case .renderedDimensionsUnavailable:
            "The completed rendered output has no readable pixel dimensions."
        case .sourceChangedDuringRender:
            "The source changed while the staged rendition was being produced."
        case let .stagingEstimateUnavailable(index):
            "A renderer-aware staging estimate could not be calculated for item \(index)."
        case .stagingEstimateOverflow:
            "The renderer-aware staging estimate is too large to represent safely."
        }
    }
}

/// Frozen-config rendering seam. The live implementation delegates pixels to
/// `EditedImageRenderer`; tests can substitute a deterministic fixture encoder without replacing
/// the production source, metadata, read-back, preservation, filesystem, or capacity adapters.
nonisolated struct DeliveryFrozenArtifactRenderer: Sendable {
    let render: @Sendable (
        _ sourceURL: URL,
        _ cameraRaw: CameraRawSettings?,
        _ isHDR: Bool,
        _ configuration: AdvancedExportConfiguration,
        _ outputDirectory: URL
    ) async throws -> URL

    static let live = Self { sourceURL, cameraRaw, isHDR, configuration, outputDirectory in
        try await EditedImageRenderer.render(
            from: sourceURL,
            cameraRaw: cameraRaw,
            isHDR: isHDR,
            outputFolder: outputDirectory,
            configuration: configuration,
            metadataCopier: nil
        )
    }
}

/// One pure source of truth shared by deadline preflight and live staging admission.
nonisolated enum DeliveryStagingProductionCapabilities {
    static let supportedMetadataWriteStrategies: [DeadlineMetadataWriteStrategy] = [
        .stagedCopies,
    ]
    static let supportedSDRFormats: [DeadlineExportSnapshot.SDRFormat] = [.jpeg, .tiff]
    static let supportedHDRFormats: [DeadlineExportSnapshot.HDRFormat] = [
        .jpegGainMap, .tiff16bit,
    ]
    static let supportedSDRGamuts: [DeadlineExportSnapshot.ColorGamut] = [
        .sRGB, .displayP3, .rec2020, .adobeRGB,
    ]
    static let supportedHDRGamuts: [DeadlineExportSnapshot.ColorGamut] = [
        .sRGB, .displayP3, .rec2020,
    ]

    static let deadlinePreflightSnapshot = DeadlineExportCapabilitySnapshot(
        isKnown: true,
        availableSDRFormats: supportedSDRFormats,
        availableHDRFormats: supportedHDRFormats,
        availableSDRGamuts: supportedSDRGamuts,
        availableHDRGamuts: supportedHDRGamuts
    )

    static func supports(_ export: DeadlineExportSnapshot, isHDR: Bool) -> Bool {
        if isHDR {
            return supportedHDRFormats.contains(export.hdrFormat)
                && supportedHDRGamuts.contains(export.hdrGamut)
        }
        return supportedSDRFormats.contains(export.sdrFormat)
            && supportedSDRGamuts.contains(export.sdrGamut)
    }

    static func supports(_ strategy: DeadlineMetadataWriteStrategy) -> Bool {
        supportedMetadataWriteStrategies.contains(strategy)
    }
}

/// The single construction boundary for live staged-delivery execution.
///
/// Only JPEG/JPEG gain-map and TIFF/TIFF16 are enabled today. SwiftExif can parse additional
/// carriers, but the app has not established an end-to-end descriptive-write plus unrelated IPTC
/// and EXIF preservation guarantee for PNG, HEIC, AVIF, or JPEG XL. Those plans are rejected before
/// a batch directory is created.
nonisolated struct DeliveryStagingProductionFactory: Sendable {
    private let artifactRenderer: DeliveryFrozenArtifactRenderer
    private let writeEngine: any MetadataWriteEngine
    private let fileSystem: DeliveryStagingFileSystem
    private let preservationVerifier: DeliveryStageMetadataPreservationVerifier
    private let sourceInspector: DeliverySourceRevisionInspector

    init(
        artifactRenderer: DeliveryFrozenArtifactRenderer = .live,
        writeEngine: any MetadataWriteEngine = SwiftExifWriteEngine(),
        fileSystem: DeliveryStagingFileSystem = .live,
        preservationVerifier: DeliveryStageMetadataPreservationVerifier = .liveRenderedDelivery,
        sourceInspector: DeliverySourceRevisionInspector = .live
    ) {
        self.artifactRenderer = artifactRenderer
        self.writeEngine = writeEngine
        self.fileSystem = fileSystem
        self.preservationVerifier = preservationVerifier
        self.sourceInspector = sourceInspector
    }

    func makeCoordinator(for plan: DeliveryPlan) throws -> StagedDeliveryCoordinator {
        do {
            try DeliveryPlanningService.validateFrozenPlan(plan)
        } catch {
            throw DeliveryStagingProductionError.invalidPlan
        }
        try Self.validateSupportedContract(plan)

        let engine = writeEngine
        let renderer = artifactRenderer
        let inspector = sourceInspector
        let sourceURLs = Set(plan.items.map {
            $0.sourceRevision.canonicalURL.standardizedFileURL.resolvingSymlinksInPath()
        })

        return StagedDeliveryCoordinator(
            fileSystem: fileSystem,
            renderer: DeliveryStageRenderer { item, snapshot, destinationURL in
                try Task.checkCancellation()
                try Self.validateSupportedContract(item: item, snapshot: snapshot)
                let canonicalDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
                guard destinationURL.isFileURL,
                      !sourceURLs.contains(canonicalDestination),
                      destinationURL.lastPathComponent == item.stagedRelativePath,
                      destinationURL.deletingLastPathComponent() != item.sourceRevision.canonicalURL
                        .standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                else {
                    throw DeliveryStagingProductionError.unsafeDestination
                }
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw DeliveryStagingProductionError.outputAlreadyExists
                }

                let scratchDirectory = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".render-\(item.stageInputFingerprint.prefix(16))", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: scratchDirectory,
                    withIntermediateDirectories: false
                )
                defer { try? FileManager.default.removeItem(at: scratchDirectory) }

                let configuration = try Self.configuration(from: snapshot.export)
                let renderedURL = try await renderer.render(
                    item.sourceRevision.canonicalURL,
                    item.developSnapshot?.settings,
                    item.isHDR,
                    configuration,
                    scratchDirectory
                )
                try Task.checkCancellation()
                let canonicalScratch = scratchDirectory.standardizedFileURL.resolvingSymlinksInPath()
                let canonicalRendered = renderedURL.standardizedFileURL.resolvingSymlinksInPath()
                guard canonicalRendered.deletingLastPathComponent() == canonicalScratch else {
                    throw DeliveryStagingProductionError.rendererReturnedUnsafeURL
                }
                try Self.validateRenderedCarrier(at: renderedURL, item: item, export: snapshot.export)

                try await engine.copyMetadataToRenderedFile(
                    from: item.sourceRevision.canonicalURL,
                    to: renderedURL,
                    bakedCameraRaw: item.developSnapshot?.settings
                )
                try Task.checkCancellation()
                let currentRevision = try await inspector.inspect(item.sourceRevision.canonicalURL)
                guard item.sourceRevision.relationship(to: currentRevision) == .exactRevision else {
                    throw DeliveryStagingProductionError.sourceChangedDuringRender
                }

                try FileManager.default.moveItem(at: renderedURL, to: destinationURL)
                return try Self.renderSettings(
                    at: destinationURL,
                    item: item,
                    export: snapshot.export
                )
            },
            metadataWriter: DeliveryStageMetadataWriter { metadata, snapshot, stagedURL in
                try Task.checkCancellation()
                guard snapshot.metadataWriteStrategy == .stagedCopies,
                      stagedURL.isFileURL,
                      !sourceURLs.contains(
                        stagedURL.standardizedFileURL.resolvingSymlinksInPath()
                      ) else {
                    throw DeliveryStagingProductionError.unsafeDestination
                }
                try await engine.writeFieldsToRenderedFiles(
                    metadata.toOverwriteFields(),
                    to: [stagedURL],
                    structuredData: StructuredWriteData(
                        editorial: EditorialStructuredWriteData(metadata: metadata)
                    )
                )
            },
            metadataVerifier: DeliveryStageMetadataVerifier { bytes, _, expected, fields in
                try Task.checkCancellation()
                let parsed = try ImageMetadata.read(from: bytes)
                let actual = iptcMetadataFromDict(parsed.asMetadataDict())
                return IPTCMetadataVerifier.compare(
                    expected: expected,
                    actual: actual,
                    fields: fields
                )
            },
            preservationVerifier: preservationVerifier,
            sourceInspector: sourceInspector,
            sizeEstimator: DeliveryStagingSizeEstimator { frozenPlan in
                try await Self.estimateRequiredBytes(for: frozenPlan)
            }
        )
    }

    static func validateSupportedContract(_ plan: DeliveryPlan) throws {
        guard DeliveryStagingProductionCapabilities.supports(
            plan.renderAndWrite.metadataWriteStrategy
        ) else {
            switch plan.renderAndWrite.metadataWriteStrategy {
            case .stagedCopies: break
            case .originals: throw DeliveryStagingProductionError.originalsNotSupported
            case .xmpSidecars: throw DeliveryStagingProductionError.sidecarsNotSupported
            }
            return
        }
        for item in plan.items {
            try validateSupportedContract(item: item, snapshot: plan.renderAndWrite)
        }
    }

    static func estimateRequiredBytes(for plan: DeliveryPlan) async throws -> Int64 {
        try validateSupportedContract(plan)
        var total: Int64 = 0
        for item in plan.items {
            try Task.checkCancellation()
            guard let measured = ImagePixelAspect.pixelSize(
                at: item.sourceRevision.canonicalURL
            ), measured.width.isFinite, measured.height.isFinite,
               measured.width > 0, measured.height > 0 else {
                throw DeliveryStagingProductionError.stagingEstimateUnavailable(
                    itemIndex: item.itemIndex
                )
            }
            // The container header is the live renderer input. Take the larger of it and the
            // frozen hints so a stale/incorrect dimension hint can never under-budget staging.
            let width = max(
                Int64(measured.width.rounded(.up)),
                Int64(item.sourceRevision.pixelWidth ?? 0)
            )
            let height = max(
                Int64(measured.height.rounded(.up)),
                Int64(item.sourceRevision.pixelHeight ?? 0)
            )

            let maximum = maximumDimension(plan.renderAndWrite.export.resolutionLimit)
            let scale: Double
            if let maximum, max(width, height) > maximum {
                scale = Double(maximum) / Double(max(width, height))
            } else {
                scale = 1
            }
            let outputWidth = max(1, Int64((Double(width) * scale).rounded(.up)))
            let outputHeight = max(1, Int64((Double(height) * scale).rounded(.up)))
            let bytesPerPixel: Int64 = item.isHDR ? 8 : 4

            let (pixels, pixelOverflow) = outputWidth.multipliedReportingOverflow(by: outputHeight)
            let (rasterBytes, rasterOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
            let sourceAllowance = max(item.sourceRevision.byteCount, 1)
            let (metadataAllowance, sourceOverflow) = sourceAllowance.multipliedReportingOverflow(by: 2)
            let (base, addOverflow) = rasterBytes.addingReportingOverflow(metadataAllowance)
            let (padded, padOverflow) = base.multipliedReportingOverflow(by: 5)
            guard !pixelOverflow, !rasterOverflow, !sourceOverflow, !addOverflow, !padOverflow else {
                throw DeliveryStagingProductionError.stagingEstimateOverflow
            }
            let estimate = max(1, padded / 4) // 25% headroom over raster + metadata allowance.
            let (newTotal, totalOverflow) = total.addingReportingOverflow(estimate)
            guard !totalOverflow else {
                throw DeliveryStagingProductionError.stagingEstimateOverflow
            }
            total = newTotal
        }
        return total
    }

    private static func validateSupportedContract(
        item: DeliveryPlanStageItem,
        snapshot: DeliveryRenderWriteSnapshot
    ) throws {
        guard snapshot.metadataWriteStrategy == .stagedCopies else {
            switch snapshot.metadataWriteStrategy {
            case .originals: throw DeliveryStagingProductionError.originalsNotSupported
            case .xmpSidecars: throw DeliveryStagingProductionError.sidecarsNotSupported
            case .stagedCopies: break
            }
            return
        }
        if item.isHDR {
            guard DeliveryStagingProductionCapabilities.supportedHDRFormats.contains(
                snapshot.export.hdrFormat
            ) else {
                throw DeliveryStagingProductionError.unsupportedHDRFormat(
                    snapshot.export.hdrFormat
                )
            }
            if !DeliveryStagingProductionCapabilities.supportedHDRGamuts.contains(
                snapshot.export.hdrGamut
            ) {
                // EditedImageRenderer intentionally substitutes Display P3 because CoreGraphics
                // has no extended-linear/HLG Adobe RGB destination.
                throw DeliveryStagingProductionError.unsupportedHDRGamut(
                    snapshot.export.hdrGamut
                )
            }
        } else {
            guard DeliveryStagingProductionCapabilities.supportedSDRFormats.contains(
                snapshot.export.sdrFormat
            ) else {
                throw DeliveryStagingProductionError.unsupportedSDRFormat(
                    snapshot.export.sdrFormat
                )
            }
        }
    }

    private static func configuration(
        from snapshot: DeadlineExportSnapshot
    ) throws -> AdvancedExportConfiguration {
        guard let sdrFormat = ExportFormatSDR(rawValue: snapshot.sdrFormat.rawValue),
              let sdrGamut = TargetColorGamut(rawValue: snapshot.sdrGamut.rawValue),
              let hdrFormat = ExportFormatHDR(rawValue: snapshot.hdrFormat.rawValue),
              let hdrGamut = TargetColorGamut(rawValue: snapshot.hdrGamut.rawValue),
              let compression = TIFFCompression(rawValue: snapshot.tiffCompression.rawValue),
              let resolution = ExportResolutionLimit(rawValue: snapshot.resolutionLimit.rawValue)
        else {
            throw DeliveryStagingProductionError.invalidPlan
        }
        return AdvancedExportConfiguration(
            sdrFormat: sdrFormat,
            sdrQuality: snapshot.sdrQuality,
            sdrGamut: sdrGamut,
            hdrFormat: hdrFormat,
            hdrQuality: snapshot.hdrQuality,
            hdrGamut: hdrGamut,
            tiffCompression: compression,
            resolutionLimit: resolution,
            locationMode: .askOnSave,
            customSubfolderName: ""
        )
    }

    private static func validateRenderedCarrier(
        at url: URL,
        item: DeliveryPlanStageItem,
        export: DeadlineExportSnapshot
    ) throws {
        let metadata = try ImageMetadata.read(from: url)
        if item.isHDR {
            switch export.hdrFormat {
            case .jpegGainMap:
                guard metadata.format == .jpeg else {
                    throw DeliveryStagingProductionError.rendererReturnedWrongFormat
                }
            case .tiff16bit:
                guard metadata.format == .tiff else {
                    throw DeliveryStagingProductionError.rendererReturnedWrongFormat
                }
            default:
                throw DeliveryStagingProductionError.unsupportedHDRFormat(export.hdrFormat)
            }
        } else {
            switch export.sdrFormat {
            case .jpeg:
                guard metadata.format == .jpeg else {
                    throw DeliveryStagingProductionError.rendererReturnedWrongFormat
                }
            case .tiff:
                guard metadata.format == .tiff else {
                    throw DeliveryStagingProductionError.rendererReturnedWrongFormat
                }
            default:
                throw DeliveryStagingProductionError.unsupportedSDRFormat(export.sdrFormat)
            }
        }
    }

    private static func renderSettings(
        at url: URL,
        item: DeliveryPlanStageItem,
        export: DeadlineExportSnapshot
    ) throws -> DeliveryRenderSettings {
        try validateRenderedCarrier(at: url, item: item, export: export)
        guard let dimensions = ImagePixelAspect.pixelSize(at: url),
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else {
            throw DeliveryStagingProductionError.renderedDimensionsUnavailable
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                imageSource, 0, nil
              ) as? [String: Any] else {
            throw DeliveryStagingProductionError.renderedDimensionsUnavailable
        }
        let actualBitDepth = (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue
        let actualProfileName = properties[kCGImagePropertyProfileName as String] as? String
        let expectedGamut = item.isHDR ? export.hdrGamut : export.sdrGamut
        guard profileName(actualProfileName, matches: expectedGamut) else {
            throw DeliveryStagingProductionError.rendererReturnedWrongColorSpace
        }
        let quality: Int?
        let formatIdentifier: String
        let colorSpaceIdentifier: String
        let bitDepth: Int?
        if item.isHDR {
            formatIdentifier = export.hdrFormat.rawValue
            colorSpaceIdentifier = expectedGamut.rawValue
            switch export.hdrFormat {
            case .jpegGainMap:
                guard SupportedImageFormats.isHDR(url: url) else {
                    throw DeliveryStagingProductionError.rendererReturnedNonHDR
                }
                bitDepth = nil
            case .heic10bit, .avif10bit, .avifFFmpeg10bit:
                guard actualBitDepth == 10 else {
                    throw DeliveryStagingProductionError.rendererReturnedWrongBitDepth
                }
                bitDepth = actualBitDepth
            case .jxl, .tiff16bit, .png16bit:
                guard actualBitDepth == 16 else {
                    throw DeliveryStagingProductionError.rendererReturnedWrongBitDepth
                }
                bitDepth = actualBitDepth
            }
            switch export.hdrFormat {
            case .tiff16bit, .png16bit: quality = nil
            default: quality = Int((export.hdrQuality * 100).rounded())
            }
        } else {
            formatIdentifier = export.sdrFormat.rawValue
            colorSpaceIdentifier = expectedGamut.rawValue
            guard actualBitDepth == 8 else {
                throw DeliveryStagingProductionError.rendererReturnedWrongBitDepth
            }
            bitDepth = actualBitDepth
            switch export.sdrFormat {
            case .png, .tiff: quality = nil
            default: quality = Int((export.sdrQuality * 100).rounded())
            }
        }
        return DeliveryRenderSettings(
            formatIdentifier: formatIdentifier,
            colorSpaceIdentifier: colorSpaceIdentifier,
            pixelWidth: Int(dimensions.width.rounded()),
            pixelHeight: Int(dimensions.height.rounded()),
            bitDepth: bitDepth,
            quality: quality
        )
    }

    private static func profileName(
        _ profileName: String?,
        matches gamut: DeadlineExportSnapshot.ColorGamut
    ) -> Bool {
        guard let profileName else { return false }
        let normalized = profileName.lowercased()
        switch gamut {
        case .sRGB:
            return normalized.contains("srgb")
        case .displayP3:
            return normalized.contains("p3")
        case .rec2020:
            return normalized.contains("2020")
        case .adobeRGB:
            return normalized.contains("adobe") && normalized.contains("rgb")
        }
    }

    private static func maximumDimension(
        _ limit: DeadlineExportSnapshot.ResolutionLimit
    ) -> Int64? {
        switch limit {
        case .original: nil
        case .pixels6000: 6_000
        case .pixels4000: 4_000
        case .pixels3000: 3_000
        case .pixels2048: 2_048
        case .pixels1600: 1_600
        }
    }
}
