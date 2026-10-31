import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AnalysisEvidenceJPEGError: Error, LocalizedError {
    case sourceImageUnavailable
    case bitmapCreationFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .sourceImageUnavailable:
            "The source image could not be decoded for evidence export."
        case .bitmapCreationFailed:
            "The annotated evidence bitmap could not be created."
        case .encodingFailed:
            "The annotated evidence bitmap could not be encoded as JPEG."
        }
    }
}

/// Creates flattened, display-oriented evidence figures without changing the source file.
/// Photo coordinates use the case's normalized top-left frame; map coordinates use the frozen
/// WGS 84 viewport also used by analysis reports.
///
/// Bitmap drawing and JPEG encoding run in `@concurrent` functions that take and return only
/// Sendable values (`CGImage`, `Data`), so multi-megapixel evidence never blocks the main actor.
/// The MainActor entry points only fetch inputs and wrap results for AppKit callers.
@MainActor
enum AnalysisEvidenceJPEGRenderer {
    static func photoJPEG(
        sourceURL: URL,
        annotations: [AnalysisAnnotation],
        maxPixelSize: CGFloat = 8_192
    ) async throws -> Data {
        let source = try await displayOrientedSourceCGImage(
            sourceURL: sourceURL,
            maxPixelSize: maxPixelSize
        )
        return try await renderAnnotatedPhotoJPEG(
            source: source,
            annotations: annotations.filter(\.isVisible)
        )
    }

    static func annotatedPhotoImage(
        sourceURL: URL,
        annotations: [AnalysisAnnotation],
        maxPixelSize: CGFloat = 4_096
    ) async throws -> NSImage {
        let source = try await displayOrientedSourceCGImage(
            sourceURL: sourceURL,
            maxPixelSize: maxPixelSize
        )
        let rendered = try await renderAnnotatedPhoto(
            source: source,
            annotations: annotations.filter(\.isVisible),
            interpolationQuality: .high
        )
        return nsImage(rendered)
    }

    static func displayOrientedSourceCGImage(
        sourceURL: URL,
        maxPixelSize: CGFloat = 4_096
    ) async throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceGetType(imageSource) != nil else {
            throw AnalysisEvidenceJPEGError.sourceImageUnavailable
        }
        guard let source = await FullScreenImageCache.loadDownsampledOffPool(
            from: sourceURL,
            maxPixelSize: maxPixelSize
        ) else {
            throw AnalysisEvidenceJPEGError.sourceImageUnavailable
        }
        try Task.checkCancellation()
        return source
    }

    /// Extracts an upright source crop without resampling, then flattens the visible annotations
    /// that intersect it. The returned bitmap retains the crop's exact displayed source-pixel
    /// dimensions; any later page-fit scaling is presentation only.
    static func annotatedEvidenceCropImage(
        sourceURL: URL,
        crop: AnalysisReportEvidenceCrop,
        annotations: [AnalysisAnnotation]
    ) async throws -> NSImage {
        guard let source = await FullScreenImageCache.loadFullResolutionOffPool(from: sourceURL),
              source.width == crop.displayedSourceWidth,
              source.height == crop.displayedSourceHeight,
              let croppedSource = AnalysisScopeSelection.croppedImage(
                  from: source,
                  normalizedRect: crop.normalizedDisplayRect
              ) else {
            throw AnalysisEvidenceJPEGError.sourceImageUnavailable
        }
        try Task.checkCancellation()

        let cropAnnotations = cropRelativeAnnotations(
            annotations.filter(\.isVisible),
            cropRect: crop.normalizedDisplayRect
        )
        let rendered = try await renderAnnotatedPhoto(
            source: croppedSource,
            annotations: cropAnnotations,
            interpolationQuality: .none
        )
        return nsImage(rendered)
    }

    /// `usesOpenStreetMap` sends the map region's tile coordinates to OpenStreetMap; without it
    /// the figure is a plain schematic grid.
    static func mapJPEG(
        evidence: AnalysisReportMapEvidence,
        usesOpenStreetMap: Bool = true,
        pixelSize: CGSize = CGSize(width: 2_000, height: 1_200)
    ) async throws -> Data {
        let evidence = evidence.fitted(toAspect: pixelSize.width / pixelSize.height)
        let basemap = usesOpenStreetMap
            ? try await mapBasemap(evidence: evidence, pixelSize: pixelSize)
            : nil
        return try await renderMapJPEG(evidence: evidence, basemap: basemap, pixelSize: pixelSize)
    }

    static func annotatedMapImage(
        evidence: AnalysisReportMapEvidence,
        pixelSize: CGSize = CGSize(width: 2_000, height: 1_200)
    ) async throws -> NSImage {
        let evidence = evidence.fitted(toAspect: pixelSize.width / pixelSize.height)
        let basemap = try await mapBasemap(evidence: evidence, pixelSize: pixelSize)
        let rendered = try await renderMap(evidence: evidence, basemap: basemap, pixelSize: pixelSize)
        return nsImage(rendered)
    }

    /// The tile snapshotter is MainActor-bound; convert its result to a Sendable CGImage here
    /// so the expensive flattening can run off the main actor.
    private static func mapBasemap(
        evidence: AnalysisReportMapEvidence,
        pixelSize: CGSize
    ) async throws -> CGImage? {
        let basemap = try? await AnalysisOpenStreetMapSnapshotter.image(
            viewport: evidence.viewport,
            pixelSize: pixelSize
        )
        try Task.checkCancellation()
        return basemap?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    @concurrent
    nonisolated private static func renderAnnotatedPhotoJPEG(
        source: CGImage,
        annotations: [AnalysisAnnotation]
    ) async throws -> Data {
        let rendered = try await renderAnnotatedPhoto(
            source: source,
            annotations: annotations,
            interpolationQuality: .high
        )
        try Task.checkCancellation()
        return try jpegData(from: rendered)
    }

    @concurrent
    nonisolated private static func renderAnnotatedPhoto(
        source: CGImage,
        annotations: [AnalysisAnnotation],
        interpolationQuality: CGInterpolationQuality
    ) async throws -> CGImage {
        let size = CGSize(width: source.width, height: source.height)
        return try bitmapImage(size: size) { context in
            context.interpolationQuality = interpolationQuality
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(origin: .zero, size: size))
            context.setBlendMode(.normal)
            drawPhotoAnnotations(annotations, in: CGRect(origin: .zero, size: size))
        }
    }

    @concurrent
    nonisolated private static func renderMapJPEG(
        evidence: AnalysisReportMapEvidence,
        basemap: CGImage?,
        pixelSize: CGSize
    ) async throws -> Data {
        let rendered = try await renderMap(evidence: evidence, basemap: basemap, pixelSize: pixelSize)
        try Task.checkCancellation()
        return try jpegData(from: rendered)
    }

    @concurrent
    nonisolated private static func renderMap(
        evidence: AnalysisReportMapEvidence,
        basemap: CGImage?,
        pixelSize: CGSize
    ) async throws -> CGImage {
        try bitmapImage(size: pixelSize) { context in
            let rect = CGRect(origin: .zero, size: pixelSize)
            if let basemap {
                context.interpolationQuality = .high
                context.setBlendMode(.copy)
                context.draw(basemap, in: rect)
                context.setBlendMode(.normal)
            } else {
                NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
                rect.fill()
                drawMapGrid(in: rect)
            }
            drawMapEvidence(evidence, in: rect)
            drawSolarEvidence(evidence, in: rect)
            drawMapAttribution(hasBasemap: basemap != nil, in: rect)
        }
    }

    /// Draws into a private bitmap. `NSGraphicsContext.current` is per-thread, so AppKit path and
    /// text drawing into this offscreen context is safe off the main thread.
    nonisolated private static func bitmapImage(
        size: CGSize,
        drawing: (CGContext) -> Void
    ) throws -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
            throw AnalysisEvidenceJPEGError.bitmapCreationFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        drawing(graphicsContext.cgContext)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let image = representation.cgImage else {
            throw AnalysisEvidenceJPEGError.bitmapCreationFailed
        }
        return image
    }

    nonisolated private static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AnalysisEvidenceJPEGError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.94,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AnalysisEvidenceJPEGError.encodingFailed
        }
        return data as Data
    }

    nonisolated private static func drawPhotoAnnotations(
        _ annotations: [AnalysisAnnotation],
        in rect: CGRect
    ) {
        let scale = max(1, min(rect.width, rect.height) / 1_200)
        for annotation in annotations {
            let color = nsColor(annotation.style.color)
            let path = NSBezierPath()
            path.lineWidth = max(2, CGFloat(annotation.style.lineWidthPoints) * scale)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            switch annotation.geometry {
            case .segment(let start, let end):
                let first = photoPoint(start, in: rect)
                let last = photoPoint(end, in: rect)
                path.move(to: first)
                path.line(to: last)
                color.setStroke()
                path.stroke()
                if annotation.kind == .arrow {
                    drawArrowHead(from: first, to: last, color: color, scale: scale)
                }
                drawPhotoLabel(annotation, near: midpoint(first, last), scale: scale)

            case .bounds(let bounds):
                let minimum = photoPoint(bounds.minimum, in: rect)
                let maximum = photoPoint(bounds.maximum, in: rect)
                let boundsRect = CGRect(
                    x: minimum.x,
                    y: maximum.y,
                    width: maximum.x - minimum.x,
                    height: minimum.y - maximum.y
                ).standardized
                let shape = annotation.kind == .ellipse
                    ? NSBezierPath(ovalIn: boundsRect)
                    : NSBezierPath(rect: boundsRect)
                shape.lineWidth = path.lineWidth
                if annotation.style.fillOpacity > 0 {
                    color.withAlphaComponent(annotation.style.fillOpacity).setFill()
                    shape.fill()
                }
                color.setStroke()
                shape.stroke()
                drawPhotoLabel(
                    annotation,
                    near: CGPoint(x: boundsRect.minX, y: boundsRect.maxY),
                    scale: scale
                )

            case .polygon(let points):
                guard let first = points.first else { continue }
                let shape = NSBezierPath()
                shape.move(to: photoPoint(first, in: rect))
                for point in points.dropFirst() {
                    shape.line(to: photoPoint(point, in: rect))
                }
                shape.close()
                shape.lineWidth = path.lineWidth
                shape.lineJoinStyle = .round
                if annotation.style.fillOpacity > 0 {
                    color.withAlphaComponent(annotation.style.fillOpacity).setFill()
                    shape.fill()
                }
                color.setStroke()
                shape.stroke()
                drawPhotoLabel(
                    annotation,
                    near: photoPoint(first, in: rect),
                    scale: scale
                )

            case .anchor(let point):
                if annotation.kind == .counter {
                    let center = photoPoint(point, in: rect)
                    let number = String(annotation.counterNumber ?? 1) as NSString
                    let font = NSFont.systemFont(ofSize: (number.length > 3 ? 8 : 11) * scale, weight: .bold)
                    let textColor: NSColor
                    switch annotation.style.color {
                    case .palette(.black): textColor = .white
                    case .custom(let custom)
                        where 0.2126 * custom.red + 0.7152 * custom.green + 0.0722 * custom.blue < 0.25:
                        textColor = .white
                    default: textColor = .black
                    }
                    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
                    let size = number.size(withAttributes: attributes)
                    let diameter = 24 * scale
                    let counterLineWidth = CGFloat(min(3, annotation.style.lineWidthPoints)) * scale
                    let circle = NSBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
                    color.setFill()
                    circle.fill()
                    textColor.withAlphaComponent(0.82).setStroke()
                    circle.lineWidth = counterLineWidth + 2 * scale
                    circle.stroke()
                    color.setStroke()
                    circle.lineWidth = counterLineWidth
                    circle.stroke()
                    number.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
                    drawPhotoLabel(annotation, near: center, scale: scale)
                } else {
                    drawPhotoLabel(annotation, near: photoPoint(point, in: rect), scale: scale)
                }
            }
        }
    }

    nonisolated private static func cropRelativeAnnotations(
        _ annotations: [AnalysisAnnotation],
        cropRect: CGRect
    ) -> [AnalysisAnnotation] {
        guard cropRect.width > 0, cropRect.height > 0 else { return [] }

        func map(_ point: AnalysisNormalizedPoint) -> AnalysisNormalizedPoint {
            AnalysisNormalizedPoint(
                x: (point.x - Double(cropRect.minX)) / Double(cropRect.width),
                y: (point.y - Double(cropRect.minY)) / Double(cropRect.height)
            )
        }

        return annotations.compactMap { annotation in
            guard annotationBounds(annotation.geometry).intersects(cropRect) else { return nil }
            var relative = annotation
            switch annotation.geometry {
            case .segment(let start, let end):
                relative.geometry = .segment(start: map(start), end: map(end))
            case .bounds(let bounds):
                relative.geometry = .bounds(AnalysisNormalizedBounds(
                    minimum: map(bounds.minimum),
                    maximum: map(bounds.maximum)
                ))
            case .polygon(let points):
                relative.geometry = .polygon(points.map(map))
            case .anchor(let point):
                relative.geometry = .anchor(map(point))
            }
            return relative
        }
    }

    nonisolated private static func annotationBounds(_ geometry: AnalysisAnnotationGeometry) -> CGRect {
        let points: [AnalysisNormalizedPoint]
        switch geometry {
        case .segment(let start, let end): points = [start, end]
        case .bounds(let bounds): points = [bounds.minimum, bounds.maximum]
        case .polygon(let vertices): points = vertices
        case .anchor(let point): points = [point]
        }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else {
            return .null
        }
        // A point/axis-aligned line still needs a non-empty hit target for intersection testing.
        let epsilon = 0.000_001
        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(max(epsilon, maxX - minX)),
            height: CGFloat(max(epsilon, maxY - minY))
        )
    }

    nonisolated private static func drawPhotoLabel(
        _ annotation: AnalysisAnnotation,
        near point: CGPoint,
        scale: CGFloat
    ) {
        let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? annotation.measurementCalibration?.formattedKnownLength
        guard let text, !text.isEmpty else { return }
        let offset: CGFloat = annotation.kind == .counter ? 16 : 6
        drawLabel(
            text,
            at: CGPoint(x: point.x + offset * scale, y: point.y + offset * scale),
            color: nsColor(annotation.style.color),
            scale: scale
        )
    }

    nonisolated private static func photoPoint(
        _ point: AnalysisNormalizedPoint,
        in rect: CGRect
    ) -> CGPoint {
        CGPoint(
            x: rect.minX + rect.width * CGFloat(point.x),
            y: rect.minY + rect.height * CGFloat(1 - point.y)
        )
    }

    nonisolated private static func drawArrowHead(
        from start: CGPoint,
        to end: CGPoint,
        color: NSColor,
        scale: CGFloat
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = 14 * scale
        let spread = CGFloat.pi / 7
        let path = NSBezierPath()
        path.move(to: end)
        path.line(to: CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        ))
        path.move(to: end)
        path.line(to: CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        ))
        path.lineWidth = max(2, 2 * scale)
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    nonisolated private static func drawMapEvidence(
        _ evidence: AnalysisReportMapEvidence,
        in rect: CGRect
    ) {
        let scale = max(1, min(rect.width, rect.height) / 1_200)
        if let location = evidence.investigationLocation {
            let point = mapPoint(location.coordinate, viewport: evidence.viewport, in: rect)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: point.x - 7 * scale,
                y: point.y - 7 * scale,
                width: 14 * scale,
                height: 14 * scale
            )).fill()
        }

        for annotation in evidence.visibleAnnotations {
            let color = nsColor(annotation.style.color)
            let width = max(2, CGFloat(annotation.style.lineWidthPoints) * scale)
            switch annotation.geometry {
            case .point(let coordinate):
                let point = mapPoint(coordinate, viewport: evidence.viewport, in: rect)
                color.setFill()
                NSBezierPath(ovalIn: CGRect(
                    x: point.x - 6 * scale,
                    y: point.y - 6 * scale,
                    width: 12 * scale,
                    height: 12 * scale
                )).fill()
                drawMapLabel(annotation, near: point, scale: scale)

            case .segment(let start, let end):
                let first = mapPoint(start, viewport: evidence.viewport, in: rect)
                let last = mapPoint(end, viewport: evidence.viewport, in: rect)
                let path = NSBezierPath()
                path.move(to: first)
                path.line(to: last)
                path.lineWidth = width
                path.lineCapStyle = .round
                color.setStroke()
                path.stroke()
                drawMapLabel(annotation, near: midpoint(first, last), scale: scale)

            case .polygon(let coordinates):
                guard let firstCoordinate = coordinates.first else { continue }
                let path = NSBezierPath()
                path.move(to: mapPoint(firstCoordinate, viewport: evidence.viewport, in: rect))
                for coordinate in coordinates.dropFirst() {
                    path.line(to: mapPoint(coordinate, viewport: evidence.viewport, in: rect))
                }
                path.close()
                color.withAlphaComponent(annotation.style.fillOpacity).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = width
                path.lineJoinStyle = .round
                path.stroke()
                if !isFieldOfView(annotation) {
                    drawMapLabel(
                        annotation,
                        near: mapPoint(
                            annotation.representativeCoordinate,
                            viewport: evidence.viewport,
                            in: rect
                        ),
                        scale: scale
                    )
                }
            }
        }
    }

    nonisolated private static func drawMapLabel(
        _ annotation: AnalysisMapAnnotation,
        near point: CGPoint,
        scale: CGFloat
    ) {
        guard let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        drawLabel(
            text,
            at: CGPoint(x: point.x + 8 * scale, y: point.y + 8 * scale),
            color: nsColor(annotation.style.color),
            scale: scale
        )
    }

    nonisolated private static func drawLabel(
        _ text: String,
        at point: CGPoint,
        color: NSColor,
        scale: CGFloat
    ) {
        let font = NSFont.systemFont(ofSize: 14 * scale, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let measured = attributed.size()
        let labelRect = CGRect(
            x: point.x,
            y: point.y,
            width: measured.width + 12 * scale,
            height: measured.height + 7 * scale
        )
        color.withAlphaComponent(0.90).setFill()
        NSBezierPath(
            roundedRect: labelRect,
            xRadius: 4 * scale,
            yRadius: 4 * scale
        ).fill()
        attributed.draw(at: CGPoint(
            x: labelRect.minX + 6 * scale,
            y: labelRect.minY + 3 * scale
        ))
    }

    nonisolated private static func mapPoint(
        _ coordinate: AnalysisGeoCoordinate,
        viewport: AnalysisMapViewport,
        in rect: CGRect
    ) -> CGPoint {
        var longitudeOffset = coordinate.longitude - viewport.center.longitude
        if longitudeOffset > 180 { longitudeOffset -= 360 }
        if longitudeOffset < -180 { longitudeOffset += 360 }
        let normalizedX = 0.5 + longitudeOffset / viewport.longitudeDelta
        let normalizedY = 0.5 + (coordinate.latitude - viewport.center.latitude)
            / viewport.latitudeDelta
        // Not clamped: off-figure points stay off the figure (the bitmap clips them) instead of
        // being pinned to the edge, which bent rays and shapes.
        return CGPoint(
            x: rect.minX + rect.width * CGFloat(normalizedX),
            y: rect.minY + rect.height * CGFloat(normalizedY)
        )
    }

    nonisolated private static func drawMapGrid(in rect: CGRect) {
        NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
        for index in 1..<5 {
            let fraction = CGFloat(index) / 5
            let path = NSBezierPath()
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.line(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// The Sun, shadow, sunrise and sunset rays the OSINT map shows, with a legend.
    nonisolated private static func drawSolarEvidence(
        _ evidence: AnalysisReportMapEvidence,
        in rect: CGRect
    ) {
        guard let solar = evidence.solarEvidence,
              let model = AnalysisSolarMapRenderModel(
                  overlay: solar.overlay,
                  origin: solar.coordinate,
                  latitudeDelta: evidence.viewport.latitudeDelta,
                  longitudeDelta: evidence.viewport.longitudeDelta,
                  day: solar.day
              ),
              !model.rays.isEmpty else { return }
        let scale = max(1, min(rect.width, rect.height) / 1_200)
        for ray in model.rays {
            let style = solarRayStyle(ray.kind)
            let path = NSBezierPath()
            path.move(to: mapPoint(ray.origin, viewport: evidence.viewport, in: rect))
            path.line(to: mapPoint(ray.destination, viewport: evidence.viewport, in: rect))
            path.lineWidth = style.lineWidth * scale
            path.lineCapStyle = .round
            if !style.dash.isEmpty {
                let dash = style.dash.map { $0 * scale }
                path.setLineDash(dash, count: dash.count, phase: 0)
            }
            style.color.setStroke()
            path.stroke()
        }

        let rowHeight = 22 * scale
        let legendRect = CGRect(
            x: rect.minX + 12 * scale,
            y: rect.maxY - CGFloat(model.rays.count) * rowHeight - 28 * scale,
            width: 300 * scale,
            height: CGFloat(model.rays.count) * rowHeight + 16 * scale
        )
        NSColor.white.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: legendRect, xRadius: 6 * scale, yRadius: 6 * scale).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        for (index, ray) in model.rays.enumerated() {
            let y = legendRect.maxY - 8 * scale - (CGFloat(index) + 0.5) * rowHeight
            let style = solarRayStyle(ray.kind)
            let sample = NSBezierPath()
            sample.move(to: CGPoint(x: legendRect.minX + 10 * scale, y: y))
            sample.line(to: CGPoint(x: legendRect.minX + 44 * scale, y: y))
            sample.lineWidth = style.lineWidth * scale
            if !style.dash.isEmpty {
                let dash = style.dash.map { $0 * scale }
                sample.setLineDash(dash, count: dash.count, phase: 0)
            }
            style.color.setStroke()
            sample.stroke()
            NSAttributedString(
                string: "\(ray.kind.displayName) \(String(format: "%.1f°", ray.bearingDegrees))",
                attributes: attributes
            ).draw(at: CGPoint(x: legendRect.minX + 52 * scale, y: y - 8 * scale))
        }
    }

    /// Same palette as the on-screen rays and the PDF figure.
    nonisolated private static func solarRayStyle(
        _ kind: AnalysisSolarMapRayKind
    ) -> (color: NSColor, lineWidth: CGFloat, dash: [CGFloat]) {
        switch kind {
        case .sun: (NSColor(srgbRed: 0.95, green: 0.72, blue: 0.04, alpha: 1), 3, [])
        case .shadow: (NSColor(srgbRed: 0.48, green: 0.24, blue: 0.68, alpha: 1), 2.4, [7, 5])
        case .sunrise: (NSColor(srgbRed: 0.90, green: 0.42, blue: 0.10, alpha: 0.82), 1.6, [])
        case .sunset: (NSColor(srgbRed: 0.84, green: 0.20, blue: 0.18, alpha: 0.82), 1.6, [])
        }
    }

    nonisolated private static func drawMapAttribution(hasBasemap: Bool, in rect: CGRect) {
        let text = hasBasemap
            ? "North up | OpenStreetMap | © OpenStreetMap contributors"
            : "North up | Schematic WGS 84 viewport"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        NSAttributedString(string: " \(text) ", attributes: attributes).draw(
            at: CGPoint(x: rect.minX + 12, y: rect.minY + 12)
        )
    }

    nonisolated private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    nonisolated private static func isFieldOfView(_ annotation: AnalysisMapAnnotation) -> Bool {
        annotation.kind == .shape && annotation.text == "Field of view"
    }

    nonisolated private static func nsColor(_ color: AnalysisAnnotationColor) -> NSColor {
        switch color {
        case .palette(let palette):
            switch palette {
            case .yellow: NSColor(srgbRed: 1, green: 0.83, blue: 0.08, alpha: 1)
            case .red: NSColor(srgbRed: 1, green: 0.20, blue: 0.18, alpha: 1)
            case .green: NSColor(srgbRed: 0.20, green: 0.84, blue: 0.38, alpha: 1)
            case .cyan: NSColor(srgbRed: 0.18, green: 0.88, blue: 1, alpha: 1)
            case .blue: NSColor(srgbRed: 0.20, green: 0.68, blue: 1, alpha: 1)
            case .orange: NSColor(srgbRed: 1, green: 0.43, blue: 0.12, alpha: 1)
            case .purple: NSColor(srgbRed: 0.74, green: 0.48, blue: 1, alpha: 1)
            case .white: .white
            case .black: .black
            }
        case .custom(let custom):
            NSColor(
                srgbRed: custom.red,
                green: custom.green,
                blue: custom.blue,
                alpha: custom.opacity
            )
        }
    }
}
