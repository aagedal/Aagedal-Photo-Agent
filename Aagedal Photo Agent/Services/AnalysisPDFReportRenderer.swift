import AppKit
import CoreGraphics
import Foundation

nonisolated enum AnalysisReportPageFormat: String, CaseIterable, Sendable {
    case a4
    case usLetter

    var displayName: String {
        switch self {
        case .a4: "A4"
        case .usLetter: "US Letter"
        }
    }

    var pageSize: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .usLetter: CGSize(width: 612, height: 792)
        }
    }
}

nonisolated struct AnalysisReportExportOptions: Equatable, Sendable {
    var pageFormat: AnalysisReportPageFormat = .a4
    var includeSelectedEvidenceCrop = true
    var includeCanonicalPath = false
    var includeCameraSerialNumber = false
    var includeLocationCoordinates = true
    var includeRawMetadata = true
    var mapBasemap: AnalysisReportMapBasemap = .schematic
}

nonisolated enum AnalysisReportMapBasemap: String, CaseIterable, Sendable {
    case schematic
    case openStreetMap

    var displayName: String {
        switch self {
        case .schematic: "Coordinate schematic"
        case .openStreetMap: "OpenStreetMap"
        }
    }
}

nonisolated enum AnalysisPDFReportError: Error, LocalizedError, Sendable {
    case couldNotCreateDocument
    case cancelled

    var errorDescription: String? {
        switch self {
        case .couldNotCreateDocument:
            "The PDF document could not be created."
        case .cancelled:
            "Report export was cancelled."
        }
    }
}

/// Deterministically renders an immutable analysis snapshot without retaining live case state.
///
/// Report pages use fixed paper colors so their appearance does not depend on the app theme. Map
/// evidence is rendered as a coordinate schematic; MapKit tiles are never read or embedded.
nonisolated enum AnalysisPDFReportRenderer {
    @MainActor
    static func makePDF(
        snapshot: AnalysisReportSnapshot,
        options: AnalysisReportExportOptions = AnalysisReportExportOptions(),
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw AnalysisPDFReportError.couldNotCreateDocument
        }
        var mediaBox = CGRect(origin: .zero, size: options.pageFormat.pageSize)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: snapshot.caseTitle,
            kCGPDFContextAuthor: "Aagedal Photo Agent",
            kCGPDFContextCreator: "Aagedal Photo Agent \(snapshot.appVersion) (\(snapshot.appBuild))",
        ]
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            metadata as CFDictionary
        ) else {
            throw AnalysisPDFReportError.couldNotCreateDocument
        }

        let renderer = Renderer(
            context: context,
            snapshot: snapshot,
            options: options,
            pageSize: options.pageFormat.pageSize,
            progress: progress
        )
        try await renderer.render()
        context.closePDF()
        progress(1)
        return data as Data
    }
}

private final class Renderer {
    private let context: CGContext
    private let snapshot: AnalysisReportSnapshot
    private let options: AnalysisReportExportOptions
    private let pageSize: CGSize
    private let progress: (Double) -> Void

    private let margin: CGFloat = 48
    private let footerHeight: CGFloat = 30
    private var cursorY: CGFloat = 0
    private var pageNumber = 0
    private var pageOpen = false
    private var openStreetMapImage: NSImage?
    private var annotatedPhotoImage: NSImage?
    private var evidenceCropImage: NSImage?

    private let ink = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
    private let secondary = NSColor(srgbRed: 0.36, green: 0.39, blue: 0.43, alpha: 1)
    private let accent = NSColor(srgbRed: 0.05, green: 0.42, blue: 0.62, alpha: 1)
    private let caution = NSColor(srgbRed: 0.72, green: 0.35, blue: 0.06, alpha: 1)
    private let hairline = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1)
    private let panelFill = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)

    private var contentWidth: CGFloat { pageSize.width - margin * 2 }
    private var minimumY: CGFloat { margin + footerHeight }

    init(
        context: CGContext,
        snapshot: AnalysisReportSnapshot,
        options: AnalysisReportExportOptions,
        pageSize: CGSize,
        progress: @escaping (Double) -> Void
    ) {
        self.context = context
        self.snapshot = snapshot
        self.options = options
        self.pageSize = pageSize
        self.progress = progress
    }

    func render() async throws {
        annotatedPhotoImage = try? await AnalysisEvidenceJPEGRenderer.annotatedPhotoImage(
            sourceURL: snapshot.source.canonicalURL,
            annotations: snapshot.photoAnnotations
        )
        if let crop = snapshot.evidenceCrop {
            evidenceCropImage = try? await AnalysisEvidenceJPEGRenderer.annotatedEvidenceCropImage(
                sourceURL: snapshot.source.canonicalURL,
                crop: crop,
                annotations: snapshot.photoAnnotations
            )
        }
        if options.mapBasemap == .openStreetMap, let map = snapshot.mapEvidence {
            openStreetMapImage = try? await AnalysisOpenStreetMapSnapshotter.image(
                viewport: map.viewport,
                pixelSize: CGSize(width: 1_000, height: 520)
            )
        }
        try checkCancellation()
        beginPage(isCover: true)
        drawCover()
        finishPage()
        try await checkpoint(progress: 0.12)

        try await section("Source facts and provenance") {
            drawSourceFacts()
        }
        try await checkpoint(progress: 0.25)

        try await section("Findings") {
            drawFindings()
        }
        try await checkpoint(progress: 0.38)

        try await section("Pixel evidence") {
            drawPixelEvidence()
        }
        try await checkpoint(progress: 0.50)

        try await section("Photo annotations") {
            drawPhotoAnnotations()
        }
        try await checkpoint(progress: 0.60)

        try await section("Timeline and observations") {
            drawTimeline()
        }
        try await checkpoint(progress: 0.70)

        try await section("Location evidence") {
            drawLocationEvidence()
        }
        try await checkpoint(progress: 0.80)

        try await section("Methodology") {
            drawMethodology()
        }
        try await checkpoint(progress: 0.89)

        try await section("Limitations") {
            drawLimitations()
        }
        try await checkpoint(progress: 0.95)

        try await section("Appendix") {
            drawAppendix()
        }
    }

    private func checkpoint(progress value: Double) async throws {
        progress(value)
        await Task.yield()
        try checkCancellation()
    }

    private func checkCancellation() throws {
        if Task<Never, Never>.isCancelled {
            throw AnalysisPDFReportError.cancelled
        }
    }

    private func beginPage(isCover: Bool = false) {
        if pageOpen { finishPage() }
        context.beginPDFPage(nil)
        pageOpen = true
        pageNumber += 1
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: pageSize)).fill()
        cursorY = pageSize.height - margin

        if !isCover {
            drawText(
                snapshot.caseTitle,
                font: .systemFont(ofSize: 9, weight: .medium),
                color: secondary,
                in: CGRect(x: margin, y: cursorY - 12, width: contentWidth, height: 12)
            )
            cursorY -= 22
            drawRule()
            cursorY -= 18
        }
    }

    private func finishPage() {
        guard pageOpen else { return }
        let footer = "Aagedal Photo Agent analysis report  |  Page \(pageNumber)  |  Snapshot \(snapshot.id.uuidString.lowercased())"
        drawText(
            footer,
            font: .systemFont(ofSize: 7.5),
            color: secondary,
            align: .center,
            in: CGRect(x: margin, y: margin - 4, width: contentWidth, height: 12)
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        pageOpen = false
    }

    private func drawCover() {
        let bar = NSBezierPath(
            roundedRect: CGRect(x: margin, y: pageSize.height - margin - 12, width: 72, height: 6),
            xRadius: 3,
            yRadius: 3
        )
        accent.setFill()
        bar.fill()
        cursorY -= 70

        drawFlowingText(
            "IMAGE ANALYSIS REPORT",
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: accent,
            lineSpacing: 2
        )
        cursorY -= 8
        drawFlowingText(
            snapshot.caseTitle,
            font: .systemFont(ofSize: 30, weight: .bold),
            color: ink,
            lineSpacing: 3
        )
        cursorY -= 18
        drawFlowingText(
            snapshot.source.filenameAtCreation,
            font: .systemFont(ofSize: 16, weight: .medium),
            color: secondary,
            lineSpacing: 2
        )

        cursorY -= 34
        drawKeyValue("Report created", formatted(snapshot.createdAt))
        drawKeyValue("Case last updated", formatted(snapshot.caseUpdatedAt))
        drawKeyValue("Source SHA-256", snapshot.source.sha256, monospaced: true)
        drawKeyValue("Representation", snapshot.representation.displayName)
        drawKeyValue("Application", "Aagedal Photo Agent \(snapshot.appVersion) (\(snapshot.appBuild))")
        drawKeyValue("Paper", options.pageFormat.displayName)

        cursorY -= 28
        drawCallout(
            title: "Evidence, not a verdict",
            body: "This report records source facts, analyzer observations, and investigator-authored case material. It does not establish that an image is authentic, manipulated, or AI-generated. Findings must be interpreted with their alternatives and limitations."
        )

        cursorY -= 18
        drawFlowingText(
            "The source was re-hashed immediately before this immutable report snapshot was created. The SHA-256 above identifies the exact bytes used.",
            font: .systemFont(ofSize: 10),
            color: secondary,
            lineSpacing: 2
        )
    }

    private func section(_ title: String, content: () -> Void) async throws {
        try checkCancellation()
        beginPage()
        drawSectionTitle(title)
        content()
        finishPage()
    }

    private func drawSectionTitle(_ title: String) {
        drawFlowingText(
            title,
            font: .systemFont(ofSize: 22, weight: .bold),
            color: ink,
            lineSpacing: 2
        )
        cursorY -= 8
        drawRule(color: accent, width: 2)
        cursorY -= 18
    }

    private func drawSourceFacts() {
        drawSubheading("Source revision")
        drawKeyValue("Filename", snapshot.source.filenameAtCreation)
        if options.includeCanonicalPath {
            drawKeyValue("Canonical path", snapshot.source.canonicalURL.path)
        } else {
            drawKeyValue("Canonical path", "Omitted by export settings")
        }
        drawKeyValue("Byte count", ByteCountFormatter.string(fromByteCount: snapshot.source.byteCount, countStyle: .file))
        drawKeyValue("SHA-256", snapshot.source.sha256, monospaced: true)
        drawKeyValue("Source modified", formatted(snapshot.source.contentModificationDate))
        drawKeyValue("Hash completed", formatted(snapshot.source.hashCompletedAt))

        guard let facts = snapshot.sourceFacts else {
            cursorY -= 10
            drawCallout(title: "Source facts unavailable", body: "The source-facts analyzer did not provide a completed result for this snapshot.")
            return
        }

        cursorY -= 18
        drawSubheading("Decoded facts")
        drawOptionalKeyValue("Detected type", facts.detectedMIMEType ?? facts.detectedTypeIdentifier)
        if let width = facts.pixelWidth, let height = facts.pixelHeight {
            drawKeyValue("Pixel dimensions", "\(width) x \(height)")
        }
        drawOptionalKeyValue("Bit depth", facts.bitDepth.map { "\($0) bits" })
        drawOptionalKeyValue("Color profile", facts.colorProfile)
        drawOptionalKeyValue("Camera", facts.camera)
        drawOptionalKeyValue("Lens", facts.lens)
        drawOptionalKeyValue("Capture time", facts.captureDate)
        if options.includeCameraSerialNumber {
            drawOptionalKeyValue("Camera serial number", facts.serialNumber)
        } else if facts.serialNumber != nil {
            drawKeyValue("Camera serial number", "Omitted by export settings")
        }
        if options.includeLocationCoordinates,
           let latitude = facts.latitude,
           let longitude = facts.longitude {
            drawKeyValue("Embedded GPS", coordinate(latitude: latitude, longitude: longitude))
        } else if facts.latitude != nil || facts.longitude != nil {
            drawKeyValue("Embedded GPS", "Omitted by export settings")
        }

        cursorY -= 18
        drawSubheading("Content credentials")
        drawKeyValue("Manifest", facts.c2pa.isPresent ? "Present" : "Not present")
        drawKeyValue("Cryptographic validity", facts.c2pa.validity.rawValue)
        drawKeyValue("Signer trust", facts.c2pa.trust.rawValue)
        drawFlowingText(facts.c2pa.message, font: .systemFont(ofSize: 9.5), color: secondary, lineSpacing: 2)
    }

    private func drawFindings() {
        guard !snapshot.includedFindings.isEmpty else {
            drawEmptyState("No findings were selected for this report.")
            return
        }

        for (index, finding) in snapshot.includedFindings.enumerated() {
            ensureSpace(116)
            let severityColor = finding.severity == .caution ? caution : accent
            drawFlowingText(
                "\(index + 1). \(finding.title)",
                font: .systemFont(ofSize: 13, weight: .semibold),
                color: ink,
                lineSpacing: 2
            )
            drawFlowingText(
                "\(finding.category.rawValue.capitalized)  |  \(finding.severity.rawValue.capitalized)  |  \(finding.evidenceClass.rawValue)",
                font: .systemFont(ofSize: 8.5, weight: .medium),
                color: severityColor,
                lineSpacing: 1
            )
            cursorY -= 3
            drawFlowingText(finding.explanation, font: .systemFont(ofSize: 10), color: ink, lineSpacing: 2)
            if !finding.technicalDetail.isEmpty {
                drawFlowingText("Technical detail: \(finding.technicalDetail)", font: .systemFont(ofSize: 8.5), color: secondary, lineSpacing: 2)
            }
            if !finding.alternatives.isEmpty {
                drawFlowingText("Alternative explanations: \(finding.alternatives.joined(separator: "; "))", font: .systemFont(ofSize: 8.5), color: secondary, lineSpacing: 2)
            }
            cursorY -= 10
            drawRule()
            cursorY -= 12
        }
    }

    private func drawPixelEvidence() {
        drawSubheading("Annotated source overview")
        if let annotatedPhotoImage {
            let imageSize = annotatedPhotoImage.size
            let figureSize = aspectFitSize(
                imageSize,
                maximum: CGSize(width: contentWidth, height: 380)
            )
            ensureSpace(figureSize.height + 32)
            let figureRect = CGRect(
                x: margin + (contentWidth - figureSize.width) / 2,
                y: cursorY - figureSize.height,
                width: figureSize.width,
                height: figureSize.height
            )
            annotatedPhotoImage.draw(
                in: figureRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            hairline.setStroke()
            let border = NSBezierPath(rect: figureRect)
            border.lineWidth = 0.75
            border.stroke()
            cursorY = figureRect.minY - 13
            drawFlowingText(
                "Original representation · bounded overview · high-quality page-fit interpolation · visible annotation overlays from the frozen case.",
                font: .systemFont(ofSize: 8.5),
                color: secondary,
                lineSpacing: 1
            )
            cursorY -= 12
        } else {
            drawCallout(
                title: "Image figure unavailable",
                body: "The source could not be decoded for the report figure. Annotation geometry and notes are still listed below."
            )
            cursorY -= 12
        }

        cursorY -= 10
        let evidenceCropFigureSize = evidenceCropImage.map { image in
            aspectFitSize(
                image.size,
                maximum: CGSize(width: contentWidth, height: 400)
            )
        }
        if snapshot.evidenceCrop != nil, let evidenceCropFigureSize {
            // Keep the crop heading with its raster. Without this reservation, a large source
            // overview can leave room for only the heading at the foot of the preceding page.
            ensureSpace(30 + evidenceCropFigureSize.height + 80)
        }
        drawSubheading("Selected true-pixel crop")
        guard let crop = snapshot.evidenceCrop else {
            drawEmptyState("No source-pixel evidence crop was selected for this report.")
            return
        }
        guard let evidenceCropImage else {
            drawCallout(
                title: "Evidence crop unavailable",
                body: "The exact crop bounds remain frozen below, but the source could not be decoded at full resolution for this figure."
            )
            drawEvidenceCropCaption(crop)
            return
        }

        let figureSize = evidenceCropFigureSize ?? aspectFitSize(
            evidenceCropImage.size,
            maximum: CGSize(width: contentWidth, height: 400)
        )
        ensureSpace(figureSize.height + 80)
        let figureRect = CGRect(
            x: margin + (contentWidth - figureSize.width) / 2,
            y: cursorY - figureSize.height,
            width: figureSize.width,
            height: figureSize.height
        )
        NSGraphicsContext.current?.cgContext.interpolationQuality = .none
        evidenceCropImage.draw(
            in: figureRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        hairline.setStroke()
        let border = NSBezierPath(rect: figureRect)
        border.lineWidth = 0.75
        border.stroke()
        cursorY = figureRect.minY - 13
        drawEvidenceCropCaption(crop)
    }

    private func drawEvidenceCropCaption(_ crop: AnalysisReportEvidenceCrop) {
        let bounds = crop.sourcePixelRect
        let annotationIDs = snapshot.photoAnnotations
            .filter(\.isVisible)
            .map { String($0.id.uuidString.lowercased().prefix(8)) }
            .joined(separator: ", ")
        let annotationList = annotationIDs.isEmpty ? "none" : annotationIDs
        drawFlowingText(
            "Original representation · true-pixel crop · source-storage bounds x \(bounds.x), y \(bounds.y), \(bounds.width) × \(bounds.height) px · \(crop.scaleLabel) · \(crop.interpolationLabel). The embedded crop raster is \(crop.displayPixelRect.width) × \(crop.displayPixelRect.height) px; the PDF viewer may scale it to fit the page. Annotation IDs in the frozen overlay set: \(annotationList).",
            font: .systemFont(ofSize: 8.5),
            color: secondary,
            lineSpacing: 2
        )
    }

    private func aspectFitSize(_ size: CGSize, maximum: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return maximum }
        let scale = min(maximum.width / size.width, maximum.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func drawPhotoAnnotations() {

        drawFlowingText(
            "Annotation geometry is stored in normalized, display-oriented coordinates tied to the source revision. Visibility below reflects the frozen case state.",
            font: .systemFont(ofSize: 9.5),
            color: secondary,
            lineSpacing: 2
        )
        cursorY -= 12

        guard !snapshot.photoAnnotations.isEmpty else {
            drawEmptyState("No photo annotations were present in the snapshot.")
            return
        }

        for (index, annotation) in snapshot.photoAnnotations.enumerated() {
            ensureSpace(70)
            let color = reportColor(annotation.style.color)
            let swatchRect = CGRect(x: margin, y: cursorY - 12, width: 12, height: 12)
            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3).fill()
            let label = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            drawText(
                "\(index + 1). \(annotation.kind.rawValue.capitalized)\(label.map { ": \($0)" } ?? "")",
                font: .systemFont(ofSize: 10.5, weight: .semibold),
                color: ink,
                in: CGRect(x: margin + 20, y: cursorY - 15, width: contentWidth - 20, height: 16)
            )
            cursorY -= 21
            drawFlowingText(
                "\(annotation.isVisible ? "Visible" : "Hidden")  |  Source-frame geometry: \(photoGeometryDescription(annotation.geometry))",
                font: .systemFont(ofSize: 8.5),
                color: secondary,
                lineSpacing: 2
            )
            if let calibration = annotation.measurementCalibration {
                drawFlowingText(
                    "Calibration: this segment was assigned a known length of \(calibration.formattedKnownLength). Converted measurements depend on that investigator-entered calibration and are not inferred from DPI metadata.",
                    font: .systemFont(ofSize: 8.5),
                    color: caution,
                    lineSpacing: 2
                )
            }
            if let note = annotation.note {
                drawFlowingText("Case note: \(note)", font: .systemFont(ofSize: 9), color: ink, lineSpacing: 2)
            }
            cursorY -= 8
        }
    }

    private func drawTimeline() {
        drawSubheading("Timestamp evidence")
        if snapshot.timestampEvidence.isEmpty {
            drawEmptyState("No timestamp evidence was present in the snapshot.")
        } else {
            for evidence in snapshot.timestampEvidence {
                ensureSpace(55)
                drawFlowingText(evidence.title, font: .systemFont(ofSize: 11, weight: .semibold), color: ink, lineSpacing: 1)
                drawFlowingText(evidence.value.formatted, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium), color: accent, lineSpacing: 1)
                let zone = evidence.value.timezoneKnown ? "timezone known" : "timezone unresolved"
                drawFlowingText("\(evidence.source.displayName)  |  \(evidence.value.precision.displayName) precision  |  \(zone)  |  \(evidence.sourceDetail)", font: .systemFont(ofSize: 8.5), color: secondary, lineSpacing: 2)
                cursorY -= 8
            }
        }

        cursorY -= 12
        drawSubheading("Observations without time")
        if snapshot.observations.isEmpty {
            drawEmptyState("No untimed investigator observations were present.")
        } else {
            for observation in snapshot.observations {
                ensureSpace(50)
                drawFlowingText(observation.title, font: .systemFont(ofSize: 11, weight: .semibold), color: ink, lineSpacing: 1)
                drawFlowingText(observation.note, font: .systemFont(ofSize: 9.5), color: ink, lineSpacing: 2)
                drawFlowingText("Case-only observation; no timestamp asserted.", font: .systemFont(ofSize: 8), color: secondary, lineSpacing: 1)
                cursorY -= 8
            }
        }
    }

    private func drawLocationEvidence() {
        guard let map = snapshot.mapEvidence else {
            drawEmptyState("No valid map viewport was captured for this report.")
            return
        }

        let mapDisclosure = openStreetMapImage == nil
            ? map.disclosure
            : "OpenStreetMap tiles captured for this report. © OpenStreetMap contributors (openstreetmap.org/copyright)."
        drawFlowingText(mapDisclosure, font: .systemFont(ofSize: 9.5, weight: .medium), color: caution, lineSpacing: 2)
        drawFlowingText("Coordinate system: \(map.coordinateSystem)", font: .systemFont(ofSize: 8.5), color: secondary, lineSpacing: 1)
        cursorY -= 12
        ensureSpace(280)
        let mapRect = CGRect(x: margin, y: cursorY - 260, width: contentWidth, height: 260)
        drawMapSchematic(map, in: mapRect)
        cursorY = mapRect.minY - 16

        if let location = map.investigationLocation {
            if options.includeLocationCoordinates {
                drawKeyValue("Investigation location", coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
            } else {
                drawKeyValue("Investigation location", "Coordinates omitted by export settings")
            }
            drawOptionalKeyValue("Place name", location.placeName)
            drawKeyValue("Location source", "\(location.source.displayName): \(location.sourceDetail)")
        }
        drawKeyValue("Visible map annotations", "\(map.visibleAnnotations.count)")
        if options.includeLocationCoordinates {
            drawFlowingText("Live Apple Maps reference: \(map.liveMapReference.absoluteString)", font: .systemFont(ofSize: 8), color: accent, lineSpacing: 2)
        } else {
            drawKeyValue("Live map reference", "Omitted by export settings")
        }
    }

    private func drawMethodology() {
        let paragraphs = [
            "Source binding. The report snapshot was created only after the current file bytes were streamed through SHA-256 and matched the revision stored by the analysis case.",
            "Analyzer provenance. Each automated finding records its analyzer identifier, version, source representation, narrow evidence class, and computation time. Only findings explicitly included in the report appear here.",
            "Annotations. Photo markup is stored in normalized coordinates relative to the display-oriented original. Geographic markup is stored in WGS 84 coordinates. Neither form of case evidence writes back to source metadata.",
            openStreetMapImage == nil
                ? "Map rendering. The location figure is generated by this application from the frozen viewport and coordinates. Apple Maps tiles, labels, and imagery are not embedded."
                : "Map rendering. The location figure uses OpenStreetMap tiles captured at export time with required attribution. Apple Maps tiles and imagery are not embedded.",
            "Reproducibility. The appendix lists analyzer runs and cache keys. Reproduction requires the exact source bytes identified by the report SHA-256 and compatible analyzer versions.",
        ]
        for paragraph in paragraphs {
            drawFlowingText(paragraph, font: .systemFont(ofSize: 10), color: ink, lineSpacing: 3)
            cursorY -= 12
        }
    }

    private func drawLimitations() {
        let limitations = [
            "This report does not provide a global authenticity, manipulation, or AI-origin verdict.",
            "Metadata can be absent, edited, copied, or produced by normal camera and export workflows. A mismatch is an observation, not proof of intent.",
            "Compression residuals and other derived views can be influenced by recompression, resizing, denoising, sharpening, and ordinary editing.",
            "Timezone-less timestamps are wall-clock evidence only and cannot be placed on an absolute chronology without an explicit offset.",
            "Investigator-entered locations, labels, observations, and measurement calibrations are user assertions stored in the case; they are not source metadata.",
            openStreetMapImage == nil
                ? "The schematic map is not survey-grade and contains no terrain, parcel, road, satellite, or provider imagery."
                : "The OpenStreetMap basemap is not survey-grade and may be incomplete or out of date.",
        ]
        for limitation in limitations {
            ensureSpace(42)
            drawFlowingText("- \(limitation)", font: .systemFont(ofSize: 10), color: ink, lineSpacing: 3, leftInset: 10)
            cursorY -= 8
        }
    }

    private func drawAppendix() {
        drawSubheading("Analyzer runs")
        if snapshot.analyzerRuns.isEmpty {
            drawEmptyState("No analyzer runs were frozen.")
        } else {
            for run in snapshot.analyzerRuns {
                ensureSpace(58)
                drawFlowingText("\(run.analyzerID) v\(run.analyzerVersion)", font: .systemFont(ofSize: 10.5, weight: .semibold), color: ink, lineSpacing: 1)
                drawFlowingText("Status: \(run.status.rawValue)  |  Input: \(run.sourceRepresentation.rawValue)", font: .systemFont(ofSize: 8.5), color: secondary, lineSpacing: 1)
                drawFlowingText("Cache key: \(run.cacheKey)", font: .monospacedSystemFont(ofSize: 7.5, weight: .regular), color: secondary, lineSpacing: 2)
                if let error = run.errorMessage {
                    drawFlowingText("Run error: \(error)", font: .systemFont(ofSize: 8.5), color: caution, lineSpacing: 2)
                }
                cursorY -= 7
            }
        }

        cursorY -= 12
        drawSubheading("Raw metadata")
        guard options.includeRawMetadata else {
            drawEmptyState("Raw metadata was omitted by export settings.")
            return
        }
        let entries = filteredRawMetadata
        if snapshot.rawMetadata.isEmpty {
            drawEmptyState("No raw metadata entries were frozen.")
            return
        }
        let omittedCount = snapshot.rawMetadata.count - entries.count
        if omittedCount > 0 {
            drawFlowingText(
                "\(omittedCount) sensitive raw metadata entr\(omittedCount == 1 ? "y was" : "ies were") omitted by export settings.",
                font: .systemFont(ofSize: 8.5),
                color: caution,
                lineSpacing: 2
            )
            cursorY -= 6
        }
        if entries.isEmpty {
            drawEmptyState("All raw metadata entries were omitted by export settings.")
            return
        }
        for entry in entries {
            ensureSpace(36)
            drawFlowingText("[\(entry.origin.rawValue)] \(entry.namespace):\(entry.key)", font: .monospacedSystemFont(ofSize: 7.5, weight: .semibold), color: secondary, lineSpacing: 1)
            drawFlowingText(entry.value, font: .systemFont(ofSize: 8.5), color: ink, lineSpacing: 2)
            cursorY -= 5
        }
    }

    private func drawMapSchematic(_ map: AnalysisReportMapEvidence, in rect: CGRect) {
        panelFill.setFill()
        let background = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        background.fill()
        hairline.setStroke()
        background.lineWidth = 1
        background.stroke()

        if let openStreetMapImage {
            openStreetMapImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
        for index in 1..<4 {
            hairline.setStroke()
            let vertical = NSBezierPath()
            vertical.move(to: CGPoint(x: rect.minX + rect.width * CGFloat(index) / 4, y: rect.minY))
            vertical.line(to: CGPoint(x: rect.minX + rect.width * CGFloat(index) / 4, y: rect.maxY))
            vertical.lineWidth = 0.5
            vertical.stroke()
            let horizontal = NSBezierPath()
            horizontal.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * CGFloat(index) / 4))
            horizontal.line(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * CGFloat(index) / 4))
            horizontal.lineWidth = 0.5
            horizontal.stroke()
        }
        }

        if let location = map.investigationLocation, options.includeLocationCoordinates {
            let point = projected(location.coordinate, viewport: map.viewport, rect: rect)
            NSColor.orange.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }

        for annotation in map.visibleAnnotations {
            let color = reportColor(annotation.style.color)
            color.setStroke()
            color.setFill()
            switch annotation.geometry {
            case .point(let coordinate):
                let point = projected(coordinate, viewport: map.viewport, rect: rect)
                NSBezierPath(ovalIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)).fill()
            case .segment(let start, let end):
                let path = NSBezierPath()
                path.move(to: projected(start, viewport: map.viewport, rect: rect))
                path.line(to: projected(end, viewport: map.viewport, rect: rect))
                path.lineWidth = CGFloat(annotation.style.lineWidthPoints)
                path.stroke()
            case .polygon(let coordinates):
                guard let first = coordinates.first else { continue }
                let path = NSBezierPath()
                path.move(to: projected(first, viewport: map.viewport, rect: rect))
                for coordinate in coordinates.dropFirst() {
                    path.line(to: projected(coordinate, viewport: map.viewport, rect: rect))
                }
                path.close()
                color.withAlphaComponent(CGFloat(annotation.style.fillOpacity)).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = CGFloat(annotation.style.lineWidthPoints)
                path.stroke()
            }
        }

        let viewportDescription: String
        if options.includeLocationCoordinates {
            let center = coordinate(latitude: map.viewport.center.latitude, longitude: map.viewport.center.longitude)
            viewportDescription = "Center \(center)"
        } else {
            viewportDescription = "Coordinates omitted by export settings"
        }
        drawText(
            "\(openStreetMapImage == nil ? "Schematic WGS 84 viewport" : "OpenStreetMap  |  © OpenStreetMap contributors")  |  \(viewportDescription)",
            font: .systemFont(ofSize: 7.5, weight: .medium),
            color: secondary,
            in: CGRect(x: rect.minX + 8, y: rect.minY + 6, width: rect.width - 16, height: 10)
        )
    }

    private func projected(
        _ coordinate: AnalysisGeoCoordinate,
        viewport: AnalysisMapViewport,
        rect: CGRect
    ) -> CGPoint {
        var longitudeOffset = coordinate.longitude - viewport.center.longitude
        if longitudeOffset > 180 { longitudeOffset -= 360 }
        if longitudeOffset < -180 { longitudeOffset += 360 }
        let normalizedX = 0.5 + longitudeOffset / viewport.longitudeDelta
        let normalizedY = 0.5 + (coordinate.latitude - viewport.center.latitude) / viewport.latitudeDelta
        return CGPoint(
            x: rect.minX + rect.width * CGFloat(min(1, max(0, normalizedX))),
            y: rect.minY + rect.height * CGFloat(min(1, max(0, normalizedY)))
        )
    }

    private func drawCallout(title: String, body: String) {
        let font = NSFont.systemFont(ofSize: 10)
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyHeight = textHeight(body, font: font, width: contentWidth - 28, lineSpacing: 2)
        let height = max(64, bodyHeight + 45)
        ensureSpace(height)
        let rect = CGRect(x: margin, y: cursorY - height, width: contentWidth, height: height)
        panelFill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        drawText(title, font: titleFont, color: ink, in: CGRect(x: rect.minX + 14, y: rect.maxY - 27, width: rect.width - 28, height: 16))
        drawText(body, font: font, color: secondary, in: CGRect(x: rect.minX + 14, y: rect.minY + 12, width: rect.width - 28, height: bodyHeight + 4), lineSpacing: 2)
        cursorY = rect.minY
    }

    private func drawSubheading(_ text: String) {
        ensureSpace(30)
        drawFlowingText(text, font: .systemFont(ofSize: 13, weight: .semibold), color: ink, lineSpacing: 2)
        cursorY -= 6
    }

    private func drawEmptyState(_ text: String) {
        drawFlowingText(text, font: .systemFont(ofSize: 10), color: secondary, lineSpacing: 2)
    }

    private func drawKeyValue(_ key: String, _ value: String, monospaced: Bool = false) {
        let keyWidth: CGFloat = 128
        let valueWidth = contentWidth - keyWidth - 12
        let valueFont = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
            : NSFont.systemFont(ofSize: 9.5)
        let valueHeight = textHeight(value, font: valueFont, width: valueWidth, lineSpacing: 2)
        let rowHeight = max(17, valueHeight)
        ensureSpace(rowHeight + 5)
        drawText(key, font: .systemFont(ofSize: 9, weight: .medium), color: secondary, in: CGRect(x: margin, y: cursorY - rowHeight, width: keyWidth, height: rowHeight), lineSpacing: 2)
        drawText(value, font: valueFont, color: ink, in: CGRect(x: margin + keyWidth + 12, y: cursorY - rowHeight, width: valueWidth, height: rowHeight), lineSpacing: 2)
        cursorY -= rowHeight + 5
    }

    private func drawOptionalKeyValue(_ key: String, _ value: String?) {
        if let value, !value.isEmpty { drawKeyValue(key, value) }
    }

    private func drawFlowingText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat,
        leftInset: CGFloat = 0
    ) {
        let width = contentWidth - leftInset
        var remaining = text
        while !remaining.isEmpty {
            let available = max(0, cursorY - minimumY)
            if available < font.pointSize * 1.8 {
                beginPage()
            }
            let pageAvailable = max(font.pointSize * 1.8, cursorY - minimumY)
            // AppKit's attributed-string bounding rectangle can be fractionally shorter than
            // the final line fragment when a paragraph nearly fills a PDF page. Reserve one
            // physical line so the renderer never clips a measured final line at the footer.
            let lineSafety = ceil(font.boundingRectForFont.height + lineSpacing + 2)
            let safePageAvailable = max(font.pointSize * 1.8, pageAvailable - lineSafety)
            let fullHeight = textHeight(remaining, font: font, width: width, lineSpacing: lineSpacing)
            if fullHeight <= safePageAvailable {
                let reservedHeight = min(pageAvailable, fullHeight + lineSafety)
                drawText(remaining, font: font, color: color, in: CGRect(x: margin + leftInset, y: cursorY - reservedHeight, width: width, height: reservedHeight), lineSpacing: lineSpacing)
                cursorY -= reservedHeight
                return
            }

            let split = fittingPrefix(in: remaining, font: font, width: width, height: safePageAvailable, lineSpacing: lineSpacing)
            guard split > remaining.startIndex else {
                beginPage()
                continue
            }
            let chunk = String(remaining[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let height = textHeight(chunk, font: font, width: width, lineSpacing: lineSpacing)
            let reservedHeight = min(pageAvailable, height + lineSafety)
            drawText(chunk, font: font, color: color, in: CGRect(x: margin + leftInset, y: cursorY - reservedHeight, width: width, height: reservedHeight), lineSpacing: lineSpacing)
            remaining = String(remaining[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            beginPage()
        }
    }

    private func fittingPrefix(
        in string: String,
        font: NSFont,
        width: CGFloat,
        height: CGFloat,
        lineSpacing: CGFloat
    ) -> String.Index {
        let words = string.indices.filter { index in
            string[index].isWhitespace
        } + [string.endIndex]
        var low = 0
        var high = words.count - 1
        var best = string.startIndex
        while low <= high {
            let middle = (low + high) / 2
            let index = words[middle]
            let candidate = String(string[..<index])
            if textHeight(candidate, font: font, width: width, lineSpacing: lineSpacing) <= height {
                best = index
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    private func ensureSpace(_ height: CGFloat) {
        if cursorY - height < minimumY { beginPage() }
    }

    private func drawRule(color: NSColor? = nil, width: CGFloat = 0.6) {
        (color ?? hairline).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: margin, y: cursorY))
        path.line(to: CGPoint(x: margin + contentWidth, y: cursorY))
        path.lineWidth = width
        path.stroke()
    }

    private func drawText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        align: NSTextAlignment = .left,
        in rect: CGRect,
        lineSpacing: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        (string as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    private func textHeight(
        _ string: String,
        font: NSFont,
        width: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: string,
            attributes: [.font: font, .paragraphStyle: paragraph]
        ))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(
            width: width,
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height) + 1
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .long, time: .standard, locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
        ) + " UTC"
    }

    private func coordinate(latitude: Double, longitude: Double) -> String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    private func photoGeometryDescription(_ geometry: AnalysisAnnotationGeometry) -> String {
        switch geometry {
        case .segment(let start, let end):
            return "segment (\(normalized(start))) to (\(normalized(end)))"
        case .bounds(let bounds):
            return "bounds (\(normalized(bounds.minimum))) to (\(normalized(bounds.maximum)))"
        case .polygon(let points):
            return "polygon with \(points.count) vertices: "
                + points.map { "(\(normalized($0)))" }.joined(separator: ", ")
        case .anchor(let point):
            return "anchor (\(normalized(point)))"
        }
    }

    private func normalized(_ point: AnalysisNormalizedPoint) -> String {
        String(format: "%.4f, %.4f", locale: Locale(identifier: "en_US_POSIX"), point.x, point.y)
    }

    private func reportColor(_ color: AnalysisAnnotationColor) -> NSColor {
        switch color {
        case .custom(let custom):
            NSColor(srgbRed: custom.red, green: custom.green, blue: custom.blue, alpha: max(0.35, custom.opacity))
        case .palette(let palette):
            switch palette {
            case .yellow: NSColor(srgbRed: 0.88, green: 0.68, blue: 0.02, alpha: 1)
            case .red: NSColor(srgbRed: 0.78, green: 0.12, blue: 0.16, alpha: 1)
            case .green: NSColor(srgbRed: 0.10, green: 0.56, blue: 0.28, alpha: 1)
            case .cyan: NSColor(srgbRed: 0.03, green: 0.56, blue: 0.68, alpha: 1)
            case .blue: NSColor(srgbRed: 0.10, green: 0.34, blue: 0.78, alpha: 1)
            case .orange: NSColor(srgbRed: 0.88, green: 0.38, blue: 0.04, alpha: 1)
            case .purple: NSColor(srgbRed: 0.50, green: 0.22, blue: 0.70, alpha: 1)
            case .white: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1)
            case .black: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
            }
        }
    }

    private var filteredRawMetadata: [AnalysisRawMetadataEntry] {
        snapshot.rawMetadata.filter { entry in
            let field = "\(entry.namespace) \(entry.key)".lowercased()
            if !options.includeCanonicalPath,
               ["path", "directory", "folder"].contains(where: field.contains) {
                return false
            }
            if !options.includeCameraSerialNumber,
               ["serial", "ownername", "owner name"].contains(where: field.contains) {
                return false
            }
            if !options.includeLocationCoordinates,
               ["gps", "latitude", "longitude", "location"].contains(where: field.contains) {
                return false
            }
            return true
        }
    }
}
