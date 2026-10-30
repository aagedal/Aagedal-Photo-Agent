import SwiftUI

struct EditFilmstripItemView: View {
    let image: ImageFile
    let thumbnailService: ThumbnailService
    let isSelected: Bool

    @State private var thumbnail: NSImage?
    @State private var thumbnailURL: URL?

    /// Re-render when the image or its Develop settings change, like the browser grid.
    private struct ThumbnailRequest: Equatable {
        let url: URL
        let settings: CameraRawSettings?
    }

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
        .task(id: ThumbnailRequest(url: image.url, settings: image.cameraRawSettings)) {
            let url = image.url
            let orientation = image.exifOrientation
            guard let settings = image.cameraRawSettings, !settings.isEmpty else {
                let original = await thumbnailService.loadThumbnail(for: url)
                guard !Task.isCancelled else { return }
                thumbnail = original
                thumbnailURL = url
                return
            }
            // Show the original first only when nothing for this image is on screen yet; a
            // settings change keeps the previous render until the edited one replaces it.
            if thumbnailURL != url || thumbnail == nil {
                let original = await thumbnailService.loadThumbnail(for: url)
                guard !Task.isCancelled else { return }
                thumbnail = original
                thumbnailURL = url
            }
            let edited = await thumbnailService.renderEditedThumbnail(
                for: url, settings: settings, exifOrientation: orientation
            )
            guard !Task.isCancelled, let edited else { return }
            thumbnail = edited
        }
    }
}

/// The Develop workspace's commands for filmstrip items. A reference the workspace refreshes on
/// each evaluation, so `EditFilmstripView` holds no closures: SwiftUI then sees its inputs as
/// unchanged and skips re-evaluating the whole strip when only the preview or a slider changed.
@MainActor
final class EditFilmstripActions {
    var select: (URL, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var copySettings: (ImageFile) -> Void = { _ in }
    var pasteSettings: (URL) -> Void = { _ in }
    var compare: (ImageFile) -> Void = { _ in }
    var applySettingsToSelection: (ImageFile) -> Void = { _ in }
}

/// The Develop filmstrip. Its own view so the folder-wide `ForEach` depends only on what the
/// strip shows (visible photos, selection, copied settings) and isn't rebuilt with every
/// re-evaluation of the Develop workspace, such as each slider step.
struct EditFilmstripView: View {
    let browserViewModel: BrowserViewModel
    let workspaceInput: DevelopWorkspaceInputCoordinator
    let actions: EditFilmstripActions
    let selectedImageURL: URL?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(browserViewModel.visibleImages) { image in
                        let isSelected = browserViewModel.selectedImageIDs.contains(image.url)
                        EditFilmstripItemView(
                            image: image,
                            thumbnailService: browserViewModel.thumbnailService,
                            isSelected: isSelected
                        )
                        .id(image.url)
                        .onTapGesture {
                            actions.select(image.url, NSEvent.modifierFlags)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(image.url.lastPathComponent)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction {
                            actions.select(image.url, [])
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                workspaceInput.hoveredFilmstripURL = image.url
                            case .ended:
                                if workspaceInput.hoveredFilmstripURL == image.url {
                                    workspaceInput.hoveredFilmstripURL = nil
                                }
                            }
                        }
                        .contextMenu {
                            Button("Copy Settings", systemImage: "doc.on.doc") {
                                actions.copySettings(image)
                            }

                            Button("Paste Settings", systemImage: "doc.on.clipboard") {
                                actions.pasteSettings(image.url)
                            }
                            .disabled(browserViewModel.copiedCameraRawSettings == nil)

                            if image.url != selectedImageURL {
                                Divider()
                                Button("Compare with Current Image", systemImage: "rectangle.split.2x1") {
                                    actions.compare(image)
                                }

                                Button("Copy Settings to Current Selection", systemImage: "paintbrush") {
                                    actions.applySettingsToSelection(image)
                                }
                                .disabled(browserViewModel.selectedImageIDs.isEmpty)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: workspaceInput.filmstripKeyboardScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    // No anchor means SwiftUI moves only as far as necessary to reveal the item.
                    proxy.scrollTo(target)
                }
            }
            .onAppear {
                // Defer until the lazy stack has completed its first layout. Otherwise a
                // selection far into the folder can be highlighted while remaining outside
                // the filmstrip's initial visible range.
                DispatchQueue.main.async {
                    guard let target = selectedImageURL else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .frame(height: 120)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
