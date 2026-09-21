import CoreFoundation
import CryptoKit
import Darwin
import Foundation

nonisolated enum MCPTemplateDiscoveryError: LocalizedError {
    case customFolderRequired, localStorageUnavailable, staleBookmark, invalidInventory, inventoryChanged, limitExceeded

    var errorDescription: String? {
        switch self {
        case .customFolderRequired:
            "Template discovery requires iCloud template sync to be disabled. Authorize the active local Templates folder for local automation."
        case .localStorageUnavailable:
            "The default local Templates location is unavailable. Configure a custom Templates folder and authorize it for local automation."
        case .staleBookmark:
            "The custom Templates folder bookmark is stale or unavailable. Choose the folder again in Settings."
        case .invalidInventory:
            "The template inventory contains an unreadable, unsupported, unsafe, or ambiguous document. Resolve it in Photo Agent before retrying."
        case .inventoryChanged:
            "The template folder or its contents changed during discovery. Retry after it is stable."
        case .limitExceeded:
            "The template inventory exceeds the bounded discovery limits."
        }
    }
}

/// The helper deliberately does not use AppPaths: that resolver creates directories,
/// falls back to private storage, and reads the helper's own defaults domain.
nonisolated struct MCPTemplateDiscovery: Sendable {
    struct Scope: Sendable {
        let directory: URL
        let release: @Sendable () -> Void
        var routing: Routing? = nil
    }

    enum Routing: Equatable, Sendable {
        case localDefault
        case custom(Data)
    }

    let authorizationStore: MCPAuthorizationStore
    var resolveScope: @Sendable () throws -> Scope = Self.configuredScope
    var checkpoint: @Sendable () -> Void = {}

    static func configuredScope() throws -> Scope {
        let domain = MCPServerConstants.preferencesSuiteName as CFString
        let cloudValue = CFPreferencesCopyAppValue("templates.iCloudEnabled" as CFString, domain)
        let bookmarkValue = CFPreferencesCopyAppValue("templatesFolderBookmark" as CFString, domain)
        // A malformed saved setting must not silently select a different library.
        guard cloudValue == nil || cloudValue is Bool else {
            throw MCPTemplateDiscoveryError.customFolderRequired
        }
        guard bookmarkValue == nil || bookmarkValue is Data else {
            throw MCPTemplateDiscoveryError.staleBookmark
        }
        return try configuredScope(
            iCloudEnabled: (cloudValue as? Bool) == true,
            bookmark: bookmarkValue as? Data,
            applicationSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
    }

    /// Resolves routing only: discovery never creates a missing library and never
    /// falls back from a configured bookmark or iCloud route to another location.
    /// The app and helper are unsandboxed and use the same user Application Support
    /// directory. Its location is not authorization; list still requires an
    /// explicit authorized root before opening it.
    static func configuredScope(iCloudEnabled: Bool, bookmark: Data?, applicationSupportDirectory: URL?) throws -> Scope {
        guard !iCloudEnabled else { throw MCPTemplateDiscoveryError.customFolderRequired }
        guard let data = bookmark else {
            guard let base = applicationSupportDirectory else {
                throw MCPTemplateDiscoveryError.localStorageUnavailable
            }
            return Scope(directory: base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
                .appendingPathComponent("Templates", isDirectory: true), release: {}, routing: .localDefault)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
            throw MCPTemplateDiscoveryError.staleBookmark
        }
        let started = url.startAccessingSecurityScopedResource()
        return Scope(directory: url, release: { if started { url.stopAccessingSecurityScopedResource() } }, routing: .custom(data))
    }

    func list(kind: String) throws -> [String: MCPJSONValue] {
        try withInventory(kind: kind) { first in
            [
                "kind": .string(kind),
                "templates": .array(first.sorted { $0.id < $1.id }.map { entry in
                    .object(["id": .string(entry.id), "name": .string(entry.name),
                             "schemaVersion": .integer(1), "revision": .string(entry.revision)])
                }),
                "discoveryOnly": .bool(true),
                "applicationAuthorized": .bool(false),
            ]
        }
    }

    /// Retains the exact inventory and its authority through the preview body.
    func withMetadataTemplate<T>(id: UUID, revision: String,
                                 body: (Data) throws -> T) throws -> T {
        try withInventory(kind: "metadata") { entries in
            guard let entry = entries.first(where: { $0.id == id.uuidString.lowercased() }),
                  entry.revision == revision else {
                throw MCPMetadataTemplatePreview.Failure.staleTemplate
            }
            return try body(entry.data)
        }
    }

    private func withInventory<T>(kind: String, body: ([Entry]) throws -> T) throws -> T {
        guard ["metadata", "develop"].contains(kind) else { throw MCPTemplateDiscoveryError.invalidInventory }
        let configuration = try authorizationStore.load()
        guard configuration.isEnabled else { throw MCPAuthorizationError.disabled }
        let scope = try resolveScope()
        defer { scope.release() }
        let directory = kind == "develop" ? scope.directory.appendingPathComponent("Develop", isDirectory: true) : scope.directory
        let target = try authorizationStore.authorizeExistingPath(directory.path)
        guard target.isDirectory,
              let root = configuration.roots.first(where: { $0.id == target.rootID }) else {
            throw MCPAuthorizationError.invalidConfiguration
        }
        let reservation = try MCPProcessReservation.acquireFolder(directory)
        defer { reservation.release() }
        let opened = try Directory(root: root, target: target)
        let first = try opened.inventory(kind: kind)
        let result = try body(first)
        checkpoint()
        guard try opened.inventory(kind: kind) == first else { throw MCPTemplateDiscoveryError.inventoryChanged }
        // A settings change must not publish the old library as the current library.
        let currentScope = try resolveScope()
        defer { currentScope.release() }
        guard currentScope.directory.standardizedFileURL == scope.directory.standardizedFileURL,
              currentScope.routing == scope.routing else {
            throw MCPTemplateDiscoveryError.inventoryChanged
        }
        // Bookmark resolution can block while a peer changes template contents.
        // Revalidate the complete snapshot after resolving the final route, then
        // recheck authorization and anchored ancestors immediately before publication.
        guard try opened.inventory(kind: kind) == first else {
            throw MCPTemplateDiscoveryError.inventoryChanged
        }
        guard try authorizationStore.load() == configuration,
              try authorizationStore.authorizeExistingPath(directory.path) == target else {
            throw MCPTemplateDiscoveryError.inventoryChanged
        }
        try opened.validate()
        return result
    }

    private struct Entry: Equatable {
        let id: String
        let name: String
        let revision: String
        let device: Int32
        let inode: UInt64
        let data: Data
    }

    /// Keep all ancestors open and read only descriptor-relative, no-follow files.
    /// No directory/file names or template field values are returned to the client.
    private final class Directory {
        let root: MCPAuthorizedRoot
        let components: [String]
        var descriptors: [Int32] = []
        var descriptor: Int32 { descriptors.last! }

        init(root: MCPAuthorizedRoot, target: MCPAuthorizedTarget) throws {
            self.root = root
            let rootComponents = URL(fileURLWithPath: root.canonicalPath).pathComponents
            let targetComponents = target.url.pathComponents
            guard Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
                throw MCPTemplateDiscoveryError.inventoryChanged
            }
            components = Array(targetComponents.dropFirst(rootComponents.count))
            let first = Darwin.open(root.canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard first >= 0 else { throw MCPTemplateDiscoveryError.inventoryChanged }
            descriptors.append(first)
            do {
                for component in components {
                    let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw MCPTemplateDiscoveryError.inventoryChanged }
                    descriptors.append(next)
                }
                try validate()
                var info = stat()
                guard Darwin.fstat(descriptor, &info) == 0,
                      UInt64(info.st_dev) == target.identity.device, UInt64(info.st_ino) == target.identity.inode else {
                    throw MCPTemplateDiscoveryError.inventoryChanged
                }
            } catch {
                for fd in descriptors { _ = Darwin.close(fd) }
                descriptors = []
                throw error
            }
        }

        deinit { for fd in descriptors { _ = Darwin.close(fd) } }

        func validate() throws {
            var entry = stat()
            var opened = stat()
            guard Darwin.lstat(root.canonicalPath, &entry) == 0,
                  (entry.st_mode & S_IFMT) == S_IFDIR,
                  UInt64(entry.st_dev) == root.identity.device, UInt64(entry.st_ino) == root.identity.inode else {
                throw MCPTemplateDiscoveryError.inventoryChanged
            }
            for (index, fd) in descriptors.enumerated() {
                if index > 0 {
                    guard Darwin.fstatat(descriptors[index - 1], components[index - 1], &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw MCPTemplateDiscoveryError.inventoryChanged
                    }
                }
                guard Darwin.fstat(fd, &opened) == 0, (entry.st_mode & S_IFMT) == S_IFDIR,
                      opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino else {
                    throw MCPTemplateDiscoveryError.inventoryChanged
                }
            }
        }

        func names() throws -> [String] {
            // A fresh open file description avoids sharing the directory stream offset.
            let scan = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scan >= 0 else { throw MCPTemplateDiscoveryError.invalidInventory }
            guard let stream = Darwin.fdopendir(scan) else {
                _ = Darwin.close(scan)
                throw MCPTemplateDiscoveryError.invalidInventory
            }
            defer { Darwin.closedir(stream) }
            var names: [String] = []
            var count = 0
            while true {
                errno = 0
                guard let item = Darwin.readdir(stream) else {
                    guard errno == 0 else { throw MCPTemplateDiscoveryError.invalidInventory }
                    break
                }
                count += 1
                guard count <= 4096 else { throw MCPTemplateDiscoveryError.limitExceeded }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if (name as NSString).pathExtension.lowercased() == "json" { names.append(name) }
            }
            guard names.count <= 256 else { throw MCPTemplateDiscoveryError.limitExceeded }
            return names.sorted()
        }

        func inventory(kind: String) throws -> [Entry] {
            let before = try names()
            var entries: [Entry] = []
            var seen: Set<UUID> = []
            var totalBytes = 0
            for name in before {
                let fd = Darwin.openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw MCPTemplateDiscoveryError.invalidInventory }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_nlink == 1, info.st_size >= 0, info.st_size <= 1_048_576 else {
                    throw MCPTemplateDiscoveryError.invalidInventory
                }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                totalBytes += data.count
                guard data.count <= 1_048_576, totalBytes <= 8_388_608 else {
                    throw MCPTemplateDiscoveryError.limitExceeded
                }
                var after = stat()
                var path = stat()
                guard Darwin.fstat(fd, &after) == 0,
                      Darwin.fstatat(descriptor, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
                      same(info, after), same(after, path), data.count == after.st_size else {
                    throw MCPTemplateDiscoveryError.inventoryChanged
                }
                guard let object = try? JSONDecoder().decode(MCPJSONValue.self, from: data).objectValue,
                      object["schemaVersion"] == nil || object["schemaVersion"] == .integer(1),
                      let idString = object["id"]?.stringValue, let id = UUID(uuidString: idString),
                      name == "\(id.uuidString).json", seen.insert(id).inserted,
                      let title = object["name"]?.stringValue, title.utf8.count <= 1024 else {
                    throw MCPTemplateDiscoveryError.invalidInventory
                }
                if kind == "metadata" {
                    let type = object["templateType"] ?? object["presetType"]
                    guard type == .string("Full") || type == .string("Per Field") else {
                        throw MCPTemplateDiscoveryError.invalidInventory
                    }
                    if let fields = object["fields"] {
                        guard case .array(let values) = fields,
                              values.allSatisfy({ value in
                                  guard let field = value.objectValue,
                                        let id = field["id"]?.stringValue, UUID(uuidString: id) != nil else { return false }
                                  return field["fieldKey"]?.stringValue != nil && field["templateValue"]?.stringValue != nil
                              }) else { throw MCPTemplateDiscoveryError.invalidInventory }
                    }
                } else {
                    guard object["settings"]?.objectValue != nil else { throw MCPTemplateDiscoveryError.invalidInventory }
                }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                entries.append(Entry(id: id.uuidString.lowercased(), name: title, revision: "sha256:\(hash)", device: info.st_dev, inode: info.st_ino, data: data))
            }
            guard try names() == before else { throw MCPTemplateDiscoveryError.inventoryChanged }
            try validate()
            return entries
        }

        private func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
                && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
                && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
                && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
    }
}
