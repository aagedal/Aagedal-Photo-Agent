import CoreGraphics
import Foundation

/// Caption's edited-preview decodes: a small LRU of rendered previews, at most one decode at a
/// time, and directional prefetch of the next photos.
///
/// Before this, every Caption navigation started an independent 3,840 px decode (often a full
/// CIRAWFilter decode for RAW files) with no cache, and rapid navigation ran several decodes in
/// parallel while superseded ones ran to completion. Requests are now sized to the preview
/// pane, decodes run strictly one after another, a request whose photo left the
/// navigation window is cancelled before it starts, and returning to a recently shown photo
/// is served from memory.
@MainActor
final class CaptionPreviewPipeline {
    /// Everything that determines the rendered pixels. File size and modification date come
    /// from the browser model, so a changed file misses without a stat on the main actor.
    struct Request: Hashable, Sendable {
        let url: URL
        let orientation: Int
        let renderToken: String?
        let fileSize: Int64?
        let fileModified: Date?
        let maxPixelSize: CGFloat

        /// Whether `other` renders the same photo, orientation and edits (at any size).
        func rendersSameVariant(as other: Request) -> Bool { variant == other.variant }

        /// The same rendering at any size.
        fileprivate var variant: Variant {
            Variant(url: url, orientation: orientation, renderToken: renderToken,
                    fileSize: fileSize, fileModified: fileModified)
        }
    }

    fileprivate struct Variant: Hashable {
        let url: URL
        let orientation: Int
        let renderToken: String?
        let fileSize: Int64?
        let fileModified: Date?
    }

    typealias Decoder = @Sendable (URL, CameraRawSettings?, Int, CGFloat) async -> CGImage?

    /// Longest-edge sizes previews are decoded at. Rounding the pane's backing size up to a
    /// bucket keeps window resizes and neighbouring photos hitting the same cache entries.
    nonisolated static let pixelBuckets: [CGFloat] = [1_024, 1_536, 2_048, 2_560, 3_072, 3_840]
    /// The 100% view shows one image pixel per point, as before.
    nonisolated static let actualSizePixels: CGFloat = 3_840

    nonisolated static func pixelBucket(forLongestBackingPixels pixels: CGFloat) -> CGFloat {
        pixelBuckets.first { $0 >= pixels } ?? pixelBuckets[pixelBuckets.count - 1]
    }

    private struct Entry {
        let request: Request
        let image: CGImage
        let cost: Int
        var lastUse: UInt64
    }

    private let decoder: Decoder
    private let countLimit: Int
    private let costLimit: Int
    private var entries: [Request: Entry] = [:]
    private var clock: UInt64 = 0
    private struct InFlight {
        let task: Task<CGImage?, Never>
        let waiterID: UInt64
    }
    private var inFlight: [Request: InFlight] = [:]

    /// The single decode slot. The current photo's request (foreground lane) is granted the slot
    /// before any queued prefetch; within a lane requests run in submission order.
    private enum Lane: Int, Comparable {
        case foreground = 0
        case prefetch = 1
        static func < (lhs: Lane, rhs: Lane) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    private struct Waiter {
        let id: UInt64
        var lane: Lane
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []
    private var waiterLanes: [UInt64: Lane] = [:]
    private var isDecoding = false
    private var nextWaiterID: UInt64 = 0

    init(countLimit: Int = 5, costLimit: Int = 320 * 1_024 * 1_024,
         decoder: @escaping Decoder = { url, settings, orientation, maxPixelSize in
             await FullScreenImageCache.decodedEditedPreview(
                 for: url, settings: settings, orientation: orientation, screenMaxPx: maxPixelSize)
         }) {
        self.countLimit = max(1, countLimit)
        self.costLimit = max(1, costLimit)
        self.decoder = decoder
    }

    /// A cached rendering of the same variant at least as large as requested.
    func cachedImage(for request: Request) -> CGImage? {
        let variant = request.variant
        guard let match = entries.values
            .filter({ $0.request.variant == variant && $0.request.maxPixelSize >= request.maxPixelSize })
            .min(by: { $0.request.maxPixelSize < $1.request.maxPixelSize }) else { return nil }
        clock &+= 1
        entries[match.request]?.lastUse = clock
        return match.image
    }

    /// Returns the cached preview or joins/queues its decode. Cancelling the caller does not
    /// cancel a decode other callers may share; `retain(only:)` cancels decodes that left the
    /// navigation window.
    func image(for request: Request, settings: CameraRawSettings?) async -> CGImage? {
        if let cached = cachedImage(for: request) { return cached }
        // A different size of the same rendering (the pane bucket changed) is superseded.
        cancel { $0.rendersSameVariant(as: request) && $0.maxPixelSize != request.maxPixelSize }
        let task = enqueue(request, settings: settings, lane: .foreground)
        return await task.value
    }

    /// Queues a decode for a photo the user is likely to open next, behind the current photo.
    func prefetch(_ request: Request, settings: CameraRawSettings?) {
        guard cachedImage(for: request) == nil else { return }
        _ = enqueue(request, settings: settings, lane: .prefetch)
    }

    /// Cancels queued or running decodes for photos outside `urls`, and (when given) decodes at
    /// another size. A cancelled decode that has not started never touches the decoder.
    func retain(only urls: Set<URL>, maxPixelSize: CGFloat? = nil) {
        cancel { request in
            !urls.contains(request.url) || (maxPixelSize.map { request.maxPixelSize != $0 } ?? false)
        }
    }

    /// Drops every cached rendering and cancels pending decodes, for example when the global
    /// RAW decode profile or the watermark library changes what an edited render looks like.
    func removeAll() {
        cancel { _ in true }
        entries.removeAll()
    }

    private func cancel(where shouldCancel: (Request) -> Bool) {
        for (request, flight) in inFlight where shouldCancel(request) {
            flight.task.cancel()
            inFlight[request] = nil
        }
    }

    private func enqueue(_ request: Request, settings: CameraRawSettings?, lane: Lane) -> Task<CGImage?, Never> {
        if let existing = inFlight[request] {
            if lane == .foreground { promote(existing.waiterID) }
            return existing.task
        }
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        waiterLanes[waiterID] = lane
        let decoder = decoder
        let task = Task<CGImage?, Never> { [weak self] in
            // One decode at a time, and the cancellation check happens before starting, so
            // superseded requests never start an expensive RAW decode.
            guard let self, await self.acquireSlot(waiterID) else { return nil }
            guard !Task.isCancelled else {
                self.releaseSlot()
                return nil
            }
            let image = await decoder(request.url, settings, request.orientation, request.maxPixelSize)
            self.releaseSlot()
            return Task.isCancelled ? nil : image
        }
        inFlight[request] = InFlight(task: task, waiterID: waiterID)
        Task { [weak self] in
            let image = await task.value
            self?.finish(request, task: task, image: image)
        }
        return task
    }

    /// Waits for the decode slot. Returns false when the waiting task was cancelled first.
    private func acquireSlot(_ id: UInt64) async -> Bool {
        let lane = waiterLanes.removeValue(forKey: id) ?? .prefetch
        if !isDecoding {
            isDecoding = true
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, lane: lane, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    private func releaseSlot() {
        guard let next = waiters.indices.min(by: { (waiters[$0].lane, $0) < (waiters[$1].lane, $1) }) else {
            isDecoding = false
            return
        }
        // The slot passes directly to the next waiter.
        waiters.remove(at: next).continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// The user navigated to a photo whose prefetch is still queued: serve it next.
    private func promote(_ id: UInt64) {
        if waiterLanes[id] != nil { waiterLanes[id] = .foreground }
        if let index = waiters.firstIndex(where: { $0.id == id }) { waiters[index].lane = .foreground }
    }

    private func finish(_ request: Request, task: Task<CGImage?, Never>, image: CGImage?) {
        guard !task.isCancelled else { return }
        if inFlight[request]?.task == task { inFlight[request] = nil }
        guard let image else { return }
        clock &+= 1
        entries[request] = Entry(request: request, image: image,
                                 cost: image.bytesPerRow * image.height, lastUse: clock)
        // Smaller renderings of the same variant are superseded by this one.
        for other in entries.values where other.request != request
            && other.request.variant == request.variant
            && other.request.maxPixelSize < request.maxPixelSize {
            entries[other.request] = nil
        }
        evict()
    }

    private func evict() {
        var total = entries.values.reduce(0) { $0 + $1.cost }
        while entries.count > countLimit || (total > costLimit && entries.count > 1),
              let oldest = entries.values.min(by: { $0.lastUse < $1.lastUse }) {
            entries[oldest.request] = nil
            total -= oldest.cost
        }
    }
}
