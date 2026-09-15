import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Aagedal_Photo_Agent

@Suite("Known People optional upgrade sources", .serialized)
struct KnownPeopleUpgradeSourceStoreTests {
    private func cropJPEG() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 320, height: 320,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func optInIsRequiredAndRemovalKeepsTheManagedGallery() async throws {
        let key = UserDefaultsKeys.knownPeopleRetainUpgradeSources
        let oldValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldValue { UserDefaults.standard.set(oldValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UpgradeSourcesTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? KnownPeopleUpgradeSourceStore.clearSynchronously(knownPeopleRoot: root)
            try? FileManager.default.removeItem(at: root)
        }
        let store = KnownPeopleUpgradeSourceStore()
        let id = UUID(), excluded = UUID()
        let data = try cropJPEG()
        let imageURL = KnownPeopleUpgradeSourceStore.imageURL(for: id, knownPeopleRoot: root)
        #expect(imageURL.path != root.appendingPathComponent("upgrade_sources/\(id.uuidString).jpg").path)

        UserDefaults.standard.set(false, forKey: key)
        #expect(try await store.saveIfEnabled([id: data], admittedIDs: [id],
            knownPeopleRoot: root) == 0)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))

        UserDefaults.standard.set(true, forKey: key)
        #expect(try await store.saveIfEnabled([id: data, excluded: data], admittedIDs: [id],
            knownPeopleRoot: root) == 1)
        #expect(try Data(contentsOf: imageURL) == data)
        #expect(try await store.read(id, knownPeopleRoot: root) == data)
        #expect(try await store.inventory(admittedIDs: [id, excluded],
            knownPeopleRoot: root) == KnownPeopleUpgradeSourceInventory(
                retainedCount: 1, retainedBytes: Int64(data.count)))
        #expect(!FileManager.default.fileExists(atPath:
            KnownPeopleUpgradeSourceStore.imageURL(for: excluded, knownPeopleRoot: root).path))

        try await store.remove([id], knownPeopleRoot: root)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(FileManager.default.fileExists(atPath: root.path))

        _ = try await store.saveIfEnabled([id: data], admittedIDs: [id], knownPeopleRoot: root)
        UserDefaults.standard.set(false, forKey: key)
        try await store.clear(knownPeopleRoot: root)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
        #expect(try await store.read(id, knownPeopleRoot: root) == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func replacementPrunesOnlyUnreferencedOwnedCrops() async throws {
        let key = UserDefaultsKeys.knownPeopleRetainUpgradeSources
        let oldValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldValue { UserDefaults.standard.set(oldValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UpgradePruneTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? KnownPeopleUpgradeSourceStore.clearSynchronously(knownPeopleRoot: root)
            try? FileManager.default.removeItem(at: root)
        }
        let store = KnownPeopleUpgradeSourceStore()
        let retained = UUID(), removed = UUID()
        let data = try cropJPEG()
        UserDefaults.standard.set(true, forKey: key)
        _ = try await store.saveIfEnabled([retained: data, removed: data],
            admittedIDs: [retained, removed], knownPeopleRoot: root)
        try await store.pruneUnreferenced(admittedIDs: [retained], knownPeopleRoot: root)
        #expect(try await store.read(retained, knownPeopleRoot: root) == data)
        #expect(try await store.read(removed, knownPeopleRoot: root) == nil)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func clearingOneStorageRouteKeepsAnotherRoutesCrops() async throws {
        let key = UserDefaultsKeys.knownPeopleRetainUpgradeSources
        let oldValue = UserDefaults.standard.object(forKey: key)
        defer {
            if let oldValue { UserDefaults.standard.set(oldValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UpgradeRoutesTest-\(UUID().uuidString)", isDirectory: true)
        let first = parent.appendingPathComponent("first", isDirectory: true)
        let second = parent.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer {
            try? KnownPeopleUpgradeSourceStore.clearSynchronously(knownPeopleRoot: first)
            try? KnownPeopleUpgradeSourceStore.clearSynchronously(knownPeopleRoot: second)
            try? FileManager.default.removeItem(at: parent)
        }
        let store = KnownPeopleUpgradeSourceStore()
        let id = UUID(), data = try cropJPEG()
        UserDefaults.standard.set(true, forKey: key)
        _ = try await store.saveIfEnabled([id: data], admittedIDs: [id], knownPeopleRoot: first)
        _ = try await store.saveIfEnabled([id: data], admittedIDs: [id], knownPeopleRoot: second)
        try await store.clear(knownPeopleRoot: first)
        #expect(try await store.read(id, knownPeopleRoot: first) == nil)
        #expect(try await store.read(id, knownPeopleRoot: second) == data)
    }
}
