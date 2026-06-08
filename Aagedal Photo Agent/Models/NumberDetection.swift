import Foundation
import CoreGraphics

/// A simple sRGB colour (components 0...1), used for sampled jersey colours and
/// configured team kit colours. Kept as a plain value type so it can be `Codable`
/// and cross actor boundaries during scanning.
nonisolated struct ColorRGB: Codable, Sendable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A jersey number detected in an image, independent of any face.
///
/// Number detection runs at the image level (not anchored to a detected face) so
/// that back-turned players — who show a number but no detectable face — are still
/// captured. When a number's box falls inside a detected face's estimated torso
/// region it is *attached* to that face (`associatedFaceID != nil`) and the same
/// values are also stamped onto the `DetectedFace`. Numbers with no containing
/// face stay standalone (`associatedFaceID == nil`) and are written to metadata
/// directly during the apply step.
nonisolated struct NumberDetection: Codable, Identifiable, Sendable {
    let id: UUID
    let imageURL: URL

    /// The recognised jersey number (0...99).
    var number: Int

    /// Vision OCR confidence for the recognised string (0...1).
    var numberConfidence: Float

    /// Normalised bounding box of the number (Vision coordinates, origin bottom-left).
    var boundingBox: CGRect

    /// Dominant jersey colour sampled near the number's box, used for team clustering.
    var jerseyColorRGB: ColorRGB?

    /// Team assignment, filled in after colour clustering. `nil` until resolved.
    var teamSide: TeamSide?

    /// The detected face this number was attached to, or `nil` for a standalone
    /// (back-turned) detection.
    var associatedFaceID: UUID?

    /// The roster player name this detection resolved to, or `nil` if unresolved.
    var resolvedPlayerName: String?

    init(
        id: UUID = UUID(),
        imageURL: URL,
        number: Int,
        numberConfidence: Float,
        boundingBox: CGRect,
        jerseyColorRGB: ColorRGB? = nil,
        teamSide: TeamSide? = nil,
        associatedFaceID: UUID? = nil,
        resolvedPlayerName: String? = nil
    ) {
        self.id = id
        self.imageURL = imageURL
        self.number = number
        self.numberConfidence = numberConfidence
        self.boundingBox = boundingBox
        self.jerseyColorRGB = jerseyColorRGB
        self.teamSide = teamSide
        self.associatedFaceID = associatedFaceID
        self.resolvedPlayerName = resolvedPlayerName
    }
}
