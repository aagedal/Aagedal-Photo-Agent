import SwiftUI

struct EditFilmstripItemView: View {
    let image: ImageFile
    let thumbnailService: ThumbnailService
    let isSelected: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                // Edit badges (top right)
                if image.hasDevelopEdits || image.hasCropEdits
                    || image.cameraRawSettings?.hdrEditMode == 1
                    || image.hasPendingMetadataChanges {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if image.hasDevelopEdits || image.hasPendingMetadataChanges {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(2.5)
                                        .background(.orange, in: Circle())
                                }
                                if image.hasCropEdits {
                                    Image(systemName: "crop")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(2.5)
                                        .background(.green, in: Circle())
                                }
                                if image.cameraRawSettings?.hdrEditMode == 1 {
                                    Image(systemName: "sun.max.fill")
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(2.5)
                                        .background(.purple, in: Circle())
                                }
                            }
                            .padding(3)
                        }
                        Spacer()
                    }
                }

                // Pending metadata indicator (top left)
                if image.hasPendingMetadataChanges {
                    VStack {
                        HStack {
                            Circle()
                                .fill(.yellow)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                                .padding(3)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Rating at a glance without spending permanent vertical space beneath the
                // compact filmstrip thumbnail. Unrated images remain visually clean.
                if image.starRating != .none {
                    VStack {
                        Spacer()
                        HStack {
                            Text(image.starRating.displayString)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.yellow)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.62), in: Capsule())
                                .padding(4)
                            Spacer()
                        }
                    }
                }
            }
            .frame(width: 94, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(image.filename)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 94)
        }
        .task(id: image.url) {
            thumbnail = await thumbnailService.loadThumbnail(for: image.url)
        }
    }
}
