import Foundation
import Vision
import AppKit
import CoreGraphics
import ImageIO
import Accelerate

nonisolated struct FaceDetectionService: Sendable {

    /// Cache for VNFeaturePrintObservation objects during clustering operations.
    /// Reduces NSKeyedUnarchiver calls from O(N³) to O(N) by deserializing each feature print only once.
    final class FeaturePrintCache: @unchecked Sendable {
        private var cache: [UUID: VNFeaturePrintObservation] = [:]

        func getFeaturePrint(for face: DetectedFace) -> VNFeaturePrintObservation? {
            if let cached = cache[face.id] { return cached }
            guard let fp = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: face.featurePrintData
            ) else { return nil }
            cache[face.id] = fp
            return fp
        }

        func getFeaturePrint(for faceID: UUID, data: Data) -> VNFeaturePrintObservation? {
            if let cached = cache[faceID] { return cached }
            guard let fp = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: data
            ) else { return nil }
            cache[faceID] = fp
            return fp
        }
    }

    /// Configuration for face detection quality filtering
    struct DetectionConfig: Sendable {
        var minConfidence: Float = 0.7
        var minFaceSize: Int = 50
        var clusteringThreshold: Float = 0.55

        /// Recognition mode for embedding generation and distance computation
        var recognitionMode: FaceRecognitionMode = .visionFeaturePrint

        /// Weight for face features in Face+Clothing mode (0-1)
        var faceWeight: Float = 0.7

        /// Weight for clothing features in Face+Clothing mode (0-1)
        var clothingWeight: Float = 0.3

        /// Clustering algorithm to use for grouping faces
        var clusteringAlgorithm: FaceClusteringAlgorithm = .chineseWhispers

        /// Number of iterations for Chinese Whispers algorithm
        var chineseWhispersIterations: Int = 15

        /// Minimum quality score for faces in the first pass of quality-gated clustering
        var qualityGateThreshold: Float = 0.6

        /// Whether to weight graph edges by face quality in Chinese Whispers
        var useQualityWeightedEdges: Bool = true

        /// Weight factor for quality in edge calculations (0-1)
        var qualityEdgeWeight: Float = 0.3

        nonisolated init(
            minConfidence: Float = 0.7,
            minFaceSize: Int = 50,
            clusteringThreshold: Float = 0.55,
            recognitionMode: FaceRecognitionMode = .visionFeaturePrint,
            faceWeight: Float = 0.7,
            clothingWeight: Float = 0.3,
            clusteringAlgorithm: FaceClusteringAlgorithm = .chineseWhispers,
            chineseWhispersIterations: Int = 15,
            qualityGateThreshold: Float = 0.6,
            useQualityWeightedEdges: Bool = true,
            qualityEdgeWeight: Float = 0.3
        ) {
            self.minConfidence = minConfidence
            self.minFaceSize = minFaceSize
            self.clusteringThreshold = clusteringThreshold
            self.recognitionMode = recognitionMode
            self.faceWeight = faceWeight
            self.clothingWeight = clothingWeight
            self.clusteringAlgorithm = clusteringAlgorithm
            self.chineseWhispersIterations = chineseWhispersIterations
            self.qualityGateThreshold = qualityGateThreshold
            self.useQualityWeightedEdges = useQualityWeightedEdges
            self.qualityEdgeWeight = qualityEdgeWeight
        }
    }

    /// Extended cache that also stores clothing feature prints
    final class ExtendedFeatureCache: @unchecked Sendable {
        private var faceFeaturePrints: [UUID: VNFeaturePrintObservation] = [:]
        private var clothingFeaturePrints: [UUID: VNFeaturePrintObservation] = [:]

        func getFaceFeaturePrint(for face: DetectedFace) -> VNFeaturePrintObservation? {
            if let cached = faceFeaturePrints[face.id] { return cached }
            guard let fp = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: face.featurePrintData
            ) else { return nil }
            faceFeaturePrints[face.id] = fp
            return fp
        }

        func getClothingFeaturePrint(for face: DetectedFace) -> VNFeaturePrintObservation? {
            if let cached = clothingFeaturePrints[face.id] { return cached }
            guard let data = face.clothingFeaturePrintData,
                  let fp = try? NSKeyedUnarchiver.unarchivedObject(
                      ofClass: VNFeaturePrintObservation.self,
                      from: data
                  ) else { return nil }
            clothingFeaturePrints[face.id] = fp
            return fp
        }
    }

    /// Detect faces in a single image, generate feature prints and thumbnails.
    /// Returns an array of `DetectedFace` and their thumbnail JPEG data keyed by face ID.
    func detectFaces(in imageURL: URL, config: DetectionConfig = DetectionConfig()) async throws -> [(face: DetectedFace, thumbnail: Data)] {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let rawCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return []
        }

        // Apply EXIF orientation to get correctly oriented image
        let cgImage = applyEXIFOrientation(to: rawCGImage, from: imageSource)

        // Use face landmarks request for better quality detection
        let faceObservations = try await detectFaceLandmarks(in: cgImage)
        guard !faceObservations.isEmpty else { return [] }

        var results: [(face: DetectedFace, thumbnail: Data)] = []
        let clothingService = ClothingFeatureService()
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        for observation in faceObservations {
            // Filter by confidence
            guard observation.confidence >= config.minConfidence else { continue }

            // Calculate face size in pixels
            let facePixelWidth = Int(observation.boundingBox.width * CGFloat(cgImage.width))
            guard facePixelWidth >= config.minFaceSize else { continue }

            let expandedRect = expandBoundingBox(observation.boundingBox, by: 0.15, imageSize: imageSize)

            guard let croppedImage = cropFace(from: cgImage, normalizedRect: expandedRect) else { continue }

            // Compute blur score for quality assessment
            let blurScore = computeBlurScore(for: croppedImage)

            // Always generate Vision feature print (used as fallback and for Vision mode)
            guard let featurePrintData = try await generateFeaturePrint(for: croppedImage) else { continue }

            let thumbnailData = generateThumbnail(from: croppedImage, size: 120)
            guard let thumbnailData else { continue }

            // Compute composite quality score
            let qualityScore = computeQualityScore(
                confidence: observation.confidence,
                faceSize: facePixelWidth,
                blurScore: blurScore
            )

            // Generate mode-specific embeddings
            var clothingFeaturePrintData: Data? = nil
            var clothingRect: CGRect? = nil

            switch config.recognitionMode {
            case .visionFeaturePrint:
                // Vision mode: only need the base feature print (already generated)
                break

            case .faceAndClothing:
                // Face+Clothing mode: generate torso feature print
                if let torsoRect = clothingService.estimateTorsoRect(from: observation.boundingBox, imageSize: imageSize) {
                    clothingRect = torsoRect
                    clothingFeaturePrintData = try? await clothingService.generateClothingFeaturePrint(for: cgImage, torsoRect: torsoRect)
                }
            }

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
                blurScore: blurScore,
                clothingFeaturePrintData: clothingFeaturePrintData,
                clothingRect: clothingRect,
                embeddingMode: config.recognitionMode
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
    ///   - cache: Optional pre-populated feature print cache for performance.
    func clusterFaces(_ faces: [DetectedFace], allFaces: [DetectedFace], existingGroups: [FaceGroup], threshold: Float = 0.55, cache: FeaturePrintCache? = nil) -> [FaceGroup] {
        let unclusteredFaces = faces.filter { $0.groupID == nil }
        guard !unclusteredFaces.isEmpty else { return existingGroups }

        // Use provided cache or create a new one for this clustering operation
        let fpCache = cache ?? FeaturePrintCache()

        var groups = existingGroups
        let faceLookup = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // First, try to assign new faces to existing groups
        var remainingFaces: [DetectedFace] = []

        for face in unclusteredFaces {
            guard let faceFP = fpCache.getFeaturePrint(for: face) else {
                remainingFaces.append(face)
                continue
            }

            var bestGroupIndex: Int?
            var bestDistance: Float = threshold

            for (index, group) in groups.enumerated() {
                let memberFaces = group.faceIDs.compactMap { faceLookup[$0] }
                guard !memberFaces.isEmpty else { continue }

                var totalDistance: Float = 0
                var count = 0
                for memberFace in memberFaces {
                    if let memberFP = fpCache.getFeaturePrint(for: memberFace),
                       let distance = computeDistanceCached(faceFP, memberFP) {
                        totalDistance += distance
                        count += 1
                    }
                }
                guard count > 0 else { continue }

                let avgDistance = totalDistance / Float(count)

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
            let newGroups = clusterFacesHierarchical(remainingFaces, threshold: threshold, cache: fpCache)
            groups.append(contentsOf: newGroups)
        }

        return groups
    }

    /// Hierarchical agglomerative clustering with average linkage.
    /// Produces deterministic, order-independent results.
    private func clusterFacesHierarchical(_ faces: [DetectedFace], threshold: Float, cache: FeaturePrintCache? = nil) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        // Use provided cache or create a new one
        let fpCache = cache ?? FeaturePrintCache()

        // Start with each face in its own cluster
        var clusters: [[DetectedFace]] = faces.map { [$0] }

        // Build initial distance matrix using the cache
        var distanceMatrix = buildDistanceMatrix(faces, cache: fpCache)

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
                let distance = computeAverageLinkageDistance(mergedCluster, cluster, cache: fpCache)
                newDistances[distanceKey(k, clusters.count)] = distance
            }

            // Add merged cluster
            clusters.append(mergedCluster)

            // Rebuild distance matrix with new indices
            distanceMatrix = rebuildDistanceMatrix(clusters: clusters, previousMatrix: distanceMatrix, newDistances: newDistances, cache: fpCache)
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

    private func buildDistanceMatrix(_ faces: [DetectedFace], cache: FeaturePrintCache) -> [String: Float] {
        var matrix: [String: Float] = [:]
        for i in 0..<faces.count {
            for j in (i + 1)..<faces.count {
                if let fp1 = cache.getFeaturePrint(for: faces[i]),
                   let fp2 = cache.getFeaturePrint(for: faces[j]),
                   let distance = computeDistanceCached(fp1, fp2) {
                    matrix[distanceKey(i, j)] = distance
                }
            }
        }
        return matrix
    }

    private func rebuildDistanceMatrix(clusters: [[DetectedFace]], previousMatrix: [String: Float], newDistances: [String: Float], cache: FeaturePrintCache) -> [String: Float] {
        var matrix: [String: Float] = [:]

        // For existing clusters (all except the last one), compute pairwise distances
        for i in 0..<(clusters.count - 1) {
            for j in (i + 1)..<(clusters.count - 1) {
                // Average linkage between clusters i and j
                let distance = computeAverageLinkageDistance(clusters[i], clusters[j], cache: cache)
                matrix[distanceKey(i, j)] = distance
            }
        }

        // Add distances to the new merged cluster
        for (key, value) in newDistances {
            matrix[key] = value
        }

        return matrix
    }

    private func computeAverageLinkageDistance(_ cluster1: [DetectedFace], _ cluster2: [DetectedFace], cache: FeaturePrintCache) -> Float {
        var totalDistance: Float = 0
        var count = 0

        for face1 in cluster1 {
            guard let fp1 = cache.getFeaturePrint(for: face1) else { continue }
            for face2 in cluster2 {
                guard let fp2 = cache.getFeaturePrint(for: face2) else { continue }
                if let distance = computeDistanceCached(fp1, fp2) {
                    totalDistance += distance
                    count += 1
                }
            }
        }

        return count > 0 ? totalDistance / Float(count) : .infinity
    }

    /// Convenience overload that creates a temporary cache for one-off distance calculations.
    private func computeAverageLinkageDistance(_ cluster1: [DetectedFace], _ cluster2: [DetectedFace]) -> Float {
        let cache = FeaturePrintCache()
        return computeAverageLinkageDistance(cluster1, cluster2, cache: cache)
    }

    private func distanceKey(_ i: Int, _ j: Int) -> String {
        let (a, b) = i < j ? (i, j) : (j, i)
        return "\(a)-\(b)"
    }

    // MARK: - Median Linkage Clustering

    /// Compute distance using median linkage (Apple Photos style).
    /// More robust to outliers than average linkage.
    private func computeMedianLinkageDistance(
        _ cluster1: [DetectedFace],
        _ cluster2: [DetectedFace],
        cache: FeaturePrintCache
    ) -> Float {
        var distances: [Float] = []
        for face1 in cluster1 {
            guard let fp1 = cache.getFeaturePrint(for: face1) else { continue }
            for face2 in cluster2 {
                guard let fp2 = cache.getFeaturePrint(for: face2) else { continue }
                if let distance = computeDistanceCached(fp1, fp2) {
                    distances.append(distance)
                }
            }
        }
        guard !distances.isEmpty else { return .infinity }
        distances.sort()
        return distances[distances.count / 2]  // Median
    }

    /// Hierarchical agglomerative clustering with median linkage.
    private func clusterFacesHierarchicalMedian(_ faces: [DetectedFace], threshold: Float, cache: FeaturePrintCache? = nil) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        let fpCache = cache ?? FeaturePrintCache()
        var clusters: [[DetectedFace]] = faces.map { [$0] }
        var distanceMatrix = buildDistanceMatrix(faces, cache: fpCache)

        while clusters.count > 1 {
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

            if minDistance > threshold {
                break
            }

            let mergedCluster = clusters[minI] + clusters[minJ]
            clusters.remove(at: minJ)
            clusters.remove(at: minI)

            var newDistances: [String: Float] = [:]
            for (k, cluster) in clusters.enumerated() {
                // Use median linkage instead of average
                let distance = computeMedianLinkageDistance(mergedCluster, cluster, cache: fpCache)
                newDistances[distanceKey(k, clusters.count)] = distance
            }

            clusters.append(mergedCluster)

            // Rebuild with median distances
            distanceMatrix = [:]
            for i in 0..<(clusters.count - 1) {
                for j in (i + 1)..<(clusters.count - 1) {
                    let distance = computeMedianLinkageDistance(clusters[i], clusters[j], cache: fpCache)
                    distanceMatrix[distanceKey(i, j)] = distance
                }
            }
            for (key, value) in newDistances {
                distanceMatrix[key] = value
            }
        }

        return clusters.map { clusterFaces in
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

    // MARK: - Chinese Whispers Clustering

    /// Edge in the similarity graph for Chinese Whispers algorithm
    private struct GraphEdge {
        let face1ID: UUID
        let face2ID: UUID
        let weight: Float
    }

    /// Cluster faces using Chinese Whispers algorithm.
    /// Graph-based, order-independent, naturally handles outliers.
    func clusterFacesChineseWhispers(
        _ faces: [DetectedFace],
        config: DetectionConfig,
        cache: FeaturePrintCache? = nil
    ) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        let fpCache = cache ?? FeaturePrintCache()

        // Build similarity graph
        let edges = buildSimilarityGraph(faces: faces, config: config, cache: fpCache)

        // Initialize labels: each face starts in its own cluster
        var labels: [UUID: UUID] = [:]
        for face in faces {
            labels[face.id] = face.id
        }

        // Build adjacency list for efficient neighbor lookup
        var adjacency: [UUID: [(neighborID: UUID, weight: Float)]] = [:]
        for face in faces {
            adjacency[face.id] = []
        }
        for edge in edges {
            adjacency[edge.face1ID, default: []].append((edge.face2ID, edge.weight))
            adjacency[edge.face2ID, default: []].append((edge.face1ID, edge.weight))
        }

        // Iterate: each face adopts the highest-weighted neighbor label
        var faceIDs = faces.map(\.id)
        for _ in 0..<config.chineseWhispersIterations {
            // Shuffle for randomness (reduces order dependency)
            faceIDs.shuffle()

            var changed = false
            for faceID in faceIDs {
                guard let neighbors = adjacency[faceID], !neighbors.isEmpty else { continue }

                // Count weighted votes for each label
                var labelVotes: [UUID: Float] = [:]
                for (neighborID, weight) in neighbors {
                    if let neighborLabel = labels[neighborID] {
                        labelVotes[neighborLabel, default: 0] += weight
                    }
                }

                // Find the label with the highest vote
                if let bestLabel = labelVotes.max(by: { $0.value < $1.value })?.key {
                    if labels[faceID] != bestLabel {
                        labels[faceID] = bestLabel
                        changed = true
                    }
                }
            }

            // Early termination if no changes
            if !changed {
                break
            }
        }

        // Convert labels to FaceGroups
        var groupsByLabel: [UUID: [DetectedFace]] = [:]
        for face in faces {
            if let label = labels[face.id] {
                groupsByLabel[label, default: []].append(face)
            }
        }

        return groupsByLabel.values.map { clusterFaces in
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

    /// Build similarity graph for Chinese Whispers.
    /// Creates edges between faces that are similar enough, weighted by similarity and quality.
    private func buildSimilarityGraph(
        faces: [DetectedFace],
        config: DetectionConfig,
        cache: FeaturePrintCache
    ) -> [GraphEdge] {
        var edges: [GraphEdge] = []

        for i in 0..<faces.count {
            guard let fp1 = cache.getFeaturePrint(for: faces[i]) else { continue }

            for j in (i + 1)..<faces.count {
                guard let fp2 = cache.getFeaturePrint(for: faces[j]) else { continue }
                guard let distance = computeDistanceCached(fp1, fp2) else { continue }

                // Only create edge if distance is below threshold
                if distance < config.clusteringThreshold {
                    var weight: Float = 1.0 - (distance / config.clusteringThreshold)

                    // Apply quality weighting if enabled
                    if config.useQualityWeightedEdges {
                        let quality1 = faces[i].qualityScore ?? 0.5
                        let quality2 = faces[j].qualityScore ?? 0.5
                        let qualityFactor = (quality1 + quality2) / 2.0
                        weight = weight * (1.0 - config.qualityEdgeWeight) + qualityFactor * config.qualityEdgeWeight
                    }

                    edges.append(GraphEdge(face1ID: faces[i].id, face2ID: faces[j].id, weight: weight))
                }
            }
        }

        return edges
    }

    // MARK: - Quality-Gated Two-Pass Clustering

    /// Cluster faces using quality-gated two-pass algorithm.
    /// Pass 1: Cluster high-quality faces using Chinese Whispers.
    /// Pass 2: Assign low-quality faces to nearest cluster or create singletons.
    func clusterFacesQualityGated(
        _ faces: [DetectedFace],
        config: DetectionConfig,
        cache: FeaturePrintCache? = nil
    ) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        let fpCache = cache ?? FeaturePrintCache()

        // Partition faces by quality
        let highQualityFaces = faces.filter { ($0.qualityScore ?? 0) >= config.qualityGateThreshold }
        let lowQualityFaces = faces.filter { ($0.qualityScore ?? 0) < config.qualityGateThreshold }

        // Pass 1: Cluster high-quality faces using Chinese Whispers
        var groups: [FaceGroup]
        if !highQualityFaces.isEmpty {
            groups = clusterFacesChineseWhispers(highQualityFaces, config: config, cache: fpCache)
        } else {
            groups = []
        }

        // Pass 2: Assign low-quality faces to nearest cluster or create singletons
        for face in lowQualityFaces {
            guard let faceFP = fpCache.getFeaturePrint(for: face) else {
                // Can't process this face, create singleton
                groups.append(FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: face.id,
                    faceIDs: [face.id]
                ))
                continue
            }

            var bestGroupIndex: Int?
            var bestDistance: Float = config.clusteringThreshold

            // Find the best matching group
            for (index, group) in groups.enumerated() {
                // Use the representative face for comparison (high-quality)
                guard let repFace = highQualityFaces.first(where: { $0.id == group.representativeFaceID }),
                      let repFP = fpCache.getFeaturePrint(for: repFace),
                      let distance = computeDistanceCached(faceFP, repFP) else { continue }

                if distance < bestDistance {
                    bestDistance = distance
                    bestGroupIndex = index
                }
            }

            if let index = bestGroupIndex {
                // Add to existing group (don't make it representative since it's low-quality)
                groups[index].faceIDs.append(face.id)
            } else {
                // Create singleton for unmatched low-quality face
                groups.append(FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: face.id,
                    faceIDs: [face.id]
                ))
            }
        }

        return groups
    }

    // MARK: - Algorithm-Aware Clustering Entry Point

    /// Cluster faces using the algorithm specified in config.
    func clusterFacesWithAlgorithm(
        _ faces: [DetectedFace],
        allFaces: [DetectedFace],
        existingGroups: [FaceGroup],
        config: DetectionConfig,
        cache: FeaturePrintCache? = nil
    ) -> [FaceGroup] {
        let unclusteredFaces = faces.filter { $0.groupID == nil }
        guard !unclusteredFaces.isEmpty else { return existingGroups }

        let fpCache = cache ?? FeaturePrintCache()
        var groups = existingGroups
        let faceLookup = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // First, try to assign new faces to existing groups using selected algorithm's distance metric
        var remainingFaces: [DetectedFace] = []

        for face in unclusteredFaces {
            guard let faceFP = fpCache.getFeaturePrint(for: face) else {
                remainingFaces.append(face)
                continue
            }

            var bestGroupIndex: Int?
            var bestDistance: Float = config.clusteringThreshold

            for (index, group) in groups.enumerated() {
                let memberFaces = group.faceIDs.compactMap { faceLookup[$0] }
                guard !memberFaces.isEmpty else { continue }

                let distance: Float
                switch config.clusteringAlgorithm {
                case .hierarchicalMedian:
                    distance = computeMedianLinkageDistance([face], memberFaces, cache: fpCache)
                case .hierarchicalAverage, .chineseWhispers, .qualityGatedTwoPass:
                    // Use average for assignment to existing groups
                    var totalDistance: Float = 0
                    var count = 0
                    for memberFace in memberFaces {
                        if let memberFP = fpCache.getFeaturePrint(for: memberFace),
                           let d = computeDistanceCached(faceFP, memberFP) {
                            totalDistance += d
                            count += 1
                        }
                    }
                    distance = count > 0 ? totalDistance / Float(count) : .infinity
                }

                if distance < bestDistance {
                    bestDistance = distance
                    bestGroupIndex = index
                }
            }

            if let index = bestGroupIndex {
                groups[index].faceIDs.append(face.id)
            } else {
                remainingFaces.append(face)
            }
        }

        // For remaining faces, use the selected clustering algorithm
        if !remainingFaces.isEmpty {
            let newGroups: [FaceGroup]
            switch config.clusteringAlgorithm {
            case .hierarchicalAverage:
                newGroups = clusterFacesHierarchical(remainingFaces, threshold: config.clusteringThreshold, cache: fpCache)
            case .hierarchicalMedian:
                newGroups = clusterFacesHierarchicalMedian(remainingFaces, threshold: config.clusteringThreshold, cache: fpCache)
            case .chineseWhispers:
                newGroups = clusterFacesChineseWhispers(remainingFaces, config: config, cache: fpCache)
            case .qualityGatedTwoPass:
                newGroups = clusterFacesQualityGated(remainingFaces, config: config, cache: fpCache)
            }
            groups.append(contentsOf: newGroups)
        }

        return groups
    }

    /// Compute merge suggestions for groups that are close to the clustering threshold.
    /// Returns pairs of groups that might be the same person but didn't quite meet the threshold.
    func computeMergeSuggestions(groups: [FaceGroup], faces: [DetectedFace], threshold: Float, marginPercent: Float = 0.15) -> [MergeSuggestion] {
        let faceLookup = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        let cache = FeaturePrintCache()
        var suggestions: [MergeSuggestion] = []

        // Check pairs of groups
        for i in 0..<groups.count {
            for j in (i + 1)..<groups.count {
                let group1Faces = groups[i].faceIDs.compactMap { faceLookup[$0] }
                let group2Faces = groups[j].faceIDs.compactMap { faceLookup[$0] }

                guard !group1Faces.isEmpty, !group2Faces.isEmpty else { continue }

                let avgDistance = computeAverageLinkageDistance(group1Faces, group2Faces, cache: cache)

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
    private nonisolated func detectFaceLandmarks(in cgImage: CGImage) async throws -> [VNFaceObservation] {
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
                nonisolated(unsafe) let result = validFaces
                continuation.resume(returning: result)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated func detectFaceRectangles(in cgImage: CGImage) async throws -> [VNFaceObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let faces = request.results as? [VNFaceObservation] ?? []
                nonisolated(unsafe) let result = faces
                continuation.resume(returning: result)
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

    /// Apply EXIF orientation to a CGImage to get the correctly oriented image.
    /// This ensures faces are detected and cropped from the visually correct orientation.
    private func applyEXIFOrientation(to cgImage: CGImage, from imageSource: CGImageSource) -> CGImage {
        // Get EXIF orientation from image properties
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let orientationValue = properties[kCGImagePropertyOrientation] as? UInt32,
              orientationValue != 1 else {  // 1 = normal orientation, no transform needed
            return cgImage
        }

        let width = cgImage.width
        let height = cgImage.height

        // Determine the new dimensions and transform based on orientation
        var newWidth = width
        var newHeight = height
        var transform = CGAffineTransform.identity

        switch orientationValue {
        case 2: // Flip horizontal
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: CGFloat(-width), y: 0)
        case 3: // Rotate 180°
            transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case 4: // Flip vertical
            transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: CGFloat(-height))
        case 5: // Rotate 90° CCW + flip horizontal
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(scaleX: -1, y: 1).rotated(by: .pi / 2)
        case 6: // Rotate 90° CW
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(translationX: CGFloat(newWidth), y: 0).rotated(by: .pi / 2)
        case 7: // Rotate 90° CW + flip horizontal
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(translationX: CGFloat(newWidth), y: CGFloat(newHeight))
                .rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 8: // Rotate 90° CCW
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(translationX: 0, y: CGFloat(newHeight)).rotated(by: -.pi / 2)
        default:
            return cgImage
        }

        // Create a new bitmap context with the correct orientation
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: newWidth,
                  height: newHeight,
                  bitsPerComponent: cgImage.bitsPerComponent,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else {
            return cgImage
        }

        context.concatenate(transform)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage() ?? cgImage
    }

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

    /// Compute distance between two already-deserialized feature prints (avoids NSKeyedUnarchiver overhead).
    func computeDistanceCached(_ fp1: VNFeaturePrintObservation, _ fp2: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try fp1.computeDistance(&distance, to: fp2)
            return distance
        } catch {
            return nil
        }
    }

    // MARK: - Mode-Aware Distance Computation

    /// Compute distance between two faces using the appropriate mode.
    /// Falls back to Vision mode if required embeddings are missing.
    func computeModeAwareDistance(
        face1: DetectedFace,
        face2: DetectedFace,
        mode: FaceRecognitionMode,
        config: DetectionConfig,
        cache: ExtendedFeatureCache
    ) -> Float? {
        switch mode {
        case .visionFeaturePrint:
            // Use Vision feature prints
            guard let fp1 = cache.getFaceFeaturePrint(for: face1),
                  let fp2 = cache.getFaceFeaturePrint(for: face2) else {
                return nil
            }
            return computeDistanceCached(fp1, fp2)

        case .faceAndClothing:
            // Get face feature prints (required)
            guard let faceFP1 = cache.getFaceFeaturePrint(for: face1),
                  let faceFP2 = cache.getFaceFeaturePrint(for: face2) else {
                return nil
            }

            var faceDistance: Float = 0
            do {
                try faceFP1.computeDistance(&faceDistance, to: faceFP2)
            } catch {
                return nil
            }

            // Get clothing feature prints (optional)
            let clothingFP1 = cache.getClothingFeaturePrint(for: face1)
            let clothingFP2 = cache.getClothingFeaturePrint(for: face2)

            // If either face lacks clothing data, use face-only distance
            guard let cfp1 = clothingFP1, let cfp2 = clothingFP2 else {
                return faceDistance
            }

            var clothingDistance: Float = 0
            do {
                try cfp1.computeDistance(&clothingDistance, to: cfp2)
            } catch {
                return faceDistance
            }

            // Combine with weights
            return (faceDistance * config.faceWeight) + (clothingDistance * config.clothingWeight)
        }
    }

    /// Compute average linkage distance between two clusters using mode-aware distance.
    func computeModeAwareAverageLinkage(
        cluster1: [DetectedFace],
        cluster2: [DetectedFace],
        mode: FaceRecognitionMode,
        config: DetectionConfig,
        cache: ExtendedFeatureCache
    ) -> Float {
        var totalDistance: Float = 0
        var count = 0

        for face1 in cluster1 {
            for face2 in cluster2 {
                if let distance = computeModeAwareDistance(
                    face1: face1,
                    face2: face2,
                    mode: mode,
                    config: config,
                    cache: cache
                ) {
                    totalDistance += distance
                    count += 1
                }
            }
        }

        return count > 0 ? totalDistance / Float(count) : .infinity
    }

    // MARK: - Mode-Aware Clustering

    /// Cluster faces using mode-aware distance computation.
    /// Falls back to Vision mode for faces without required embeddings.
    func clusterFacesModeAware(
        _ faces: [DetectedFace],
        allFaces: [DetectedFace],
        existingGroups: [FaceGroup],
        config: DetectionConfig
    ) -> [FaceGroup] {
        let unclusteredFaces = faces.filter { $0.groupID == nil }
        guard !unclusteredFaces.isEmpty else { return existingGroups }

        let cache = ExtendedFeatureCache()
        var groups = existingGroups
        let faceLookup = Dictionary(uniqueKeysWithValues: allFaces.map { ($0.id, $0) })

        // First, try to assign new faces to existing groups
        var remainingFaces: [DetectedFace] = []

        for face in unclusteredFaces {
            var bestGroupIndex: Int?
            var bestDistance: Float = config.clusteringThreshold

            for (index, group) in groups.enumerated() {
                let memberFaces = group.faceIDs.compactMap { faceLookup[$0] }
                guard !memberFaces.isEmpty else { continue }

                var totalDistance: Float = 0
                var count = 0
                for memberFace in memberFaces {
                    if let distance = computeModeAwareDistance(
                        face1: face,
                        face2: memberFace,
                        mode: config.recognitionMode,
                        config: config,
                        cache: cache
                    ) {
                        totalDistance += distance
                        count += 1
                    }
                }
                guard count > 0 else { continue }

                let avgDistance = totalDistance / Float(count)

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
            let newGroups = clusterFacesHierarchicalModeAware(remainingFaces, config: config, cache: cache)
            groups.append(contentsOf: newGroups)
        }

        return groups
    }

    /// Hierarchical agglomerative clustering with mode-aware distance computation.
    private func clusterFacesHierarchicalModeAware(
        _ faces: [DetectedFace],
        config: DetectionConfig,
        cache: ExtendedFeatureCache
    ) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        // Start with each face in its own cluster
        var clusters: [[DetectedFace]] = faces.map { [$0] }

        // Build initial distance matrix
        var distanceMatrix: [String: Float] = [:]
        for i in 0..<faces.count {
            for j in (i + 1)..<faces.count {
                if let distance = computeModeAwareDistance(
                    face1: faces[i],
                    face2: faces[j],
                    mode: config.recognitionMode,
                    config: config,
                    cache: cache
                ) {
                    distanceMatrix[distanceKey(i, j)] = distance
                }
            }
        }

        // Iteratively merge closest clusters
        while clusters.count > 1 {
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

            if minDistance > config.clusteringThreshold {
                break
            }

            // Merge clusters
            let mergedCluster = clusters[minI] + clusters[minJ]
            clusters.remove(at: minJ)
            clusters.remove(at: minI)

            // Compute distances to new merged cluster
            var newDistances: [String: Float] = [:]
            for (k, cluster) in clusters.enumerated() {
                let distance = computeModeAwareAverageLinkage(
                    cluster1: mergedCluster,
                    cluster2: cluster,
                    mode: config.recognitionMode,
                    config: config,
                    cache: cache
                )
                newDistances[distanceKey(k, clusters.count)] = distance
            }

            clusters.append(mergedCluster)

            // Rebuild distance matrix
            distanceMatrix = [:]
            for i in 0..<(clusters.count - 1) {
                for j in (i + 1)..<(clusters.count - 1) {
                    let distance = computeModeAwareAverageLinkage(
                        cluster1: clusters[i],
                        cluster2: clusters[j],
                        mode: config.recognitionMode,
                        config: config,
                        cache: cache
                    )
                    distanceMatrix[distanceKey(i, j)] = distance
                }
            }
            for (key, value) in newDistances {
                distanceMatrix[key] = value
            }
        }

        // Convert clusters to FaceGroups
        return clusters.map { clusterFaces in
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

}

// MARK: - VNFaceObservation Helpers

private extension CGRect {
    nonisolated var asCGRect: CGRect { self }
}
