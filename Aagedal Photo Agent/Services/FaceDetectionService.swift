import Foundation
import Vision
import AppKit
import CoreGraphics
import ImageIO

struct FaceDetectionService: Sendable {

    /// Detect faces in a single image, generate feature prints and thumbnails.
    /// Returns an array of `DetectedFace` and their thumbnail JPEG data keyed by face ID.
    func detectFaces(in imageURL: URL) async throws -> [(face: DetectedFace, thumbnail: Data)] {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return []
        }

        let faceObservations = try await detectFaceRectangles(in: cgImage)
        guard !faceObservations.isEmpty else { return [] }

        var results: [(face: DetectedFace, thumbnail: Data)] = []

        for observation in faceObservations {
            let expandedRect = expandBoundingBox(observation.boundingBox, by: 0.3, imageSize: CGSize(width: cgImage.width, height: cgImage.height))

            guard let croppedImage = cropFace(from: cgImage, normalizedRect: expandedRect) else { continue }

            guard let featurePrintData = try await generateFeaturePrint(for: croppedImage) else { continue }

            let thumbnailData = generateThumbnail(from: croppedImage, size: 120)

            guard let thumbnailData else { continue }

            let face = DetectedFace(
                id: UUID(),
                imageURL: imageURL,
                faceRect: observation.boundingBox.asCGRect,
                featurePrintData: featurePrintData,
                groupID: nil,
                detectedAt: Date()
            )

            results.append((face: face, thumbnail: thumbnailData))
        }

        return results
    }

    /// Cluster faces into groups based on feature print distance.
    func clusterFaces(_ faces: [DetectedFace], existingGroups: [FaceGroup], threshold: Float = 0.5) -> [FaceGroup] {
        var groups = existingGroups

        for face in faces where face.groupID == nil {
            var bestGroupIndex: Int?
            var bestDistance: Float = threshold

            for (index, group) in groups.enumerated() {
                guard let representativeFace = faces.first(where: { $0.id == group.representativeFaceID }) ?? findFace(id: group.representativeFaceID, in: faces) else { continue }

                if let distance = computeDistance(face.featurePrintData, representativeFace.featurePrintData),
                   distance < bestDistance {
                    bestDistance = distance
                    bestGroupIndex = index
                }
            }

            if let index = bestGroupIndex {
                groups[index].faceIDs.append(face.id)
            } else {
                let newGroup = FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: face.id,
                    faceIDs: [face.id]
                )
                groups.append(newGroup)
            }
        }

        return groups
    }

    // MARK: - Vision Requests

    private func detectFaceRectangles(in cgImage: CGImage) async throws -> [VNFaceObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let faces = request.results as? [VNFaceObservation] ?? []
                continuation.resume(returning: faces)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func generateFeaturePrint(for cgImage: CGImage) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
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
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Image Processing

    private func expandBoundingBox(_ box: CGRect, by factor: CGFloat, imageSize: CGSize) -> CGRect {
        let expandW = box.width * factor
        let expandH = box.height * factor
        var expanded = CGRect(
            x: box.origin.x - expandW / 2,
            y: box.origin.y - expandH / 2,
            width: box.width + expandW,
            height: box.height + expandH
        )
        // Clamp to 0..1 normalized
        expanded.origin.x = max(0, expanded.origin.x)
        expanded.origin.y = max(0, expanded.origin.y)
        expanded.size.width = min(expanded.size.width, 1 - expanded.origin.x)
        expanded.size.height = min(expanded.size.height, 1 - expanded.origin.y)
        return expanded
    }

    private func cropFace(from cgImage: CGImage, normalizedRect: CGRect) -> CGImage? {
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

    private func generateThumbnail(from cgImage: CGImage, size: Int) -> Data? {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        let targetSize = NSSize(width: size, height: size)
        let thumbnailImage = NSImage(size: targetSize)
        thumbnailImage.lockFocus()

        let sourceAspect = nsImage.size.width / nsImage.size.height
        var drawRect: NSRect
        if sourceAspect > 1 {
            let drawHeight = CGFloat(size)
            let drawWidth = drawHeight * sourceAspect
            drawRect = NSRect(x: -(drawWidth - CGFloat(size)) / 2, y: 0, width: drawWidth, height: drawHeight)
        } else {
            let drawWidth = CGFloat(size)
            let drawHeight = drawWidth / sourceAspect
            drawRect = NSRect(x: 0, y: -(drawHeight - CGFloat(size)) / 2, width: drawWidth, height: drawHeight)
        }

        nsImage.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        thumbnailImage.unlockFocus()

        guard let tiffData = thumbnailImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        return jpegData
    }

    // MARK: - Feature Print Comparison

    func computeDistance(_ data1: Data, _ data2: Data) -> Float? {
        guard let fp1 = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data1),
              let fp2 = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data2) else {
            return nil
        }

        var distance: Float = 0
        do {
            try fp1.computeDistance(&distance, to: fp2)
            return distance
        } catch {
            return nil
        }
    }

    private func findFace(id: UUID, in faces: [DetectedFace]) -> DetectedFace? {
        faces.first { $0.id == id }
    }
}

// MARK: - VNFaceObservation Helpers

private extension CGRect {
    var asCGRect: CGRect { self }
}
