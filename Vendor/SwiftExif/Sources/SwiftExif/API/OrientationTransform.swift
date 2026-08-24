import Foundation

/// Operations that can be applied to EXIF orientation without touching pixel data.
public enum OrientationOperation: Sendable, CaseIterable {
    case rotateClockwise
    case rotateCounterClockwise
    case flipHorizontal
    case flipVertical
}

/// Composes EXIF orientation values with lossless transform operations.
///
/// EXIF orientation values 1-8 encode combinations of rotation and mirroring.
/// This utility maps (current orientation, operation) → new orientation value.
public struct OrientationTransform: Sendable {

    // Lookup table: [operation][currentOrientation - 1] → newOrientation
    // Orientations are 1-indexed (1-8), array is 0-indexed.
    // Derived from D4 group composition: new = operation ∘ current
    private static let table: [[UInt16]] = [
        // RotateCW:   1→6, 2→7, 3→8, 4→5, 5→2, 6→3, 7→4, 8→1
        [6, 7, 8, 5, 2, 3, 4, 1],
        // RotateCCW:  1→8, 2→5, 3→6, 4→7, 5→4, 6→1, 7→2, 8→3
        [8, 5, 6, 7, 4, 1, 2, 3],
        // FlipH:      1→2, 2→1, 3→4, 4→3, 5→6, 6→5, 7→8, 8→7
        [2, 1, 4, 3, 6, 5, 8, 7],
        // FlipV:      1→4, 2→3, 3→2, 4→1, 5→8, 6→7, 7→6, 8→5
        [4, 3, 2, 1, 8, 7, 6, 5],
    ]

    /// Compose a current EXIF orientation with an operation to produce a new orientation.
    /// - Parameters:
    ///   - current: Current EXIF orientation value (1-8). Values outside this range default to 1.
    ///   - operation: The lossless transform to apply.
    /// - Returns: The resulting EXIF orientation value (1-8).
    public static func compose(current: UInt16, operation: OrientationOperation) -> UInt16 {
        let clamped = (current >= 1 && current <= 8) ? current : 1
        let row: Int
        switch operation {
        case .rotateClockwise:        row = 0
        case .rotateCounterClockwise: row = 1
        case .flipHorizontal:         row = 2
        case .flipVertical:           row = 3
        }
        return table[row][Int(clamped) - 1]
    }
}
