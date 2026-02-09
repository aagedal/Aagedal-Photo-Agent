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
            thumbnail = await thumbnailService.loadThumbnail(for: image.url, cameraRawSettings: image.cameraRawSettings)
        }
    }
}
