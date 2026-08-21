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

/// Whether a number → player claim has been accepted for writing.
///
/// A detected number is only ever a *claim* that a given player is in the image —
/// a supporter in a similar shirt, an OCR misread, or the opposing team's number
/// can all produce a wrong claim. Names reach the metadata only once a claim is
/// `confirmed`. Claims auto-confirm when they corroborate an independently
/// recognised face naming the same player (two signals agree); everything else
/// waits in the review queue. `rejected` is a sticky user decision, never undone
/// by a re-resolution.
nonisolated enum NumberClaimState: String, Codable, Sendable {
    case suggested
    case confirmed
    case rejected
}

/// A jersey number detected in an image — a self-contained identity *claim*.
///
/// Number detection runs at the image level (not anchored to a detected face) so
/// that back-turned players — who show a number but no detectable face — are still
/// captured. A number whose box falls inside a detected face's estimated torso
/// region records that face in `associatedFaceID` as a *hint* only: which player a
/// number physically belongs to can't be inferred reliably from geometry (a packed
/// shot may put another player's number over a face's estimated torso), so the
/// association never silently renames a face group. It only helps suggest a card
/// and enables auto-confirmation when the face is independently identified.
nonisolated struct NumberDetection: Codable, Identifiable, Sendable {
    let id: UUID
    var imageURL: URL

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

    /// Whether the resolved claim has been accepted for writing. Optional for
    /// backwards compatibility with `face_data.json` written before the review
    /// queue existed; `nil` is treated as `.suggested`.
    var claimState: NumberClaimState?

    /// The claim state, defaulting un-set (legacy) values to `.suggested`.
    var effectiveClaimState: NumberClaimState { claimState ?? .suggested }

    init(
        id: UUID = UUID(),
        imageURL: URL,
        number: Int,
        numberConfidence: Float,
        boundingBox: CGRect,
        jerseyColorRGB: ColorRGB? = nil,
        teamSide: TeamSide? = nil,
        associatedFaceID: UUID? = nil,
        resolvedPlayerName: String? = nil,
        claimState: NumberClaimState? = nil
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
        self.claimState = claimState
    }
}
