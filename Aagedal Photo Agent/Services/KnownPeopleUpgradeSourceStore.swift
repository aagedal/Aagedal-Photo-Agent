import Foundation
import ImageIO
import CryptoKit

nonisolated struct KnownPeopleUpgradeSourceInventory: Equatable, Sendable {
    let retainedCount: Int
    let retainedBytes: Int64
}

/// Optional enrollment crops. Kept outside the strict Known People managed root; package
/// exports declare each crop explicitly, and an enabled iCloud route uses a coordinated sibling.
actor KnownPeopleUpgradeSourceStore {
    static let shared = KnownPeopleUpgradeSourceStore()

    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.known-people.upgrade-sources", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    nonisolated static func cloudDirectory(for knownPeopleRoot: URL) -> URL? {
        var cursor = knownPeopleRoot.standardizedFileURL
        while cursor.path != "/" {
            if cursor.lastPathComponent == "KnownPeople",
               cursor.deletingLastPathComponent().lastPathComponent == "Documents",
               cursor.path.contains(AppPaths.iCloudContainerID) {
                return cursor.deletingLastPathComponent().appendingPathComponent(
                    "KnownPeopleUpgradeSources", isDirectory: true)
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated static func directory(for knownPeopleRoot: URL) -> URL {
        if AppPaths.isTestProcess {
            return knownPeopleRoot.deletingLastPathComponent().appendingPathComponent(
                "\(knownPeopleRoot.lastPathComponent)-UpgradeSources", isDirectory: true
            )
        }
        if let cloud = cloudDirectory(for: knownPeopleRoot) { return cloud }
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
        if Self.cloudDirectory(for: knownPeopleRoot) != nil,
           !KnownPeoplePrivacyLifecycle.hasConfirmedICloudTransfer() { return 0 }
        let root = Self.directory(for: knownPeopleRoot)
        try Self.ensureSafeDirectory(root)
        var written = 0
        for id in admittedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleRetainUpgradeSources),
                  let data = sources[id], Self.isValidUpgradeCrop(data) else { continue }
            let url = root.appendingPathComponent("\(id.uuidString).jpg")
            if Self.cloudDirectory(for: knownPeopleRoot) != nil {
                try CloudCoordinatedIO.writeData(data, to: url)
            } else {
                try data.write(to: url, options: .atomic)
            }
            written += 1
        }
        return written
    }

    func remove(_ embeddingIDs: [UUID], knownPeopleRoot: URL) throws {
        let root = Self.directory(for: knownPeopleRoot)
        guard Self.itemExists(root, knownPeopleRoot: knownPeopleRoot) else { return }
        try Self.requireSafeDirectory(root)
        for id in embeddingIDs {
            let url = Self.imageURL(for: id, knownPeopleRoot: knownPeopleRoot)
            if Self.itemExists(url, knownPeopleRoot: knownPeopleRoot) {
                if Self.cloudDirectory(for: knownPeopleRoot) != nil {
                    try CloudCoordinatedIO.removeItem(at: url)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// An explicit People Library replacement may remove examples without using ordinary CRUD.
    /// Only UUID-named crop files are owned by this store; unrelated files are left untouched.
    func pruneUnreferenced(admittedIDs: Set<UUID>, knownPeopleRoot: URL) throws {
        let root = Self.directory(for: knownPeopleRoot)
        guard Self.itemExists(root, knownPeopleRoot: knownPeopleRoot) else { return }
        try Self.requireSafeDirectory(root)
        let entries = Self.cloudDirectory(for: knownPeopleRoot) != nil
            ? try CloudCoordinatedIO.contentsOfDirectory(at: root)
            : try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for url in entries {
            guard url.pathExtension.lowercased() == "jpg",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !admittedIDs.contains(id) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if Self.cloudDirectory(for: knownPeopleRoot) != nil {
                try CloudCoordinatedIO.removeItem(at: url)
            } else {
                try FileManager.default.removeItem(at: url)
            }
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
        let documents = AppPaths.iCloudDocuments
        if documents == nil,
           UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleICloudEnabled) {
            throw CocoaError(.fileNoSuchFile)
        }
        let parent = AppPaths.applicationSupport.appendingPathComponent(
            "KnownPeopleUpgradeSources", isDirectory: true)
        if FileManager.default.fileExists(atPath: parent.path) {
            try Self.requireSafeDirectory(parent)
            try FileManager.default.removeItem(at: parent)
        }
        if let documents {
            let cloud = documents.appendingPathComponent("KnownPeopleUpgradeSources", isDirectory: true)
            if CloudCoordinatedIO.itemExists(at: cloud) {
                try Self.requireSafeDirectory(cloud)
                try CloudCoordinatedIO.removeItem(at: cloud)
            }
        }
    }

    func inventory(admittedIDs: Set<UUID>, knownPeopleRoot: URL) throws -> KnownPeopleUpgradeSourceInventory {
        let root = Self.directory(for: knownPeopleRoot)
        let packageRoot = knownPeopleRoot.appendingPathComponent(
            ".admitted-package/upgrade_sources", isDirectory: true)
        let hasRoot = Self.itemExists(root, knownPeopleRoot: knownPeopleRoot)
        let hasPackage = FileManager.default.fileExists(atPath: packageRoot.path)
        guard hasRoot || hasPackage else {
            return KnownPeopleUpgradeSourceInventory(retainedCount: 0, retainedBytes: 0)
        }
        if hasRoot { try Self.requireSafeDirectory(root) }
        if hasPackage { try Self.requireSafeDirectory(packageRoot) }
        var count = 0, bytes: Int64 = 0
        for id in admittedIDs {
            let direct = Self.imageURL(for: id, knownPeopleRoot: knownPeopleRoot)
            let url = hasRoot && Self.itemExists(direct, knownPeopleRoot: knownPeopleRoot)
                ? direct : packageRoot.appendingPathComponent("\(id.uuidString.lowercased()).jpg")
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
        if !Self.itemExists(root, knownPeopleRoot: knownPeopleRoot) {
            return try Self.readAdmittedPackage(embeddingID, knownPeopleRoot: knownPeopleRoot)
        }
        try Self.requireSafeDirectory(root)
        let url = Self.imageURL(for: embeddingID, knownPeopleRoot: knownPeopleRoot)
        guard Self.itemExists(url, knownPeopleRoot: knownPeopleRoot) else {
            return try Self.readAdmittedPackage(embeddingID, knownPeopleRoot: knownPeopleRoot)
        }
        let data: Data
        if Self.cloudDirectory(for: knownPeopleRoot) != nil {
            data = try CloudCoordinatedIO.readData(at: url)
        } else {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadNoPermission)
            }
            data = try Data(contentsOf: url)
        }
        return Self.isValidUpgradeCrop(data) ? data : nil
    }

    nonisolated private static func readAdmittedPackage(_ embeddingID: UUID,
        knownPeopleRoot: URL) throws -> Data? {
        let directory = knownPeopleRoot.appendingPathComponent(
            ".admitted-package/upgrade_sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try requireSafeDirectory(directory)
        let url = directory.appendingPathComponent("\(embeddingID.uuidString.lowercased()).jpg")
        guard cloudDirectory(for: knownPeopleRoot) != nil
            ? CloudCoordinatedIO.itemExists(at: url)
            : FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = cloudDirectory(for: knownPeopleRoot) != nil
            ? try CloudCoordinatedIO.readData(at: url) : try Data(contentsOf: url)
        return isValidUpgradeCrop(data) ? data : nil
    }


    func snapshot(admittedIDs: Set<UUID>, knownPeopleRoot: URL) throws -> [UUID: Data] {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.knownPeopleRetainUpgradeSources) else { return [:] }
        var sources: [UUID: Data] = [:]
        for id in admittedIDs {
            if let data = try read(id, knownPeopleRoot: knownPeopleRoot) { sources[id] = data }
        }
        return sources
    }

    /// Compatibility paths used by synchronous Known People deletion/reset entry points.
    nonisolated static func removeSynchronously(_ embeddingIDs: [UUID], knownPeopleRoot: URL) throws {
        let root = directory(for: knownPeopleRoot)
        guard itemExists(root, knownPeopleRoot: knownPeopleRoot) else { return }
        try requireSafeDirectory(root)
        for id in embeddingIDs {
            let url = imageURL(for: id, knownPeopleRoot: knownPeopleRoot)
            if itemExists(url, knownPeopleRoot: knownPeopleRoot) {
                if cloudDirectory(for: knownPeopleRoot) != nil {
                    try CloudCoordinatedIO.removeItem(at: url)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    nonisolated static func clearSynchronously(knownPeopleRoot: URL) throws {
        let root = directory(for: knownPeopleRoot)
        guard itemExists(root, knownPeopleRoot: knownPeopleRoot) else { return }
        try requireSafeDirectory(root)
        if cloudDirectory(for: knownPeopleRoot) != nil {
            try CloudCoordinatedIO.removeItem(at: root)
        } else {
            try FileManager.default.removeItem(at: root)
        }
    }

    nonisolated static func isValidUpgradeCrop(_ data: Data) -> Bool {
        guard data.count <= 1_000_000,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == 320,
              properties[kCGImagePropertyPixelHeight] as? Int == 320,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) != nil else { return false }
        return true
    }

    nonisolated private static func ensureSafeDirectory(_ root: URL) throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try requireSafeDirectory(root)
        } else {
            if root.path.contains(AppPaths.iCloudContainerID) {
                try CloudCoordinatedIO.ensureDirectory(root)
            } else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            try requireSafeDirectory(root)
        }
    }

    nonisolated private static func itemExists(_ url: URL, knownPeopleRoot: URL) -> Bool {
        cloudDirectory(for: knownPeopleRoot) != nil
            ? CloudCoordinatedIO.itemExists(at: url)
            : FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated private static func requireSafeDirectory(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
