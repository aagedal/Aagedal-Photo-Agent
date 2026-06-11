import Foundation
import Vision
import CoreGraphics

/// Detects jersey numbers in an image using on-device Apple Vision OCR, and
/// samples the dominant jersey colour near each number so the two teams can be
/// told apart by kit colour.
///
/// Runs at the image level (not anchored to a face) so back-turned players —
/// number visible, no face — are still captured. Modelled on
/// `ClothingFeatureService`: a `nonisolated struct` reusing the same
/// Vision→pixel cropping math.
nonisolated struct JerseyDetectionService: Sendable {

    /// A raw jersey-number detection before association to a face/team.
    struct RawNumber: Sendable {
        var value: Int
        var confidence: Float
        /// Normalised bounding box (Vision coordinates, origin bottom-left).
        var box: CGRect
        var color: ColorRGB?
    }

    /// Detect plausible jersey numbers in the image.
    ///
    /// Runs OCR on the whole image **and** a grid of overlapping tiles, then merges. Vision
    /// downsamples large frames internally, so small chest numbers (~3% of image height on a
    /// 4–6k sports frame) are only found when a tile makes them large enough relative to the
    /// input — the same reason face detection tiles.
    ///
    /// Known limitation: outline/keyline digits (hollow glyphs in the jersey's own colour with
    /// a thin contrasting border) are not proposed by Vision's text detector at all, under any
    /// preprocessing tried — those numbers cannot be recovered by OCR.
    ///
    /// - Parameters:
    ///   - cgImage: the already-decoded, EXIF-oriented image.
    ///   - imageSize: full image dimensions (unused for normalised boxes, kept for symmetry).
    ///   - ocrConfidenceThreshold: minimum OCR confidence (0...1). Note Vision reports only
    ///     coarse confidences (≈0.3 / 0.5 / 1.0).
    ///   - minHeightFraction: minimum box height as a fraction of full-image height.
    func detectNumbers(
        in cgImage: CGImage,
        imageSize: CGSize,
        ocrConfidenceThreshold: Float,
        minHeightFraction: CGFloat
    ) async throws -> [RawNumber] {
        var candidates: [RawNumber] = []

        // Whole image: catches large back numbers spanning tile boundaries.
        candidates += try await recognizeNumbers(
            in: cgImage,
            mappedTo: CGRect(x: 0, y: 0, width: 1, height: 1),
            ocrConfidenceThreshold: ocrConfidenceThreshold
        )

        // Overlapping tiles at two scales. Vision's text detector is framing-sensitive on
        // isolated digits: empirically (5k sports frames) a 3×3 grid finds chest numbers a
        // 4×4 misses and vice versa, so both run and the merge step deduplicates.
        for grid in [3, 4] {
            for region in Self.tileRegions(grid: grid) {
                guard !Task.isCancelled else { break }
                let pixelRect = CGRect(
                    x: region.origin.x * CGFloat(cgImage.width),
                    y: (1 - region.origin.y - region.height) * CGFloat(cgImage.height),
                    width: region.width * CGFloat(cgImage.width),
                    height: region.height * CGFloat(cgImage.height)
                )
                guard let tile = cgImage.cropping(to: pixelRect.integral) else { continue }
                candidates += try await recognizeNumbers(
                    in: tile,
                    mappedTo: region,
                    ocrConfidenceThreshold: ocrConfidenceThreshold
                )
            }
        }

        // Merge duplicates (the same number seen by several passes), apply the size floor,
        // then sample the jersey colour once per surviving detection.
        let merged = Self.deduplicate(candidates).filter { $0.box.height >= minHeightFraction }
        return merged.map { raw in
            var enriched = raw
            enriched.color = sampleDominantColor(in: cgImage, near: raw.box)
            return enriched
        }
    }

    /// Run text recognition on one image (full frame or tile) and return jersey-number
    /// candidates with boxes mapped into full-image normalised coordinates via `mappedTo`
    /// (the region of the full image this input covers, Vision coords). Colour sampling
    /// happens later, after deduplication.
    private func recognizeNumbers(
        in image: CGImage,
        mappedTo region: CGRect,
        ocrConfidenceThreshold: Float
    ) async throws -> [RawNumber] {
        // Parse into the Sendable `[RawNumber]` *inside* the completion handler —
        // `VNRecognizedTextObservation` is not Sendable and must not cross the
        // continuation boundary.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RawNumber], any Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var results: [RawNumber] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= ocrConfidenceThreshold,
                          let value = Self.parseJerseyNumber(candidate.string) else { continue }

                    let box = observation.boundingBox
                    let mappedBox = CGRect(
                        x: region.origin.x + box.origin.x * region.width,
                        y: region.origin.y + box.origin.y * region.height,
                        width: box.width * region.width,
                        height: box.height * region.height
                    )
                    results.append(RawNumber(
                        value: value,
                        confidence: candidate.confidence,
                        box: mappedBox,
                        color: nil
                    ))
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Extract a jersey number from an OCR string, tolerating a single junk character —
    /// stylised kit fonts often read as "c17" or "d7". Rejects anything with more than one
    /// non-digit (sponsor boards, dates, scoreboards: "TO26", "07.06.2026").
    static func parseJerseyNumber(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return nil }
        guard trimmed.filter({ !$0.isNumber }).count <= 1 else { return nil }
        let runs = trimmed.split(whereSeparator: { !$0.isNumber })
        guard runs.count == 1, runs[0].count <= 2,
              let value = Int(runs[0]), (0...99).contains(value) else { return nil }
        return value
    }

    /// Overlapping grid in Vision-normalised coordinates (matches the face detector's
    /// tiling scheme: each tile extends 15% of a tile size beyond its cell).
    private static func tileRegions(grid: Int) -> [CGRect] {
        var regions: [CGRect] = []
        let tw = 1.0 / CGFloat(grid), th = 1.0 / CGFloat(grid)
        let overlap: CGFloat = 0.15
        for r in 0..<grid {
            for c in 0..<grid {
                let rect = CGRect(
                    x: CGFloat(c) * tw - tw * overlap,
                    y: CGFloat(r) * th - th * overlap,
                    width: tw * (1 + 2 * overlap),
                    height: th * (1 + 2 * overlap)
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                regions.append(rect)
            }
        }
        return regions
    }

    /// Merge detections from overlapping passes. Candidates whose boxes coincide (IoU > 0.3
    /// or either centre lies in the other) are one physical number — even when the values
    /// differ: a one-digit read coinciding with a two-digit read is a partial read of the
    /// same print ("4" inside "14", "7" inside "17"). Prefers two-digit reads, then higher
    /// confidence, then larger boxes.
    static func deduplicate(_ candidates: [RawNumber]) -> [RawNumber] {
        let ranked = candidates.sorted { a, b in
            let aDigits = a.value >= 10 ? 2 : 1
            let bDigits = b.value >= 10 ? 2 : 1
            if aDigits != bDigits { return aDigits > bDigits }
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            return a.box.width * a.box.height > b.box.width * b.box.height
        }
        var merged: [RawNumber] = []
        for candidate in ranked {
            if !merged.contains(where: { boxesCoincide($0.box, candidate.box) }) {
                merged.append(candidate)
            }
        }
        return merged
    }

    private static func boxesCoincide(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return false }
        if a.contains(CGPoint(x: b.midX, y: b.midY)) || b.contains(CGPoint(x: a.midX, y: a.midY)) {
            return true
        }
        let unionArea = a.width * a.height + b.width * b.height - intersection.width * intersection.height
        return unionArea > 0 && (intersection.width * intersection.height) / unionArea > 0.3
    }

    /// Sample the dominant colour around a number's box — i.e. the surrounding
    /// jersey, not the (minority-area) number strokes. Expands the box to capture
    /// jersey fabric, downsamples, and takes the per-channel median (robust to the
    /// number itself, logos, and shadows).
    func sampleDominantColor(in cgImage: CGImage, near box: CGRect) -> ColorRGB? {
        let expanded = clamp(expand(box, byFraction: 0.6))
        guard expanded.width > 0, expanded.height > 0,
              let crop = cropRegion(from: cgImage, normalizedRect: expanded) else { return nil }
        return medianColor(of: crop)
    }

    // MARK: - Private helpers

    private func expand(_ rect: CGRect, byFraction f: CGFloat) -> CGRect {
        let dw = rect.width * f
        let dh = rect.height * f
        return CGRect(
            x: rect.origin.x - dw / 2,
            y: rect.origin.y - dh / 2,
            width: rect.width + dw,
            height: rect.height + dh
        )
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        var r = rect
        r.origin.x = max(0, r.origin.x)
        r.origin.y = max(0, r.origin.y)
        r.size.width = min(r.size.width, 1 - r.origin.x)
        r.size.height = min(r.size.height, 1 - r.origin.y)
        return r
    }

    /// Crop a normalized (Vision-coord, origin bottom-left) rect from a CGImage.
    /// Identical math to `ClothingFeatureService.cropRegion`.
    private func cropRegion(from cgImage: CGImage, normalizedRect: CGRect) -> CGImage? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normalizedRect.origin.x * imageWidth,
            y: (1 - normalizedRect.origin.y - normalizedRect.height) * imageHeight,
            width: normalizedRect.width * imageWidth,
            height: normalizedRect.height * imageHeight
        )
        return cgImage.cropping(to: pixelRect)
    }

    /// Per-channel median colour of a downsampled crop.
    private func medianColor(of cgImage: CGImage) -> ColorRGB? {
        let side = 16
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rs: [UInt8] = []; rs.reserveCapacity(side * side)
        var gs: [UInt8] = []; gs.reserveCapacity(side * side)
        var bs: [UInt8] = []; bs.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = pixels[i + 3]
            guard alpha > 16 else { continue } // skip transparent edge pixels
            rs.append(pixels[i])
            gs.append(pixels[i + 1])
            bs.append(pixels[i + 2])
        }
        guard !rs.isEmpty else { return nil }

        func median(_ values: [UInt8]) -> Double {
            let sorted = values.sorted()
            return Double(sorted[sorted.count / 2]) / 255.0
        }
        return ColorRGB(r: median(rs), g: median(gs), b: median(bs))
    }
}
