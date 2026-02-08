import SwiftUI
import AppKit

struct ThumbnailCell: View, Equatable {
    let image: ImageFile
    let isSelected: Bool
    let thumbnailService: ThumbnailService
    var onDelete: (() -> Void)?
    var onAddToSubfolder: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onOpenInExternalEditor: (() -> Void)?
    var onCopyFilePaths: (() -> Void)?

    @State private var thumbnail: NSImage?
    private let thumbnailSize = CGSize(width: 180, height: 140)

    static func == (lhs: ThumbnailCell, rhs: ThumbnailCell) -> Bool {
        lhs.image.url == rhs.image.url
            && lhs.isSelected == rhs.isSelected
            && lhs.image.starRating == rhs.image.starRating
            && lhs.image.colorLabel == rhs.image.colorLabel
            && lhs.image.hasC2PA == rhs.image.hasC2PA
            && lhs.image.hasDevelopEdits == rhs.image.hasDevelopEdits
            && lhs.image.hasCropEdits == rhs.image.hasCropEdits
            && lhs.image.cropRegion == rhs.image.cropRegion
            && lhs.image.hasPendingMetadataChanges == rhs.image.hasPendingMetadataChanges
            && lhs.image.pendingFieldNames == rhs.image.pendingFieldNames
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
                .overlay {
                    if image.hasCropEdits,
                       let crop = image.cropRegion,
                       let thumbnail {
                        CropThumbnailOverlay(
                            crop: crop,
                            imageSize: thumbnail.size,
                            containerSize: thumbnailSize
                        )
                    }
                }

                // C2PA / edited / crop badges (top right)
                if image.hasC2PA || image.hasDevelopEdits || image.hasCropEdits || image.hasPendingMetadataChanges {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                if image.hasC2PA {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(.blue, in: Circle())
                                }
                                if image.hasDevelopEdits || image.hasPendingMetadataChanges {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(.orange, in: Circle())
                                        .help("Image has edits")
                                }
                                if image.hasCropEdits {
                                    Image(systemName: "crop")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(.green, in: Circle())
                                        .help("Image is cropped")
                                }
                            }
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
                if let onRevealInFinder {
                    onRevealInFinder()
                } else {
                    NSWorkspace.shared.selectFile(image.url.path, inFileViewerRootedAtPath: image.url.deletingLastPathComponent().path)
                }
            }

            if let editorPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultExternalEditor),
               !editorPath.isEmpty {
                Button("Open in External Editor") {
                    if let onOpenInExternalEditor {
                        onOpenInExternalEditor()
                    } else {
                        NSWorkspace.shared.open(
                            [image.url],
                            withApplicationAt: URL(fileURLWithPath: editorPath),
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
            }

            Button("Copy File Path(s)") {
                if let onCopyFilePaths {
                    onCopyFilePaths()
                } else {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(image.url.path, forType: .string)
                }
            }

            Divider()

            if let onAddToSubfolder {
                Button("Add to Subfolder...") {
                    onAddToSubfolder()
                }
                Divider()
            }

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

private struct CropThumbnailOverlay: View {
    let crop: ThumbnailCropRegion
    let imageSize: CGSize
    let containerSize: CGSize

    var body: some View {
        let fitted = fittedImageRect(in: containerSize, imageSize: imageSize)
        let clamped = crop.clamped
        let aabbW = max(1, (clamped.right - clamped.left) * fitted.width)
        let aabbH = max(1, (clamped.bottom - clamped.top) * fitted.height)
        let cx = fitted.minX + ((clamped.left + clamped.right) * 0.5 * fitted.width)
        let cy = fitted.minY + ((clamped.top + clamped.bottom) * 0.5 * fitted.height)

        // Project diagonal onto rotated axes to get actual crop dimensions
        let radians = clamped.angle * Double.pi / 180.0
        let cosA = cos(radians)
        let sinA = sin(radians)
        let w = max(1, abs(aabbW * cosA + aabbH * sinA))
        let h = max(1, abs(-aabbW * sinA + aabbH * cosA))

        ZStack {
            Rectangle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 1)
                .frame(width: w, height: h)
                .rotationEffect(.degrees(clamped.angle))
                .position(x: cx, y: cy)

            Rectangle()
                .strokeBorder(.black.opacity(0.65), lineWidth: 0.5)
                .frame(width: w, height: h)
                .rotationEffect(.degrees(clamped.angle))
                .position(x: cx, y: cy)
        }
    }

    private func fittedImageRect(in containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard containerSize.width > 0,
              containerSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (containerSize.width - width) * 0.5
        let y = (containerSize.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
