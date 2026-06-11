import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Everything one background prewarm pass produces for the secondary lenses.
nonisolated struct FaceLensPrewarmOutcome: Sendable {
    let folderURL: URL
    /// Newly computed appearance prints by face ID (faces that already had one are absent).
    let appearancePrints: [UUID: Data]
    /// Newly computed clothing prints + torso rects by face ID.
    let clothingPrints: [UUID: (data: Data, rect: CGRect)]
    let expressionGroups: [FaceGroup]
}

/// Embedding prewarm + assists for the non-Face lenses.
///
/// The Face lens clusters ArcFace identity embeddings during the scan itself. After that
/// scan completes, a low-priority prewarm computes the extra vectors once —
/// - **appearance**: a `VNFeaturePrintObservation` of each stored face thumbnail (used by the
///   Expression lens's own clustering; deliberately not identity),
/// - **clothing**: a `VNFeaturePrintObservation` of each face's estimated torso region (used
///   by the Red Carpet assist's combined distance) —
/// so lens switches never re-detect or re-embed.
nonisolated struct FaceLensService: Sendable {

    private let clothingService = ClothingFeatureService()

    // MARK: - Prewarm

    /// One full prewarm pass: compute the missing appearance + clothing feature prints, then
    /// cluster the Expression lens from the enriched faces. Runs off the main actor; checks
    /// cancellation throughout (a cancelled pass returns a partial outcome the caller discards).
    func prewarm(
        faces: [DetectedFace],
        folderURL: URL,
        storage: FaceDataStorageService
    ) async -> FaceLensPrewarmOutcome {
        let appearance = await computeAppearancePrints(for: faces, folderURL: folderURL, storage: storage)
        let clothing = await computeClothingPrints(for: faces)

        var enriched = faces
        for i in enriched.indices {
            if let print = appearance[enriched[i].id] {
                enriched[i].appearanceFeaturePrintData = print
            }
            if let item = clothing[enriched[i].id] {
                enriched[i].clothingFeaturePrintData = item.data
                enriched[i].clothingRect = item.rect
            }
        }

        return FaceLensPrewarmOutcome(
            folderURL: folderURL,
            appearancePrints: appearance,
            clothingPrints: clothing,
            expressionGroups: clusterExpression(faces: enriched)
        )
    }

    // MARK: - Red Carpet assist

    /// Suggest merging existing people groups whose combined face+clothing distance clears
    /// the Red Carpet threshold — pairs the face-only threshold alone couldn't merge. Pairs
    /// without clothing data on both sides are skipped (face-only similarity is the Face
    /// lens's job); so are pairs already named as different people.
    func clothingAssistedMergeSuggestions(
        groups: [FaceGroup],
        faces: [DetectedFace]
    ) async -> [MergeSuggestion] {
        let lookup = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        let identityVectors = decodeIdentityVectors(faces)
        let clothing = decodeObservations(faces, data: \.clothingFeaturePrintData)
        let faceWeight = FaceRecognitionDefaults.redCarpetFaceWeight
        let threshold = FaceRecognitionDefaults.redCarpetClusteringThreshold

        var suggestions: [MergeSuggestion] = []
        for i in 0..<groups.count {
            if Task.isCancelled { break }
            for j in (i + 1)..<groups.count {
                if let n1 = groups[i].name, let n2 = groups[j].name, n1 != n2 { continue }

                let faces1 = groups[i].faceIDs.compactMap { lookup[$0] }
                let faces2 = groups[j].faceIDs.compactMap { lookup[$0] }
                guard !faces1.isEmpty, !faces2.isEmpty else { continue }

                var total: Float = 0
                var count = 0
                for a in faces1 {
                    guard let v1 = identityVectors[a.id], let c1 = clothing[a.id] else { continue }
                    for b in faces2 {
                        guard let v2 = identityVectors[b.id], let c2 = clothing[b.id],
                              let faceDistance = EmbeddingCodec.cosineDistance(v1, v2),
                              let clothingDistance = Self.visionDistance(c1, c2) else { continue }
                        total += faceDistance * faceWeight + clothingDistance * (1 - faceWeight)
                        count += 1
                    }
                }
                guard count > 0 else { continue }

                let avgDistance = total / Float(count)
                if avgDistance <= threshold {
                    suggestions.append(MergeSuggestion(
                        group1ID: groups[i].id,
                        group2ID: groups[j].id,
                        similarity: max(0, 1 - avgDistance)
                    ))
                }
            }
        }
        return suggestions.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Appearance embeddings (Expression lens)

    /// Compute appearance feature prints for faces that lack one, from their stored face-crop
    /// thumbnails (no original-image decode needed). Returns archived observations by face ID.
    func computeAppearancePrints(
        for faces: [DetectedFace],
        folderURL: URL,
        storage: FaceDataStorageService
    ) async -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        for face in faces where face.appearanceFeaturePrintData == nil {
            if Task.isCancelled { break }
            guard let jpegData = storage.loadThumbnail(for: face.id, folderURL: folderURL),
                  let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            if let data = try? await featurePrint(for: cgImage) {
                result[face.id] = data
            }
        }
        return result
    }

    // MARK: - Clothing embeddings (Red Carpet lens)

    /// Compute clothing feature prints for faces that lack one, decoding each source image once
    /// (downsampled) and cropping every face's estimated torso from it.
    /// Returns archived observations and torso rects by face ID.
    func computeClothingPrints(for faces: [DetectedFace]) async -> [UUID: (data: Data, rect: CGRect)] {
        var result: [UUID: (data: Data, rect: CGRect)] = [:]
        let byImage = Dictionary(grouping: faces.filter { $0.clothingFeaturePrintData == nil }, by: \.imageURL)

        for (imageURL, imageFaces) in byImage {
            if Task.isCancelled { break }
            guard let cgImage = decodeDownsampled(imageURL, maxPixel: 1536) else { continue }
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

            for face in imageFaces {
                if Task.isCancelled { break }
                guard let torsoRect = clothingService.estimateTorsoRect(from: face.faceRect, imageSize: imageSize),
                      let data = try? await clothingService.generateClothingFeaturePrint(for: cgImage, torsoRect: torsoRect)
                else { continue }
                result[face.id] = (data: data, rect: torsoRect)
            }
        }
        return result
    }

    // MARK: - Expression clustering

    /// Cluster faces by appearance (VNFeaturePrint on the stored crops) for the Expression
    /// lens. Faces without an appearance print end up as singletons.
    func clusterExpression(faces: [DetectedFace]) -> [FaceGroup] {
        let observations = decodeObservations(faces, data: \.appearanceFeaturePrintData)
        return clusterFaces(
            faces,
            threshold: FaceRecognitionDefaults.expressionClusteringThreshold
        ) { a, b in
            guard let o1 = observations[a.id], let o2 = observations[b.id] else { return nil }
            return Self.visionDistance(o1, o2)
        }
    }

    /// Generic quality-gated two-pass clustering over an arbitrary distance: agglomerative
    /// average-linkage over high-quality faces, then nearest-group assignment (or singleton)
    /// for the rest. Mirrors the Face pipeline's structure.
    func clusterFaces(
        _ faces: [DetectedFace],
        threshold: Float,
        qualityGateThreshold: Float = FaceRecognitionDefaults.qualityGateThreshold,
        distance: (DetectedFace, DetectedFace) -> Float?
    ) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        // Pass 1: agglomerative clustering over high-quality faces.
        var highQuality: [DetectedFace] = []
        var lowQuality: [DetectedFace] = []
        for face in faces {
            if (face.qualityScore ?? 0) >= qualityGateThreshold {
                highQuality.append(face)
            } else {
                lowQuality.append(face)
            }
        }

        var clusters = clusterHierarchical(highQuality, threshold: threshold, distance: distance)

        // Pass 2: attach each remaining face to the nearest cluster (average linkage), else singleton.
        for face in lowQuality {
            if Task.isCancelled { break }
            var bestIndex: Int?
            var bestDistance = threshold
            for (index, cluster) in clusters.enumerated() {
                guard let d = averageLinkage([face], cluster, distance: distance) else { continue }
                if d < bestDistance {
                    bestDistance = d
                    bestIndex = index
                }
            }
            if let bestIndex {
                clusters[bestIndex].append(face)
            } else {
                clusters.append([face])
            }
        }

        // Largest groups first so the lens view leads with the strongest clusters.
        return clusters
            .sorted { $0.count > $1.count }
            .compactMap { cluster -> FaceGroup? in
                let representative = cluster.max { ($0.qualityScore ?? 0) < ($1.qualityScore ?? 0) }
                guard let representative else { return nil }
                return FaceGroup(
                    id: UUID(),
                    name: nil,
                    representativeFaceID: representative.id,
                    faceIDs: cluster.map(\.id)
                )
            }
    }

    // MARK: - Generic average-linkage agglomerative clustering

    private func clusterHierarchical(
        _ faces: [DetectedFace],
        threshold: Float,
        distance: (DetectedFace, DetectedFace) -> Float?
    ) -> [[DetectedFace]] {
        guard !faces.isEmpty else { return [] }

        var clusters: [Int: [DetectedFace]] = Dictionary(uniqueKeysWithValues: faces.indices.map { ($0, [faces[$0]]) })
        var activeIndices = Set(0..<faces.count)
        var nextClusterID = faces.count

        var distanceMatrix: [Int64: Float] = [:]
        for i in 0..<faces.count {
            if Task.isCancelled { break }
            for j in (i + 1)..<faces.count {
                if let d = distance(faces[i], faces[j]) {
                    distanceMatrix[Self.distanceKey(i, j)] = d
                }
            }
        }

        while activeIndices.count > 1 {
            if Task.isCancelled { break }

            var minDistance = Float.infinity
            var minI = 0
            var minJ = 0
            let active = activeIndices.sorted()
            for ai in 0..<active.count {
                for aj in (ai + 1)..<active.count {
                    let key = Self.distanceKey(active[ai], active[aj])
                    if let d = distanceMatrix[key], d < minDistance {
                        minDistance = d
                        minI = active[ai]
                        minJ = active[aj]
                    }
                }
            }

            if minDistance > threshold { break }

            let merged = clusters[minI]! + clusters[minJ]!
            activeIndices.remove(minI)
            activeIndices.remove(minJ)
            let mergedID = nextClusterID
            nextClusterID += 1
            clusters[mergedID] = merged

            for otherID in activeIndices {
                if let d = averageLinkage(merged, clusters[otherID]!, distance: distance) {
                    distanceMatrix[Self.distanceKey(otherID, mergedID)] = d
                }
            }
            activeIndices.insert(mergedID)
        }

        return activeIndices.sorted().compactMap { clusters[$0] }
    }

    private func averageLinkage(
        _ cluster1: [DetectedFace],
        _ cluster2: [DetectedFace],
        distance: (DetectedFace, DetectedFace) -> Float?
    ) -> Float? {
        var total: Float = 0
        var count = 0
        for a in cluster1 {
            for b in cluster2 {
                if let d = distance(a, b) {
                    total += d
                    count += 1
                }
            }
        }
        return count > 0 ? total / Float(count) : nil
    }

    private static func distanceKey(_ i: Int, _ j: Int) -> Int64 {
        let (a, b) = i < j ? (i, j) : (j, i)
        return Int64(a) &<< 32 | Int64(b)
    }

    // MARK: - Decode helpers

    private func decodeObservations(
        _ faces: [DetectedFace],
        data keyPath: KeyPath<DetectedFace, Data?>
    ) -> [UUID: VNFeaturePrintObservation] {
        var result: [UUID: VNFeaturePrintObservation] = [:]
        for face in faces {
            guard let data = face[keyPath: keyPath],
                  let observation = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
            else { continue }
            result[face.id] = observation
        }
        return result
    }

    private func decodeIdentityVectors(_ faces: [DetectedFace]) -> [UUID: [Float]] {
        var result: [UUID: [Float]] = [:]
        for face in faces {
            if let vector = EmbeddingCodec.decode(face.featurePrintData) {
                result[face.id] = vector
            }
        }
        return result
    }

    private static func visionDistance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            return nil
        }
    }

    // MARK: - Image helpers

    private func featurePrint(for cgImage: CGImage) async throws -> Data? {
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

    /// Decode an image downsampled to `maxPixel` on the long edge, with EXIF orientation applied
    /// (`kCGImageSourceCreateThumbnailWithTransform`), so torso rects line up with `faceRect`.
    private func decodeDownsampled(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
