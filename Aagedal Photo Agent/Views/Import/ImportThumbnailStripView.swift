import SwiftUI

/// Compact, overlapping "stack of photos" preview for a single import date group.
/// Shows up to ~8 thumbnails sampled evenly across the shooting day; hovering pops a
/// larger row so the user can quickly see what was shot that day. Only the sampled
/// representatives are ever decoded, so it stays cheap even for very large days.
struct ImportThumbnailStripView: View {
    let group: ImportDateGroup
    let thumbnailService: ThumbnailService

    @State private var isHovering = false

    private var representatives: [URL] {
        ImportViewModel.representativeFiles(from: group, max: 8)
    }

    var body: some View {
        let urls = representatives
        HStack(spacing: -12) {
            ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                ImportStripTile(url: url, thumbnailService: thumbnailService)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .zIndex(Double(urls.count - index))
            }
        }
        .opacity(urls.isEmpty ? 0 : 1)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            ImportThumbnailStripPreview(group: group, urls: urls, thumbnailService: thumbnailService)
        }
        .help("\(group.files.count) photos — hover to preview")
    }
}

/// A single thumbnail tile that async-loads via the shared ThumbnailService.
private struct ImportStripTile: View {
    let url: URL
    let thumbnailService: ThumbnailService

    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            }
        }
        .task(id: url) {
            thumbnail = await thumbnailService.loadThumbnail(for: url)
        }
    }
}

/// Enlarged hover preview: the same sampled thumbnails shown bigger with capture times.
private struct ImportThumbnailStripPreview: View {
    let group: ImportDateGroup
    let urls: [URL]
    let thumbnailService: ThumbnailService

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(urls, id: \.self) { url in
                VStack(spacing: 3) {
                    ImportStripTile(url: url, thumbnailService: thumbnailService)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(timeLabel(for: url))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func timeLabel(for url: URL) -> String {
        guard let date = group.captureTimes[url] else { return "—" }
        return Self.timeFormatter.string(from: date)
    }
}
