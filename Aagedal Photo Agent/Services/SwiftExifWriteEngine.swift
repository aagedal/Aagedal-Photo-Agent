import Foundation
import SwiftExif
import os

nonisolated private let swiftExifLog = Logger(subsystem: "com.aagedal.photo-agent", category: "SwiftExifWriteEngine")

/// XMP namespace URI for Adobe Camera Raw Settings.
nonisolated private let crsNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"

/// App-private XMP namespace for settings ACR can't represent — currently the global node's
/// position in the reorderable layer chain (mirrors XMPSidecarService's `aaphoto`).
nonisolated private let aaphotoNamespace = "http://aagedal.me/ns/photo/1.0/"

/// Native, in-process metadata write engine. Reads and re-emits the image file
/// via SwiftExif. There is no external process and no fallback path.
nonisolated final class SwiftExifWriteEngine: MetadataWriteEngine, @unchecked Sendable {

    init() {}

    /// RAW containers must NEVER be embedded into. Rewriting a proprietary RAW via
    /// SwiftExif/libexif cannot preserve maker-private structures — e.g. Sony's
    /// `SR2Private` block, which holds the encrypted white-balance calibration — so the
    /// rewrite corrupts the file (mangled WB → garbage decode) and bloats it with orphaned
    /// data. Camera-raw and IPTC metadata for RAW always lives in an XMP sidecar instead
    /// (see `MetadataWriteMode` / Photo Mechanic + Adobe convention). This guards every
    /// file-writing path so a stray caller can never damage a RAW, regardless of preset.
    private func embeddableURLs(_ urls: [URL]) -> [URL] {
        var embeddable: [URL] = []
        var skipped: [URL] = []
        for url in urls {
            if SupportedImageFormats.isRaw(url: url) { skipped.append(url) } else { embeddable.append(url) }
        }
        if !skipped.isEmpty {
            swiftExifLog.error("Refusing to embed metadata into \(skipped.count) RAW file(s) — RAW uses XMP sidecars; skipping \(skipped.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        }
        return embeddable
    }

    func writeFields(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws {
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty, !fields.isEmpty || !structuredData.isEmpty else { return }

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                try self.writeFieldsToFile(fields, structuredData: structuredData, url: url)
            }
        }
    }

    func writeFieldsToRenderedFiles(
        _ fields: [MetadataFieldKey: String],
        to urls: [URL],
        structuredData: StructuredWriteData
    ) async throws {
        // Keep the ordinary RAW-extension guard even at this explicit render boundary.
        // The opt-in below exists only for normal raster outputs whose copied camera Make
        // tag can make SwiftExif's byte heuristic mistake a generated TIFF for an ARW.
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty, !fields.isEmpty || !structuredData.isEmpty else { return }

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                try self.writeFieldsToFile(
                    fields,
                    structuredData: structuredData,
                    url: url,
                    allowRenderedTIFFRewrite: true
                )
            }
        }
    }

    func addRemoveListValues(
        add: [MetadataFieldKey: [String]],
        remove: [MetadataFieldKey: [String]],
        to urls: [URL]
    ) async throws {
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty else { return }
        let hasAdd = add.values.contains { !$0.isEmpty }
        let hasRemove = remove.values.contains { !$0.isEmpty }
        guard hasAdd || hasRemove else { return }

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                var metadata = try readMetadata(from: url)

                for (key, valuesToRemove) in remove {
                    guard !valuesToRemove.isEmpty else { continue }
                    self.applyListRemove(key: key, values: valuesToRemove, metadata: &metadata)
                }

                for (key, valuesToAdd) in add {
                    guard !valuesToAdd.isEmpty else { continue }
                    self.applyListAdd(key: key, values: valuesToAdd, metadata: &metadata)
                }

                metadata.syncIPTCToXMP()
                try metadata.write(to: url)
            }
        }
    }

    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty else { return }

        let value = rating == .none ? "" : String(rating.rawValue)

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                var metadata = try readMetadata(from: url)
                if value.isEmpty {
                    metadata.xmp?.removeValue(namespace: XMPNamespace.xmp, property: "Rating")
                } else {
                    if metadata.xmp == nil { metadata.xmp = XMPData() }
                    metadata.xmp?.setValue(.simple(value), namespace: XMPNamespace.xmp, property: "Rating")
                }
                try metadata.write(to: url)
            }
        }
    }

    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty else { return }

        let value = label.xmpLabelValue ?? ""

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                var metadata = try readMetadata(from: url)
                if value.isEmpty {
                    metadata.xmp?.removeValue(namespace: XMPNamespace.xmp, property: "Label")
                } else {
                    if metadata.xmp == nil { metadata.xmp = XMPData() }
                    metadata.xmp?.setValue(.simple(value), namespace: XMPNamespace.xmp, property: "Label")
                }
                try metadata.write(to: url)
            }
        }
    }

    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty else { return }

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                var metadata = try readMetadata(from: url)
                metadata.setOrientation(UInt16(clamping: orientation))
                try metadata.write(to: url)
            }
        }
    }

    func stripIPTCAndXMP(from urls: [URL]) async throws {
        let urls = embeddableURLs(urls)
        guard !urls.isEmpty else { return }

        for url in urls {
            try Task.checkCancellation()
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
                let creationDates = captureCreationDates(for: [url])
                defer { restoreCreationDates(creationDates) }
                var metadata = try readMetadata(from: url)
                metadata.iptc = IPTCData()
                metadata.xmp = nil
                try metadata.write(to: url)
            }
        }
    }

    func copyMetadataToRenderedFile(
        from source: URL,
        to destination: URL,
        bakedCameraRaw: CameraRawSettings?
    ) async throws {
        // Read the source under its own lock so it can't be read mid-write while the user
        // edits the original. Locks are released between the two phases (source and destination
        // are distinct files / keys), which avoids any same-key re-entrancy.
        let sourceMetadata: ImageMetadata
        do {
            sourceMetadata = try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: source)) {
                try readMetadata(from: source)
            }
        } catch {
            swiftExifLog.error(
                "copyMetadataToRenderedFile: read source failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: destination)) {
            let creationDates = captureCreationDates(for: [destination])
            defer { restoreCreationDates(creationDates) }

            var destMetadata: ImageMetadata
            do {
                destMetadata = try readMetadata(from: destination)
            } catch {
                swiftExifLog.error(
                    "copyMetadataToRenderedFile: read destination failed for \(destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            // Copy EXIF (technical camera fields + GPS), IPTC, and XMP wholesale, then
            // strip Camera Raw and supersize-to-Standard tags that would mislead viewers
            // about the rendered output. EXIF must be copied here so non-JPEG outputs
            // (JXL/HEIC/AVIF/PNG/TIFF) carry camera metadata — only the JPEG renderer path
            // (writeJPEGWithSourceProperties) bakes EXIF in on its own. The source EXIF is
            // post-processed below: its thumbnail IFD is dropped and orientation normalized.
            destMetadata.exif = sourceMetadata.exif
            destMetadata.iptc = sourceMetadata.iptc
            destMetadata.xmp = sourceMetadata.xmp

            // Drop the entire Adobe Camera Raw namespace the source may have carried —
            // including settings the app doesn't model (ACR's Texture, HSL, …) and any
            // live AlreadyApplied="False" marker from the source — so the rendered file
            // starts from a clean crs slate.
            destMetadata.xmp?.removeAll(namespace: crsNamespace)

            // Re-emit the develop settings that were baked into the rendered pixels as a
            // crs block marked AlreadyApplied="True". This documents how the image was
            // edited; the True marker means ACR/Bridge — and our own reader (see
            // crsIsAlreadyApplied) — treat the settings as already applied and never
            // re-apply them on top of the baked render. When there were no edits, the crs
            // block stays empty.
            if let baked = bakedCameraRaw, !baked.isEmpty {
                self.embedBakedCameraRaw(baked, sourceURL: source, into: &destMetadata)
            }

            // Stamp the producing application so the export records that it was rendered
            // by this app and version. xmp:CreatorTool is the Adobe/Lightroom convention
            // for "software that produced this rendition"; it does not clobber the
            // camera's original EXIF/TIFF Software string copied above.
            self.stampCreatorTool(into: &destMetadata)

            // Drop the IFD1 thumbnail and ICC profile from the source — the renderer
            // is expected to set its own profile and produce a fresh thumbnail when
            // emitting the new file.
            destMetadata.exif?.ifd1 = nil
            destMetadata.stripICCProfile()

            // Drop the source's Exif pixel-dimension tags (PixelXDimension/Y,
            // 0xA002/0xA003). They describe the *source* frame and drift from the
            // rendered output whenever a crop was applied, leaving a file whose Exif
            // size contradicts its actual encoded (SOF / container) dimensions.
            // Removing them lets readers fall back to the true rendered size.
            destMetadata.removeExifSubIFDTag(0xA002)
            destMetadata.removeExifSubIFDTag(0xA003)

            // Force orientation to 1 — rendered pixels are already upright.
            destMetadata.setOrientation(1)

            do {
                try destMetadata.write(to: destination)
            } catch {
                swiftExifLog.error(
                    "copyMetadataToRenderedFile: write failed for \(destination.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
    }

    // MARK: - Private Helpers

    private func writeFieldsToFile(
        _ fields: [MetadataFieldKey: String],
        structuredData: StructuredWriteData,
        url: URL,
        allowRenderedTIFFRewrite: Bool = false
    ) throws {
        var metadata = try readMetadata(from: url)

        // Adobe-faithful develop write: ACR replaces the file's whole crs block
        // with its live state on save, dropping settings it isn't carrying —
        // otherwise stale baked globals (Texture, vignette, HSL, …) left from a
        // previously-exported JPEG survive next to AlreadyApplied="False" and
        // ACR re-applies them on top of our render. Callers opt in only when
        // the write carries the complete develop state. The crs-content check
        // keeps a save that carries no develop state at all (e.g. captioning an
        // image whose crs block we couldn't model) from wiping the block.
        let writesCameraRaw = fields.keys.contains(where: \.isCameraRawField)
            || structuredData.toneCurve != nil || structuredData.masks != nil
            || structuredData.watermarkLayers != nil
            || structuredData.hslAdjustments != nil
            || structuredData.unparsedMaskCorrections?.isEmpty == false
        if structuredData.replaceCameraRawBlock && writesCameraRaw {
            metadata.xmp?.removeAll(namespace: crsNamespace)
            // Our private global-position tag tracks develop state — clear it with the block
            // so a reset/replace can't leave a stale GlobalLayerIndex/LayerOrder/watermark
            // set behind.
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "GlobalLayerIndex")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "LayerOrder")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "WatermarkLayers")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "AnonymizerAmount")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "AnonymizerBlackOut")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "GlobalDensity")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "FilmGrain")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "FilmGrainCoarseness")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "FilmHalation")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "FilmBloom")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "FilmVignette")
            metadata.xmp?.removeValue(namespace: aaphotoNamespace, property: "FilmEdgeBlur")
        }

        // GPS coordinates are paired: SwiftExif's setGPS takes both at once and
        // derives the N/S and E/W refs from the *sign* of each value. Callers
        // (see IPTCMetadata.toWriteFields) store the magnitude in .gpsLatitude/
        // .gpsLongitude and the hemisphere in the paired *Ref field, so we must
        // re-apply the ref sign here — otherwise southern/western coordinates
        // (e.g. anywhere in the Americas) get written flipped to N/E.
        let latString = fields[.gpsLatitude]
        let lonString = fields[.gpsLongitude]
        let bothCleared = (latString?.isEmpty ?? false) && (lonString?.isEmpty ?? false)
        if let latString, let lonString, !latString.isEmpty, !lonString.isEmpty,
           let latMagnitude = Double(latString), let lonMagnitude = Double(lonString) {
            let lat = applyHemisphere(latMagnitude, ref: fields[.gpsLatitudeRef], negativeRef: "S")
            let lon = applyHemisphere(lonMagnitude, ref: fields[.gpsLongitudeRef], negativeRef: "W")
            metadata.setGPS(latitude: lat, longitude: lon)
        } else if bothCleared {
            metadata.removeGPS()
        }

        for (key, value) in fields {
            // GPS handled above; refs are derived in setGPS.
            switch key {
            case .gpsLatitude, .gpsLongitude, .gpsLatitudeRef, .gpsLongitudeRef:
                continue
            default:
                applyField(key: key, value: value, metadata: &metadata)
            }
        }

        if let tc = structuredData.toneCurve {
            applyToneCurves(tc, metadata: &metadata)
        }

        if structuredData.masks != nil || structuredData.watermarkLayers != nil
            || structuredData.unparsedMaskCorrections?.isEmpty == false {
            applyLayerChain(masks: structuredData.masks ?? [], watermarks: structuredData.watermarkLayers ?? [],
                            layerOrder: structuredData.layerOrder,
                            preserved: structuredData.unparsedMaskCorrections ?? [], metadata: &metadata)
        }

        if let hsl = structuredData.hslAdjustments {
            applyHSL(hsl, metadata: &metadata)
        }

        if let anon = structuredData.anonymizer {
            applyAnonymizer(anon, metadata: &metadata)
        }

        if let editorial = structuredData.editorial {
            var xmp = metadata.xmp ?? XMPData()
            XMPDataBuilder.applyStructuredEditorial(editorial, into: &xmp)
            metadata.xmp = xmp
        }

        // After a block replacement that carries settings, re-stamp the edited
        // markers: applyMasks sets them only when masks exist, and Bridge/ACR
        // treat a crs block without an EXPLICIT AlreadyApplied="False" as not
        // edited (absence is not enough; verified against ACR 18.3.2). A fully
        // cleared block (develop reset) stays empty — no markers, no badge.
        if structuredData.replaceCameraRawBlock, writesCameraRaw,
           let xmp = metadata.xmp, !xmp.properties(in: crsNamespace).isEmpty {
            metadata.xmp?.setValue(.simple("False"), namespace: crsNamespace, property: "AlreadyApplied")
            metadata.xmp?.setValue(.simple("234881024"), namespace: crsNamespace, property: "CompatibleVersion")
        }

        // Sync IPTC → XMP to ensure both sides are consistent.
        metadata.syncIPTCToXMP()
        normalizeEditorialRoleXMP(for: fields, metadata: &metadata)

        if allowRenderedTIFFRewrite,
           ["tif", "tiff"].contains(url.pathExtension.lowercased()) {
            try metadata.write(
                to: url,
                options: .init(allowUnsafeRawEmbed: true)
            )
        } else {
            try metadata.write(to: url)
        }
    }

    /// SwiftExif models the legacy IIM datasets as repeatable and therefore mirrors them to
    /// XMP arrays. IPTC Photo Metadata defines the corresponding Photoshop properties as scalar
    /// text, so normalize only the fields touched by this write after the general IIM→XMP sync.
    private func normalizeEditorialRoleXMP(
        for fields: [MetadataFieldKey: String],
        metadata: inout ImageMetadata
    ) {
        let mappings: [(MetadataFieldKey, String)] = [
            (.creatorJobTitle, "AuthorsPosition"),
            (.descriptionWriter, "CaptionWriter"),
        ]

        for (key, property) in mappings {
            guard let value = fields[key] else { continue }
            if value.isEmpty {
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: property)
            } else {
                if metadata.xmp == nil { metadata.xmp = XMPData() }
                metadata.xmp?.setValue(
                    .simple(value),
                    namespace: XMPNamespace.photoshop,
                    property: property
                )
            }
        }
    }

    /// Re-applies an EXIF hemisphere ref onto a coordinate magnitude. Callers split a
    /// signed coordinate into a positive magnitude plus a `*Ref` field ("N"/"S", "E"/"W");
    /// `setGPS` wants the sign back. When the ref is missing we trust the value's own sign
    /// so a directly-signed value still round-trips.
    private func applyHemisphere(_ magnitude: Double, ref: String?, negativeRef: String) -> Double {
        guard let ref = ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            return magnitude
        }
        return ref.caseInsensitiveCompare(negativeRef) == .orderedSame ? -abs(magnitude) : abs(magnitude)
    }

    /// Apply a single field to the metadata.
    private func applyField(key: MetadataFieldKey, value: String, metadata: inout ImageMetadata) {
        let isEmpty = value.isEmpty

        switch key {
        // IPTC fields — set on IPTC, syncIPTCToXMP fills XMP.
        //
        // On clear we must ALSO remove the mirrored XMP property: `syncIPTCToXMP`
        // only ever *sets* XMP from a present IPTC value (never unsets), so removing
        // the IPTC entry alone leaves the old XMP value behind — and readers that
        // prefer XMP (ours does) would resurrect the field the user just cleared.
        case .headline:
            if isEmpty {
                metadata.iptc.removeAll(for: .headline)
                metadata.iptc.removeAll(for: .objectName)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "Headline")
                metadata.xmp?.removeValue(namespace: XMPNamespace.dc, property: "title")
            } else {
                metadata.iptc.headline = value
                metadata.iptc.objectName = value
            }

        case .description:
            if isEmpty {
                metadata.iptc.removeAll(for: .captionAbstract)
                metadata.xmp?.removeValue(namespace: XMPNamespace.dc, property: "description")
            } else {
                metadata.iptc.caption = value
            }

        case .subject:
            metadata.iptc.removeAll(for: .keywords)
            if !isEmpty {
                let keywords = value.components(separatedBy: ", ")
                metadata.iptc.keywords = keywords
            } else {
                metadata.xmp?.removeValue(namespace: XMPNamespace.dc, property: "subject")
            }

        case .creator:
            if isEmpty {
                metadata.iptc.removeAll(for: .byline)
                metadata.xmp?.removeValue(namespace: XMPNamespace.dc, property: "creator")
            } else {
                metadata.iptc.byline = value
            }

        case .creatorJobTitle:
            if isEmpty {
                metadata.iptc.removeAll(for: .bylineTitle)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "AuthorsPosition")
            } else {
                metadata.iptc.bylineTitle = value
            }

        case .descriptionWriter:
            if isEmpty {
                metadata.iptc.removeAll(for: .writerEditor)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "CaptionWriter")
            } else {
                metadata.iptc.writerEditor = value
            }

        case .credit:
            if isEmpty {
                metadata.iptc.removeAll(for: .credit)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "Credit")
            } else {
                metadata.iptc.credit = value
            }

        case .rights:
            if isEmpty {
                metadata.iptc.removeAll(for: .copyrightNotice)
                metadata.xmp?.removeValue(namespace: XMPNamespace.dc, property: "rights")
            } else {
                metadata.iptc.copyright = value
            }

        case .rightsUsageTerms:
            setXMPField(
                &metadata,
                namespace: XMPDataBuilder.xmpRightsNamespace,
                property: "UsageTerms",
                value: isEmpty ? nil : .langAlternative(value)
            )

        case .webStatementOfRights:
            setXMPField(
                &metadata,
                namespace: XMPDataBuilder.xmpRightsNamespace,
                property: "WebStatement",
                value: isEmpty ? nil : .simple(value)
            )

        case .transmissionReference:
            if isEmpty {
                metadata.iptc.removeAll(for: .originalTransmissionReference)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "TransmissionReference")
            } else {
                metadata.iptc.jobId = value
            }

        case .dateCreated:
            if isEmpty {
                metadata.iptc.removeAll(for: .dateCreated)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "DateCreated")
            } else {
                metadata.iptc.dateCreated = value
            }

        case .city:
            if isEmpty {
                metadata.iptc.removeAll(for: .city)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "City")
            } else {
                metadata.iptc.city = value
            }

        case .sublocation:
            if isEmpty {
                metadata.iptc.removeAll(for: .sublocation)
                metadata.xmp?.removeValue(namespace: XMPNamespace.iptcCore, property: "Location")
            } else {
                metadata.iptc.sublocation = value
            }

        case .provinceState:
            if isEmpty {
                metadata.iptc.removeAll(for: .provinceState)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "State")
            } else {
                metadata.iptc.provinceState = value
            }

        case .country:
            if isEmpty {
                metadata.iptc.removeAll(for: .countryPrimaryLocationName)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "Country")
            } else {
                metadata.iptc.countryName = value
            }

        case .countryCode:
            if isEmpty {
                metadata.iptc.removeAll(for: .countryPrimaryLocationCode)
                metadata.xmp?.removeValue(namespace: XMPNamespace.iptcCore, property: "CountryCode")
            } else {
                metadata.iptc.countryCode = ISO3166Country.normalizedAlpha3(value)
            }

        case .urgency:
            if isEmpty {
                metadata.iptc.removeAll(for: .urgency)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "Urgency")
            } else if let urgency = Int(value) {
                metadata.iptc.urgency = urgency
                setXMPField(
                    &metadata,
                    namespace: XMPNamespace.photoshop,
                    property: "Urgency",
                    value: .simple(String(urgency))
                )
            }

        case .instructions:
            if isEmpty {
                metadata.iptc.removeAll(for: .specialInstructions)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "Instructions")
            } else {
                metadata.iptc.specialInstructions = value
            }

        case .source:
            if isEmpty {
                metadata.iptc.removeAll(for: .source)
                metadata.xmp?.removeValue(namespace: XMPNamespace.photoshop, property: "Source")
            } else {
                metadata.iptc.source = value
            }

        // XMP-only fields
        case .extendedDescription:
            setXMPField(&metadata, namespace: XMPNamespace.iptcCore, property: "ExtDescrAccessibility",
                        value: isEmpty ? nil : .langAlternative(value))

        case .personInImage:
            if isEmpty {
                metadata.xmp?.removeValue(namespace: XMPNamespace.iptcExt, property: "PersonInImage")
            } else {
                let persons = value.components(separatedBy: ", ")
                if metadata.xmp == nil { metadata.xmp = XMPData() }
                metadata.xmp?.setValue(.array(persons), namespace: XMPNamespace.iptcExt, property: "PersonInImage")
            }

        case .organisationInImageName:
            setXMPListField(
                &metadata,
                property: "OrganisationInImageName",
                commaSeparatedValue: value
            )

        case .organisationInImageCode:
            setXMPListField(
                &metadata,
                property: "OrganisationInImageCode",
                commaSeparatedValue: value
            )

        case .digitalSourceType:
            setXMPField(&metadata, namespace: XMPNamespace.iptcExt, property: "DigitalSourceType",
                        value: isEmpty ? nil : .simple(value))

        case .event:
            setXMPField(&metadata, namespace: XMPNamespace.iptcExt, property: "Event",
                        value: isEmpty ? nil : .langAlternative(value))

        case .xmpTitle:
            setXMPField(&metadata, namespace: XMPNamespace.dc, property: "title",
                        value: isEmpty ? nil : .langAlternative(value))

        case .rating:
            setXMPField(&metadata, namespace: XMPNamespace.xmp, property: "Rating",
                        value: isEmpty ? nil : .simple(value))

        case .label:
            setXMPField(&metadata, namespace: XMPNamespace.xmp, property: "Label",
                        value: isEmpty ? nil : .simple(value))

        // EXIF IFD: orientation
        case .orientation:
            if isEmpty {
                metadata.resetOrientation()
            } else if let parsed = Int(value) {
                metadata.setOrientation(UInt16(clamping: parsed))
            }

        // GPS coordinates are handled in `writeFieldsToFile` (paired write
        // via `setGPS`); these cases should never be reached but are here
        // to keep the switch exhaustive.
        case .gpsLatitude, .gpsLongitude, .gpsLatitudeRef, .gpsLongitudeRef:
            break

        // Camera Raw simple fields
        case .crsVersion: setCRSField(&metadata, property: "Version", value: value)
        case .crsProcessVersion: setCRSField(&metadata, property: "ProcessVersion", value: value)
        case .crsWhiteBalance: setCRSField(&metadata, property: "WhiteBalance", value: value)
        case .crsTemperature: setCRSField(&metadata, property: "Temperature", value: value)
        case .crsTint: setCRSField(&metadata, property: "Tint", value: value)
        case .crsIncrementalTemperature: setCRSField(&metadata, property: "IncrementalTemperature", value: value)
        case .crsIncrementalTint: setCRSField(&metadata, property: "IncrementalTint", value: value)
        case .crsExposure2012: setCRSField(&metadata, property: "Exposure2012", value: value)
        case .crsContrast2012: setCRSField(&metadata, property: "Contrast2012", value: value)
        case .crsHighlights2012: setCRSField(&metadata, property: "Highlights2012", value: value)
        case .crsShadows2012: setCRSField(&metadata, property: "Shadows2012", value: value)
        case .crsWhites2012: setCRSField(&metadata, property: "Whites2012", value: value)
        case .crsBlacks2012: setCRSField(&metadata, property: "Blacks2012", value: value)
        case .crsSaturation: setCRSField(&metadata, property: "Saturation", value: value)
        case .crsVibrance: setCRSField(&metadata, property: "Vibrance", value: value)
        case .crsSharpness: setCRSField(&metadata, property: "Sharpness", value: value)
        case .crsClarity2012: setCRSField(&metadata, property: "Clarity2012", value: value)
        case .crsDehaze: setCRSField(&metadata, property: "Dehaze", value: value)
        case .crsHasSettings: setCRSField(&metadata, property: "HasSettings", value: value)
        case .crsCropTop: setCRSField(&metadata, property: "CropTop", value: value)
        case .crsCropLeft: setCRSField(&metadata, property: "CropLeft", value: value)
        case .crsCropBottom: setCRSField(&metadata, property: "CropBottom", value: value)
        case .crsCropRight: setCRSField(&metadata, property: "CropRight", value: value)
        case .crsCropAngle: setCRSField(&metadata, property: "CropAngle", value: value)
        case .crsHasCrop: setCRSField(&metadata, property: "HasCrop", value: value)
        case .crsCropConstrainToWarp: setCRSField(&metadata, property: "CropConstrainToWarp", value: value)
        case .crsCropConstrainToUnitSquare: setCRSField(&metadata, property: "CropConstrainToUnitSquare", value: value)
        case .crsHDREditMode: setCRSField(&metadata, property: "HDREditMode", value: value)
        case .crsHDRMaxValue: setCRSField(&metadata, property: "HDRMaxValue", value: value)
        case .crsSDRBrightness: setCRSField(&metadata, property: "SDRBrightness", value: value)
        case .crsSDRContrast: setCRSField(&metadata, property: "SDRContrast", value: value)
        case .crsSDRClarity: setCRSField(&metadata, property: "SDRClarity", value: value)
        case .crsSDRHighlights: setCRSField(&metadata, property: "SDRHighlights", value: value)
        case .crsSDRShadows: setCRSField(&metadata, property: "SDRShadows", value: value)
        case .crsSDRWhites: setCRSField(&metadata, property: "SDRWhites", value: value)
        case .crsSDRBlend: setCRSField(&metadata, property: "SDRBlend", value: value)
        case .crsToneCurveName2012: setCRSField(&metadata, property: "ToneCurveName2012", value: value)
        case .aaphotoGlobalDensity:
            setXMPField(
                &metadata,
                namespace: aaphotoNamespace,
                property: "GlobalDensity",
                value: isEmpty ? nil : .simple(value)
            )
        case .aaphotoFilmGrain:
            setXMPField(&metadata, namespace: aaphotoNamespace, property: "FilmGrain",
                        value: isEmpty ? nil : .simple(value))
        case .aaphotoFilmGrainCoarseness:
            setXMPField(&metadata, namespace: aaphotoNamespace, property: "FilmGrainCoarseness",
                        value: isEmpty ? nil : .simple(value))
        case .aaphotoFilmHalation:
            setXMPField(&metadata, namespace: aaphotoNamespace, property: "FilmHalation",
                        value: isEmpty ? nil : .simple(value))
        case .aaphotoFilmBloom:
            setXMPField(&metadata, namespace: aaphotoNamespace, property: "FilmBloom",
                        value: isEmpty ? nil : .simple(value))
        case .aaphotoFilmVignette:
            setXMPField(&metadata, namespace: aaphotoNamespace, property: "FilmVignette",
                        value: isEmpty ? nil : .simple(value))
        case .aaphotoFilmEdgeBlur:
            setXMPField(&metadata, namespace: aaphotoNamespace, property: "FilmEdgeBlur",
                        value: isEmpty ? nil : .simple(value))
        }
    }

    /// Mutate `metadata.xmp` in place, creating an empty `XMPData` first if absent — the bridge for
    /// calling the shared `XMPDataBuilder` (which works on `inout XMPData`) from the engine, whose
    /// `xmp` is optional.
    private func mutateXMP(_ metadata: inout ImageMetadata, _ body: (inout XMPData) -> Void) {
        var xmp = metadata.xmp ?? XMPData()
        body(&xmp)
        metadata.xmp = xmp
    }

    /// Apply tone curves as XMP-crs array values — shared with the `.xmp` sidecar writer via
    /// `XMPDataBuilder` so the two stores can't drift.
    private func applyToneCurves(_ tc: ToneCurve, metadata: inout ImageMetadata) {
        mutateXMP(&metadata) { XMPDataBuilder.applyToneCurves(tc, into: &$0) }
    }

    /// Write the local-mask block in render-stack order plus the app-private
    /// `aaphoto:GlobalLayerIndex` for the global node's position — shared with the `.xmp` sidecar
    /// writer via `XMPDataBuilder` (one implementation of the `MaskGroupBasedCorrections` nesting).
    private func applyLayerChain(masks: [MaskAdjustment], watermarks: [WatermarkLayer] = [], layerOrder: [LayerRef]?, preserved: [PreservedMaskCorrection] = [], metadata: inout ImageMetadata) {
        mutateXMP(&metadata) { XMPDataBuilder.applyLayerChain(masks: masks, watermarks: watermarks, layerOrder: layerOrder, preserved: preserved, into: &$0) }
    }

    /// Apply per-color HSL adjustments as simple XMP-crs properties
    /// (`HueAdjustmentRed`, `SaturationAdjustmentAqua`, …). Field content comes
    /// from the shared `encodeHSLAdjustments` (also used by the .xmp sidecar
    /// writer) so the embedded-file and sidecar HSL encodings stay identical.
    private func applyHSL(_ hsl: HSLAdjustments, metadata: inout ImageMetadata) {
        let encoded = encodeHSLAdjustments(hsl)
        guard !encoded.isEmpty else { return }
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        for (name, value) in encoded {
            metadata.xmp?.setValue(.simple(value), namespace: crsNamespace, property: name)
        }
    }

    /// Apply the global Anonymizer redaction settings as app-private XMP — shared with the
    /// `.xmp` sidecar writer via `XMPDataBuilder` so the two stores can't drift.
    private func applyAnonymizer(_ anon: AnonymizerSettings, metadata: inout ImageMetadata) {
        mutateXMP(&metadata) { XMPDataBuilder.applyAnonymizer(anon, into: &$0) }
    }

    /// Set an XMP field, creating XMPData if needed. Pass nil value to remove.
    private func setXMPField(_ metadata: inout ImageMetadata, namespace: String, property: String, value: XMPValue?) {
        if let value {
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            metadata.xmp?.setValue(value, namespace: namespace, property: property)
        } else {
            metadata.xmp?.removeValue(namespace: namespace, property: property)
        }
    }

    /// Set a Camera Raw Settings (XMP-crs) field.
    private func setCRSField(_ metadata: inout ImageMetadata, property: String, value: String) {
        if value.isEmpty {
            metadata.xmp?.removeValue(namespace: crsNamespace, property: property)
        } else {
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            metadata.xmp?.setValue(.simple(value), namespace: crsNamespace, property: property)
        }
    }

    /// Re-emit the develop settings baked into a rendered export as a crs block marked
    /// `AlreadyApplied="True"`. Reuses the same simple-field / tone-curve / mask writers as
    /// a live develop write, then overrides the marker to True (the live writers stamp
    /// "False"). The caller is expected to have cleared the crs namespace first.
    private func embedBakedCameraRaw(
        _ settings: CameraRawSettings,
        sourceURL: URL,
        into metadata: inout ImageMetadata
    ) {
        let fields = settings.developWriteFields(imageAspect: { ImagePixelAspect.aspect(at: sourceURL) })
        for (key, value) in fields {
            applyField(key: key, value: value, metadata: &metadata)
        }
        if let tc = settings.toneCurve, !tc.isEmpty {
            applyToneCurves(tc, metadata: &metadata)
        }
        if settings.localAdjustments?.isEmpty == false || settings.watermarkLayers?.isEmpty == false {
            applyLayerChain(masks: settings.localAdjustments ?? [], watermarks: settings.watermarkLayers ?? [],
                            layerOrder: settings.layerOrder, metadata: &metadata)
        }
        if let hsl = settings.hslAdjustments, !hsl.isEmpty {
            applyHSL(hsl, metadata: &metadata)
        }
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.setValue(.simple("True"), namespace: crsNamespace, property: "AlreadyApplied")
        metadata.xmp?.setValue(.simple("234881024"), namespace: crsNamespace, property: "CompatibleVersion")
    }

    /// `xmp:CreatorTool` value identifying the producing app + version, e.g.
    /// "Aagedal Photo Agent 2.0.0".
    nonisolated static let creatorTool: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return version.isEmpty ? "Aagedal Photo Agent" : "Aagedal Photo Agent \(version)"
    }()

    /// Stamp `xmp:CreatorTool` so a rendered export records which app/version produced it.
    private func stampCreatorTool(into metadata: inout ImageMetadata) {
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        metadata.xmp?.setValue(.simple(Self.creatorTool), namespace: XMPNamespace.xmp, property: "CreatorTool")
    }

    // MARK: - List Operations

    private func applyListRemove(key: MetadataFieldKey, values: [String], metadata: inout ImageMetadata) {
        switch key {
        case .subject:
            var existing = metadata.iptc.keywords
            existing.removeAll { values.contains($0) }
            metadata.iptc.removeAll(for: .keywords)
            metadata.iptc.keywords = existing

        case .personInImage:
            if let xmpPersons = metadata.xmp?.personInImage {
                var existing = xmpPersons
                existing.removeAll { values.contains($0) }
                if existing.isEmpty {
                    metadata.xmp?.removeValue(namespace: XMPNamespace.iptcExt, property: "PersonInImage")
                } else {
                    metadata.xmp?.setValue(.array(existing), namespace: XMPNamespace.iptcExt, property: "PersonInImage")
                }
            }

        case .organisationInImageName:
            removeXMPListValues(values, property: "OrganisationInImageName", metadata: &metadata)

        case .organisationInImageCode:
            removeXMPListValues(values, property: "OrganisationInImageCode", metadata: &metadata)

        default:
            swiftExifLog.warning("addRemoveListValues: unsupported key \(key.rawValue, privacy: .public) for remove")
        }
    }

    private func applyListAdd(key: MetadataFieldKey, values: [String], metadata: inout ImageMetadata) {
        switch key {
        case .subject:
            var existing = metadata.iptc.keywords
            for value in values {
                existing.removeAll { $0 == value }
                existing.append(value)
            }
            metadata.iptc.removeAll(for: .keywords)
            metadata.iptc.keywords = existing

        case .personInImage:
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            var existing = metadata.xmp?.personInImage ?? []
            for value in values {
                existing.removeAll { $0 == value }
                existing.append(value)
            }
            metadata.xmp?.setValue(.array(existing), namespace: XMPNamespace.iptcExt, property: "PersonInImage")

        case .organisationInImageName:
            addXMPListValues(values, property: "OrganisationInImageName", metadata: &metadata)

        case .organisationInImageCode:
            addXMPListValues(values, property: "OrganisationInImageCode", metadata: &metadata)

        default:
            swiftExifLog.warning("addRemoveListValues: unsupported key \(key.rawValue, privacy: .public) for add")
        }
    }

    private func setXMPListField(
        _ metadata: inout ImageMetadata,
        property: String,
        commaSeparatedValue value: String
    ) {
        let values = value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
        if values.isEmpty {
            metadata.xmp?.removeValue(namespace: XMPNamespace.iptcExt, property: property)
        } else {
            if metadata.xmp == nil { metadata.xmp = XMPData() }
            metadata.xmp?.setValue(.array(values), namespace: XMPNamespace.iptcExt, property: property)
        }
    }

    private func removeXMPListValues(
        _ values: [String],
        property: String,
        metadata: inout ImageMetadata
    ) {
        var existing = metadata.xmp?.arrayValue(
            namespace: XMPNamespace.iptcExt,
            property: property
        ) ?? []
        guard !existing.isEmpty else { return }
        existing.removeAll { values.contains($0) }
        if existing.isEmpty {
            metadata.xmp?.removeValue(namespace: XMPNamespace.iptcExt, property: property)
        } else {
            metadata.xmp?.setValue(.array(existing), namespace: XMPNamespace.iptcExt, property: property)
        }
    }

    private func addXMPListValues(
        _ values: [String],
        property: String,
        metadata: inout ImageMetadata
    ) {
        if metadata.xmp == nil { metadata.xmp = XMPData() }
        var existing = metadata.xmp?.arrayValue(
            namespace: XMPNamespace.iptcExt,
            property: property
        ) ?? []
        for value in values {
            existing.removeAll { $0 == value }
            existing.append(value)
        }
        metadata.xmp?.setValue(.array(existing), namespace: XMPNamespace.iptcExt, property: property)
    }
}
