import SwiftUI

/// Compact, overlapping "stack of photos" preview for a set of import files.
/// Shows up to ~8 thumbnails sampled evenly across the set (chronologically when
/// capture times are known); hovering pops a larger row so the user can quickly see
/// what was shot. When the set has more photos than are shown, the last card carries a
/// "+N" badge so it's clear the preview is a representative subset, not the whole set.
/// Only the sampled representatives are ever decoded, so it stays cheap on large sets.
struct ImportThumbnailStripView: View {
    let files: [URL]
    let captureTimes: [URL: Date]
    let thumbnailService: ThumbnailService
    var prefetchThumbnails: Bool = true
    var onPrefetchTimeout: (() -> Void)?

    @State private var isHovering = false
    @State private var finishedLoads: Set<URL> = []

    private var representatives: [URL] {
        ImportViewModel.representativeFiles(from: files, captureTimes: captureTimes, max: 8)
    }

    var body: some View {
        let urls = representatives
        let remaining = max(0, files.count - urls.count)
        HStack(spacing: -12) {
            ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                ImportStripTile(
                    url: url,
                    thumbnailService: thumbnailService,
                    onLoadFinished: { finishedLoads.insert(url) }
                )
                    .environment(\.importStripShouldLoadThumbnail, prefetchThumbnails || isHovering)
                    .frame(width: 28, height: 28)
                    .overlay {
                        // Mark the last visible card with the count of hidden photos.
                        if remaining > 0, index == urls.count - 1 {
                            ZStack {
                                Color.black.opacity(0.55)
                                Text("+\(remaining)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)
                                    .padding(.horizontal, 1)
                            }
                        }
                    }
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
