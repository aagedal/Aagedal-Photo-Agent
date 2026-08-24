import Foundation

/// A 3-dimensional k-d tree for nearest-neighbor lookup over ECEF-converted points.
/// Used internally by `ReverseGeocoder` for efficient spatial search.
struct KDTree: Sendable {
    private let nodes: [Node]
    private let points: [ECEF]
    private let rootIndex: Int32

    struct ECEF: Sendable {
        let x: Float
        let y: Float
        let z: Float
        let index: Int32  // index into the original city array
    }

    private struct Node: Sendable {
        let pointIndex: Int32    // index into points array
        let left: Int32          // -1 = no child
        let right: Int32         // -1 = no child
        let splitAxis: UInt8     // 0=x, 1=y, 2=z
    }

    /// Build a k-d tree from ECEF points.
    init(points: [ECEF]) {
        self.points = points
        var nodes: [Node] = []
        nodes.reserveCapacity(points.count)
        var indices = Array(0..<Int32(points.count))
        let root = Self.buildNode(indices: &indices, range: 0..<indices.count,
                                  depth: 0, points: points, nodes: &nodes)
        self.nodes = nodes
        self.rootIndex = root
    }

    /// Find the nearest point to a query.
    func nearest(to query: ECEF) -> (point: ECEF, distanceSquared: Float)? {
        guard !nodes.isEmpty else { return nil }
        var bestIndex: Int32 = -1
        var bestDist: Float = .infinity
        searchNearest(nodeIndex: rootIndex, query: query, bestIndex: &bestIndex, bestDist: &bestDist)
        guard bestIndex >= 0 else { return nil }
        return (points[Int(bestIndex)], bestDist)
    }

    /// Find the k nearest points to a query.
    func nearestK(_ k: Int, to query: ECEF) -> [(point: ECEF, distanceSquared: Float)] {
        guard !nodes.isEmpty, k > 0 else { return [] }
        var heap = BoundedMaxHeap(capacity: k)
        searchNearestK(nodeIndex: rootIndex, query: query, heap: &heap)
        return heap.sorted().map { (points[Int($0.index)], $0.distance) }
    }

    // MARK: - Build

    private static func buildNode(
        indices: inout [Int32], range: Range<Int>, depth: Int,
        points: [ECEF], nodes: inout [Node]
    ) -> Int32 {
        guard !range.isEmpty else { return -1 }
        let axis = UInt8(depth % 3)

        // Sort the range by the split axis
        let subrange = indices[range]
        var sorted = Array(subrange)
        sorted.sort { a, b in
            axisValue(points[Int(a)], axis: axis) < axisValue(points[Int(b)], axis: axis)
        }
        for (i, val) in sorted.enumerated() {
            indices[range.lowerBound + i] = val
        }

        let median = range.lowerBound + sorted.count / 2
        let nodeIdx = Int32(nodes.count)
        // Placeholder — will be filled after children are built
        nodes.append(Node(pointIndex: indices[median], left: -1, right: -1, splitAxis: axis))

        let leftIdx = buildNode(indices: &indices, range: range.lowerBound..<median,
                                depth: depth + 1, points: points, nodes: &nodes)
        let rightIdx = buildNode(indices: &indices, range: (median + 1)..<range.upperBound,
                                 depth: depth + 1, points: points, nodes: &nodes)

        nodes[Int(nodeIdx)] = Node(pointIndex: indices[median], left: leftIdx,
                                    right: rightIdx, splitAxis: axis)
        return nodeIdx
    }

    // MARK: - Search

    private func searchNearest(nodeIndex: Int32, query: ECEF, bestIndex: inout Int32, bestDist: inout Float) {
        guard nodeIndex >= 0 else { return }
        let node = nodes[Int(nodeIndex)]
        let point = points[Int(node.pointIndex)]

        let dist = squaredDistance(query, point)
        if dist < bestDist {
            bestDist = dist
            bestIndex = node.pointIndex
        }

        let axis = node.splitAxis
        let diff = axisValue(query, axis: axis) - axisValue(point, axis: axis)
        let diffSq = diff * diff

        let first: Int32
        let second: Int32
        if diff < 0 {
            first = node.left
            second = node.right
        } else {
            first = node.right
            second = node.left
        }

        searchNearest(nodeIndex: first, query: query, bestIndex: &bestIndex, bestDist: &bestDist)
        if diffSq < bestDist {
            searchNearest(nodeIndex: second, query: query, bestIndex: &bestIndex, bestDist: &bestDist)
        }
    }

    private func searchNearestK(nodeIndex: Int32, query: ECEF, heap: inout BoundedMaxHeap) {
        guard nodeIndex >= 0 else { return }
        let node = nodes[Int(nodeIndex)]
        let point = points[Int(node.pointIndex)]

        let dist = squaredDistance(query, point)
        heap.insert(index: node.pointIndex, distance: dist)

        let axis = node.splitAxis
        let diff = axisValue(query, axis: axis) - axisValue(point, axis: axis)
        let diffSq = diff * diff

        let first: Int32
        let second: Int32
        if diff < 0 {
            first = node.left
            second = node.right
        } else {
            first = node.right
            second = node.left
        }

        searchNearestK(nodeIndex: first, query: query, heap: &heap)
        if diffSq < heap.worstDistance {
            searchNearestK(nodeIndex: second, query: query, heap: &heap)
        }
    }

    // MARK: - Helpers

    private func squaredDistance(_ a: ECEF, _ b: ECEF) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return dx * dx + dy * dy + dz * dz
    }

    private static func axisValue(_ p: ECEF, axis: UInt8) -> Float {
        switch axis {
        case 0: return p.x
        case 1: return p.y
        default: return p.z
        }
    }

    private func axisValue(_ p: ECEF, axis: UInt8) -> Float {
        Self.axisValue(p, axis: axis)
    }
}

// MARK: - ECEF Conversion

extension KDTree.ECEF {
    static let earthRadiusKm: Float = 6371.0

    /// Convert latitude/longitude (degrees) to ECEF Cartesian coordinates.
    static func fromLatLon(latitude: Float, longitude: Float, index: Int32) -> KDTree.ECEF {
        let latRad = latitude * .pi / 180.0
        let lonRad = longitude * .pi / 180.0
        let cosLat = cos(latRad)
        return KDTree.ECEF(
            x: earthRadiusKm * cosLat * cos(lonRad),
            y: earthRadiusKm * cosLat * sin(lonRad),
            z: earthRadiusKm * sin(latRad),
            index: index
        )
    }
}

// MARK: - Bounded Max-Heap for K-Nearest

private struct BoundedMaxHeap {
    struct Entry: Comparable {
        let index: Int32
        let distance: Float
        static func < (lhs: Entry, rhs: Entry) -> Bool { lhs.distance < rhs.distance }
    }

    private var entries: [Entry] = []
    let capacity: Int

    var worstDistance: Float {
        entries.count < capacity ? .infinity : (entries.first?.distance ?? .infinity)
    }

    init(capacity: Int) {
        self.capacity = capacity
        entries.reserveCapacity(capacity + 1)
    }

    mutating func insert(index: Int32, distance: Float) {
        if entries.count < capacity {
            entries.append(Entry(index: index, distance: distance))
            siftUp(entries.count - 1)
        } else if distance < entries[0].distance {
            entries[0] = Entry(index: index, distance: distance)
            siftDown(0)
        }
    }

    func sorted() -> [Entry] {
        entries.sorted()
    }

    private mutating func siftUp(_ idx: Int) {
        var i = idx
        while i > 0 {
            let parent = (i - 1) / 2
            if entries[i].distance > entries[parent].distance {
                entries.swapAt(i, parent)
                i = parent
            } else { break }
        }
    }

    private mutating func siftDown(_ idx: Int) {
        var i = idx
        let count = entries.count
        while true {
            var largest = i
            let left = 2 * i + 1
            let right = 2 * i + 2
            if left < count && entries[left].distance > entries[largest].distance { largest = left }
            if right < count && entries[right].distance > entries[largest].distance { largest = right }
            if largest == i { break }
            entries.swapAt(i, largest)
            i = largest
        }
    }
}
