import SwiftUI

struct FaceGroupThumbnail: View {
    let group: FaceGroup
    let image: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary)
                        .frame(width: 56, height: 56)
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
            }
            .frame(width: 56, height: 56)

            Text(group.name ?? "?")
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: 64)
                .foregroundStyle(group.name != nil ? .primary : .secondary)
        }
    }
}
