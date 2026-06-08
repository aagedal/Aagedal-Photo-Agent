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
    /// - Parameters:
    ///   - cgImage: the already-decoded, EXIF-oriented image.
    ///   - imageSize: full image dimensions (unused for normalised boxes, kept for symmetry).
    ///   - ocrConfidenceThreshold: minimum OCR confidence (0...1).
    ///   - minHeightFraction: minimum box height as a fraction of image height.
    func detectNumbers(
        in cgImage: CGImage,
        imageSize: CGSize,
        ocrConfidenceThreshold: Float,
        minHeightFraction: CGFloat
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
                    guard observation.boundingBox.height >= minHeightFraction else { continue }
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= ocrConfidenceThreshold else { continue }

                    let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 1, trimmed.count <= 2,
                          trimmed.allSatisfy(\.isNumber),
                          let value = Int(trimmed), (0...99).contains(value) else { continue }

                    let color = self.sampleDominantColor(in: cgImage, near: observation.boundingBox)
                    results.append(RawNumber(
                        value: value,
                        confidence: candidate.confidence,
                        box: observation.boundingBox,
                        color: color
                    ))
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
