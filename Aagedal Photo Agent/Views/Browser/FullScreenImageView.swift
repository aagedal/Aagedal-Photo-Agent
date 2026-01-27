import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

nonisolated private let imageLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "ImageLoading")

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
    @State private var isLoading = false
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
            }

            if isLoading {
                VStack {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.5)
                            .tint(.white)
                            .padding(12)
                        Spacer()
                    }
                    Spacer()
                }
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
        let filename = currentImageFile?.url.lastPathComponent ?? "nil"
        imageLogger.info("loadImage called for \(filename)")

        // Cancel any in-flight full-resolution decode from the previous image
        if fullLoadTask != nil {
            imageLogger.info("Cancelling previous full-resolution load")
        }
        fullLoadTask?.cancel()
        fullLoadTask = nil

        guard let url = currentImageFile?.url else {
            currentImage = nil
            isLoading = false
            return
        }

        isLoading = true

        let isRAW = isRAWFile(url)
        imageLogger.info("\(filename): isRAW=\(isRAW)")

        // Phase 1: For RAW files, instantly show the embedded JPEG preview
        if isRAW {
            let previewStart = CFAbsoluteTimeGetCurrent()
            let preview = await Task.detached(priority: .userInitiated) {
                Self.extractEmbeddedPreview(from: url)
            }.value
            let previewElapsed = CFAbsoluteTimeGetCurrent() - previewStart
            if let preview {
                imageLogger.info("\(filename): Phase 1 preview loaded in \(String(format: "%.1f", previewElapsed * 1000))ms (\(preview.size.width)×\(preview.size.height))")
                currentImage = preview
            } else {
                imageLogger.warning("\(filename): Phase 1 no embedded preview found (\(String(format: "%.1f", previewElapsed * 1000))ms)")
            }
        }

        // Phase 2: Load screen-resolution image without blocking navigation.
        // We eagerly downsample via CGImageSource so the rendering pipeline doesn't
        // have to push 50MP through the main thread.
        let fullStart = CFAbsoluteTimeGetCurrent()
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenMaxPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160) * screenScale
        imageLogger.info("\(filename): Phase 2 starting (target \(Int(screenMaxPx))px)")
        fullLoadTask = Task.detached(priority: .userInitiated) {
            let image = Self.loadDownsampled(from: url, maxPixelSize: screenMaxPx)
            let fullElapsed = CFAbsoluteTimeGetCurrent() - fullStart
            guard !Task.isCancelled else {
                imageLogger.info("\(filename): Phase 2 cancelled after \(String(format: "%.1f", fullElapsed * 1000))ms")
                return
            }
            await MainActor.run {
                if currentImageFile?.url == url {
                    let w = image?.size.width ?? 0
                    let h = image?.size.height ?? 0
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms (\(w)×\(h))")
                    currentImage = image
                    isLoading = false
                } else {
                    imageLogger.info("\(filename): Phase 2 done in \(String(format: "%.1f", fullElapsed * 1000))ms but image changed, discarding")
                }
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

    /// Load an image suitable for full-screen display.
    /// For oversized images (e.g. 50MP RAW), eagerly downsample to screen resolution
    /// so SwiftUI doesn't have to decode the full bitmap on the main thread.
    /// For images already at or near screen size, use NSImage directly (faster).
    nonisolated private static func loadDownsampled(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Check source dimensions to decide whether downsampling is worthwhile
        let needsDownsample: Bool
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            let longest = max(pw, ph)
            // Only downsample if the image is significantly larger than the target
            needsDownsample = CGFloat(longest) > maxPixelSize * 1.5
        } else {
            needsDownsample = true
        }

        if needsDownsample {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return NSImage(contentsOf: url)
    }

    nonisolated private static func extractEmbeddedPreview(from url: URL) -> NSImage? {
        let filename = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            imageLogger.warning("\(filename): CGImageSourceCreateWithURL failed")
            return nil
        }

        let imageCount = CGImageSourceGetCount(source)
        let sourceType = CGImageSourceGetType(source) as String? ?? "unknown"
        imageLogger.info("\(filename): CGImageSource type=\(sourceType), imageCount=\(imageCount)")

        // First try to get the embedded JPEG thumbnail (fastest)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            imageLogger.info("\(filename): Got embedded thumbnail \(cgThumb.width)×\(cgThumb.height)")
            return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        } else {
            imageLogger.info("\(filename): No embedded thumbnail at index 0")
        }

        // Fallback: check for additional images in the source (many RAW formats
        // store a full-size JPEG as a secondary image)
        if imageCount > 1 {
            for i in 1..<imageCount {
                if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] {
                    let w = props[kCGImagePropertyPixelWidth].map { "\($0)" } ?? "?"
                    let h = props[kCGImagePropertyPixelHeight].map { "\($0)" } ?? "?"
                    imageLogger.info("\(filename): Image at index \(i): \(w)×\(h)")
                }
            }
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 1, nil) {
                imageLogger.info("\(filename): Using secondary image \(cgImage.width)×\(cgImage.height)")
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        imageLogger.warning("\(filename): No preview found")
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
