import AppKit
import Observation

@MainActor
@Observable
final class ComparisonWorkspaceModel {
    enum LoadState: Equatable {
        case idle
        case identifyingSources
        case loadingPreviews
        case ready
        case failed(String)
    }

    struct PaneImage: @unchecked Sendable {
        let cgImage: CGImage
        let isHDR: Bool
    }

    private(set) var session: ComparisonSession?
    private(set) var loadState: LoadState = .idle
    private(set) var paneImages: [ComparisonPane: PaneImage] = [:]
    private(set) var sourceFiles: [ComparisonPane: ImageFile] = [:]

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    deinit {
        loadTask?.cancel()
    }

    func open(left: ImageFile, right: ImageFile) {
        loadTask?.cancel()
        session = nil
        paneImages = [:]
        sourceFiles = [.left: left, .right: right]
        loadState = .identifyingSources

        loadTask = Task { [weak self] in
            do {
                async let leftRevision = Self.captureRevision(for: left)
                async let rightRevision = Self.captureRevision(for: right)
                let revisions = try await (leftRevision, rightRevision)
                try Task.checkCancellation()

                guard let self,
                      self.sourceFiles[.left]?.url == left.url,
                      self.sourceFiles[.right]?.url == right.url else { return }

                self.session = ComparisonSession(
                    origin: .browser,
                    leftSource: ComparisonSource(
                        revision: revisions.0,
                        representation: Self.representation(for: left)
                    ),
                    rightSource: ComparisonSource(
                        revision: revisions.1,
                        representation: Self.representation(for: right)
                    )
                )
                self.loadState = .loadingPreviews

                async let leftImage = Self.loadPreview(for: left)
                async let rightImage = Self.loadPreview(for: right)
                let images = await (leftImage, rightImage)
                try Task.checkCancellation()

                guard self.sourceFiles[.left]?.url == left.url,
                      self.sourceFiles[.right]?.url == right.url else { return }

                if let leftImage = images.0 {
                    self.paneImages[.left] = leftImage
                }
                if let rightImage = images.1 {
                    self.paneImages[.right] = rightImage
                }

                guard images.0 != nil || images.1 != nil else {
                    self.loadState = .failed("Neither image could be decoded for comparison.")
                    return
                }
                self.loadState = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.sourceFiles[.left]?.url == left.url,
                      self.sourceFiles[.right]?.url == right.url else { return }
                self.loadState = .failed(
                    error.localizedDescription.isEmpty
                        ? "The comparison sources could not be identified."
                        : error.localizedDescription
                )
            }
        }
    }

    func retry() {
        guard let left = sourceFiles[.left], let right = sourceFiles[.right] else { return }
        open(left: left, right: right)
    }

    func close() {
        loadTask?.cancel()
        loadTask = nil
        session = nil
        paneImages = [:]
        sourceFiles = [:]
        loadState = .idle
    }

    func setLayout(_ layout: ComparisonLayout) {
        guard var session else { return }
        session.layout = layout
        self.session = session
    }

    func focus(_ pane: ComparisonPane) {
        guard var session else { return }
        session.focusedPane = pane
        self.session = session
    }

    private nonisolated static func captureRevision(for image: ImageFile) async throws -> SourceImageRevision {
        let pixelSize = FullScreenImageCache.nativePixelSize(of: image.url)
        return try await SourceImageRevision.capture(
            at: image.url,
            pixelWidth: pixelSize.map { Int($0.width) },
            pixelHeight: pixelSize.map { Int($0.height) },
            exifOrientation: image.exifOrientation
        )
    }

    private nonisolated static func representation(for image: ImageFile) -> ComparisonSource.Representation {
        image.hasDevelopEdits || image.hasCropEdits ? .committedEdit : .original
    }

    private nonisolated static func loadPreview(for image: ImageFile) async -> PaneImage? {
        let maxPixelSize: CGFloat = 4_096
        if (image.hasDevelopEdits || image.hasCropEdits), let settings = image.cameraRawSettings,
           let rendered = await FullScreenImageCache.decodedEditedPreview(
               for: image.url,
               settings: settings,
               orientation: image.exifOrientation,
               screenMaxPx: maxPixelSize
           ) {
            return PaneImage(
                cgImage: rendered,
                isHDR: image.isNativeHDR || settings.hdrEditMode == 1
            )
        }

        guard let decoded = await FullScreenImageCache.loadDownsampledOffPool(
            from: image.url,
            maxPixelSize: maxPixelSize
        ) else { return nil }
        return PaneImage(cgImage: decoded, isHDR: image.isNativeHDR)
    }
}
