import Foundation
import Vision
import AppKit
import CoreGraphics
import ImageIO
import Accelerate

struct FaceDetectionService: Sendable {

    /// Configuration for face detection quality filtering
    struct DetectionConfig: Sendable {
        var minConfidence: Float = 0.7
        var minFaceSize: Int = 50
        var clusteringThreshold: Float = 0.55

        nonisolated init(minConfidence: Float = 0.7, minFaceSize: Int = 50, clusteringThreshold: Float = 0.55) {
            self.minConfidence = minConfidence
            self.minFaceSize = minFaceSize
            self.clusteringThreshold = clusteringThreshold
        }
    }

    /// Detect faces in a single image, generate feature prints and thumbnails.
    /// Returns an array of `DetectedFace` and their thumbnail JPEG data keyed by face ID.
    func detectFaces(in imageURL: URL, config: DetectionConfig = DetectionConfig()) async throws -> [(face: DetectedFace, thumbnail: Data)] {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return []
        }

        // Use face landmarks request for better quality detection
        let faceObservations = try await detectFaceLandmarks(in: cgImage)
        guard !faceObservations.isEmpty else { return [] }

        var results: [(face: DetectedFace, thumbnail: Data)] = []

        for observation in faceObservations {
            // Filter by confidence
            guard observation.confidence >= config.minConfidence else { continue }

            // Calculate face size in pixels
            let facePixelWidth = Int(observation.boundingBox.width * CGFloat(cgImage.width))
            guard facePixelWidth >= config.minFaceSize else { continue }

            let expandedRect = expandBoundingBox(observation.boundingBox, by: 0.15, imageSize: CGSize(width: cgImage.width, height: cgImage.height))

            guard let croppedImage = cropFace(from: cgImage, normalizedRect: expandedRect) else { continue }

            // Compute blur score for quality assessment
            let blurScore = computeBlurScore(for: croppedImage)

            guard let featurePrintData = try await generateFeaturePrint(for: croppedImage) else { continue }

            let thumbnailData = generateThumbnail(from: croppedImage, size: 120)

            guard let thumbnailData else { continue }

            // Compute composite quality score
            let qualityScore = computeQualityScore(
                confidence: observation.confidence,
                faceSize: facePixelWidth,
                blurScore: blurScore
            )

            let face = DetectedFace(
                id: UUID(),
                imageURL: imageURL,
                faceRect: observation.boundingBox.asCGRect,
                featurePrintData: featurePrintData,
                groupID: nil,
                detectedAt: Date(),
                qualityScore: qualityScore,
                confidence: observation.confidence,
                faceSize: facePixelWidth,
                blurScore: blurScore
            )

            results.append((face: face, thumbnail: thumbnailData))
        }

        return results
    }

    // MARK: - Quality Scoring

    /// Compute blur score using Laplacian variance. Higher = sharper.
    private func computeBlurScore(for cgImage: CGImage) -> Float {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return 0 }

        // Convert to grayscale
        guard let grayscaleData = convertToGrayscale(cgImage) else { return 0 }

        // Compute Laplacian variance
        var laplacianSum: Float = 0
        var laplacianSumSq: Float = 0
        var count: Float = 0

        // Simple 3x3 Laplacian kernel: [0, 1, 0], [1, -4, 1], [0, 1, 0]
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let center = Float(grayscaleData[idx])
                let top = Float(grayscaleData[(y - 1) * width + x])
                let bottom = Float(grayscaleData[(y + 1) * width + x])
                let left = Float(grayscaleData[y * width + (x - 1)])
                let right = Float(grayscaleData[y * width + (x + 1)])

                let laplacian = top + bottom + left + right - 4 * center
                laplacianSum += laplacian
                laplacianSumSq += laplacian * laplacian
                count += 1
            }
        }

        guard count > 0 else { return 0 }

        let mean = laplacianSum / count
        let variance = (laplacianSumSq / count) - (mean * mean)

        // Normalize to 0-1 range (empirically, values > 500 are very sharp)
        return min(1.0, max(0.0, variance / 500.0))
    }

    private func convertToGrayscale(_ cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: width,
                  height: height,
                  bitsPerComponent: bitsPerComponent,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to grayscale
        var grayscale = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Float(pixelData[i * 4])
            let g = Float(pixelData[i * 4 + 1])
            let b = Float(pixelData[i * 4 + 2])
            grayscale[i] = UInt8(0.299 * r + 0.587 * g + 0.114 * b)
        }

        return grayscale
    }

    /// Compute composite quality score from individual metrics
    private func computeQualityScore(confidence: Float, faceSize: Int, blurScore: Float) -> Float {
        // Normalize face size (50-200 pixels maps to 0-1)
        let sizeScore = min(1.0, max(0.0, Float(faceSize - 50) / 150.0))

        // Weighted combination
        let weights: (confidence: Float, size: Float, blur: Float) = (0.4, 0.3, 0.3)
        return weights.confidence * confidence +
               weights.size * sizeScore +
               weights.blur * blurScore
    }

    /// Cluster faces into groups based on feature print distance using hierarchical agglomerative clustering.
    /// - Parameters:
    ///   - faces: Only the unclustered faces to assign to groups.
    ///   - allFaces: All known faces (including already-grouped ones) so representative lookups succeed.
    ///   - existingGroups: Previously formed groups to match against.
    ///   - threshold: Maximum average distance to consider faces part of the same group.
    func clusterFaces(_ faces: [DetectedFace], allFaces: [DetectedFace], existingGroups: [FaceGroup], threshold: Float = 0.55) -> [FaceGroup] {
        let unclusteredFaces = faces.filter { $0.groupID == nil }
        guard !unclusteredFaces.isEmpty else { return existingGroups }

        var groups = existingGroups
        let faceLookup = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // First, try to assign new faces to existing groups
        var remainingFaces: [DetectedFace] = []

        for face in unclusteredFaces {
            var bestGroupIndex: Int?
            var bestDistance: Float = threshold

            for (index, group) in groups.enumerated() {
                let memberFaces = group.faceIDs.compactMap { faceLookup[$0] }
                guard !memberFaces.isEmpty else { continue }

                let distances = memberFaces.compactMap { computeDistance(face.featurePrintData, $0.featurePrintData) }
                guard !distances.isEmpty else { continue }

                let avgDistance = distances.reduce(0, +) / Float(distances.count)

                if avgDistance < bestDistance {
                    bestDistance = avgDistance
                    bestGroupIndex = index
                }
            }

            if let index = bestGroupIndex {
                groups[index].faceIDs.append(face.id)
            } else {
                remainingFaces.append(face)
            }
        }

        // For remaining faces, use hierarchical agglomerative clustering
        if !remainingFaces.isEmpty {
            let newGroups = clusterFacesHierarchical(remainingFaces, threshold: threshold)
            groups.append(contentsOf: newGroups)
        }

        return groups
    }

    /// Hierarchical agglomerative clustering with average linkage.
    /// Produces deterministic, order-independent results.
    private func clusterFacesHierarchical(_ faces: [DetectedFace], threshold: Float) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        // Start with each face in its own cluster
        var clusters: [[DetectedFace]] = faces.map { [$0] }

        // Build initial distance matrix
        var distanceMatrix = buildDistanceMatrix(faces)

        // Iteratively merge closest clusters until all distances exceed threshold
        while clusters.count > 1 {
            // Find minimum distance pair
            var minDistance: Float = .infinity
            var minI = 0
            var minJ = 1

            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let key = distanceKey(i, j)
                    if let distance = distanceMatrix[key], distance < minDistance {
                        minDistance = distance
                        minI = i
                        minJ = j
                    }
                }
            }

            // Stop if minimum distance exceeds threshold
            if minDistance > threshold {
                break
            }

            // Merge clusters i and j
            let mergedCluster = clusters[minI] + clusters[minJ]

            // Remove old clusters (j first since j > i)
            clusters.remove(at: minJ)
            clusters.remove(at: minI)

            // Update distance matrix for the new merged cluster
            var newDistances: [String: Float] = [:]
            for (k, cluster) in clusters.enumerated() {
                // Average linkage: average of all pairwise distances
                let distance = computeAverageLinkageDistance(mergedCluster, cluster)
                newDistances[distanceKey(k, clusters.count)] = distance
            }

            // Add merged cluster
            clusters.append(mergedCluster)

            // Rebuild distance matrix with new indices
            distanceMatrix = rebuildDistanceMatrix(clusters: clusters, previousMatrix: distanceMatrix, newDistances: newDistances)
        }

        // Convert clusters to FaceGroups
        return clusters.map { clusterFaces in
            // Pick the face with highest quality score as representative
            let sortedByQuality = clusterFaces.sorted { ($0.qualityScore ?? 0) > ($1.qualityScore ?? 0) }
            let representative = sortedByQuality.first!

            return FaceGroup(
                id: UUID(),
                name: nil,
                representativeFaceID: representative.id,
                faceIDs: clusterFaces.map(\.id)
            )
        }
    }

    private func buildDistanceMatrix(_ faces: [DetectedFace]) -> [String: Float] {
        var matrix: [String: Float] = [:]
        for i in 0..<faces.count {
            for j in (i + 1)..<faces.count {
                if let distance = computeDistance(faces[i].featurePrintData, faces[j].featurePrintData) {
                    matrix[distanceKey(i, j)] = distance
                }
            }
        }
        return matrix
    }

    private func rebuildDistanceMatrix(clusters: [[DetectedFace]], previousMatrix: [String: Float], newDistances: [String: Float]) -> [String: Float] {
        var matrix: [String: Float] = [:]

        // For existing clusters (all except the last one), compute pairwise distances
        for i in 0..<(clusters.count - 1) {
            for j in (i + 1)..<(clusters.count - 1) {
                // Average linkage between clusters i and j
                let distance = computeAverageLinkageDistance(clusters[i], clusters[j])
                matrix[distanceKey(i, j)] = distance
            }
        }

        // Add distances to the new merged cluster
        for (key, value) in newDistances {
            matrix[key] = value
        }

        return matrix
    }

    private func computeAverageLinkageDistance(_ cluster1: [DetectedFace], _ cluster2: [DetectedFace]) -> Float {
        var totalDistance: Float = 0
        var count = 0

        for face1 in cluster1 {
            for face2 in cluster2 {
                if let distance = computeDistance(face1.featurePrintData, face2.featurePrintData) {
                    totalDistance += distance
                    count += 1
                }
            }
        }

        return count > 0 ? totalDistance / Float(count) : .infinity
    }

    private func distanceKey(_ i: Int, _ j: Int) -> String {
        let (a, b) = i < j ? (i, j) : (j, i)
        return "\(a)-\(b)"
    }

    /// Compute merge suggestions for groups that are close to the clustering threshold.
    /// Returns pairs of groups that might be the same person but didn't quite meet the threshold.
    func computeMergeSuggestions(groups: [FaceGroup], faces: [DetectedFace], threshold: Float, marginPercent: Float = 0.15) -> [MergeSuggestion] {
        let faceLookup = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        var suggestions: [MergeSuggestion] = []

        // Check pairs of groups
        for i in 0..<groups.count {
            for j in (i + 1)..<groups.count {
                let group1Faces = groups[i].faceIDs.compactMap { faceLookup[$0] }
                let group2Faces = groups[j].faceIDs.compactMap { faceLookup[$0] }

                guard !group1Faces.isEmpty, !group2Faces.isEmpty else { continue }

                let avgDistance = computeAverageLinkageDistance(group1Faces, group2Faces)

                // If distance is within margin of threshold, suggest merge
                let margin = threshold * marginPercent
                if avgDistance > threshold && avgDistance <= threshold + margin {
                    // Convert distance to similarity (0-1, higher = more similar)
                    let similarity = max(0, 1 - avgDistance)
                    suggestions.append(MergeSuggestion(
                        group1ID: groups[i].id,
                        group2ID: groups[j].id,
                        similarity: similarity
                    ))
                }
            }
        }

        // Sort by similarity descending
        return suggestions.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Vision Requests

    /// Detect faces with landmarks for better quality filtering
    private func detectFaceLandmarks(in cgImage: CGImage) async throws -> [VNFaceObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let faces = request.results as? [VNFaceObservation] ?? []
                // Filter to only faces with valid landmarks (eyes detected)
                let validFaces = faces.filter { observation in
                    guard let landmarks = observation.landmarks else { return true }
                    // Require at least one eye to be detected
                    return landmarks.leftEye != nil || landmarks.rightEye != nil
                }
                continuation.resume(returning: validFaces)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

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

}

// MARK: - VNFaceObservation Helpers

private extension CGRect {
    var asCGRect: CGRect { self }
}
