import Foundation
import ImageIO
import CryptoKit

nonisolated struct KnownPeopleUpgradeSourceInventory: Equatable, Sendable {
    let retainedCount: Int
    let retainedBytes: Int64
}

/// Optional, local-only enrollment crops. Kept outside the strict Known People managed root so
/// existing People Library packages and iCloud generations never upload them implicitly.
actor KnownPeopleUpgradeSourceStore {
    static let shared = KnownPeopleUpgradeSourceStore()

    nonisolated static func directory(for knownPeopleRoot: URL) -> URL {
        if AppPaths.isTestProcess {
            return knownPeopleRoot.deletingLastPathComponent().appendingPathComponent(
                "\(knownPeopleRoot.lastPathComponent)-UpgradeSources", isDirectory: true
            )
        }
        // Different local/cloud storage routes can retain different People Libraries. Never let
        // clearing or replacing one route erase another route's optional crops.
        let routeHash = SHA256.hash(data: Data(knownPeopleRoot.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return AppPaths.applicationSupport
            .appendingPathComponent("KnownPeopleUpgradeSources", isDirectory: true)
            .appendingPathComponent(routeHash, isDirectory: true)
    }

    nonisolated static func imageURL(for embeddingID: UUID, knownPeopleRoot: URL) -> URL {
        directory(for: knownPeopleRoot).appendingPathComponent("\(embeddingID.uuidString).jpg")
    }

    /// Only committed examples may be saved. A late setting change is checked on this serialized
    /// actor so turning retention off cannot be followed by a queued write re-creating the crops.
    func saveIfEnabled(_ sources: [UUID: Data], admittedIDs: Set<UUID>,
                       knownPeopleRoot: URL) throws -> Int {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleRetainUpgradeSources) else { return 0 }
        let root = Self.directory(for: knownPeopleRoot)
        try Self.ensureSafeDirectory(root)
        var written = 0
        for id in admittedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleRetainUpgradeSources),
                  let data = sources[id], Self.isValidUpgradeCrop(data) else { continue }
            try data.write(to: root.appendingPathComponent("\(id.uuidString).jpg"), options: .atomic)
            written += 1
        }
        return written
    }

    func remove(_ embeddingIDs: [UUID], knownPeopleRoot: URL) throws {
        let root = Self.directory(for: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try Self.requireSafeDirectory(root)
        for id in embeddingIDs {
            let url = Self.imageURL(for: id, knownPeopleRoot: knownPeopleRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// An explicit People Library replacement may remove examples without using ordinary CRUD.
    /// Only UUID-named crop files are owned by this store; unrelated files are left untouched.
    func pruneUnreferenced(admittedIDs: Set<UUID>, knownPeopleRoot: URL) throws {
        let root = Self.directory(for: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try Self.requireSafeDirectory(root)
        for url in try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            guard url.pathExtension.lowercased() == "jpg",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !admittedIDs.contains(id) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    func clear(knownPeopleRoot: URL) throws {
        try Self.clearSynchronously(knownPeopleRoot: knownPeopleRoot)
    }

    /// The opt-out setting applies to the whole Mac, not only the currently selected library.
    func clearAll(knownPeopleRoot: URL) throws {
        if AppPaths.isTestProcess {
            try Self.clearSynchronously(knownPeopleRoot: knownPeopleRoot)
            return
        }
        let parent = AppPaths.applicationSupport.appendingPathComponent(
            "KnownPeopleUpgradeSources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        try Self.requireSafeDirectory(parent)
        try FileManager.default.removeItem(at: parent)
    }

    func inventory(admittedIDs: Set<UUID>, knownPeopleRoot: URL) throws -> KnownPeopleUpgradeSourceInventory {
        let root = Self.directory(for: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return KnownPeopleUpgradeSourceInventory(retainedCount: 0, retainedBytes: 0)
        }
        try Self.requireSafeDirectory(root)
        var count = 0, bytes: Int64 = 0
        for id in admittedIDs {
            let url = Self.imageURL(for: id, knownPeopleRoot: knownPeopleRoot)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 1_000_000 else { continue }
            count += 1
            bytes += Int64(size)
        }
        return KnownPeopleUpgradeSourceInventory(retainedCount: count, retainedBytes: bytes)
    }

    func read(_ embeddingID: UUID, knownPeopleRoot: URL) throws -> Data? {
        let root = Self.directory(for: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        try Self.requireSafeDirectory(root)
        let url = Self.imageURL(for: embeddingID, knownPeopleRoot: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try Data(contentsOf: url)
        return Self.isValidUpgradeCrop(data) ? data : nil
    }

    /// Compatibility paths used by synchronous Known People deletion/reset entry points.
    nonisolated static func removeSynchronously(_ embeddingIDs: [UUID], knownPeopleRoot: URL) throws {
        let root = directory(for: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try requireSafeDirectory(root)
        for id in embeddingIDs {
            let url = imageURL(for: id, knownPeopleRoot: knownPeopleRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated static func clearSynchronously(knownPeopleRoot: URL) throws {
        let root = directory(for: knownPeopleRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try requireSafeDirectory(root)
        try FileManager.default.removeItem(at: root)
    }

    nonisolated private static func isValidUpgradeCrop(_ data: Data) -> Bool {
        guard data.count <= 1_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 320,
              properties[kCGImagePropertyPixelHeight] as? Int == 320 else { return false }
        return true
    }

    nonisolated private static func ensureSafeDirectory(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try requireSafeDirectory(root)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try requireSafeDirectory(root)
        }
    }

    nonisolated private static func requireSafeDirectory(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
