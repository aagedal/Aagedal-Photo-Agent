import Foundation

/// Cleans SAM's 256×256 logit grid before it is upsampled. Where SAM is unsure, its logits hover
/// around zero with a patch-sized texture from the image encoder, which thresholds into blotches,
/// pinholes and stray islands. Cleanup smooths that texture, keeps only the regions the user
/// clicked, and fills small enclosed holes, the same way selection tools tidy a raw segmentation.
nonisolated enum SAM2MatteCleanup {
    /// Gaussian sigma in logit cells; about one encoder patch at the 1024 px input.
    static let smoothingSigma: Float = 1
    /// Enclosed holes smaller than this fraction of the frame are filled.
    static let maximumHoleFraction = 0.01
    /// Logit magnitude written into removed islands and filled holes: enough to clear the
    /// upsampler's [-1, 1] edge band without overwriting real edges with a hard step.
    static let settledLogit: Float = 2

    static func cleaned(_ logits: [Float], points: [AIMaskPromptPoint]) -> [Float] {
        let side = SAM2LowResolutionMask.side
        guard logits.count == side * side else { return logits }
        var result = smoothed(logits, side: side)
        var inside = result.map { $0 > 0 }

        // Keep only the components under a positive click. A click whose cell ended up outside
        // the mask (SAM disagreed) keeps nothing by itself; if no click lands inside, keep all.
        let islands = components(of: inside, side: side)
        var kept = Set<Int>()
        for point in points where point.isPositive {
            let label = islands.labels[cell(point.y, side) * side + cell(point.x, side)]
            if label >= 0 { kept.insert(label) }
        }
        if !kept.isEmpty {
            for index in inside.indices where inside[index] && !kept.contains(islands.labels[index]) {
                inside[index] = false
                result[index] = min(result[index], -settledLogit)
            }
        }

        // Fill holes: background components that are small and do not touch the frame edge.
        let holes = components(of: inside.map { !$0 }, side: side)
        let maximumHole = Int(Double(side * side) * maximumHoleFraction)
        for index in inside.indices where !inside[index] {
            let label = holes.labels[index]
            if !holes.touchesEdge[label], holes.sizes[label] < maximumHole {
                result[index] = max(result[index], settledLogit)
            }
        }
        return result
    }

    private static func cell(_ coordinate: Double, _ side: Int) -> Int {
        min(max(Int(coordinate * Double(side)), 0), side - 1)
    }

    /// Separable Gaussian blur with clamped edges.
    static func smoothed(_ values: [Float], side: Int) -> [Float] {
        let radius = Int((smoothingSigma * 3).rounded(.up))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * smoothingSigma * smoothingSigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }

        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum: Float = 0
                for offset in -radius...radius {
                    sum += values[y * side + min(max(x + offset, 0), side - 1)] * kernel[offset + radius]
                }
                horizontal[y * side + x] = sum
            }
        }
        var result = [Float](repeating: 0, count: values.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum: Float = 0
                for offset in -radius...radius {
                    sum += horizontal[min(max(y + offset, 0), side - 1) * side + x] * kernel[offset + radius]
                }
                result[y * side + x] = sum
            }
        }
        return result
    }

    struct Components {
        /// Component per cell, or -1 for cells outside `mask`.
        var labels: [Int]
        var sizes: [Int]
        var touchesEdge: [Bool]
    }

    /// 4-connected components of the true cells.
    static func components(of mask: [Bool], side: Int) -> Components {
        var labels = [Int](repeating: -1, count: mask.count)
        var sizes: [Int] = []
        var touchesEdge: [Bool] = []
        var stack: [Int] = []
        for seed in mask.indices where mask[seed] && labels[seed] < 0 {
            let label = sizes.count
            var size = 0
            var edge = false
            labels[seed] = label
            stack.append(seed)
            while let index = stack.popLast() {
                size += 1
                let x = index % side
                let y = index / side
                if x == 0 || y == 0 || x == side - 1 || y == side - 1 { edge = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                    let neighbour = ny * side + nx
                    if mask[neighbour], labels[neighbour] < 0 {
                        labels[neighbour] = label
                        stack.append(neighbour)
                    }
                }
            }
            sizes.append(size)
            touchesEdge.append(edge)
        }
        return Components(labels: labels, sizes: sizes, touchesEdge: touchesEdge)
    }
}
