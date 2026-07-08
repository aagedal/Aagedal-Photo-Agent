import SwiftUI

/// Compact, overlapping "stack of photos" preview for a set of import files.
/// Shows five fixed-width frames sampled evenly across the set (chronologically when
/// capture times are known); hovering pops a larger row so the user can quickly see
/// what was shot. Short shoots render empty frames so every row reserves the same
/// layout space, and a top badge always shows the total photo count.
/// Only the sampled representatives are ever decoded, so it stays cheap on large sets.
struct ImportThumbnailStripView: View {
    let files: [URL]
    let captureTimes: [URL: Date]
    let thumbnailService: ThumbnailService
    var prefetchThumbnails: Bool = true
    var onPrefetchTimeout: (() -> Void)?

    @State private var isHovering = false
    @State private var finishedLoads: Set<URL> = []

    private static let visibleTileCount = 5
    private static let tileSize: CGFloat = 28
    private static let tileOverlap: CGFloat = -12
    private static let cornerRadius: CGFloat = 4
    private static let stripWidth = tileSize * CGFloat(visibleTileCount)
        + tileOverlap * CGFloat(visibleTileCount - 1)

    private var representatives: [URL] {
        ImportViewModel.representativeFiles(from: files, captureTimes: captureTimes, max: Self.visibleTileCount)
    }

    var body: some View {
        let urls = representatives
        let remaining = max(0, files.count - urls.count)
        ZStack(alignment: .topTrailing) {
            HStack(spacing: Self.tileOverlap) {
                ForEach(0..<Self.visibleTileCount, id: \.self) { index in
                    Group {
                        if index < urls.count {
                            ImportStripTile(
                                url: urls[index],
                                thumbnailService: thumbnailService,
                                onLoadFinished: { finishedLoads.insert(urls[index]) }
                            )
                            .environment(\.importStripShouldLoadThumbnail, prefetchThumbnails || isHovering)
                        } else {
                            ImportStripPlaceholderTile()
                        }
                    }
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .zIndex(Double(Self.visibleTileCount - index))
                }
            }

            if files.count > 0 {
                Text("\(files.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(.black.opacity(0.68), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                    )
                    .offset(x: 2, y: -5)
                    .zIndex(100)
            }
        }
        .frame(width: Self.stripWidth, height: Self.tileSize, alignment: .leading)
        .opacity(urls.isEmpty ? 0 : 1)
        .onHover { isHovering = $0 }
        .onAppear {
            finishedLoads = []
        }
        .onChange(of: urls) { _, _ in
            finishedLoads = []
        }
        .task(id: prefetchThumbnails ? urls : []) {
            guard prefetchThumbnails, !urls.isEmpty else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, prefetchThumbnails else { return }
            let expected = Set(urls)
            if !expected.isSubset(of: finishedLoads) {
                onPrefetchTimeout?()
            }
        }
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            ImportThumbnailStripPreview(
                urls: urls,
                captureTimes: captureTimes,
                remaining: remaining,
                totalCount: files.count,
                thumbnailService: thumbnailService
            )
        }
        .help("\(files.count) photos — hover to preview")
    }
}

/// Empty frame used to keep short shoots aligned with longer shoots.
private struct ImportStripPlaceholderTile: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            RoundedRectangle(cornerRadius: 3)
                .inset(by: 4)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
            Image(systemName: "photo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

/// A single thumbnail tile that async-loads via the shared ThumbnailService.
private struct ImportStripTile: View {
    let url: URL
    let thumbnailService: ThumbnailService
    var onLoadFinished: () -> Void = {}

    @Environment(\.importStripShouldLoadThumbnail) private var shouldLoadThumbnail
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: shouldLoadThumbnail ? url : nil) {
            guard shouldLoadThumbnail else { return }
            thumbnail = await thumbnailService.loadThumbnail(for: url)
            onLoadFinished()
        }
    }
}

private struct ImportStripShouldLoadThumbnailKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var importStripShouldLoadThumbnail: Bool {
        get { self[ImportStripShouldLoadThumbnailKey.self] }
        set { self[ImportStripShouldLoadThumbnailKey.self] = newValue }
    }
}

/// Enlarged hover preview: the same sampled thumbnails shown bigger with capture times.
/// The trailing card shows "+N more" when the strip is a subset of the full set.
private struct ImportThumbnailStripPreview: View {
    let urls: [URL]
    let captureTimes: [URL: Date]
    let remaining: Int
    let totalCount: Int
    let thumbnailService: ThumbnailService

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                    VStack(spacing: 3) {
                        ImportPreviewTile(url: url, thumbnailService: thumbnailService)
                            .frame(width: 120, height: 120)
                            .overlay {
                                if remaining > 0, index == urls.count - 1 {
                                    ZStack {
                                        Color.black.opacity(0.55)
                                        VStack(spacing: 2) {
                                            Text("+\(remaining)")
                                                .font(.title3.weight(.bold))
                                            Text("more")
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(.white)
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(timeLabel(for: url))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if remaining > 0 {
                Text("Showing \(urls.count) of \(totalCount) photos, evenly spread")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    private func timeLabel(for url: URL) -> String {
        guard let date = captureTimes[url] else { return " " }
        return Self.timeFormatter.string(from: date)
    }
}

/// Larger thumbnail tile for the hover preview.
private struct ImportPreviewTile: View {
    let url: URL
    let thumbnailService: ThumbnailService

    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) {
            thumbnail = await thumbnailService.loadThumbnail(for: url)
        }
    }
}
