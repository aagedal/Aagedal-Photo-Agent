import SwiftUI

struct StarRatingFilterBar: View {
    @Binding var minimumRating: StarRating

    private let starFrameWidth: CGFloat = 18
    private let starSpacing: CGFloat = 1
    private let totalSlots = 6 // 0 (clear) + 1-5 stars

    var body: some View {
        HStack(spacing: starSpacing) {
            Image(systemName: "star.slash")
                .font(.system(size: 14))
                .frame(width: starFrameWidth)
                .foregroundStyle(.secondary.opacity(minimumRating == .none ? 1.0 : 0.5))
                .help("Clear star filter")

            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= minimumRating.rawValue ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .frame(width: starFrameWidth)
                    .foregroundStyle(star <= minimumRating.rawValue ? .yellow : .secondary.opacity(0.5))
                    .help("\(star) stars & up")
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "starBar")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("starBar"))
                .onChanged { value in
                    let rating = ratingAt(x: value.location.x)
                    if rating != minimumRating {
                        minimumRating = rating
                    }
                }
        )
    }

    private func ratingAt(x: CGFloat) -> StarRating {
        let itemWidth = starFrameWidth + starSpacing
        let index = Int(x / itemWidth)
        guard index >= 0, index < totalSlots else {
            return index < 0 ? .none : .five
        }
        return StarRating(rawValue: index) ?? .none
    }
}
