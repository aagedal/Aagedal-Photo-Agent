import AppKit
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Image similarity sorting")
@MainActor
struct ImageSimilarityServiceTests {
    @Test("identical photos lead, unavailable files sort last in stable order")
    func identicalPhotosLead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = folder.appendingPathComponent("z-reference.png")
        let duplicate = folder.appendingPathComponent("b-duplicate.png")
        let different = folder.appendingPathComponent("a-different.png")
        try writeImage(to: reference, alternating: false)
        try FileManager.default.copyItem(at: reference, to: duplicate)
        try writeImage(to: different, alternating: true)
        let missing = folder.appendingPathComponent("c-missing.png")
        let cloud = folder.appendingPathComponent("d-cloud.png")
        let inputs = [ImageFile(url: different), ImageFile(url: duplicate), ImageFile(url: missing),
                      ImageFile(url: cloud, isICloudDownloadPending: true), ImageFile(url: reference)]
            .map(ImageSimilarityService.Input.init)
        let service = ImageSimilarityService()
        var snapshots: [ImageSimilarityService.Progress] = []
        let order = try await service.order(inputs, reference: reference) { @MainActor progress in
            snapshots.append(progress)
        }
        #expect(order == [reference, duplicate, different, missing, cloud])
        #expect(snapshots.first == .init(completed: 0, total: 4))
        #expect(snapshots.last == .init(completed: 4, total: 4))
        #expect(snapshots.allSatisfy { $0.total == 4 && $0.completed <= $0.total })
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.completed < $1.completed })
        // A second pass exercises the same cached feature prints.
        #expect(try await service.order(inputs, reference: reference) == order)
        try writeImage(to: duplicate, alternating: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                                             ofItemAtPath: duplicate.path)
        let refreshed = inputs.map { $0.url == duplicate ? ImageSimilarityService.Input(ImageFile(url: duplicate)) : $0 }
        #expect(try await service.order(refreshed, reference: reference) == [reference, different, duplicate, missing, cloud])
    }

    @Test("an unreadable reference reports a useful failure")
    func unavailableReference() async {
        let image = ImageFile(url: URL(fileURLWithPath: "/missing/reference.png"))
        await #expect(throws: ImageSimilarityService.AnalysisError.self) {
            try await ImageSimilarityService().order([.init(image)], reference: image.url)
        }
    }

    @Test("browser keeps the reference fixed, supports reverse, and cancels when leaving similarity")
    func browserIntegration() async throws {
        let defaults = AppDefaults.store
        let keys = [UserDefaultsKeys.thumbnailSortOrder, UserDefaultsKeys.thumbnailSortReversed]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("Name", forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.png")
        let reference = folder.appendingPathComponent("z.png")
        try writeImage(to: first, alternating: true)
        try writeImage(to: reference, alternating: false)
        let model = BrowserViewModel()
        model.images = [ImageFile(url: first), ImageFile(url: reference)]
        for _ in 0..<200 where model.sortedImages.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.selectedImageIDs = [reference]
        model.selectSortOrder(.similarity)
        for _ in 0..<500 {
            if model.sortedImages.first?.url == reference && !model.isSortingBySimilarity { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.sortedImages.first?.url == reference)
        #expect(model.similarityScanProgress == nil)
        model.selectedImageIDs = [first]
        #expect(model.similarityReferenceURL == reference)
        model.sortReversed = true
        for _ in 0..<200 where model.sortedImages.first?.url != first {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.sortedImages.first?.url == first)
        model.selectSortOrder(.similarity)
        #expect(model.similarityReferenceURL == first)
        model.selectSortOrder(.name)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!model.isSortingBySimilarity)
        #expect(model.similarityScanProgress == nil)
        #expect(model.similarityReferenceURL == nil)
        #expect(model.sortOrder == .name)
    }

    @Test("cancelled work never returns an order")
    func cancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImageSimilarityService().order([], reference: URL(fileURLWithPath: "/missing.png"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func writeImage(to url: URL, alternating: Bool) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<128 {
            for x in 0..<128 {
                let rgb: (UInt8, UInt8, UInt8) = alternating
                    ? ((x / 16 + y / 16).isMultiple(of: 2) ? (0, 0, 255) : (255, 255, 255))
                    : (x < 64 ? (255, 0, 0) : (0, 255, 0))
                let offset = y * bitmap.bytesPerRow + x * 3
                bitmap.bitmapData![offset] = rgb.0
                bitmap.bitmapData![offset + 1] = rgb.1
                bitmap.bitmapData![offset + 2] = rgb.2
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
