import Foundation
import os

nonisolated private let xmpLog = Logger(subsystem: "com.aagedal.photo-agent", category: "XMPSidecarService")

struct XMPSidecarService: Sendable {
    private enum Namespace {
        static let x = "adobe:ns:meta/"
        static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        static let dc = "http://purl.org/dc/elements/1.1/"
        static let xmp = "http://ns.adobe.com/xap/1.0/"
        static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        static let iptcExt = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
        static let tiff = "http://ns.adobe.com/tiff/1.0/"
        static let exif = "http://ns.adobe.com/exif/1.0/"
        static let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
        /// App-private namespace for settings Adobe's schema can't represent (e.g. the
        /// reorderable-global layer chain). Adobe tools ignore unknown namespaces.
        static let aaphoto = "http://aagedal.me/ns/photo/1.0/"
    }

    private enum XMPPacket {
        static let id = "W5M0MpCehiHzreSzNTczkc9d"
        static let bom = "\u{FEFF}"
    }

    nonisolated func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    nonisolated func sidecarExists(for imageURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: sidecarURL(for: imageURL).path)
    }

    func loadSidecar(for imageURL: URL) -> IPTCMetadata? {
        guard let data = sidecarDataIfExists(for: imageURL) else { return nil }
        return loadSidecar(fromData: data, imageAspect: { ImagePixelAspect.aspect(at: imageURL) })
    }

    /// Reads the sidecar file's bytes if it exists. Pure file I/O — safe to call
    /// off the main actor (and intended to be, since `Data(contentsOf:)` can stall
    /// on iCloud-not-downloaded files).
    nonisolated func sidecarDataIfExists(for imageURL: URL) -> Data? {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Nonisolated, lightweight read of just the display orientation from the `.xmp`
    /// sidecar — `tiff:Orientation` (Adobe's authoritative tag), falling back to
    /// `exif:Orientation`. For off-main thumbnail generation, which needs only the
    /// orientation and must not touch the MainActor-isolated full parse. Returns nil
    /// when there's no sidecar or it carries no orientation. Reads both the attribute
    /// form (how we and ACR write it) and the child-element form.
    nonisolated func sidecarOrientation(for imageURL: URL) -> Int? {
        guard let data = sidecarDataIfExists(for: imageURL) else { return nil }
        // Keep the parsed NSXML tree's temporaries inside an explicit pool (see saveSidecar).
        return autoreleasepool { () -> Int? in
            guard let document = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]),
                  let description = (try? document.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement
            else { return nil }

            func value(_ localName: String, _ prefix: String) -> String? {
                if let attr = description.attribute(forName: "\(prefix):\(localName)")?.stringValue { return attr }
                let child = description.elements(forName: "\(prefix):\(localName)").first
                return child?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let raw = value("Orientation", "tiff") ?? value("Orientation", "exif")
            return raw.flatMap { Int($0) }
        }
    }

    /// Parses already-read XMP bytes into IPTCMetadata. Cheap — call on the main
    /// actor after preloading bytes off-main via `sidecarDataIfExists`.
    /// `imageAspect` supplies the image's sensor-frame width/height ratio for the
    /// ACR crop-convention conversion; it is only invoked when the sidecar
    /// carries an angled crop (an angled crop without it stays in Adobe's
    /// corner convention, i.e. wrong — pass it whenever the image is known).
    func loadSidecar(fromData data: Data, imageAspect: () -> Double? = { nil }) -> IPTCMetadata? {
        // Contain the parsed NSXML tree's autoreleased temporaries in an explicit pool — on the
        // main actor they would otherwise drain at the job boundary (see saveSidecar). Only the
        // value-type IPTCMetadata escapes.
        autoreleasepool {
            guard let document = parseXMLDocument(from: data) else { return nil }
            guard let description = findDescription(in: document) else { return nil }
            return parseMetadata(from: description, imageAspect: imageAspect)
        }
    }

    /// Removes all IPTC/descriptive metadata from the sidecar while preserving
    /// Camera Raw edit settings. Deletes the sidecar entirely if no edit settings remain.
    func stripIPTCFromSidecar(for imageURL: URL) {
        let url = sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard let metadata = loadSidecar(for: imageURL) else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                xmpLog.warning("Failed to remove unreadable XMP sidecar for \(imageURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if let cameraRaw = metadata.cameraRaw, !cameraRaw.isEmpty {
            let editOnly = IPTCMetadata(cameraRaw: cameraRaw, exifOrientation: metadata.exifOrientation)
            do {
                try saveSidecar(metadata: editOnly, for: imageURL)
            } catch {
                xmpLog.error("Failed to save stripped XMP sidecar for \(imageURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                xmpLog.warning("Failed to remove empty XMP sidecar for \(imageURL.lastPathComponent): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func saveSidecar(metadata: IPTCMetadata, for imageURL: URL) throws {
        let url = sidecarURL(for: imageURL)
        // Build + serialize the NSXML tree inside an explicit autoreleasepool. The write runs
        // in a @MainActor Task whose autoreleased NSXML temporaries would otherwise drain at
        // the main-queue job boundary (after the local document is gone), over-releasing nodes
        // — a crash in `objc_autoreleasePoolPop`. Draining them synchronously here avoids it;
        // only the value-type Data escapes the pool.
        let data: Data = try autoreleasepool {
            let document = try loadOrCreateDocument(at: url)
            let description = ensureDescription(in: document)
            ensureNamespaces(on: description)
            updateDescription(
                description,
                with: metadata,
                imageAspect: imageAspectIfCropAngled(for: imageURL, crop: metadata.cameraRaw?.crop)
            )
            return serializeXMP(document)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Writes a descriptive-metadata record to the `.xmp` sidecar WITHOUT disturbing
    /// any develop (`crs`) block already on disk.
    ///
    /// `saveSidecar(metadata:)` rebuilds the whole sidecar and treats a nil
    /// `cameraRaw` as "clear", stripping the crs block. That's correct for the
    /// develop editor (where nil genuinely means the user removed all edits), but
    /// wrong for descriptive writes — rating, label, orientation, keywords, batch
    /// edits — whose `metadata` is sourced from the JSON sidecar or the image file
    /// and therefore NEVER carries `cameraRaw`. Those callers must use this method so
    /// a caption change doesn't wipe the user's exposure/crop/mask edits. Develop
    /// edits are cleared explicitly via `saveCameraRawOnly(nil, …)`, never here.
    func saveSidecarPreservingDevelopSettings(metadata: IPTCMetadata, for imageURL: URL) throws {
        var merged = metadata
        if merged.cameraRaw == nil {
            merged.cameraRaw = loadSidecar(for: imageURL)?.cameraRaw
        }
        try saveSidecar(metadata: merged, for: imageURL)
    }

    func saveCameraRawOnly(_ settings: CameraRawSettings?, orientation: Int?, for imageURL: URL) throws {
        let url = sidecarURL(for: imageURL)
        // NSXML build+serialize stays inside an autoreleasepool — see saveSidecar for why.
        if let settings, !settings.isEmpty {
            let data: Data = try autoreleasepool {
                let document = try loadOrCreateDocument(at: url)
                let description = ensureDescription(in: document)
                ensureNamespaces(on: description)
                updateCameraRawSettings(
                    on: description,
                    settings: settings,
                    imageAspect: imageAspectIfCropAngled(for: imageURL, crop: settings.crop)
                )
                if let orientation {
                    setOrientation(on: description, value: orientation)
                }
                return serializeXMP(document)
            }
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            let data: Data = try autoreleasepool {
                let document = try loadOrCreateDocument(at: url)
                let description = ensureDescription(in: document)
                removeCameraRawSettings(from: description)
                return serializeXMP(document)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    /// Sensor-frame aspect for the ACR crop-convention conversion — read from the
    /// image header only when the crop is angled (the conversion is the identity
    /// at angle 0, so straight crops skip the file I/O).
    private func imageAspectIfCropAngled(for imageURL: URL, crop: CameraRawCrop?) -> Double? {
        guard let crop, abs(crop.angle ?? 0) > 0.0001 else { return nil }
        return ImagePixelAspect.aspect(at: imageURL)
    }

    // MARK: - Document Helpers

    private func loadOrCreateDocument(at url: URL) throws -> XMLDocument {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let document = parseXMLDocument(from: data) { return document }
        }
        return createEmptyDocument()
    }

    private func createEmptyDocument() -> XMLDocument {
        let xmpmeta = XMLElement(name: "x:xmpmeta")
        ensureNamespace(xmpmeta, prefix: "x", uri: Namespace.x)
        ensureToolkitAttribute(on: xmpmeta)

        let rdf = XMLElement(name: "rdf:RDF")
        ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)

        xmpmeta.addChild(rdf)

        let description = XMLElement(name: "rdf:Description")
        if let aboutAttr = XMLNode.attribute(withName: "rdf:about", stringValue: "") as? XMLNode {
            description.addAttribute(aboutAttr)
        }
        ensureNamespaces(on: description)
        rdf.addChild(description)

        let document = XMLDocument(rootElement: xmpmeta)
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        return document
    }

    private func ensureDescription(in document: XMLDocument) -> XMLElement {
        if let description = findDescription(in: document) {
            return description
        }

        let rdf = ensureRdfRoot(in: document)
        let description = XMLElement(name: "rdf:Description")
        if let aboutAttr = XMLNode.attribute(withName: "rdf:about", stringValue: "") as? XMLNode {
            description.addAttribute(aboutAttr)
        }
        ensureNamespaces(on: description)
        rdf.addChild(description)
        return description
    }

    private func ensureRdfRoot(in document: XMLDocument) -> XMLElement {
        if let rdf = findFirstElement(in: document, localName: "RDF", namespace: Namespace.rdf) {
            return rdf
        }

        let root = document.rootElement() ?? {
            let xmpmeta = XMLElement(name: "x:xmpmeta")
            ensureNamespace(xmpmeta, prefix: "x", uri: Namespace.x)
            ensureToolkitAttribute(on: xmpmeta)
            document.setRootElement(xmpmeta)
            return xmpmeta
        }()

        let rdf = XMLElement(name: "rdf:RDF")
        ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)
        root.addChild(rdf)
        return rdf
    }

    private func findDescription(in document: XMLDocument) -> XMLElement? {
        findFirstElement(in: document, localName: "Description", namespace: Namespace.rdf)
    }

    private func findFirstElement(in node: XMLNode, localName: String, namespace: String) -> XMLElement? {
        if let element = node as? XMLElement,
           element.localName == localName,
           element.uri == namespace {
            return element
        }

        for child in node.children ?? [] {
            if let match = findFirstElement(in: child, localName: localName, namespace: namespace) {
                return match
            }
        }
        return nil
    }

    private func ensureNamespaces(on description: XMLElement) {
        ensureNamespace(description, prefix: "dc", uri: Namespace.dc)
        ensureNamespace(description, prefix: "xmp", uri: Namespace.xmp)
        ensureNamespace(description, prefix: "photoshop", uri: Namespace.photoshop)
        ensureNamespace(description, prefix: "Iptc4xmpCore", uri: Namespace.iptcCore)
        ensureNamespace(description, prefix: "Iptc4xmpExt", uri: Namespace.iptcExt)
        ensureNamespace(description, prefix: "exif", uri: Namespace.exif)
        ensureNamespace(description, prefix: "tiff", uri: Namespace.tiff)
        ensureNamespace(description, prefix: "crs", uri: Namespace.crs)
        ensureNamespace(description, prefix: "aaphoto", uri: Namespace.aaphoto)
        if let rdf = description.parent as? XMLElement {
            ensureNamespace(rdf, prefix: "rdf", uri: Namespace.rdf)
        }
    }

    private func ensureNamespace(_ element: XMLElement, prefix: String, uri: String) {
        if element.namespace(forPrefix: prefix) == nil {
            if let ns = XMLNode.namespace(withName: prefix, stringValue: uri) as? XMLNode {
                element.addNamespace(ns)
            }
        }
    }

    private func ensureToolkitAttribute(on element: XMLElement) {
        guard element.localName == "xmpmeta" else { return }
        ensureNamespace(element, prefix: "x", uri: Namespace.x)
        if element.attribute(forName: "x:xmptk") == nil {
            if let tkAttr = XMLNode.attribute(withName: "x:xmptk", stringValue: "Aagedal Photo Agent") as? XMLNode {
                element.addAttribute(tkAttr)
            }
        }
    }

    private func serializeXMP(_ document: XMLDocument) -> Data {
        if let root = document.rootElement() {
            ensureToolkitAttribute(on: root)
        }

        let body = document.rootElement()?.xmlString(options: [.nodePrettyPrint])
            ?? document.xmlString(options: [.nodePrettyPrint])
        let packet = [
            "<?xpacket begin=\"\(XMPPacket.bom)\" id=\"\(XMPPacket.id)\"?>",
            body,
            "<?xpacket end=\"w\"?>"
        ].joined(separator: "\n")

        return packet.data(using: .utf8) ?? Data()
    }

    private func parseXMLDocument(from data: Data) -> XMLDocument? {
        if let document = try? XMLDocument(data: data, options: [.nodePreserveAll]) {
            return document
        }

        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = stripXPacket(from: xml)
        guard let cleanedData = cleaned.data(using: .utf8) else { return nil }
        return try? XMLDocument(data: cleanedData, options: [.nodePreserveAll])
    }

    private func stripXPacket(from xml: String) -> String {
        var cleaned = xml
        let pattern = "<\\?xpacket[^>]*\\?>"
        while let range = cleaned.range(of: pattern, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Update

    private func updateDescription(_ description: XMLElement, with metadata: IPTCMetadata, imageAspect: Double?) {
        setSimple(on: description, prefix: "photoshop", localName: "Headline", value: metadata.title)
        setAltText(on: description, prefix: "dc", localName: "title", value: metadata.title)
        setAltText(on: description, prefix: "dc", localName: "description", value: metadata.description)
        setAltText(on: description, prefix: "Iptc4xmpCore", localName: "ExtDescrAccessibility", value: metadata.extendedDescription)
        setBag(on: description, prefix: "dc", localName: "subject", values: metadata.keywords)
        setBag(on: description, prefix: "Iptc4xmpExt", localName: "PersonInImage", values: metadata.personShown)
        setSimple(on: description, prefix: "xmp", localName: "Rating", value: metadata.rating.map(String.init))
        setSimple(on: description, prefix: "xmp", localName: "Label", value: metadata.label)
        setSimple(on: description, prefix: "Iptc4xmpExt", localName: "DigitalSourceType", value: metadata.digitalSourceType?.rawValue)
        setSeq(on: description, prefix: "dc", localName: "creator", values: metadata.creator.map { [$0] } ?? [])
        setSimple(on: description, prefix: "photoshop", localName: "Credit", value: metadata.credit)
        setSimple(on: description, prefix: "photoshop", localName: "TransmissionReference", value: metadata.jobId)
        setAltText(on: description, prefix: "dc", localName: "rights", value: metadata.copyright)
        setSimple(on: description, prefix: "photoshop", localName: "DateCreated", value: metadata.dateCreated)
        setSimple(on: description, prefix: "photoshop", localName: "City", value: metadata.city)
        setSimple(on: description, prefix: "photoshop", localName: "Country", value: metadata.country)
        setSimple(on: description, prefix: "Iptc4xmpExt", localName: "Event", value: metadata.event)

        if let lat = metadata.latitude, let lon = metadata.longitude {
            setSimple(on: description, prefix: "exif", localName: "GPSLatitude", value: String(format: "%.6f", lat))
            setSimple(on: description, prefix: "exif", localName: "GPSLongitude", value: String(format: "%.6f", lon))
        } else {
            setSimple(on: description, prefix: "exif", localName: "GPSLatitude", value: nil)
            setSimple(on: description, prefix: "exif", localName: "GPSLongitude", value: nil)
        }

        setOrientation(on: description, value: metadata.exifOrientation)

        updateCameraRawSettings(on: description, settings: metadata.cameraRaw, imageAspect: imageAspect)
    }

    private func updateCameraRawSettings(on description: XMLElement, settings: CameraRawSettings?, imageAspect: Double?) {
        guard let settings else {
            removeCameraRawSettings(from: description)
            return
        }

        // ACR requires Version and ProcessVersion to recognize settings.
        setSimple(on: description, prefix: "crs", localName: "Version", value: settings.version ?? "15.4")
        setSimple(on: description, prefix: "crs", localName: "ProcessVersion", value: settings.processVersion ?? "15.4")
        setSimple(on: description, prefix: "crs", localName: "WhiteBalance", value: settings.whiteBalance)
        setSimple(on: description, prefix: "crs", localName: "Temperature", value: settings.temperature.map(String.init))
        setSimple(on: description, prefix: "crs", localName: "Tint", value: settings.tint.map(formatSignedInt))
        setSimple(
            on: description,
            prefix: "crs",
            localName: "IncrementalTemperature",
            value: settings.incrementalTemperature.map(formatSignedInt)
        )
        setSimple(
            on: description,
            prefix: "crs",
            localName: "IncrementalTint",
            value: settings.incrementalTint.map(formatSignedInt)
        )
        setSimple(
            on: description,
            prefix: "crs",
            localName: "Exposure2012",
            value: settings.exposure2012.map { formatSignedDouble($0, precision: 2) }
        )
        setSimple(on: description, prefix: "crs", localName: "Contrast2012", value: settings.contrast2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Highlights2012", value: settings.highlights2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Shadows2012", value: settings.shadows2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Whites2012", value: settings.whites2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Blacks2012", value: settings.blacks2012.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Saturation", value: settings.saturation.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "Vibrance", value: settings.vibrance.map(formatSignedInt))

        // HSL per-color adjustments (ACR-compatible tags + custom SkinTone).
        // Clear every channel, then set the present ones via the shared encoder
        // so the sidecar and embedded-file HSL encodings can't drift.
        let hslValues = Dictionary(
            uniqueKeysWithValues: (settings.hslAdjustments.map(encodeHSLAdjustments) ?? [])
                .map { ($0.name, $0.value) }
        )
        for name in acrHSLPropertyNames {
            setSimple(on: description, prefix: "crs", localName: name, value: hslValues[name])
        }

        let hasSettings = settings.hasSettings ?? !settings.isEmpty
        setSimple(on: description, prefix: "crs", localName: "HasSettings", value: formatBool(hasSettings))

        // crs fields carry Adobe's un-rotated-frame corner encoding, not the
        // app's upright rect — convert at this write boundary (identity at angle 0).
        let crop = settings.crop?.encodedForACR(aspect: imageAspect)
        let hasCrop: Bool? = {
            guard let crop else { return nil }
            return crop.hasCrop ?? !crop.isEmpty
        }()
        setSimple(on: description, prefix: "crs", localName: "CropTop", value: crop?.top.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropLeft", value: crop?.left.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropBottom", value: crop?.bottom.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropRight", value: crop?.right.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "CropAngle", value: crop?.angle.map { formatUnsignedDouble($0, precision: 6) })
        setSimple(on: description, prefix: "crs", localName: "HasCrop", value: hasCrop.map(formatBool))
        setSimple(on: description, prefix: "crs", localName: "CropConstrainToWarp", value: hasCrop == true ? "0" : nil)
        setSimple(on: description, prefix: "crs", localName: "CropConstrainToUnitSquare", value: hasCrop == true ? "1" : nil)

        setSimple(on: description, prefix: "crs", localName: "HDREditMode", value: settings.hdrEditMode.map(String.init))
        setSimple(on: description, prefix: "crs", localName: "HDRMaxValue", value: settings.hdrMaxValue)
        setSimple(on: description, prefix: "crs", localName: "SDRBrightness", value: settings.sdrBrightness.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "SDRContrast", value: settings.sdrContrast.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "SDRClarity", value: settings.sdrClarity.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "SDRHighlights", value: settings.sdrHighlights.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "SDRShadows", value: settings.sdrShadows.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "SDRWhites", value: settings.sdrWhites.map(formatSignedInt))
        setSimple(on: description, prefix: "crs", localName: "SDRBlend", value: settings.sdrBlend.map(formatSignedInt))

        // Tone curve: stored as rdf:Seq of "x, y" strings in 0-255 scale (Adobe ACR format)
        updateToneCurveChannel(on: description, localName: "ToneCurvePV2012", points: settings.toneCurve?.master)
        updateToneCurveChannel(on: description, localName: "ToneCurvePV2012Red", points: settings.toneCurve?.red)
        updateToneCurveChannel(on: description, localName: "ToneCurvePV2012Green", points: settings.toneCurve?.green)
        updateToneCurveChannel(on: description, localName: "ToneCurvePV2012Blue", points: settings.toneCurve?.blue)
        let hasCustomCurve = settings.toneCurve != nil && !(settings.toneCurve?.isEmpty ?? true)
        setSimple(on: description, prefix: "crs", localName: "ToneCurveName2012", value: hasCustomCurve ? "Custom" : nil)

        // Masks are written exactly as ACR would — in render-stack order — so the crs block
        // stays fully ACR-compatible and Adobe honors the user's mask stacking.
        updateMaskCorrections(on: description, masks: settings.masksInRenderOrder())

        // ACR has no global-adjustment node, so the ONLY thing we add is where Global sits in
        // the stack: the number of masks that precede it. 0 (global first) is canonical and
        // written as absent. The masks themselves come back from the crs block on read.
        setSimple(on: description, prefix: "aaphoto", localName: "GlobalLayerIndex",
                  value: settings.globalLayerIndex().flatMap { $0 > 0 ? String($0) : nil })
    }

    /// Rebuilds `layerOrder` from the crs mask order (already in render-stack order) plus the
    /// stored `GlobalLayerIndex`. nil when the tag is absent ⇒ canonical global-first.
    private func reconstructLayerOrder(masks: [MaskAdjustment]?, from description: XMLElement) -> [LayerRef]? {
        guard let raw = parseSimple(from: description, prefix: "aaphoto", localName: "GlobalLayerIndex"),
              let index = Int(raw) else { return nil }
        return CameraRawSettings.layerOrder(masks: masks, globalIndex: index)
    }

    /// Write local mask adjustments as ACR's `crs:MaskGroupBasedCorrections`,
    /// mirroring Adobe's own sidecar shape: an rdf:Seq whose items carry the
    /// correction fields in attribute form, with the nested `CorrectionMasks`
    /// array as a child element. Field content comes from the shared
    /// `encodeMaskGroupBasedCorrections` (also used by the embedded-XMP writer).
    private func updateMaskCorrections(on description: XMLElement, masks: [MaskAdjustment]?) {
        removeProperty(from: description, prefix: "crs", localName: "MaskGroupBasedCorrections")
        let corrections = encodeMaskGroupBasedCorrections(masks ?? [])
        guard !corrections.isEmpty else { return }

        let property = XMLElement(name: "crs:MaskGroupBasedCorrections")
        let seq = XMLElement(name: "rdf:Seq")
        for correction in corrections {
            let li = XMLElement(name: "rdf:li")
            let item = XMLElement(name: "rdf:Description")
            for (name, value) in correction.correctionFields {
                if let attr = XMLNode.attribute(withName: "crs:\(name)", stringValue: value) as? XMLNode {
                    item.addAttribute(attr)
                }
            }

            let masksProperty = XMLElement(name: "crs:CorrectionMasks")
            let maskSeq = XMLElement(name: "rdf:Seq")
            let maskLi = XMLElement(name: "rdf:li")
            for (name, value) in correction.maskFields {
                if let attr = XMLNode.attribute(withName: "crs:\(name)", stringValue: value) as? XMLNode {
                    maskLi.addAttribute(attr)
                }
            }
            maskSeq.addChild(maskLi)
            masksProperty.addChild(maskSeq)
            item.addChild(masksProperty)
            li.addChild(item)
            seq.addChild(li)
        }
        property.addChild(seq)
        description.addChild(property)

        // ACR ignores every crs setting in a block marked AlreadyApplied=True,
        // and Bridge/ACR only badge a file as edited when the marker is
        // EXPLICITLY False (see SwiftExifWriteEngine.applyMasks).
        setSimple(on: description, prefix: "crs", localName: "AlreadyApplied", value: "False")
        setSimple(on: description, prefix: "crs", localName: "CompatibleVersion", value: "234881024")
    }

    private func removeCameraRawSettings(from description: XMLElement) {
        let fields = [
            "Version",
            "ProcessVersion",
            "WhiteBalance",
            "Temperature",
            "Tint",
            "IncrementalTemperature",
            "IncrementalTint",
            "Exposure2012",
            "Contrast2012",
            "Highlights2012",
            "Shadows2012",
            "Whites2012",
            "Blacks2012",
            "Saturation",
            "Vibrance",
            "HasSettings",
            "CropTop",
            "CropLeft",
            "CropBottom",
            "CropRight",
            "CropAngle",
            "HasCrop",
            "CropConstrainToWarp",
            "CropConstrainToUnitSquare",
            "HDREditMode",
            "HDRMaxValue",
            "SDRBrightness",
            "SDRContrast",
            "SDRClarity",
            "SDRHighlights",
            "SDRShadows",
            "SDRWhites",
            "SDRBlend",
            "ToneCurvePV2012",
            "ToneCurvePV2012Red",
            "ToneCurvePV2012Green",
            "ToneCurvePV2012Blue",
            "ToneCurveName2012",
            "MaskGroupBasedCorrections",
            "AlreadyApplied",
            "CompatibleVersion",
        ] + acrHSLPropertyNames // HSL per-color adjustments
        for field in fields {
            removeProperty(from: description, prefix: "crs", localName: field)
        }
    }

    private func updateToneCurveChannel(on description: XMLElement, localName: String, points: [ToneCurvePoint]?) {
        if let points, points.count > 2 {
            let strings = serializeToneCurvePoints(points)
            setSeq(on: description, prefix: "crs", localName: localName, values: strings)
        } else {
            removeProperty(from: description, prefix: "crs", localName: localName)
        }
    }

    /// Parse `crs:MaskGroupBasedCorrections` back into `[MaskAdjustment]` by
    /// converting the rdf:Seq items into bare-key dictionaries and reusing the
    /// shared `parseMaskGroupBasedCorrections` decoder.
    private func parseMaskCorrections(from description: XMLElement) -> [MaskAdjustment]? {
        guard let property = childElement(from: description, prefix: "crs", localName: "MaskGroupBasedCorrections"),
              let seq = childElement(from: property, prefix: "rdf", localName: "Seq") else {
            return nil
        }
        let corrections = childElements(from: seq, prefix: "rdf", localName: "li").map(structFields(from:))
        return parseMaskGroupBasedCorrections(corrections)
    }

    /// Flatten an rdf:Seq struct item into a bare-key dictionary. Accepts both
    /// shapes ACR emits: fields as attributes directly on rdf:li, or on a
    /// wrapped rdf:Description. Child elements holding nested rdf:Seq arrays
    /// (e.g. `CorrectionMasks`) recurse into arrays of dictionaries; simple
    /// element-form fields become their string values.
    private func structFields(from li: XMLElement) -> [String: Any] {
        let node = childElement(from: li, prefix: "rdf", localName: "Description") ?? li
        var fields: [String: Any] = [:]

        for attribute in node.attributes ?? [] {
            let name = attribute.name ?? ""
            guard let localName = attribute.localName,
                  let value = attribute.stringValue,
                  attribute.uri != Namespace.rdf,
                  !name.hasPrefix("xmlns"), !name.hasPrefix("xml:") else { continue }
            fields[localName] = value
        }

        for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
            guard let localName = child.localName, child.uri != Namespace.rdf else { continue }
            if let seq = childElement(from: child, prefix: "rdf", localName: "Seq") {
                fields[localName] = childElements(from: seq, prefix: "rdf", localName: "li").map(structFields(from:))
            } else if let value = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                fields[localName] = value
            }
        }

        return fields
    }

    private func parseToneCurveChannel(from description: XMLElement, localName: String) -> [ToneCurvePoint]? {
        let strings = parseSeq(from: description, prefix: "crs", localName: localName)
        guard !strings.isEmpty else { return nil }
        let points = strings.compactMap { str -> ToneCurvePoint? in
            let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]) else { return nil }
            return ToneCurvePoint(acr255: x, y)
        }
        return points.isEmpty ? nil : points
    }

    private func formatSignedInt(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func formatSignedDouble(_ value: Double, precision: Int) -> String {
        let absFormat = "%.\(precision)f"
        let absValue = String(format: absFormat, abs(value))
        if value > 0 { return "+\(absValue)" }
        if value < 0 { return "-\(absValue)" }
        return absValue
    }

    private func formatUnsignedDouble(_ value: Double, precision: Int) -> String {
        String(format: "%.\(precision)f", value)
    }

    private func formatBool(_ value: Bool) -> String {
        value ? "True" : "False"
    }

    /// Writes orientation to BOTH `tiff:Orientation` and `exif:Orientation`. The reader treats
    /// `tiff:Orientation` as authoritative (Adobe's convention — see `parseMetadata`), so writing
    /// only `exif:Orientation` lets a stale Adobe-authored `tiff:Orientation` win on read-back and
    /// silently revert the rotation. Keep the two tags in lockstep. `nil` clears both.
    private func setOrientation(on description: XMLElement, value: Int?) {
        let str = value.map(String.init)
        setSimple(on: description, prefix: "tiff", localName: "Orientation", value: str)
        setSimple(on: description, prefix: "exif", localName: "Orientation", value: str)
    }

    private func setSimple(on description: XMLElement, prefix: String, localName: String, value: String?) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        guard let value, !value.isEmpty else { return }
        if let attribute = XMLNode.attribute(withName: "\(prefix):\(localName)", stringValue: value) as? XMLNode {
            description.addAttribute(attribute)
        }
    }

    private func setAltText(on description: XMLElement, prefix: String, localName: String, value: String?) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        guard let value, !value.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let alt = XMLElement(name: "rdf:Alt")
        let li = XMLElement(name: "rdf:li", stringValue: value)
        if let langAttr = XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as? XMLNode {
            li.addAttribute(langAttr)
        }
        alt.addChild(li)
        element.addChild(alt)
        description.addChild(element)
    }

    private func setBag(on description: XMLElement, prefix: String, localName: String, values: [String]) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let bag = XMLElement(name: "rdf:Bag")
        for value in cleaned {
            bag.addChild(XMLElement(name: "rdf:li", stringValue: value))
        }
        element.addChild(bag)
        description.addChild(element)
    }

    private func setSeq(on description: XMLElement, prefix: String, localName: String, values: [String]) {
        removeProperty(from: description, prefix: prefix, localName: localName)
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        let element = XMLElement(name: "\(prefix):\(localName)")
        let seq = XMLElement(name: "rdf:Seq")
        for value in cleaned {
            seq.addChild(XMLElement(name: "rdf:li", stringValue: value))
        }
        element.addChild(seq)
        description.addChild(element)
    }

    private func removeProperty(from description: XMLElement, prefix: String, localName: String) {
        let namespace = namespaceURI(for: prefix)
        removeChildren(from: description, localName: localName, namespace: namespace)

        if let exactNameMatch = description.attributes?.first(where: { $0.name == "\(prefix):\(localName)" }) {
            exactNameMatch.detach()
        }

        if let namespaceMatch = description.attributes?.first(where: { $0.localName == localName && $0.uri == namespace }) {
            namespaceMatch.detach()
        }
    }

    private func removeChildren(from description: XMLElement, localName: String, namespace: String) {
        let toRemove = (description.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.localName == localName && $0.uri == namespace }
        for child in toRemove {
            child.detach()
        }
    }

    private func namespaceURI(for prefix: String) -> String {
        switch prefix {
        case "rdf":
            return Namespace.rdf
        case "dc":
            return Namespace.dc
        case "xmp":
            return Namespace.xmp
        case "photoshop":
            return Namespace.photoshop
        case "Iptc4xmpCore":
            return Namespace.iptcCore
        case "Iptc4xmpExt":
            return Namespace.iptcExt
        case "tiff":
            return Namespace.tiff
        case "exif":
            return Namespace.exif
        case "crs":
            return Namespace.crs
        case "aaphoto":
            return Namespace.aaphoto
        default:
            return ""
        }
    }

    // MARK: - Parse

    private func parseMetadata(from description: XMLElement, imageAspect: () -> Double?) -> IPTCMetadata {
        let headline = parseSimple(from: description, prefix: "photoshop", localName: "Headline")
        let title = headline ?? parseAltText(from: description, prefix: "dc", localName: "title")
        let descriptionText = parseAltText(from: description, prefix: "dc", localName: "description")
        let extendedDescription = parseAltText(from: description, prefix: "Iptc4xmpCore", localName: "ExtDescrAccessibility")
        let keywords = parseBag(from: description, prefix: "dc", localName: "subject")
        let personShown = parseBag(from: description, prefix: "Iptc4xmpExt", localName: "PersonInImage")
        let ratingValue = parseSimple(from: description, prefix: "xmp", localName: "Rating")
        let label = ColorLabel.canonicalMetadataLabel(
            parseSimple(from: description, prefix: "xmp", localName: "Label")
        )
        let digitalSourceType = parseSimple(from: description, prefix: "Iptc4xmpExt", localName: "DigitalSourceType")
        let creator = parseSeq(from: description, prefix: "dc", localName: "creator").first
        let credit = parseSimple(from: description, prefix: "photoshop", localName: "Credit")
        let jobId = parseSimple(from: description, prefix: "photoshop", localName: "TransmissionReference")
        let rights = parseAltText(from: description, prefix: "dc", localName: "rights")
        let dateCreated = parseSimple(from: description, prefix: "photoshop", localName: "DateCreated")
        let city = parseSimple(from: description, prefix: "photoshop", localName: "City")
        let country = parseSimple(from: description, prefix: "photoshop", localName: "Country")
        let event = parseSimple(from: description, prefix: "Iptc4xmpExt", localName: "Event")
        let latValue = parseSimple(from: description, prefix: "exif", localName: "GPSLatitude")
        let lonValue = parseSimple(from: description, prefix: "exif", localName: "GPSLongitude")
        // Prefer tiff:Orientation (original camera orientation) over exif:Orientation.
        // Adobe-authored sidecars set exif:Orientation to the "processed" display orientation
        // (often 1) while tiff:Orientation retains the actual sensor orientation — using the
        // wrong one causes corrective-rotation mismatches in full-screen and edit views.
        let tiffOrientation = parseSimple(from: description, prefix: "tiff", localName: "Orientation")
        let exifOrientationRaw = parseSimple(from: description, prefix: "exif", localName: "Orientation")
        let orientationValue = tiffOrientation ?? exifOrientationRaw
        let cameraRaw = parseCameraRawSettings(from: description, imageAspect: imageAspect)

        return IPTCMetadata(
            title: title,
            description: descriptionText,
            extendedDescription: extendedDescription,
            keywords: keywords,
            personShown: personShown,
            digitalSourceType: digitalSourceType.flatMap { DigitalSourceType(rawValue: $0) },
            latitude: latValue.flatMap { parseCoordinateComponent($0) },
            longitude: lonValue.flatMap { parseCoordinateComponent($0) },
            creator: creator,
            credit: credit,
            copyright: rights,
            jobId: jobId,
            dateCreated: dateCreated,
            city: city,
            country: country,
            event: event,
            rating: ratingValue.flatMap { Int($0) },
            label: label,
            cameraRaw: cameraRaw,
            exifOrientation: orientationValue.flatMap { Int($0) }
        )
    }

    private func parseCameraRawSettings(from description: XMLElement, imageAspect: () -> Double?) -> CameraRawSettings? {
        // A block marked AlreadyApplied="True" describes edits already baked into the
        // pixels (documentation, not live state) — never load it as editable settings,
        // or they'd be applied a second time. Our own RAW sidecars write "False".
        if let applied = parseSimple(from: description, prefix: "crs", localName: "AlreadyApplied"),
           applied.caseInsensitiveCompare("True") == .orderedSame {
            return nil
        }

        let version = parseSimple(from: description, prefix: "crs", localName: "Version")
        let processVersion = parseSimple(from: description, prefix: "crs", localName: "ProcessVersion")
        let whiteBalance = parseSimple(from: description, prefix: "crs", localName: "WhiteBalance")
        let temperature = parseSimple(from: description, prefix: "crs", localName: "Temperature").flatMap(parseSignedInt)
        let tint = parseSimple(from: description, prefix: "crs", localName: "Tint").flatMap(parseSignedInt)
        let incrementalTemperature = parseSimple(
            from: description,
            prefix: "crs",
            localName: "IncrementalTemperature"
        ).flatMap(parseSignedInt)
        let incrementalTint = parseSimple(
            from: description,
            prefix: "crs",
            localName: "IncrementalTint"
        ).flatMap(parseSignedInt)
        let exposure2012 = parseSimple(from: description, prefix: "crs", localName: "Exposure2012").flatMap(parseSignedDouble)
        let contrast2012 = parseSimple(from: description, prefix: "crs", localName: "Contrast2012").flatMap(parseSignedInt)
        let highlights2012 = parseSimple(from: description, prefix: "crs", localName: "Highlights2012").flatMap(parseSignedInt)
        let shadows2012 = parseSimple(from: description, prefix: "crs", localName: "Shadows2012").flatMap(parseSignedInt)
        let whites2012 = parseSimple(from: description, prefix: "crs", localName: "Whites2012").flatMap(parseSignedInt)
        let blacks2012 = parseSimple(from: description, prefix: "crs", localName: "Blacks2012").flatMap(parseSignedInt)
        let saturation = parseSimple(from: description, prefix: "crs", localName: "Saturation").flatMap(parseSignedInt)
        let vibrance = parseSimple(from: description, prefix: "crs", localName: "Vibrance").flatMap(parseSignedInt)
        let hasSettings = parseSimple(from: description, prefix: "crs", localName: "HasSettings").flatMap(parseBool)

        // Stored crs values use Adobe's un-rotated-frame corner encoding; convert
        // to the app's upright rect. The aspect closure (a file-header read) is
        // only invoked for angled crops — the conversion is the identity at angle 0.
        let storedCrop = CameraRawCrop(
            top: parseSimple(from: description, prefix: "crs", localName: "CropTop").flatMap(Double.init),
            left: parseSimple(from: description, prefix: "crs", localName: "CropLeft").flatMap(Double.init),
            bottom: parseSimple(from: description, prefix: "crs", localName: "CropBottom").flatMap(Double.init),
            right: parseSimple(from: description, prefix: "crs", localName: "CropRight").flatMap(Double.init),
            angle: parseSimple(from: description, prefix: "crs", localName: "CropAngle").flatMap(Double.init),
            hasCrop: parseSimple(from: description, prefix: "crs", localName: "HasCrop").flatMap(parseBool)
        )
        let crop = abs(storedCrop.angle ?? 0) > 0.0001
            ? storedCrop.decodedFromACR(aspect: imageAspect())
            : storedCrop
        let cropValue = crop.isEmpty ? nil : crop

        let hdrEditMode = parseSimple(from: description, prefix: "crs", localName: "HDREditMode").flatMap(parseSignedInt)
        let hdrMaxValue = parseSimple(from: description, prefix: "crs", localName: "HDRMaxValue")
        let sdrBrightness = parseSimple(from: description, prefix: "crs", localName: "SDRBrightness").flatMap(parseSignedInt)
        let sdrContrast = parseSimple(from: description, prefix: "crs", localName: "SDRContrast").flatMap(parseSignedInt)
        let sdrClarity = parseSimple(from: description, prefix: "crs", localName: "SDRClarity").flatMap(parseSignedInt)
        let sdrHighlights = parseSimple(from: description, prefix: "crs", localName: "SDRHighlights").flatMap(parseSignedInt)
        let sdrShadows = parseSimple(from: description, prefix: "crs", localName: "SDRShadows").flatMap(parseSignedInt)
        let sdrWhites = parseSimple(from: description, prefix: "crs", localName: "SDRWhites").flatMap(parseSignedInt)
        let sdrBlend = parseSimple(from: description, prefix: "crs", localName: "SDRBlend").flatMap(parseSignedInt)

        // Tone curve: parse rdf:Seq of "x, y" strings (0-255 scale) back to ToneCurvePoints (0-1 scale)
        let tcMaster = parseToneCurveChannel(from: description, localName: "ToneCurvePV2012")
        let tcRed = parseToneCurveChannel(from: description, localName: "ToneCurvePV2012Red")
        let tcGreen = parseToneCurveChannel(from: description, localName: "ToneCurvePV2012Green")
        let tcBlue = parseToneCurveChannel(from: description, localName: "ToneCurvePV2012Blue")
        let toneCurve: ToneCurve? = {
            let tc = ToneCurve(master: tcMaster, red: tcRed, green: tcGreen, blue: tcBlue)
            return tc.isEmpty ? nil : tc
        }()

        // HSL per-color adjustments (ACR-compatible tags + custom SkinTone),
        // reconstructed via the shared decoder (inverse of the sidecar write).
        let hslAdjustments = decodeHSLAdjustments { name in
            parseSimple(from: description, prefix: "crs", localName: name).flatMap(parseSignedInt)
        }

        let localAdjustments = parseMaskCorrections(from: description)

        var settings = CameraRawSettings(
            version: version,
            processVersion: processVersion,
            whiteBalance: whiteBalance,
            temperature: temperature,
            tint: tint,
            incrementalTemperature: incrementalTemperature,
            incrementalTint: incrementalTint,
            exposure2012: exposure2012,
            contrast2012: contrast2012,
            highlights2012: highlights2012,
            shadows2012: shadows2012,
            whites2012: whites2012,
            blacks2012: blacks2012,
            saturation: saturation,
            vibrance: vibrance,
            hasSettings: hasSettings,
            crop: cropValue,
            hdrEditMode: hdrEditMode,
            hdrMaxValue: hdrMaxValue,
            sdrBrightness: sdrBrightness,
            sdrContrast: sdrContrast,
            sdrClarity: sdrClarity,
            sdrHighlights: sdrHighlights,
            sdrShadows: sdrShadows,
            sdrWhites: sdrWhites,
            sdrBlend: sdrBlend,
            toneCurve: toneCurve,
            localAdjustments: localAdjustments,
            hslAdjustments: hslAdjustments
        )
        // Restore the chain: masks already came back from crs in render-stack order; our
        // private GlobalLayerIndex says where the global node sits among them. nil ⇒ resolver
        // falls back to canonical global-first.
        settings.layerOrder = reconstructLayerOrder(masks: localAdjustments, from: description)
        // Ignore a lone `HasSettings` flag: ACR writes `crs:HasSettings="False"` (and our
        // own writer derives it from emptiness) on a RAW with no develop adjustments — e.g.
        // after a reset, or a rotation-only edit. A CRS carrying nothing but that flag has
        // no actual edits and must read as nil, not as an edited image.
        var probe = settings
        probe.hasSettings = nil
        return probe.isEmpty ? nil : settings
    }

    private func parseSimple(from description: XMLElement, prefix: String, localName: String) -> String? {
        if let attr = attributeValue(from: description, prefix: prefix, localName: localName) {
            return attr
        }
        guard let element = childElement(from: description, prefix: prefix, localName: localName) else { return nil }
        return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseAltText(from description: XMLElement, prefix: String, localName: String) -> String? {
        guard let element = childElement(from: description, prefix: prefix, localName: localName),
              let alt = childElement(from: element, prefix: "rdf", localName: "Alt") else {
            return nil
        }
        let items = childElements(from: alt, prefix: "rdf", localName: "li")
        if let preferred = items.first(where: { ($0.attribute(forName: "xml:lang")?.stringValue ?? "") == "x-default" }) {
            return preferred.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return items.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseBag(from description: XMLElement, prefix: String, localName: String) -> [String] {
        guard let element = childElement(from: description, prefix: prefix, localName: localName),
              let bag = childElement(from: element, prefix: "rdf", localName: "Bag") else {
            return []
        }
        return childElements(from: bag, prefix: "rdf", localName: "li")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
    }

    private func parseSeq(from description: XMLElement, prefix: String, localName: String) -> [String] {
        guard let element = childElement(from: description, prefix: prefix, localName: localName),
              let seq = childElement(from: element, prefix: "rdf", localName: "Seq") else {
            return []
        }
        return childElements(from: seq, prefix: "rdf", localName: "li")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func attributeValue(from element: XMLElement, prefix: String, localName: String) -> String? {
        let namespace = namespaceURI(for: prefix)

        if let namespaceMatch = element.attributes?.first(where: { $0.localName == localName && $0.uri == namespace }),
           let value = namespaceMatch.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        if let nameMatch = element.attributes?.first(where: { $0.name == "\(prefix):\(localName)" }),
           let value = nameMatch.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return nil
    }

    private func childElement(from parent: XMLElement, prefix: String, localName: String) -> XMLElement? {
        childElements(from: parent, prefix: prefix, localName: localName).first
    }

    private func childElements(from parent: XMLElement, prefix: String, localName: String) -> [XMLElement] {
        let namespace = namespaceURI(for: prefix)
        return (parent.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.localName == localName && $0.uri == namespace }
    }

    private func parseCoordinateComponent(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = Double(trimmed) {
            return direct
        }

        let decimalWithDir = /^\s*(-?\d+\.?\d*)\s*([NSEWnsew])\s*$/
        if let match = trimmed.firstMatch(of: decimalWithDir),
           let base = Double(match.1) {
            let dir = String(match.2).uppercased()
            if dir == "S" || dir == "W" { return -abs(base) }
            return abs(base)
        }

        let dms = /(-?\d+)\s*°\s*(\d+)\s*[''′]\s*([\d.]+)\s*[""″]?\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: dms),
           let degrees = Int(match.1),
           let minutes = Int(match.2),
           let seconds = Double(match.3) {
            var decimal = Double(abs(degrees)) + Double(minutes) / 60.0 + seconds / 3600.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.4.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        let ddm = /(-?\d+)\s*°\s*([\d.]+)\s*[''′]\s*([NSEWnsew])?/
        if let match = trimmed.firstMatch(of: ddm),
           let degrees = Int(match.1),
           let minutes = Double(match.2) {
            var decimal = Double(abs(degrees)) + minutes / 60.0
            if degrees < 0 { decimal = -decimal }
            if let dir = match.3.map({ String($0).uppercased() }), dir == "S" || dir == "W" {
                decimal = -abs(decimal)
            }
            return decimal
        }

        return nil
    }

    private func parseSignedInt(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseSignedDouble(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            return nil
        }
    }
}
