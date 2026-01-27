import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Custom NSWindow that intercepts Escape and Space

private class FullScreenWindow: NSWindow {
    var onDismiss: (() -> Void)?
    var onSetRating: ((Int) -> Void)?
    var onSetLabel: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags
        let hasCmd = flags.contains(.command)
        let hasOption = flags.contains(.option)

        // Escape or Space → dismiss
        if keyCode == 53 || keyCode == 49 {
            onDismiss?()
            return
        }

        let numberKeyCodes: [Int: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6]

        if hasCmd && hasOption {
            // CMD+Option+0 through CMD+Option+6 → set color label
            if let index = numberKeyCodes[keyCode], index <= 6 {
                onSetLabel?(index)
                return
            }
        } else if hasCmd {
            // CMD+0 through CMD+5 → set rating
            if let rating = numberKeyCodes[keyCode], rating <= 5 {
                onSetRating?(rating)
                return
            }
        }

        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

// MARK: - SwiftUI View

struct FullScreenImageView: View {
    @Bindable var viewModel: BrowserViewModel
    @State private var currentImage: NSImage?
    @State private var fullLoadTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private var currentImageFile: ImageFile? {
        viewModel.firstSelectedImage
    }

    var body: some View {
        ZStack {
            Color.black

            if let currentImage {
                Image(nsImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .tint(.white)
            }

            if let file = currentImageFile {
                // Bottom-left: star rating + color label
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        starRatingOverlay(for: file)
                        colorLabelOverlay(for: file)
                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 20)
                }

                // Bottom-center: filename
                VStack {
                    Spacer()
                    Text(file.filename)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 16)
                }
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.leftArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.selectNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.selectPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.selectNext()
            return .handled
        }
        .task(id: currentImageFile?.url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        // Cancel any in-flight full-resolution decode from the previous image
        fullLoadTask?.cancel()
        fullLoadTask = nil

        guard let url = currentImageFile?.url else {
            currentImage = nil
            return
        }

        // Phase 1: For RAW files, instantly show the embedded JPEG preview
        if isRAWFile(url) {
            if let preview = Self.extractEmbeddedPreview(from: url) {
                currentImage = preview
            } else {
                currentImage = nil
            }
        } else {
            currentImage = nil
        }

        // Phase 2: Load full-resolution image without blocking navigation.
        // This is an unstructured Task so it doesn't block the .task(id:) modifier;
        // we cancel it explicitly at the top of this function on each navigation.
        fullLoadTask = Task {
            let image = await Task.detached {
                NSImage(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            if currentImageFile?.url == url {
                currentImage = image
            }
        }
    }

    private func isRAWFile(_ url: URL) -> Bool {
        let rawExtensions: Set<String> = [
            "raw", "cr2", "cr3", "nef", "nrw", "arw", "raf",
            "dng", "rw2", "orf", "pef", "srw"
        ]
        return rawExtensions.contains(url.pathExtension.lowercased())
    }

    private static func extractEmbeddedPreview(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // First try to get the embedded JPEG thumbnail (fastest)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        }

        // Fallback: check for additional images in the source (many RAW formats
        // store a full-size JPEG as a secondary image)
        let imageCount = CGImageSourceGetCount(source)
        if imageCount > 1, let cgImage = CGImageSourceCreateImageAtIndex(source, 1, nil) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return nil
    }

    private func colorLabelOverlay(for file: ImageFile) -> some View {
        Menu {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button {
                    viewModel.setLabel(label)
                } label: {
                    HStack {
                        if let c = label.color {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(c)
                        }
                        Text(label.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let color = file.colorLabel.color {
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                    Text(file.colorLabel.displayName)
                        .font(.caption)
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                        .frame(width: 12, height: 12)
                    Text("Label")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func starRatingOverlay(for file: ImageFile) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= file.starRating.rawValue ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(star <= file.starRating.rawValue ? .yellow : .white.opacity(0.5))
                    .onTapGesture {
                        let newRating: StarRating = star == file.starRating.rawValue
                            ? .none
                            : StarRating(rawValue: star) ?? .none
                        viewModel.setRating(newRating)
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

// MARK: - Presenter (ViewModifier)

struct FullScreenPresenter: ViewModifier {
    @Bindable var viewModel: BrowserViewModel
    @State private var fullScreenWindow: FullScreenWindow?

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.isFullScreen) { _, newValue in
                if newValue {
                    openFullScreen()
                } else {
                    closeFullScreen()
                }
            }
    }

    private func openFullScreen() {
        guard fullScreenWindow == nil,
              let screen = NSScreen.main else { return }

        let window = FullScreenWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .mainMenu + 1
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .ignoresCycle]
        window.hasShadow = false
        window.onDismiss = { [weak viewModel] in
            viewModel?.isFullScreen = false
        }
        window.onSetRating = { [weak viewModel] ratingValue in
            guard let rating = StarRating(rawValue: ratingValue) else { return }
            viewModel?.setRating(rating)
        }
        window.onSetLabel = { [weak viewModel] index in
            guard let label = ColorLabel.fromShortcutIndex(index) else { return }
            viewModel?.setLabel(label)
        }

        let hostingView = NSHostingView(
            rootView: FullScreenImageView(viewModel: viewModel)
        )
        window.contentView = hostingView
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        fullScreenWindow = window
    }

    private func closeFullScreen() {
        fullScreenWindow?.orderOut(nil)
        fullScreenWindow = nil
    }
}

extension View {
    func fullScreenImagePresenter(viewModel: BrowserViewModel) -> some View {
        modifier(FullScreenPresenter(viewModel: viewModel))
    }
}
