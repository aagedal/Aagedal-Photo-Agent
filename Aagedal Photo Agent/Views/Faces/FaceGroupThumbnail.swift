import SwiftUI

struct FaceGroupThumbnail: View {
    let group: FaceGroup
    let image: NSImage?
    var isMultiSelected: Bool = false
    var isHighlighted: Bool = false   // Drop target highlight
    var isExpanded: Bool = false      // Expanded mode sizing

    private var imageSize: CGFloat { isExpanded ? 70 : 56 }
    private var nameWidth: CGFloat { isExpanded ? 100 : 64 }
    private var fontSize: CGFloat { isExpanded ? 12 : 11 }

    private var borderColor: Color {
        if isHighlighted {
            return .green
        } else if isMultiSelected {
            return .accentColor
        } else {
            return .clear
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: imageSize, height: imageSize)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary)
                        .frame(width: imageSize, height: imageSize)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                }

                // Count badge
                if group.faceIDs.count > 1 {
                    Text("\(group.faceIDs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.secondary, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(2)
                }

                // Multi-select checkmark
                if isMultiSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.accentColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(2)
                }
            }
            .frame(width: imageSize, height: imageSize)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(borderColor, lineWidth: isHighlighted ? 3 : 2)
            )

            Text(group.name ?? "?")
                .font(.system(size: fontSize))
                .lineLimit(1)
                .frame(width: nameWidth)
                .foregroundStyle(group.name != nil ? .primary : .secondary)
        }
    }
}
