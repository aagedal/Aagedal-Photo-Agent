import SwiftUI
import AppKit

struct ThumbnailCell: View, Equatable {
    let image: ImageFile
    let isSelected: Bool
    let thumbnailService: ThumbnailService
    var onDelete: (() -> Void)?

    @State private var thumbnail: NSImage?

    static func == (lhs: ThumbnailCell, rhs: ThumbnailCell) -> Bool {
        lhs.image == rhs.image && lhs.isSelected == rhs.isSelected
    }

    private var pendingFieldsTooltip: String {
        if image.pendingFieldNames.isEmpty {
            return "Pending metadata changes"
        }
        return "Pending: " + image.pendingFieldNames.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Thumbnail image
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 180, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // C2PA badge (top right)
                if image.hasC2PA {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.blue, in: Circle())
                                .padding(4)
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
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                                .padding(4)
                                .help(pendingFieldsTooltip)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }

            // Color label stripe
            if let color = image.colorLabel.color {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(height: 4)
                    .frame(maxWidth: 180)
            }

            // Filename
            Text(image.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            // Star rating + color label
            HStack(spacing: 4) {
                if image.starRating != .none {
                    HStack(spacing: 1) {
                        ForEach(0..<image.starRating.rawValue, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                if let color = image.colorLabel.color {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(image.colorLabel.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(image.url.path, inFileViewerRootedAtPath: image.url.deletingLastPathComponent().path)
            }

            if let editorPath = UserDefaults.standard.string(forKey: "defaultExternalEditor"),
               !editorPath.isEmpty {
                Button("Open in External Editor") {
                    NSWorkspace.shared.open(
                        [image.url],
                        withApplicationAt: URL(fileURLWithPath: editorPath),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                }
            }

            Divider()

            Menu("Rating") {
                ForEach(StarRating.allCases, id: \.self) { rating in
                    Button(rating == .none ? "No Rating" : rating.displayString) {
                        NotificationCenter.default.post(name: .setRating, object: rating)
                    }
                }
            }

            Menu("Label") {
                ForEach(ColorLabel.allCases, id: \.self) { label in
                    Button(label.displayName) {
                        NotificationCenter.default.post(name: .setLabel, object: label)
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        .task(id: image.url) {
            thumbnail = await thumbnailService.loadThumbnail(for: image.url)
        }
    }
}
