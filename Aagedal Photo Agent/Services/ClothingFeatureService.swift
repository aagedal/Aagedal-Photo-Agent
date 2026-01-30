import Foundation
import Vision
import CoreGraphics
import AppKit

/// Service for extracting clothing/torso features to supplement face recognition.
/// Used in Face+Clothing mode to help distinguish similar faces by their attire.
nonisolated struct ClothingFeatureService: Sendable {

    /// Estimate the torso region based on a detected face.
    /// The torso is assumed to be 1.5x face height below the face, with width expanded.
    /// - Parameters:
    ///   - faceRect: Normalized face bounding box (Vision coordinates, origin bottom-left)
    ///   - imageSize: Full image dimensions for clamping
    /// - Returns: Normalized rect for the estimated torso region, or nil if out of bounds
    func estimateTorsoRect(from faceRect: CGRect, imageSize: CGSize) -> CGRect? {
        // Face rect is normalized (0-1 range), Vision coordinates (origin at bottom-left)
        let faceHeight = faceRect.height
        let faceWidth = faceRect.width

        // Torso starts below the face (in Vision coords, "below" means lower Y value)
        // Gap between face bottom and torso top: ~0.2x face height
        let gap = faceHeight * 0.2
        let torsoHeight = faceHeight * 1.5
        let torsoWidth = faceWidth * 1.8  // Torso is wider than face

        // Calculate torso position (Vision coords: origin at bottom-left)
        let torsoY = faceRect.minY - gap - torsoHeight
        let torsoX = faceRect.midX - (torsoWidth / 2)

        var torsoRect = CGRect(
            x: torsoX,
            y: torsoY,
            width: torsoWidth,
            height: torsoHeight
        )

        // Clamp to normalized bounds (0-1)
        torsoRect.origin.x = max(0, torsoRect.origin.x)
        torsoRect.origin.y = max(0, torsoRect.origin.y)
        torsoRect.size.width = min(torsoRect.size.width, 1 - torsoRect.origin.x)
        torsoRect.size.height = min(torsoRect.size.height, 1 - torsoRect.origin.y)

        // Ensure the torso region is meaningful (at least 30% of face size)
        guard torsoRect.width > faceWidth * 0.3,
              torsoRect.height > faceHeight * 0.3 else {
            return nil
        }

        return torsoRect
    }

    /// Generate a VNFeaturePrint for a clothing/torso region.
    /// - Parameters:
    ///   - cgImage: The full source image
    ///   - torsoRect: Normalized rect for the torso region
    /// - Returns: Archived feature print data, or nil on failure
    func generateClothingFeaturePrint(for cgImage: CGImage, torsoRect: CGRect) async throws -> Data? {
        // Crop the torso region
        guard let croppedImage = cropRegion(from: cgImage, normalizedRect: torsoRect) else {
            return nil
        }

        // Generate feature print using Vision
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNGenerateImageFeaturePrintRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Compute the combined distance using face and clothing features.
    /// - Parameters:
    ///   - face1Data: Face feature print data for face 1
    ///   - face2Data: Face feature print data for face 2
    ///   - clothing1Data: Clothing feature print data for face 1 (optional)
    ///   - clothing2Data: Clothing feature print data for face 2 (optional)
    ///   - faceWeight: Weight for face distance (0-1)
    ///   - clothingWeight: Weight for clothing distance (0-1)
    /// - Returns: Combined weighted distance, or nil if face comparison fails
    func computeCombinedDistance(
        face1Data: Data,
        face2Data: Data,
        clothing1Data: Data?,
        clothing2Data: Data?,
        faceWeight: Float,
        clothingWeight: Float
    ) -> Float? {
        // Compute face distance (required)
        guard let faceFP1 = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: face1Data),
              let faceFP2 = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: face2Data) else {
            return nil
        }

        var faceDistance: Float = 0
        do {
            try faceFP1.computeDistance(&faceDistance, to: faceFP2)
        } catch {
            return nil
        }

        // If no clothing data, return face distance only
        guard let c1Data = clothing1Data,
              let c2Data = clothing2Data,
              let clothingFP1 = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: c1Data),
              let clothingFP2 = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: c2Data) else {
            return faceDistance
        }

        var clothingDistance: Float = 0
        do {
            try clothingFP1.computeDistance(&clothingDistance, to: clothingFP2)
        } catch {
            // Fall back to face-only distance
            return faceDistance
        }

        // Combine distances with weights
        return (faceDistance * faceWeight) + (clothingDistance * clothingWeight)
    }

    /// Compute combined distance using cached feature prints for performance.
    func computeCombinedDistanceCached(
        faceFP1: VNFeaturePrintObservation,
        faceFP2: VNFeaturePrintObservation,
        clothingFP1: VNFeaturePrintObservation?,
        clothingFP2: VNFeaturePrintObservation?,
        faceWeight: Float,
        clothingWeight: Float
    ) -> Float? {
        var faceDistance: Float = 0
        do {
            try faceFP1.computeDistance(&faceDistance, to: faceFP2)
        } catch {
            return nil
        }

        // If no clothing features, return face distance only
        guard let cfp1 = clothingFP1, let cfp2 = clothingFP2 else {
            return faceDistance
        }

        var clothingDistance: Float = 0
        do {
            try cfp1.computeDistance(&clothingDistance, to: cfp2)
        } catch {
            return faceDistance
        }

        return (faceDistance * faceWeight) + (clothingDistance * clothingWeight)
    }

    // MARK: - Private Helpers

    private func cropRegion(from cgImage: CGImage, normalizedRect: CGRect) -> CGImage? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        // Vision coordinates: origin is bottom-left, convert to top-left for CGImage
        let pixelRect = CGRect(
            x: normalizedRect.origin.x * imageWidth,
            y: (1 - normalizedRect.origin.y - normalizedRect.height) * imageHeight,
            width: normalizedRect.width * imageWidth,
            height: normalizedRect.height * imageHeight
        )

        return cgImage.cropping(to: pixelRect)
    }
}
