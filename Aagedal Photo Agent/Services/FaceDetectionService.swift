import Foundation
import Vision
import AppKit
import CoreGraphics
import ImageIO
import Accelerate

nonisolated struct FaceDetectionService: Sendable {

    /// The face-identity embedder. Folder faces and (transitively, via copied face
    /// embeddings) the Known People gallery all run through this one embedder, so every
    /// comparison happens in the same embedding space.
    let embedder: any FaceEmbedder

    nonisolated init(embedder: any FaceEmbedder = CoreMLFaceEmbedder.shared) {
        self.embedder = embedder
    }

    /// Cache for decoded face embeddings during clustering operations.
    /// Reduces `EmbeddingCodec.decode` calls from O(N³) to O(N) by decoding each embedding only once.
    /// Uses NSCache (thread-safe, auto-evicts under memory pressure) instead of Dictionary.
    final class FeaturePrintCache: @unchecked Sendable {
        private final class Entry { let vector: [Float]; init(_ v: [Float]) { self.vector = v } }
        private let cache: NSCache<NSUUID, Entry> = {
            let c = NSCache<NSUUID, Entry>()
            c.countLimit = 4000
            return c
        }()

        func getFeaturePrint(for face: DetectedFace) -> [Float]? {
            getFeaturePrint(for: face.id, data: face.featurePrintData)
        }

        func getFeaturePrint(for faceID: UUID, data: Data) -> [Float]? {
            let key = faceID as NSUUID
            if let cached = cache.object(forKey: key) { return cached.vector }
            guard let vector = EmbeddingCodec.decode(data) else { return nil }
            cache.setObject(Entry(vector), forKey: key)
            return vector
        }
    }

    /// Configuration for face detection quality filtering and clustering.
    struct DetectionConfig: Sendable {
        var minConfidence: Float = 0.7
        var minFaceSize: Int = 50

        /// When true, detection runs Vision over the whole image plus a grid of overlapping tiles
        /// and merges the results. Apple's detector under-detects on large group shots (small/off-angle
        /// faces are dropped); restricting it to a sub-region recovers many of them. Costs extra Vision
        /// passes per image (one per tile). The hardest non-frontal/motion poses still aren't found —
        /// that's a detector limitation, not a tiling one.
        var tiledDetection: Bool = true

        /// Maximum cosine distance (0...2) for two faces to be considered the same person.
        /// Default lives in `FaceRecognitionDefaults`; lower = stricter.
        var clusteringThreshold: Float = FaceRecognitionDefaults.clusteringThreshold

        /// Minimum face quality score (0...1) to participate in the first clustering pass.
        var qualityGateThreshold: Float = FaceRecognitionDefaults.qualityGateThreshold

        /// Retained only as stored metadata on `FolderFaceData`/`DetectedFace.embeddingMode`.
        /// The pipeline always uses the single CoreML face embedder; this is no longer a user choice.
        var recognitionMode: FaceRecognitionMode = .visionFeaturePrint

        // MARK: - Sports tagging
        /// When true, the scan also runs jersey-number OCR + colour sampling.
        var sportsModeEnabled: Bool = false
        /// Minimum Vision OCR confidence (0...1) to accept a recognised number.
        var sportsOCRConfidenceThreshold: Float = 0.5
        /// Minimum number-box height as a fraction of image height. Chest numbers on a
        /// 4–6k sports frame measure ~0.025–0.035; back numbers ~0.07–0.11.
        var sportsNumberMinHeightFraction: CGFloat = 0.02

        nonisolated init(
            minConfidence: Float = 0.7,
            minFaceSize: Int = 50,
            tiledDetection: Bool = true,
            clusteringThreshold: Float = FaceRecognitionDefaults.clusteringThreshold,
            qualityGateThreshold: Float = FaceRecognitionDefaults.qualityGateThreshold,
            recognitionMode: FaceRecognitionMode = .visionFeaturePrint,
            sportsModeEnabled: Bool = false,
            sportsOCRConfidenceThreshold: Float = 0.5,
            sportsNumberMinHeightFraction: CGFloat = 0.02
        ) {
            self.minConfidence = minConfidence
            self.minFaceSize = minFaceSize
            self.tiledDetection = tiledDetection
            self.clusteringThreshold = clusteringThreshold
            self.qualityGateThreshold = qualityGateThreshold
            self.recognitionMode = recognitionMode
            self.sportsModeEnabled = sportsModeEnabled
            self.sportsOCRConfidenceThreshold = sportsOCRConfidenceThreshold
            self.sportsNumberMinHeightFraction = sportsNumberMinHeightFraction
        }
    }

    /// Output of `detectFaces`: the detected faces (each possibly enriched with a
    /// jersey number in sports mode) plus standalone jersey numbers that had no
    /// containing face (back-turned players).
    struct DetectionResult: Sendable {
        var faces: [(face: DetectedFace, thumbnail: Data)]
        var standaloneNumbers: [NumberDetection]

        init(faces: [(face: DetectedFace, thumbnail: Data)], standaloneNumbers: [NumberDetection] = []) {
            self.faces = faces
            self.standaloneNumbers = standaloneNumbers
        }
    }

    /// Detect faces in a single image, generate feature prints and thumbnails.
    /// Returns an array of `DetectedFace` and their thumbnail JPEG data keyed by face ID.
    func detectFaces(in imageURL: URL, config: DetectionConfig = DetectionConfig()) async throws -> DetectionResult {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw NSError(
                domain: "FaceDetectionService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create image source for \(imageURL.lastPathComponent)"]
            )
        }
        guard let rawCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NSError(
                domain: "FaceDetectionService", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode image at index 0 for \(imageURL.lastPathComponent)"]
            )
        }

        // Apply EXIF orientation to get correctly oriented image
        let cgImage = applyEXIFOrientation(to: rawCGImage, from: imageSource)

        // Use face landmarks request for better quality detection. When tiling is enabled we also
        // scan overlapping sub-regions and merge — Apple's whole-image detector drops small/off-angle
        // faces in group shots, and restricting it to a tile recovers many of them.
        let faceObservations = try await detectFaceLandmarksTiled(in: cgImage, tiled: config.tiledDetection)

        let clothingService = ClothingFeatureService()
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        // No faces: in sports mode still scan for standalone jersey numbers
        // (back-turned players have a number but no detectable face).
        guard !faceObservations.isEmpty else {
            if config.sportsModeEnabled {
                let standalone = await detectStandaloneNumbers(in: cgImage, imageURL: imageURL, imageSize: imageSize, config: config)
                return DetectionResult(faces: [], standaloneNumbers: standalone)
            }
            return DetectionResult(faces: [])
        }

        // Apple's learned face-capture-quality per detected face (blur/lighting/pose/occlusion),
        // reusing the observations we already detected. Index-aligned to faceObservations.
        let captureQualities = await faceCaptureQualities(for: faceObservations, in: cgImage)

        var results: [(face: DetectedFace, thumbnail: Data)] = []

        for (faceIndex, observation) in faceObservations.enumerated() {
            // Filter by confidence
            guard observation.confidence >= config.minConfidence else { continue }

            // Calculate face size in pixels
            let facePixelWidth = Int(observation.boundingBox.width * CGFloat(cgImage.width))
            guard facePixelWidth >= config.minFaceSize else { continue }

            // Capture-quality is stored per face; the too-blurry filter is applied live at display
            // time (the "Sharpness" slider) rather than dropped here, so it can be tuned without rescanning.
            let captureQuality = captureQualities[faceIndex]

            // Standard bounding box crop for thumbnail and blur score (unchanged from original)
            let expandedRect = expandBoundingBox(observation.boundingBox, by: 0.15, imageSize: imageSize)
            guard let croppedImage = cropFace(from: cgImage, normalizedRect: expandedRect) else { continue }

            // Compute blur score for quality assessment
            let blurScore = computeBlurScore(for: croppedImage)

            // Try eye-aligned crop for feature print only (improves clustering consistency)
            // Pre-crop a generous region (3x bbox) to avoid transforming the full-res image
            var featurePrintImage: CGImage = croppedImage
            if let (leftEyeNorm, rightEyeNorm) = computeEyeCenters(from: observation) {
                let preCropRect = expandBoundingBox(observation.boundingBox, by: 2.0, imageSize: imageSize)
                if let preCrop = cropFace(from: cgImage, normalizedRect: preCropRect) {
                    // Eye coords relative to pre-crop, in CG bottom-left pixel space
                    // Both eye norms and preCropRect use Vision normalized coords (bottom-left origin)
                    let fullW = CGFloat(cgImage.width)
                    let fullH = CGFloat(cgImage.height)
                    let leftPixel = CGPoint(
                        x: (leftEyeNorm.x - preCropRect.origin.x) * fullW,
                        y: (leftEyeNorm.y - preCropRect.origin.y) * fullH
                    )
                    let rightPixel = CGPoint(
                        x: (rightEyeNorm.x - preCropRect.origin.x) * fullW,
                        y: (rightEyeNorm.y - preCropRect.origin.y) * fullH
                    )
                    let eyeDx = rightPixel.x - leftPixel.x
                    let eyeDy = rightPixel.y - leftPixel.y
                    let interEyeDist = sqrt(eyeDx * eyeDx + eyeDy * eyeDy)
                    if interEyeDist >= 20,
                       let aligned = createArcFaceAlignedCrop(from: preCrop, leftEyePixel: leftPixel, rightEyePixel: rightPixel) {
                        featurePrintImage = aligned
                    }
                }
            }

            // Generate feature print from aligned crop (or fallback to bbox crop)
            guard let featurePrintData = try await generateFeaturePrint(for: featurePrintImage) else { continue }

            // Thumbnail always from original bbox crop (preserves existing appearance)
            let thumbnailData = generateThumbnail(from: croppedImage, size: 120)
            guard let thumbnailData else { continue }

            // Compute composite quality score
            let qualityScore = computeQualityScore(
                confidence: observation.confidence,
                faceSize: facePixelWidth,
                blurScore: blurScore,
                captureQuality: captureQuality
            )

            // The single CoreML face embedder is identity-discriminative on its own, so
            // clothing features are no longer used for recognition (only the face embedding).
            let clothingFeaturePrintData: Data? = nil
            let clothingRect: CGRect? = nil

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
                captureQuality: captureQuality,
                clothingFeaturePrintData: clothingFeaturePrintData,
                clothingRect: clothingRect,
                embeddingMode: config.recognitionMode
            )

            results.append((face: face, thumbnail: thumbnailData))
        }

        // Sports mode: detect jersey numbers across the image and attach each to
        // the face whose estimated torso contains it; numbers with no containing
        // face become standalone (back-turned) detections.
        var standaloneNumbers: [NumberDetection] = []
        if config.sportsModeEnabled {
            let jersey = JerseyDetectionService()
            let raws = (try? await jersey.detectNumbers(
                in: cgImage,
                imageSize: imageSize,
                ocrConfidenceThreshold: config.sportsOCRConfidenceThreshold,
                minHeightFraction: config.sportsNumberMinHeightFraction
            )) ?? []

            // Precompute each face's estimated torso rect once.
            let torsos: [CGRect?] = results.map {
                clothingService.estimateTorsoRect(from: $0.face.faceRect, imageSize: imageSize)
            }

            for raw in raws {
                let center = CGPoint(x: raw.box.midX, y: raw.box.midY)
                var bestIdx: Int?
                var bestDist = CGFloat.greatestFiniteMagnitude
                for (i, torso) in torsos.enumerated() {
                    guard let torso, torso.contains(center) else { continue }
                    let d = hypot(torso.midX - center.x, torso.midY - center.y)
                    if d < bestDist { bestDist = d; bestIdx = i }
                }
                if let idx = bestIdx {
                    // Collapse into the face; keep the highest-confidence number. The loser is
                    // demoted to a standalone detection, NOT dropped — in packed group shots the
                    // estimated torsos overlap, so a face's torso routinely contains another
                    // player's (real) number.
                    if (results[idx].face.numberConfidence ?? 0) < raw.confidence {
                        if let previousNumber = results[idx].face.jerseyNumber,
                           let previousBox = results[idx].face.jerseyNumberBox {
                            standaloneNumbers.append(NumberDetection(
                                imageURL: imageURL,
                                number: previousNumber,
                                numberConfidence: results[idx].face.numberConfidence ?? 0,
                                boundingBox: previousBox,
                                jerseyColorRGB: results[idx].face.jerseyColorRGB
                            ))
                        }
                        results[idx].face.jerseyNumber = raw.value
                        results[idx].face.numberConfidence = raw.confidence
                        results[idx].face.jerseyNumberBox = raw.box
                        results[idx].face.jerseyColorRGB = raw.color
                    } else {
                        standaloneNumbers.append(NumberDetection(
                            imageURL: imageURL,
                            number: raw.value,
                            numberConfidence: raw.confidence,
                            boundingBox: raw.box,
                            jerseyColorRGB: raw.color
                        ))
                    }
                } else {
                    standaloneNumbers.append(NumberDetection(
                        imageURL: imageURL,
                        number: raw.value,
                        numberConfidence: raw.confidence,
                        boundingBox: raw.box,
                        jerseyColorRGB: raw.color
                    ))
                }
            }
        }

        return DetectionResult(faces: results, standaloneNumbers: standaloneNumbers)
    }

    /// Detect jersey numbers in an image with no detectable faces — all results
    /// are standalone (back-turned) detections.
    private func detectStandaloneNumbers(
        in cgImage: CGImage,
        imageURL: URL,
        imageSize: CGSize,
        config: DetectionConfig
    ) async -> [NumberDetection] {
        let jersey = JerseyDetectionService()
        let raws = (try? await jersey.detectNumbers(
            in: cgImage,
            imageSize: imageSize,
            ocrConfidenceThreshold: config.sportsOCRConfidenceThreshold,
            minHeightFraction: config.sportsNumberMinHeightFraction
        )) ?? []
        return raws.map {
            NumberDetection(
                imageURL: imageURL,
                number: $0.value,
                numberConfidence: $0.confidence,
                boundingBox: $0.box,
                jerseyColorRGB: $0.color
            )
        }
    }

    // MARK: - Quality Scoring

    /// Compute blur score using Laplacian variance (Accelerate-optimized). Higher = sharper.
    private func computeBlurScore(for cgImage: CGImage) -> Float {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return 0 }

        // Convert CGImage to Planar8 grayscale via vImageConverter
        guard let sourceFormat = vImage_CGImageFormat(cgImage: cgImage),
              let destFormat = vImage_CGImageFormat(
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  colorSpace: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
              ),
              let converter = try? vImageConverter.make(
                  sourceFormat: sourceFormat,
                  destinationFormat: destFormat
              ) else { return 0 }

        guard let sourceBuffer = try? vImage_Buffer(cgImage: cgImage) else { return 0 }
        defer { sourceBuffer.free() }

        guard var grayBuffer = try? vImage_Buffer(
            width: width,
            height: height,
            bitsPerPixel: 8
        ) else { return 0 }
        defer { grayBuffer.free() }

        guard (try? converter.convert(source: sourceBuffer, destination: &grayBuffer)) != nil else {
            return 0
        }

        // Convert Planar8 to PlanarF for convolution
        guard var floatBuffer = try? vImage_Buffer(
            width: width,
            height: height,
            bitsPerPixel: 32
        ) else { return 0 }
        defer { floatBuffer.free() }

        let convertErr = vImageConvert_Planar8toPlanarF(
            &grayBuffer,
            &floatBuffer,
            0.0, 255.0,
            vImage_Flags(kvImageNoFlags)
        )
        guard convertErr == kvImageNoError else { return 0 }

        // Apply 3x3 Laplacian kernel via vImageConvolve_PlanarF
        guard var laplacianBuffer = try? vImage_Buffer(
            width: width,
            height: height,
            bitsPerPixel: 32
        ) else { return 0 }
        defer { laplacianBuffer.free() }

        var kernel: [Float] = [
            0,  1,  0,
            1, -4,  1,
            0,  1,  0
        ]
        let convolveErr = vImageConvolve_PlanarF(
            &floatBuffer,
            &laplacianBuffer,
            nil,
            0, 0,
            &kernel,
            3, 3,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )
        guard convolveErr == kvImageNoError else { return 0 }

        // Compute variance using vDSP: Var(X) = E[X²] - E[X]²
        let pixelCount = width * height
        let laplacianPtr = laplacianBuffer.data.assumingMemoryBound(to: Float.self)
        let laplacianData = UnsafeBufferPointer(start: laplacianPtr, count: pixelCount)
        let mean = vDSP.mean(laplacianData)
        let meanSquare = vDSP.meanSquare(laplacianData)
        let variance = meanSquare - (mean * mean)

        // Normalize to 0-1 range (empirically, values > 500 are very sharp)
        return min(1.0, max(0.0, variance / 500.0))
    }

    /// Compute composite quality score from individual metrics
    private func computeQualityScore(confidence: Float, faceSize: Int, blurScore: Float, captureQuality: Float?) -> Float {
        // Normalize face size (50-200 pixels maps to 0-1)
        let sizeScore = min(1.0, max(0.0, Float(faceSize - 50) / 150.0))

        // Prefer Apple's learned capture-quality (robust) over the Laplacian blur proxy, which is
        // unreliable at typical face-crop resolutions. Weighted so the sharpest face wins as the
        // group representative/thumbnail.
        let sharpness = captureQuality ?? blurScore
        let weights: (confidence: Float, size: Float, sharpness: Float) = (0.3, 0.2, 0.5)
        return weights.confidence * confidence +
               weights.size * sizeScore +
               weights.sharpness * sharpness
    }

    /// Hierarchical agglomerative clustering with average linkage.
    /// Produces deterministic, order-independent results.
    private func clusterFacesHierarchical(_ faces: [DetectedFace], threshold: Float, cache: FeaturePrintCache? = nil) -> [FaceGroup] {
        guard !faces.isEmpty else { return [] }

        // Use provided cache or create a new one
        let fpCache = cache ?? FeaturePrintCache()

        // Start with each face in its own cluster, using stable IDs
        var clusters: [Int: [DetectedFace]] = Dictionary(uniqueKeysWithValues: faces.indices.map { ($0, [faces[$0]]) })
        var activeIndices = Set(0..<faces.count)
        var nextClusterID = faces.count

        // Build initial distance matrix using the cache
        var distanceMatrix = buildDistanceMatrix(faces, cache: fpCache)

        // Iteratively merge closest clusters until all distances exceed threshold
        while activeIndices.count > 1 {
            guard !Task.isCancelled else { break }

            // Find minimum distance pair
            var minDistance: Float = .infinity
            var minI = 0
            var minJ = 0
            let active = activeIndices.sorted()

            for ai in 0..<active.count {
                for aj in (ai + 1)..<active.count {
                    let key = distanceKey(active[ai], active[aj])
                    if let distance = distanceMatrix[key], distance < minDistance {
                        minDistance = distance
                        minI = active[ai]
                        minJ = active[aj]
                    }
                }
            }

            // Stop if minimum distance exceeds threshold
            if minDistance > threshold {
                break
            }

            // Merge clusters using stable IDs — no matrix rebuild needed
            let mergedCluster = clusters[minI]! + clusters[minJ]!
            activeIndices.remove(minI)
            activeIndices.remove(minJ)

            let mergedID = nextClusterID
            nextClusterID += 1
            clusters[mergedID] = mergedCluster

            // Compute distances from the merged cluster to each surviving cluster
            for otherID in activeIndices {
                let distance = computeAverageLinkageDistance(mergedCluster, clusters[otherID]!, cache: fpCache)
                distanceMatrix[distanceKey(otherID, mergedID)] = distance
            }

            activeIndices.insert(mergedID)
        }

        // Convert clusters to FaceGroups
        return activeIndices.compactMap { id -> FaceGroup? in
            guard let clusterFaces = clusters[id] else { return nil }
            // Pick the face with highest quality score as representative
            let sortedByQuality = clusterFaces.sorted { ($0.qualityScore ?? 0) > ($1.qualityScore ?? 0) }
            guard let representative = sortedByQuality.first else { return nil }

            return FaceGroup(
                id: UUID(),
                name: nil,
                representativeFaceID: representative.id,
                faceIDs: clusterFaces.map(\.id)
            )
        }
    }

    private func buildDistanceMatrix(_ faces: [DetectedFace], cache: FeaturePrintCache) -> [Int64: Float] {
        var matrix: [Int64: Float] = [:]
        for i in 0..<faces.count {
            guard !Task.isCancelled else { break }
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

    private func distanceKey(_ i: Int, _ j: Int) -> Int64 {
        let (a, b) = i < j ? (i, j) : (j, i)
        return Int64(a) &<< 32 | Int64(b)
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

        // Partition faces by quality (single pass)
        var highQualityFaces: [DetectedFace] = []
        var lowQualityFaces: [DetectedFace] = []
        for face in faces {
            if (face.qualityScore ?? 0) >= config.qualityGateThreshold {
                highQualityFaces.append(face)
            } else {
                lowQualityFaces.append(face)
            }
        }
        let highQualityByID = Dictionary(uniqueKeysWithValues: highQualityFaces.map { ($0.id, $0) })

        // Pass 1: Cluster high-quality faces with deterministic agglomerative (average-linkage) clustering.
        var groups: [FaceGroup]
        if !highQualityFaces.isEmpty {
            groups = clusterFacesHierarchical(highQualityFaces, threshold: config.clusteringThreshold, cache: fpCache)
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
                guard let repFace = highQualityByID[group.representativeFaceID],
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

    // MARK: - Clustering Entry Point

    /// The single standardized clustering pipeline: incrementally assign each new face to the
    /// nearest existing group (average cosine linkage), then cluster the leftovers with the
    /// quality-gated agglomerative pass. Deterministic and order-independent.
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

        // First, try to assign new faces to existing groups by average cosine distance to members.
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

                var totalDistance: Float = 0
                var count = 0
                for memberFace in memberFaces {
                    if let memberFP = fpCache.getFeaturePrint(for: memberFace),
                       let d = computeDistanceCached(faceFP, memberFP) {
                        totalDistance += d
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let distance = totalDistance / Float(count)

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

        // Cluster the remaining faces with the quality-gated agglomerative pass.
        if !remainingFaces.isEmpty {
            let newGroups = clusterFacesQualityGated(remainingFaces, config: config, cache: fpCache)
            groups.append(contentsOf: newGroups)
        }

        return groups
    }

    /// Compute merge suggestions for groups that are close to the clustering threshold.
    /// Returns pairs of groups that might be the same person but didn't quite meet the threshold.
    func computeMergeSuggestions(groups: [FaceGroup], faces: [DetectedFace], threshold: Float, marginPercent: Float = 0.15, cache: FeaturePrintCache? = nil) -> [MergeSuggestion] {
        let faceLookup = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        // Reuse the caller's cache when provided so feature prints unarchived on a prior
        // call aren't re-unarchived here; fall back to a private cache otherwise.
        let fpCache = cache ?? FeaturePrintCache()
        var suggestions: [MergeSuggestion] = []

        // Check pairs of groups
        for i in 0..<groups.count {
            for j in (i + 1)..<groups.count {
                let group1Faces = groups[i].faceIDs.compactMap { faceLookup[$0] }
                let group2Faces = groups[j].faceIDs.compactMap { faceLookup[$0] }

                guard !group1Faces.isEmpty, !group2Faces.isEmpty else { continue }

                let avgDistance = computeAverageLinkageDistance(group1Faces, group2Faces, cache: fpCache)

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

    /// Compute refinement suggestions using named groups as anchors.
    /// Compares unnamed groups against named groups and suggests merges for close matches.
    /// This leverages user corrections to improve clustering accuracy.
    func computeRefinementSuggestions(
        groups: [FaceGroup],
        faces: [DetectedFace],
        threshold: Float
    ) -> [MergeSuggestion] {
        let namedGroups = groups.filter { $0.name != nil }
        let unnamedGroups = groups.filter { $0.name == nil }

        guard !namedGroups.isEmpty, !unnamedGroups.isEmpty else { return [] }

        let faceLookup = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        let cache = FeaturePrintCache()
        var suggestions: [MergeSuggestion] = []

        // For each unnamed group, find the best matching named group
        for unnamedGroup in unnamedGroups {
            let unnamedFaces = unnamedGroup.faceIDs.compactMap { faceLookup[$0] }
            guard !unnamedFaces.isEmpty else { continue }

            var bestMatch: (namedGroup: FaceGroup, distance: Float)?

            for namedGroup in namedGroups {
                let namedFaces = namedGroup.faceIDs.compactMap { faceLookup[$0] }
                guard !namedFaces.isEmpty else { continue }

                let avgDistance = computeAverageLinkageDistance(unnamedFaces, namedFaces, cache: cache)

                // Use a slightly relaxed threshold for refinement (user has provided context)
                let refinementThreshold = threshold * 1.15

                if avgDistance <= refinementThreshold {
                    if bestMatch.map({ avgDistance < $0.distance }) ?? true {
                        bestMatch = (namedGroup, avgDistance)
                    }
                }
            }

            if let match = bestMatch {
                let similarity = max(0, 1 - match.distance)
                suggestions.append(MergeSuggestion(
                    group1ID: match.namedGroup.id,  // Named group first
                    group2ID: unnamedGroup.id,
                    similarity: similarity
                ))
            }
        }

        // Sort by similarity descending (best matches first)
        return suggestions.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Vision Requests

    /// Tile grid for `detectFaceLandmarksTiled`: columns × rows, plus the fractional overlap added
    /// to each tile edge so faces straddling a seam are fully contained in at least one tile.
    private static let tileColumns = 3
    private static let tileRows = 2
    private static let tileOverlap = 0.15
    /// Two detections whose bounding boxes overlap by at least this IoU are treated as the same face.
    private static let mergeIoUThreshold: CGFloat = 0.3

    /// Detect faces with landmarks, optionally scanning overlapping tiles and merging the results.
    ///
    /// Apple's whole-image detector under-detects on large group shots (small or slightly
    /// off-angle faces get dropped). Re-running the request restricted to a `regionOfInterest`
    /// lets Vision resolve those faces; because ROI results are reported in full-image normalized
    /// coordinates with landmarks intact, the merged observations flow through the rest of the
    /// pipeline (capture quality, eye alignment, crops) unchanged.
    private nonisolated func detectFaceLandmarksTiled(in cgImage: CGImage, tiled: Bool) async throws -> [VNFaceObservation] {
        // Whole-image pass first; its detections are best-centered, so they win ties on merge.
        var merged = try await detectFaceLandmarks(in: cgImage, regionOfInterest: nil)
        guard tiled else { return merged }

        for roi in Self.tileRegions() {
            let tileFaces = try await detectFaceLandmarks(in: cgImage, regionOfInterest: roi)
            for face in tileFaces where !merged.contains(where: { Self.iou($0.boundingBox, face.boundingBox) >= Self.mergeIoUThreshold }) {
                merged.append(face)
            }
        }
        return merged
    }

    /// The set of overlapping regions-of-interest (normalized, bottom-left origin) tiling the image.
    private nonisolated static func tileRegions() -> [CGRect] {
        var regions: [CGRect] = []
        for row in 0..<tileRows {
            for col in 0..<tileColumns {
                let x0 = max(0.0, Double(col) / Double(tileColumns) - tileOverlap)
                let x1 = min(1.0, Double(col + 1) / Double(tileColumns) + tileOverlap)
                let y0 = max(0.0, Double(row) / Double(tileRows) - tileOverlap)
                let y1 = min(1.0, Double(row + 1) / Double(tileRows) + tileOverlap)
                regions.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        return regions
    }

    /// Intersection-over-union of two normalized rects, used to dedup faces seen in multiple tiles.
    private nonisolated static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// Detect faces with landmarks for better quality filtering. When `regionOfInterest` is set
    /// (normalized, bottom-left origin), Vision searches only that sub-region but still reports
    /// results in full-image coordinates.
    private nonisolated func detectFaceLandmarks(in cgImage: CGImage, regionOfInterest: CGRect? = nil) async throws -> [VNFaceObservation] {
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
            if let regionOfInterest {
                request.regionOfInterest = regionOfInterest
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Apple `VNDetectFaceCaptureQuality` for already-detected faces, returned aligned (by index)
    /// to `observations`. Reuses the existing detections via `inputFaceObservations`; results are
    /// matched back by observation UUID. Returns `nil` for any face whose quality couldn't be scored.
    private nonisolated func faceCaptureQualities(for observations: [VNFaceObservation], in cgImage: CGImage) async -> [Float?] {
        guard !observations.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNDetectFaceCaptureQualityRequest()
            request.inputFaceObservations = observations
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let scored = request.results ?? []
                var byUUID: [UUID: Float] = [:]
                for face in scored where face.faceCaptureQuality != nil {
                    byUUID[face.uuid] = face.faceCaptureQuality
                }
                continuation.resume(returning: observations.map { byUUID[$0.uuid] })
            } catch {
                continuation.resume(returning: [Float?](repeating: nil, count: observations.count))
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

    /// Generate the face-identity embedding for an aligned crop and encode it for storage.
    /// Backed by the bundled ArcFace CoreML model via `FaceEmbedder`.
    private func generateFeaturePrint(for cgImage: CGImage) async throws -> Data? {
        let vector = try await embedder.embed(cgImage)
        return EmbeddingCodec.encode(vector)
    }

    // MARK: - Image Processing

    /// Apply EXIF orientation to a CGImage to get the correctly oriented image.
    /// This ensures faces are detected and cropped from the visually correct orientation.
    private func applyEXIFOrientation(to cgImage: CGImage, from imageSource: CGImageSource) -> CGImage {
        // Get EXIF orientation from image properties - check multiple locations for different formats
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return cgImage
        }

        // Try to get orientation from multiple locations (different formats store it differently)
        var orientationValue: UInt32 = 1

        // 1. Root level kCGImagePropertyOrientation (most common)
        if let value = properties[kCGImagePropertyOrientation] {
            if let uint32 = value as? UInt32 {
                orientationValue = uint32
            } else if let int = value as? Int {
                orientationValue = UInt32(int)
            } else if let number = value as? NSNumber {
                orientationValue = number.uint32Value
            }
        }

        // 2. TIFF dictionary (some formats including HEIC)
        if orientationValue == 1,
           let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiffDict[kCGImagePropertyTIFFOrientation] {
            if let uint32 = value as? UInt32 {
                orientationValue = uint32
            } else if let int = value as? Int {
                orientationValue = UInt32(int)
            } else if let number = value as? NSNumber {
                orientationValue = number.uint32Value
            }
        }

        // 3. HEIF/HEIC specific dictionary
        if orientationValue == 1,
           let heifDict = properties[kCGImagePropertyHEICSDictionary] as? [CFString: Any],
           let value = heifDict[kCGImagePropertyOrientation] {
            if let uint32 = value as? UInt32 {
                orientationValue = uint32
            } else if let int = value as? Int {
                orientationValue = UInt32(int)
            } else if let number = value as? NSNumber {
                orientationValue = number.uint32Value
            }
        }

        // No rotation needed for normal orientation
        guard orientationValue != 1 else {
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
        case 5: // Rotate 90° CCW + flip horizontal (transpose)
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(translationX: CGFloat(newWidth), y: CGFloat(newHeight))
                .rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 6: // Rotate 90° CW (image was stored rotated 90° CCW)
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(translationX: 0, y: CGFloat(newHeight)).rotated(by: -.pi / 2)
        case 7: // Rotate 90° CW + flip horizontal (transverse)
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(rotationAngle: -.pi / 2).scaledBy(x: -1, y: 1).translatedBy(x: CGFloat(-newWidth), y: 0)
        case 8: // Rotate 90° CCW (image was stored rotated 90° CW)
            newWidth = height
            newHeight = width
            transform = CGAffineTransform(translationX: CGFloat(newWidth), y: 0).rotated(by: .pi / 2)
        default:
            return cgImage
        }

        // Create a new bitmap context with the correct orientation
        // Try original format first, fall back to standard 8-bit RGBA for compatibility
        // (HEIC 10-bit images may not be supported by CGContext)
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: cgImage.bitmapInfo.rawValue
        )

        // Fallback to standard 8-bit RGBA if original format isn't supported
        if context == nil {
            context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }

        guard let context else {
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

    // MARK: - Eye-Aligned Face Cropping

    /// Extract eye center positions from face observation landmarks.
    /// Returns centers in full-image normalized coordinates (Vision bottom-left origin), or nil if both eyes aren't detected.
    private func computeEyeCenters(from observation: VNFaceObservation) -> (leftEye: CGPoint, rightEye: CGPoint)? {
        guard let landmarks = observation.landmarks,
              let leftEyeRegion = landmarks.leftEye,
              let rightEyeRegion = landmarks.rightEye else {
            return nil
        }

        let leftPoints = leftEyeRegion.normalizedPoints
        let rightPoints = rightEyeRegion.normalizedPoints
        guard !leftPoints.isEmpty, !rightPoints.isEmpty else { return nil }

        // Compute centroids of each eye's point cloud (in face-bbox-relative coords, bottom-left origin)
        let leftSum = leftPoints.reduce(.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let leftCenter = CGPoint(
            x: leftSum.x / CGFloat(leftPoints.count),
            y: leftSum.y / CGFloat(leftPoints.count)
        )
        let rightSum = rightPoints.reduce(.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let rightCenter = CGPoint(
            x: rightSum.x / CGFloat(rightPoints.count),
            y: rightSum.y / CGFloat(rightPoints.count)
        )

        // Convert from face-bbox-relative to full-image normalized coords
        let bbox = observation.boundingBox
        let leftImageNorm = CGPoint(
            x: bbox.origin.x + leftCenter.x * bbox.width,
            y: bbox.origin.y + leftCenter.y * bbox.height
        )
        let rightImageNorm = CGPoint(
            x: bbox.origin.x + rightCenter.x * bbox.width,
            y: bbox.origin.y + rightCenter.y * bbox.height
        )

        return (leftEye: leftImageNorm, rightEye: rightImageNorm)
    }

    /// Warp a face crop to the canonical ArcFace 112×112 template via a two-point (eye) similarity
    /// transform, so the bundled ArcFace model sees faces aligned the way it was trained.
    ///
    /// Robust to Vision's left/right eye naming: the image-left eye (smaller x) is anchored to the
    /// template's left-eye position and the image-right eye to the right, which guarantees an upright,
    /// non-mirrored result. Coordinates use the CG/Vision bottom-left origin convention.
    private func createArcFaceAlignedCrop(
        from cgImage: CGImage,
        leftEyePixel: CGPoint,
        rightEyePixel: CGPoint,
        outputSize: Int = 112
    ) -> CGImage? {
        let n = CGFloat(outputSize)
        let scaleToN = n / 112.0  // canonical template is defined for 112×112

        // Standard ArcFace 5-point template eye coords (top-left origin, 112×112),
        // converted to CG bottom-left (y' = 112 - y) and scaled to the output size.
        let templateLeftEye  = CGPoint(x: 38.2946 * scaleToN, y: (112.0 - 51.6963) * scaleToN)
        let templateRightEye = CGPoint(x: 73.5318 * scaleToN, y: (112.0 - 51.5014) * scaleToN)

        // Anchor by image position, not by Vision's naming, to avoid mirror/flip.
        let p0 = leftEyePixel.x <= rightEyePixel.x ? leftEyePixel : rightEyePixel   // image-left eye
        let p1 = leftEyePixel.x <= rightEyePixel.x ? rightEyePixel : leftEyePixel   // image-right eye

        let sdx = p1.x - p0.x, sdy = p1.y - p0.y
        let srcDist = sqrt(sdx * sdx + sdy * sdy)
        guard srcDist > 0 else { return nil }

        let tdx = templateRightEye.x - templateLeftEye.x
        let tdy = templateRightEye.y - templateLeftEye.y
        let dstDist = sqrt(tdx * tdx + tdy * tdy)

        let scale = dstDist / srcDist
        let rotation = atan2(tdy, tdx) - atan2(sdy, sdx)

        // T = translate(q0) · scale · rotate · translate(-p0): maps p0→q0 and p1→q1.
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: templateLeftEye.x, y: templateLeftEye.y)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.rotated(by: rotation)
        transform = transform.translatedBy(x: -p0.x, y: -p0.y)

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputSize,
            height: outputSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        return context.makeImage()
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

    /// Cosine distance (0...2) between two encoded face embeddings. Lower = more similar.
    func computeDistance(_ data1: Data, _ data2: Data) -> Float? {
        EmbeddingCodec.cosineDistance(data1, data2)
    }

    /// Cosine distance between two already-decoded embeddings (avoids re-decoding in clustering).
    func computeDistanceCached(_ v1: [Float], _ v2: [Float]) -> Float? {
        EmbeddingCodec.cosineDistance(v1, v2)
    }

}

// MARK: - VNFaceObservation Helpers

private extension CGRect {
    nonisolated var asCGRect: CGRect { self }
}
