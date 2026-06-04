import SwiftUI

/// Editor sheet for splitting one capture-date group into multiple shoots.
///
/// Two modes:
/// - **Split by time** (default): photos are shown chronologically; large time gaps
///   are pre-marked as suggested shoot boundaries. Click a photo to toggle whether it
///   starts a new shoot. Produces contiguous segments via `onSplit(boundaries:)`.
/// - **Select & move**: click to multi-select arbitrary photos and move them into a
///   new shoot via `onMove(fileURLs:)` — for the rare interleaved case.
struct ImportSplitEditorView: View {
    let group: ImportDateGroup
    let thumbnailService: ThumbnailService
    let onSplit: ([Int]) -> Void
    let onMove: (Set<URL>) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case byTime = "Split by time"
        case select = "Select & move"
        var id: String { rawValue }
    }

    private let ordered: [URL]
    private let gapThreshold: TimeInterval

    @State private var mode: Mode = .byTime
    /// Chronological indices (> 0) that start a new shoot.
    @State private var boundaries: Set<Int>
    /// Chronological indices selected for "move to new shoot".
    @State private var selection: Set<Int> = []

    init(
        group: ImportDateGroup,
        thumbnailService: ThumbnailService,
        onSplit: @escaping ([Int]) -> Void,
        onMove: @escaping (Set<URL>) -> Void
    ) {
        self.group = group
        self.thumbnailService = thumbnailService
        self.onSplit = onSplit
        self.onMove = onMove
        self.ordered = group.chronologicalFiles
        let threshold = ImportViewModel.defaultShootGapThreshold
        self.gapThreshold = threshold
        let suggested = ImportViewModel.suggestedSplitBoundaries(for: group, gapThreshold: threshold)
        self._boundaries = State(initialValue: Set(suggested))
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(ordered.enumerated()), id: \.element) { index, url in
                        cell(index: index, url: url)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split “\(group.folderName)”")
                .font(.headline)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(mode == .byTime
                 ? "Photos are in capture order. Click a photo to mark it as the start of a new shoot. Large time gaps are suggested for you."
                 : "Click photos to select them, then move them into a new shoot.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: - Cell

    @ViewBuilder
    private func cell(index: Int, url: URL) -> some View {
        let isBoundary = mode == .byTime && boundaries.contains(index)
        let isSelected = mode == .select && selection.contains(index)
        let segment = segmentIndex(for: index)

        VStack(spacing: 3) {
            ImportSplitCellThumb(url: url, thumbnailService: thumbnailService)
                .frame(height: 78)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if isBoundary {
                        Image(systemName: "scissors")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.accentColor, in: Circle())
                            .padding(3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let gap = gapLabel(at: index) {
                        Text(gap)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.orange, in: Capsule())
                            .padding(3)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? Color.accentColor
                                : (isBoundary ? Color.accentColor.opacity(0.7) : Color.clear),
                            lineWidth: isSelected ? 3 : 2
                        )
                }

            Text(timeLabel(for: url))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(mode == .byTime ? segmentTint(segment) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle(index: index) }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center) {
            if mode == .byTime {
                Text(resultSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(selection.isEmpty
                     ? "No photos selected"
                     : "\(selection.count) photo\(selection.count == 1 ? "" : "s") selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if mode == .byTime {
                Button("Split into \(boundaries.count + 1) Shoots") {
                    onSplit(boundaries.sorted())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(boundaries.isEmpty)
            } else {
                Button("Move to New Shoot") {
                    let moved = Set(selection.compactMap { ordered.indices.contains($0) ? ordered[$0] : nil })
                    onMove(moved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || selection.count >= ordered.count)
            }
        }
        .padding(16)
    }

    // MARK: - Interaction

    private func toggle(index: Int) {
        switch mode {
        case .byTime:
            guard index > 0 else { return } // index 0 always starts the first shoot
            if boundaries.contains(index) { boundaries.remove(index) } else { boundaries.insert(index) }
        case .select:
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        }
    }

    // MARK: - Derived

    /// Zero-based shoot segment that `index` belongs to.
    private func segmentIndex(for index: Int) -> Int {
        boundaries.reduce(0) { $0 + ($1 <= index ? 1 : 0) }
    }

    private func segmentTint(_ segment: Int) -> Color {
        segment.isMultiple(of: 2) ? Color.accentColor.opacity(0.08) : Color.accentColor.opacity(0.16)
    }

    private var resultSummary: String {
        let count = boundaries.count + 1
        if count == 1 { return "No split — click photos where a new shoot begins." }
        return "Will create \(count) shoots: \(resultNames.joined(separator: ", "))"
    }

    private var resultNames: [String] {
        (0..<(boundaries.count + 1)).map { i in
            i == 0 ? group.folderName : "\(group.folderName) – Shoot \(i + 1)"
        }
    }

    private func gapLabel(at index: Int) -> String? {
        guard index > 0,
              let prev = group.captureTimes[ordered[index - 1]],
              let cur = group.captureTimes[ordered[index]] else { return nil }
        let gap = cur.timeIntervalSince(prev)
        guard gap > gapThreshold else { return nil }
        return Self.formatGap(gap)
    }

    private func timeLabel(for url: URL) -> String {
        guard let date = group.captureTimes[url] else { return "—" }
        return Self.timeFormatter.string(from: date)
    }

    private static func formatGap(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m gap" : "\(hours)h gap" }
        return "\(minutes)m gap"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Lazily-loaded thumbnail for a split-editor grid cell.
private struct ImportSplitCellThumb: View {
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
        .task(id: url) {
            thumbnail = await thumbnailService.loadThumbnail(for: url)
        }
    }
}
