import Foundation
import SwiftMediaMetadata
import os

nonisolated private let xmpLog = Logger(subsystem: "com.aagedal.photo-agent", category: "XMPSidecarService")
nonisolated private let localizedTitleClearedProperty = XMPMetadataNamespace.localizedTitleClearedProperty

/// Reads and writes Adobe-compatible `.xmp` sidecars for RAW (and any file we don't embed into).
///
/// Pure Swift: parsing goes through SwiftExif's `XMPReader` and serialization through its
/// string-based `XMPWriter` (via `XMPDataBuilder`) — there is NO Foundation NSXML / libxml2 DOM
/// here. That removes the process-global libxml2 state that used to race ImageIO/RAW decode and
/// crash with EXC_BAD_ACCESS, and makes every method thread-safe with no lock (`XMPData` is a
/// `Sendable` value type). The develop/crs/mask/tone encoders are shared with the embedded-file
/// writer via `XMPDataBuilder`, so the sidecar and embedded XMP can't drift.
struct XMPSidecarService: Sendable {

    /// A sidecar may also be edited by Bridge/Lightroom while Photo Agent is preparing a write.
    /// Serialized app writes retry from the newly observed bytes instead of installing a merge
    /// based on a stale source document.
    private nonisolated static let transactionRetryLimit = 4

    nonisolated func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    nonisolated func sidecarExists(for imageURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: imageURL).path)
    }

    /// Reads the sidecar file's bytes if it exists. Pure file I/O — safe to call off the main actor
    /// (and intended to be, since `Data(contentsOf:)` can stall on iCloud-not-downloaded files).
    nonisolated func sidecarDataIfExists(for imageURL: URL) -> Data? {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Nonisolated, lightweight read of just the display orientation from the `.xmp` sidecar —
    /// `tiff:Orientation` (Adobe's authoritative tag), falling back to `exif:Orientation`. For
    /// off-main thumbnail generation, which needs only the orientation. Returns nil when there's no
    /// sidecar or it carries no orientation.
    nonisolated func sidecarOrientation(for imageURL: URL) -> Int? {
        guard let data = sidecarDataIfExists(for: imageURL),
              let xmp = try? XMPReader.readFromXML(data) else { return nil }
        let raw = xmp.tiffOrientation ?? xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
        return raw.flatMap { Int($0) }
    }

    /// Pretty-prints the sidecar's XML for the metadata inspector by round-tripping it through the
    /// pure-Swift reader/writer (stable formatting). Falls back to the raw UTF-8 bytes if it won't
    /// parse. Returns nil when there's no sidecar.
    nonisolated func prettyPrintedSidecarXML(for imageURL: URL) -> String? {
        guard let data = sidecarDataIfExists(for: imageURL) else { return nil }
        if let xmp = try? XMPReader.readFromXML(data) {
            return XMPWriter.generateXML(xmp)
        }
        return String(data: data, encoding: .utf8) ?? "Unable to read XMP sidecar"
    }

    nonisolated func loadSidecar(for imageURL: URL) -> IPTCMetadata? {
        guard let data = sidecarDataIfExists(for: imageURL) else { return nil }
        return loadSidecar(fromData: data, imageAspect: { ImagePixelAspect.aspect(at: imageURL) })
    }

    /// Parses already-read XMP bytes into IPTCMetadata. `imageAspect` supplies the image's
    /// sensor-frame width/height ratio for the ACR angled-crop conversion; it is only invoked when
    /// the sidecar carries an angled crop (the conversion is the identity at angle 0).
    nonisolated func loadSidecar(fromData data: Data, imageAspect: () -> Double? = { nil }) -> IPTCMetadata? {
        XMPMetadataReader.read(data, imageAspect: imageAspect)
    }

    /// Removes all IPTC/descriptive metadata from the sidecar while preserving Camera Raw edit
    /// settings. Deletes the sidecar entirely if no edit settings remain.
    func stripIPTCFromSidecar(for imageURL: URL) {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard let metadata = loadSidecar(for: imageURL) else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                xmpLog.warning("Failed to remove unreadable XMP sidecar for \(imageURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
            return
        }

        if let cameraRaw = metadata.cameraRaw, !cameraRaw.isEmpty {
            let editOnly = IPTCMetadata(
                localizedTitles: [],
                cameraRaw: cameraRaw,
                exifOrientation: metadata.exifOrientation
            )
            do {
                // Removing descriptive metadata is not a pending Title-clear edit. Suppress the
                // tombstone so the remaining develop-only sidecar stays non-descriptive.
                try saveSidecar(
                    metadata: editOnly,
                    for: imageURL,
                    writesLocalizedTitleClearTombstone: false
                )
            } catch {
                xmpLog.error("Failed to save stripped XMP sidecar for \(imageURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        } else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                xmpLog.warning("Failed to remove empty XMP sidecar for \(imageURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Serialized destructive counterpart used by Metadata's remove-IPTC workflow. It keeps the
    /// complete read/strip/install (or delete) decision inside the same URL boundary as caption,
    /// face, and Develop mutations and retries if an external editor changes the source revision.
    @MetadataSidecarFilesystemActor
    func stripIPTCFromSidecarSerialized(
        for imageURL: URL,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            let url = self.sidecarURL(for: imageURL)
            for attempt in 0..<Self.transactionRetryLimit {
                guard let sourceData = try Self.currentData(at: url) else { return }
                var xmp = try XMPReader.readFromXML(sourceData)
                let metadata = XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil })
                let stagedData: Data?

                if let cameraRaw = metadata.cameraRaw, !cameraRaw.isEmpty {
                    let editOnly = IPTCMetadata(
                        localizedTitles: [],
                        cameraRaw: cameraRaw,
                        exifOrientation: metadata.exifOrientation
                    )
                    XMPDataBuilder.applyDescriptive(editOnly, into: &xmp)
                    xmp.removeValue(
                        namespace: XMPDataBuilder.aaphotoNamespace,
                        property: localizedTitleClearedProperty
                    )
                    xmp.creatorTool = SwiftExifWriteEngine.creatorTool
                    let xml = XMPWriter.generateXML(xmp)
                    guard let encoded = xml.data(using: .utf8) else {
                        throw CocoaError(.fileWriteInapplicableStringEncoding)
                    }
                    _ = try XMPReader.readFromXML(encoded)
                    stagedData = encoded
                } else {
                    stagedData = nil
                }

                beforeRevisionCheck(attempt)
                await Task.yield()
                guard try Self.currentData(at: url) == sourceData else { continue }

                if let stagedData {
                    try stagedData.write(to: url, options: .atomic)
                    let installedData = try Data(contentsOf: url)
                    guard installedData == stagedData else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    _ = try XMPReader.readFromXML(installedData)
                } else {
                    try FileManager.default.removeItem(at: url)
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                return
            }
            throw DescriptiveMetadataWriteError.staleXMPSidecar(url)
        }
    }

    nonisolated func saveSidecar(metadata: IPTCMetadata, for imageURL: URL) throws {
        try saveSidecar(
            metadata: metadata,
            for: imageURL,
            writesLocalizedTitleClearTombstone: true
        )
    }

    nonisolated private func saveSidecar(
        metadata: IPTCMetadata,
        for imageURL: URL,
        writesLocalizedTitleClearTombstone: Bool
    ) throws {
        let url = sidecarURL(for: imageURL)
        // Merge into the existing sidecar so unknown third-party XMP (namespaces / properties we
        // don't model) is preserved by design — XMPData round-trips every property it parsed.
        var xmp = (try? XMPSidecar.read(from: url)) ?? XMPData()
        XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
        if let localizedTitles = metadata.localizedTitles {
            if localizedTitles.isEmpty, writesLocalizedTitleClearTombstone {
                xmp.setValue(
                    .simple("True"),
                    namespace: XMPDataBuilder.aaphotoNamespace,
                    property: localizedTitleClearedProperty
                )
            } else {
                xmp.removeValue(
                    namespace: XMPDataBuilder.aaphotoNamespace,
                    property: localizedTitleClearedProperty
                )
            }
        }
        // nil cameraRaw clears the crs block (matches the prior "nil = clear" contract).
        XMPDataBuilder.applyCameraRaw(
            metadata.cameraRaw,
            imageAspect: imageAspectIfCropAngled(for: imageURL, crop: metadata.cameraRaw?.crop),
            into: &xmp
        )
        xmp.creatorTool = SwiftExifWriteEngine.creatorTool
        try writeXMP(xmp, to: url)
    }

    /// Writes a descriptive-metadata record to the `.xmp` sidecar WITHOUT disturbing any develop
    /// (`crs`) block already on disk. `saveSidecar` treats a nil `cameraRaw` as "clear", which is
    /// wrong for descriptive writes (rating/label/orientation/keywords) whose metadata never carries
    /// `cameraRaw`; those callers must use this so a caption change doesn't wipe the user's edits.
    nonisolated func saveSidecarPreservingDevelopSettings(metadata: IPTCMetadata, for imageURL: URL) throws {
        var merged = metadata
        if merged.cameraRaw == nil {
            merged.cameraRaw = loadSidecar(for: imageURL)?.cameraRaw
        }
        try saveSidecar(metadata: merged, for: imageURL)
    }

    /// Complete serialized descriptive transaction. The existing XMP is read and mutated only
    /// after this photo's URL boundary has been acquired, so Develop/face/caption writes cannot
    /// interleave their read/merge/install phases. A content comparison immediately before the
    /// atomic install catches out-of-process edits and restarts the merge.
    /// `onlyIfExisting` checks existence inside that same transaction, including retries, and
    /// returns false without creating a sidecar when none exists. True means a record was installed.
    /// Embedded read-back mirrors may retain missing orientation from the current source revision;
    /// explicit embedded orientation still wins. Camera Raw properties always remain untouched.
    @discardableResult
    @MetadataSidecarFilesystemActor
    func saveSidecarPreservingDevelopSettingsSerialized(
        metadata: IPTCMetadata,
        for imageURL: URL,
        mergeWithExisting: Bool = false,
        imageSuppliersOverride: [EditorialImageSupplier]? = nil,
        onlyIfExisting: Bool = false,
        preserveExistingOrientationIfMissing: Bool = false,
        expectedSnapshot: XMPSidecarWriteSnapshot? = nil,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Bool {
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            try await self.updateXMPTransaction(
                for: imageURL,
                expectedSnapshot: expectedSnapshot,
                onlyIfExisting: onlyIfExisting,
                beforeRevisionCheck: beforeRevisionCheck
            ) { xmp in
                var record: IPTCMetadata
                if mergeWithExisting {
                    let existing = XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil })
                    record = existing.merged(preferring: metadata)
                } else {
                    record = metadata
                }
                // Explicit batch clear/replace intent must survive the nonempty-value merge.
                if let imageSuppliersOverride {
                    record.imageSuppliers = imageSuppliersOverride
                }
                if preserveExistingOrientationIfMissing, record.exifOrientation == nil {
                    let raw = xmp.tiffOrientation
                        ?? xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
                    record.exifOrientation = raw.flatMap(Int.init)
                }
                XMPDataBuilder.applyDescriptive(record, into: &xmp)
                if let localizedTitles = record.localizedTitles {
                    if localizedTitles.isEmpty {
                        xmp.setValue(
                            .simple("True"),
                            namespace: XMPDataBuilder.aaphotoNamespace,
                            property: localizedTitleClearedProperty
                        )
                    } else {
                        xmp.removeValue(
                            namespace: XMPDataBuilder.aaphotoNamespace,
                            property: localizedTitleClearedProperty
                        )
                    }
                }
                xmp.creatorTool = SwiftExifWriteEngine.creatorTool
            }
        }
    }

    /// Exact editorial restore used only while the caller owns this photo's MetadataIOCoordinator
    /// lock. Do not acquire that lock again here. Validate the pre-restore XMP revision and retain
    /// its opaque Develop data and both orientation carriers, including explicit absence.
    @MetadataSidecarFilesystemActor
    func restoreDescriptiveMetadataInHeldTransaction(
        _ metadata: IPTCMetadata,
        for imageURL: URL,
        expectedSnapshot: XMPSidecarWriteSnapshot,
        onInstalled: @Sendable (XMPSidecarWriteSnapshot) -> Void = { _ in }
    ) async throws {
        _ = try await updateXMPTransaction(for: imageURL, expectedSnapshot: expectedSnapshot,
            onInstalled: onInstalled) { xmp in
            let tiffOrientation = xmp.simpleValue(namespace: XMPNamespace.tiff, property: "Orientation")
            let exifOrientation = xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
            XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
            if let localizedTitles = metadata.localizedTitles {
                if localizedTitles.isEmpty {
                    xmp.setValue(.simple("True"), namespace: XMPDataBuilder.aaphotoNamespace,
                                 property: localizedTitleClearedProperty)
                } else {
                    xmp.removeValue(namespace: XMPDataBuilder.aaphotoNamespace,
                                    property: localizedTitleClearedProperty)
                }
            } else {
                xmp.removeValue(namespace: XMPNamespace.dc, property: "title")
                xmp.removeValue(namespace: XMPDataBuilder.aaphotoNamespace,
                                property: localizedTitleClearedProperty)
            }
            for (namespace, value) in [(XMPNamespace.tiff, tiffOrientation), (XMPNamespace.exif, exifOrientation)] {
                if let value {
                    xmp.setValue(.simple(value), namespace: namespace, property: "Orientation")
                } else {
                    xmp.removeValue(namespace: namespace, property: "Orientation")
                }
            }
            xmp.creatorTool = SwiftExifWriteEngine.creatorTool
        }
    }

    /// Completes an explicit metadata write while the caller owns the photo lock. Editorial
    /// fields form an exact record; technical fields change only with explicit captured intent.
    /// An embedded-only write may create a Develop-only sidecar without introducing an IPTC record.
    @MetadataSidecarFilesystemActor
    func writeMetadataInHeldTransaction(
        _ metadata: IPTCMetadata,
        for imageURL: URL,
        expectedSnapshot: XMPSidecarWriteSnapshot,
        onlyIfExisting: Bool,
        replaceDevelopSettings: Bool,
        replaceOrientation: Bool,
        onInstalled: @escaping @Sendable (XMPSidecarWriteSnapshot) -> Void = { _ in }
    ) async throws -> Bool {
        let technicalOnly = onlyIfExisting && expectedSnapshot.data == nil
        let createsTechnicalSidecar = replaceDevelopSettings && metadata.cameraRaw?.isEmpty == false
        return try await updateXMPTransaction(for: imageURL, expectedSnapshot: expectedSnapshot,
            onlyIfExisting: onlyIfExisting && !createsTechnicalSidecar, onInstalled: onInstalled) { xmp in
            let tiffOrientation = xmp.simpleValue(namespace: XMPNamespace.tiff, property: "Orientation")
            let exifOrientation = xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
            if !technicalOnly {
                XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
                if let titles = metadata.localizedTitles {
                    if titles.isEmpty {
                        xmp.setValue(.simple("True"), namespace: XMPDataBuilder.aaphotoNamespace,
                            property: localizedTitleClearedProperty)
                    } else {
                        xmp.removeValue(namespace: XMPDataBuilder.aaphotoNamespace,
                            property: localizedTitleClearedProperty)
                    }
                }
            }
            if replaceDevelopSettings {
                XMPDataBuilder.applyCameraRaw(metadata.cameraRaw,
                    imageAspect: self.imageAspectIfCropAngled(for: imageURL, crop: metadata.cameraRaw?.crop), into: &xmp)
            }
            for (namespace, previous) in [(XMPNamespace.tiff, tiffOrientation), (XMPNamespace.exif, exifOrientation)] {
                let value = replaceOrientation ? metadata.exifOrientation.map(String.init) : previous
                if let value {
                    xmp.setValue(.simple(value), namespace: namespace, property: "Orientation")
                } else {
                    xmp.removeValue(namespace: namespace, property: "Orientation")
                }
            }
            xmp.creatorTool = SwiftExifWriteEngine.creatorTool
        }
    }

    nonisolated func fieldMutationData(for imageURL: URL) throws -> Data? {
        let url = sidecarURL(for: imageURL)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
    }

    /// Caller owns the photo lock. Mutate a single physical field; never mirror a pending draft.
    @MetadataSidecarFilesystemActor
    func mutateFieldInHeldTransaction(_ mutation: MetadataPhysicalFieldMutation, for imageURL: URL,
        expectedSnapshot: XMPSidecarWriteSnapshot, embeddedBaseline: IPTCMetadata,
        onInstalled: @escaping @Sendable (XMPSidecarWriteSnapshot) -> Void
    ) async throws -> Bool {
        guard try fieldMutationData(for: imageURL) == expectedSnapshot.data else { throw MetadataFieldMutationConflict() }
        return try await updateXMPTransaction(for: imageURL, expectedSnapshot: expectedSnapshot,
            onInstalled: onInstalled) { xmp in
            if case .addPersons = mutation,
               !XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil }).hasDescriptiveContent {
                // PersonInImage makes this an authoritative descriptive XMP record. Seed from
                // actual embedded facts, never unrelated pending JSON, before adding that field.
                let orientation = xmp.tiffOrientation
                let exifOrientation = xmp.simpleValue(namespace: XMPNamespace.exif, property: "Orientation")
                let current = XMPMetadataReader.parseMetadata(from: xmp, imageAspect: { nil })
                // Existing rating, label, GPS and technical overlays remain authoritative when
                // adding the first descriptive field to an otherwise technical-only sidecar.
                let seed = embeddedBaseline.merged(preferring: current)
                XMPDataBuilder.applyDescriptive(seed, into: &xmp)
                if expectedSnapshot.data != nil {
                    for (namespace, value) in [(XMPNamespace.tiff, orientation), (XMPNamespace.exif, exifOrientation)] {
                        if let value { xmp.setValue(.simple(value), namespace: namespace, property: "Orientation") }
                        else { xmp.removeValue(namespace: namespace, property: "Orientation") }
                    }
                }
            }
            switch mutation {
            case .rating(let value): xmp.rating = Double(MetadataPhysicalFieldMutation.normalizedRating(value) ?? 0)
            case .label(let value): xmp.label = MetadataPhysicalFieldMutation.normalizedLabel(value) ?? ""
            case .orientation(_, let target):
                xmp.tiffOrientation = String(target)
                xmp.setValue(.simple(String(target)), namespace: XMPNamespace.exif, property: "Orientation")
            case .addPersons(let names):
                xmp.setValue(.array(MetadataPhysicalFieldMutation.add(names, to: xmp.personInImage)),
                    namespace: XMPNamespace.iptcExt, property: "PersonInImage")
            }
            xmp.creatorTool = SwiftExifWriteEngine.creatorTool
        }
    }

    /// Reads the batch baseline inside the per-photo transaction and replays the captured
    /// mutation after an external revision change. A queued edit cannot replace newer fields
    /// or Develop settings with the UI's stale batch record.
    @MetadataSidecarFilesystemActor
    func updateSidecarSerialized(
        for imageURL: URL,
        fallback: IPTCMetadata,
        beforeRevisionCheck: @escaping @Sendable (Int) -> Void = { _ in },
        mutation: @escaping @Sendable (inout IPTCMetadata) -> Void
    ) async throws -> IPTCMetadata {
        try Task.checkCancellation()
        return try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            let url = self.sidecarURL(for: imageURL)
            for attempt in 0..<Self.transactionRetryLimit {
                let sourceData = try Self.currentData(at: url)
                var xmp = try sourceData.map { try XMPReader.readFromXML($0) } ?? XMPData()
                var metadata = sourceData == nil ? fallback : XMPMetadataReader.parseMetadata(
                    from: xmp, imageAspect: { ImagePixelAspect.aspect(at: imageURL) }
                )
                mutation(&metadata)
                XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
                if let titles = metadata.localizedTitles {
                    if titles.isEmpty {
                        xmp.setValue(.simple("True"), namespace: XMPDataBuilder.aaphotoNamespace,
                                     property: localizedTitleClearedProperty)
                    } else {
                        xmp.removeValue(namespace: XMPDataBuilder.aaphotoNamespace,
                                        property: localizedTitleClearedProperty)
                    }
                }
                XMPDataBuilder.applyCameraRaw(
                    metadata.cameraRaw,
                    imageAspect: self.imageAspectIfCropAngled(for: imageURL, crop: metadata.cameraRaw?.crop),
                    into: &xmp
                )
                xmp.creatorTool = SwiftExifWriteEngine.creatorTool
                let staged = Data(XMPWriter.generateXML(xmp).utf8)
                _ = try XMPReader.readFromXML(staged)
                beforeRevisionCheck(attempt)
                await Task.yield()
                guard try Self.currentData(at: url) == sourceData else { continue }
                try staged.write(to: url, options: .atomic)
                let installed = try Data(contentsOf: url)
                guard installed == staged else { throw CocoaError(.fileWriteUnknown) }
                return XMPMetadataReader.parseMetadata(
                    from: try XMPReader.readFromXML(installed),
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) }
                )
            }
            throw DescriptiveMetadataWriteError.staleXMPSidecar(url)
        }
    }

    /// Complete serialized full-record transaction for workflows that intentionally own both the
    /// descriptive and Develop portions of the sidecar.
    @MetadataSidecarFilesystemActor
    func saveSidecarSerialized(
        metadata: IPTCMetadata,
        for imageURL: URL
    ) async throws {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            _ = try await self.updateXMPTransaction(for: imageURL) { xmp in
                XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
                if let localizedTitles = metadata.localizedTitles {
                    if localizedTitles.isEmpty {
                        xmp.setValue(
                            .simple("True"),
                            namespace: XMPDataBuilder.aaphotoNamespace,
                            property: localizedTitleClearedProperty
                        )
                    } else {
                        xmp.removeValue(
                            namespace: XMPDataBuilder.aaphotoNamespace,
                            property: localizedTitleClearedProperty
                        )
                    }
                }
                XMPDataBuilder.applyCameraRaw(
                    metadata.cameraRaw,
                    imageAspect: self.imageAspectIfCropAngled(
                        for: imageURL,
                        crop: metadata.cameraRaw?.crop
                    ),
                    into: &xmp
                )
                xmp.creatorTool = SwiftExifWriteEngine.creatorTool
            }
        }
    }

    /// Complete serialized Develop transaction. Descriptive and third-party namespaces are
    /// retained from the source revision used for this attempt.
    @MetadataSidecarFilesystemActor
    func saveCameraRawOnlySerialized(
        _ settings: CameraRawSettings?,
        orientation: Int?,
        for imageURL: URL
    ) async throws {
        try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) { @MetadataSidecarFilesystemActor in
            _ = try await self.updateXMPTransaction(for: imageURL) { xmp in
                if let settings, !settings.isEmpty {
                    XMPDataBuilder.applyCameraRaw(
                        settings,
                        imageAspect: self.imageAspectIfCropAngled(for: imageURL, crop: settings.crop),
                        into: &xmp
                    )
                    if let orientation {
                        let value = String(orientation)
                        xmp.setValue(.simple(value), namespace: XMPNamespace.tiff, property: "Orientation")
                        xmp.setValue(.simple(value), namespace: XMPNamespace.exif, property: "Orientation")
                    }
                    xmp.creatorTool = SwiftExifWriteEngine.creatorTool
                } else {
                    XMPDataBuilder.removeCRSBlock(&xmp)
                }
            }
        }
    }

    func saveCameraRawOnly(_ settings: CameraRawSettings?, orientation: Int?, for imageURL: URL) throws {
        let url = sidecarURL(for: imageURL)
        if let settings, !settings.isEmpty {
            var xmp = (try? XMPSidecar.read(from: url)) ?? XMPData()
            XMPDataBuilder.applyCameraRaw(
                settings,
                imageAspect: imageAspectIfCropAngled(for: imageURL, crop: settings.crop),
                into: &xmp
            )
            if let orientation {
                let value = String(orientation)
                xmp.setValue(.simple(value), namespace: XMPNamespace.tiff, property: "Orientation")
                xmp.setValue(.simple(value), namespace: XMPNamespace.exif, property: "Orientation")
            }
            xmp.creatorTool = SwiftExifWriteEngine.creatorTool
            try writeXMP(xmp, to: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            var xmp = (try? XMPSidecar.read(from: url)) ?? XMPData()
            XMPDataBuilder.removeCRSBlock(&xmp)
            try writeXMP(xmp, to: url)
        }
    }

    // MARK: - Write

    nonisolated private func writeXMP(_ xmp: XMPData, to url: URL) throws {
        let xml = XMPWriter.generateXML(xmp)
        guard let data = xml.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        // `.atomic` keeps the sidecar crash-safe (XMPSidecar.write is a plain non-atomic write).
        try data.write(to: url, options: .atomic)
    }

    /// Read/merge/revision-check/stage/install/read-back loop used by every new asynchronous XMP
    /// entry point. `Task.yield()` is intentional: it gives file presenters and external editors a
    /// chance to publish a pending replacement before the content-token check.
    @discardableResult
    @MetadataSidecarFilesystemActor
    private func updateXMPTransaction(
        for imageURL: URL,
        expectedSnapshot: XMPSidecarWriteSnapshot? = nil,
        onlyIfExisting: Bool = false,
        beforeRevisionCheck: @Sendable (Int) -> Void = { _ in },
        onInstalled: @Sendable (XMPSidecarWriteSnapshot) -> Void = { _ in },
        mutation: @Sendable (inout XMPData) -> Void
    ) async throws -> Bool {
        let url = sidecarURL(for: imageURL)
        for attempt in 0..<Self.transactionRetryLimit {
            let sourceData = try Self.currentData(at: url)
            if let expectedSnapshot, sourceData != expectedSnapshot.data {
                throw DescriptiveMetadataWriteError.staleXMPSidecar(url)
            }
            // Re-evaluate on every retry: an external deletion must not recreate the sidecar.
            guard !onlyIfExisting || sourceData != nil else { return false }
            var xmp: XMPData
            if let sourceData {
                xmp = try XMPReader.readFromXML(sourceData)
            } else {
                xmp = XMPData()
            }
            mutation(&xmp)

            let xml = XMPWriter.generateXML(xmp)
            guard let stagedData = xml.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            // Validate the staged schema before it can replace the recoverable source bytes.
            _ = try XMPReader.readFromXML(stagedData)

            beforeRevisionCheck(attempt)
            await Task.yield()
            guard try Self.currentData(at: url) == sourceData else { continue }

            try stagedData.write(to: url, options: .atomic)
            onInstalled(XMPSidecarWriteSnapshot(data: stagedData))
            let installedData = try Data(contentsOf: url)
            guard installedData == stagedData else {
                throw CocoaError(.fileWriteUnknown)
            }
            _ = try XMPReader.readFromXML(installedData)
            return true
        }
        throw DescriptiveMetadataWriteError.staleXMPSidecar(url)
    }

    private nonisolated static func currentData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Sensor-frame aspect for the ACR crop-convention conversion — read from the image header only
    /// when the crop is angled (the conversion is the identity at angle 0, so straight crops skip
    /// the file I/O).
    nonisolated private func imageAspectIfCropAngled(for imageURL: URL, crop: CameraRawCrop?) -> Double? {
        guard let crop, abs(crop.angle ?? 0) > 0.0001 else { return nil }
        return ImagePixelAspect.aspect(at: imageURL)
    }
}
