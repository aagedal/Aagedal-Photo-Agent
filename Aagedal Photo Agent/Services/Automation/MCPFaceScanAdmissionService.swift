import CryptoKit
import Darwin
import Foundation

/// Read-only rooted preparation. A snapshot is neither model readiness nor permission
/// to mutate. The eventual executor must retain rooted authority and its reservation
/// across every scan suspension and write; this service deliberately schedules nothing.
nonisolated final class MCPFaceScanAdmissionService: Sendable {
    enum Failure: String, LocalizedError, Sendable {
        case invalidArguments = "invalid_arguments"
        case invalidInventory = "invalid_inventory"
        case staleSnapshot = "stale_snapshot"
        case authorizationChanged = "authorization_changed"
        case releasedReservation = "released_face_scan_reservation"

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Face scan preparation requires an absolute folder path and optional Boolean scan options."
            case .invalidInventory: "Face scanning requires a nonempty complete immediate inventory of local regular supported images, without links or pending downloads."
            case .staleSnapshot: "The folder image inventory changed. Prepare the face scan again."
            case .authorizationChanged: "Automation folder authorization changed. Prepare the face scan again."
            case .releasedReservation: "The retained face scan reservation was released. Prepare and admit a new intent."
            }
        }
    }

    struct Request: Equatable, Sendable {
        let path: String
        let forceFullScan: Bool
        let includeJerseyNumbers: Bool

        init(arguments: [String: MCPJSONValue]) throws {
            guard Set(arguments.keys).isSubset(of: ["path", "forceFullScan", "includeJerseyNumbers"]),
                  let path = arguments["path"]?.stringValue, path.hasPrefix("/"),
                  !path.contains("\0"), path.utf8.count <= 4096 else { throw Failure.invalidArguments }
            func flag(_ key: String) throws -> Bool {
                guard let value = arguments[key] else { return false }
                guard case .bool(let flag) = value else { throw Failure.invalidArguments }
                return flag
            }
            self.path = path
            includeJerseyNumbers = try flag("includeJerseyNumbers")
            forceFullScan = try flag("forceFullScan") || includeJerseyNumbers
        }
    }

    struct PreparedFolder: Sendable {
        fileprivate let request: Request
        fileprivate let authorization: MCPAuthorizationConfiguration
        fileprivate let target: MCPAuthorizedTarget
        fileprivate let images: [ImageWitness]
        let snapshotRevision: String

        var folderURL: URL { target.url }
        var imageURLs: [URL] { images.map { target.url.appendingPathComponent($0.name) } }
        var forceFullScan: Bool { request.forceFullScan }
        var includeJerseyNumbers: Bool { request.includeJerseyNumbers }
        var protocolValue: MCPJSONValue {
            .object(["schemaVersion": .integer(1), "status": .string("prepared"),
                "canonicalPath": .string(target.url.path), "rootID": .string(target.rootID.uuidString.lowercased()),
                "snapshotRevision": .string(snapshotRevision),
                "photoCount": .integer(Int64(images.count)), "forceFullScan": .bool(forceFullScan),
                "includeJerseyNumbers": .bool(includeJerseyNumbers), "executionAvailable": .bool(false),
                "modelReadinessChecked": .bool(false), "mutationAuthorized": .bool(false),
                "warnings": .array([
                    .string("Read-only snapshot only; no retained execution plan, scan, model download, or operation was created."),
                    .string("The snapshot revision covers authorization, options, filenames, and filesystem identities/timestamps; it is not a photo-content hash."),
                    .string("The folder reservation ends when preparation returns. External filesystem edits are not frozen; execution requires fresh rooted admission.")
                ])])
        }
    }

    fileprivate struct ImageWitness: Codable, Equatable, Sendable {
        let name: String
        let identity: MCPPreparedXMPIdentity
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    static let maximumPhotos = 10_000
    private let authorizationStore: MCPAuthorizationStore

    init(authorizationStore: MCPAuthorizationStore = MCPAuthorizationStore()) {
        self.authorizationStore = authorizationStore
    }

    func prepare(arguments: [String: MCPJSONValue]) throws -> PreparedFolder {
        try capture(Request(arguments: arguments))
    }

    /// A fresh lease covers the complete recapture. Returning the snapshot releases
    /// that lease; callers cannot treat successful revalidation as a write grant.
    func revalidate(_ prepared: PreparedFolder) throws -> PreparedFolder {
        let current = try capture(prepared.request)
        guard current.authorization == prepared.authorization else { throw Failure.authorizationChanged }
        guard current.target == prepared.target, current.images == prepared.images,
              current.snapshotRevision == prepared.snapshotRevision else { throw Failure.staleSnapshot }
        return current
    }

    /// Native admission foundation only: retains the original complete inventory and
    /// exclusive folder lease until explicit release or deinitialization. This is not
    /// consent, durable admission or an executor. Callers must separately establish
    /// those grants and use anchored writes; path-based writes are not made safe here.
    func retain(_ prepared: PreparedFolder) throws -> RetainedFolder {
        try Task.checkCancellation()
        guard try authorizationStore.load() == prepared.authorization else { throw Failure.authorizationChanged }
        let current = try authorizationStore.authorizeExistingPath(prepared.folderURL.path)
        guard current == prepared.target else { throw Failure.staleSnapshot }
        let lease = try MCPProcessReservation.acquireFolder(prepared.folderURL)
        let descriptor = Darwin.open(prepared.folderURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { lease.release(); throw Failure.invalidInventory }
        let retained = RetainedFolder(prepared: prepared, service: self, lease: lease, descriptor: descriptor)
        do { try retained.validate(); return retained }
        catch { retained.release(); throw error }
    }

    /// A retained kernel descriptor and lease survive asynchronous scanner suspension.
    /// Synchronous boundary checks serialize against release. The descriptor must not
    /// escape a checked callback or be closed by its caller. No mutation grant is minted.
    final class RetainedFolder: @unchecked Sendable {
        let prepared: PreparedFolder
        private let service: MCPFaceScanAdmissionService
        private let lock = NSRecursiveLock()
        private var lease: MCPProcessReservationLease?
        private var descriptor: Int32

        fileprivate init(prepared: PreparedFolder, service: MCPFaceScanAdmissionService,
                         lease: MCPProcessReservationLease, descriptor: Int32) {
            self.prepared = prepared; self.service = service
            self.lease = lease; self.descriptor = descriptor
        }

        func validate() throws { try withValidatedFolder { _, _ in } }

        /// A cheap poll checks frozen authorization and retained folder identity.
        /// Full inventory validation remains required before each effect boundary.
        func checkAuthority() throws {
            try lock.withLock {
                try requireActive()
                try Task.checkCancellation()
                try service.verifyFolder(descriptor, target: prepared.target, authorization: prepared.authorization)
            }
        }

        func withValidatedFolder<Value>(_ body: (PreparedFolder, Int32) throws -> Value) throws -> Value {
            try lock.withLock {
                try requireActive()
                try validateInventory()
                let value = try body(prepared, descriptor)
                try requireActive()
                try validateInventory()
                return value
            }
        }

        private func validateInventory() throws {
            try Task.checkCancellation()
            try service.verifyFolder(descriptor, target: prepared.target, authorization: prepared.authorization)
            guard try service.inventory(descriptor, target: prepared.target) == prepared.images,
                  try service.inventory(descriptor, target: prepared.target) == prepared.images else {
                throw Failure.staleSnapshot
            }
            try service.verifyFolder(descriptor, target: prepared.target, authorization: prepared.authorization)
        }

        private func requireActive() throws {
            guard lease != nil, descriptor >= 0 else { throw Failure.releasedReservation }
        }

        func release() {
            lock.withLock {
                if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
                lease?.release(); lease = nil
            }
        }

        deinit { release() }
    }

    private func capture(_ request: Request) throws -> PreparedFolder {
        try Task.checkCancellation()
        let authorization = try authorizationStore.load()
        let target = try authorizationStore.authorizeExistingPath(request.path)
        guard target.isDirectory else { throw Failure.invalidArguments }
        let lease = try MCPProcessReservation.acquireFolder(target.url)
        defer { lease.release() }
        let descriptor = Darwin.open(target.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidInventory }
        defer { Darwin.close(descriptor) }
        try verifyFolder(descriptor, target: target, authorization: authorization)
        let images = try inventory(descriptor, target: target)
        // Recapture the whole ordered set before releasing the lease. Cooperating
        // writers are excluded; external filesystem edits still require refusal.
        guard try inventory(descriptor, target: target) == images else { throw Failure.staleSnapshot }
        try verifyFolder(descriptor, target: target, authorization: authorization)
        struct Revision: Codable {
            let authorization: MCPAuthorizationConfiguration
            let canonicalPath: String
            let rootID: UUID
            let folderIdentity: MCPFileIdentity
            let forceFullScan: Bool
            let includeJerseyNumbers: Bool
            let images: [ImageWitness]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Revision(authorization: authorization, canonicalPath: target.url.path,
            rootID: target.rootID, folderIdentity: target.identity,
            forceFullScan: request.forceFullScan, includeJerseyNumbers: request.includeJerseyNumbers, images: images))
        let revision = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return PreparedFolder(request: request, authorization: authorization, target: target,
                              images: images, snapshotRevision: revision)
    }

    private func verifyFolder(_ descriptor: Int32, target: MCPAuthorizedTarget,
                              authorization: MCPAuthorizationConfiguration) throws {
        guard try authorizationStore.load() == authorization else { throw Failure.authorizationChanged }
        let current = try authorizationStore.authorizeExistingPath(target.url.path)
        var item = stat()
        guard current == target, Darwin.fstat(descriptor, &item) == 0,
              item.st_mode & S_IFMT == S_IFDIR,
              MCPFileIdentity(device: UInt64(item.st_dev), inode: UInt64(item.st_ino)) == target.identity else {
            throw Failure.staleSnapshot
        }
    }

    private func inventory(_ descriptor: Int32, target: MCPAuthorizedTarget) throws -> [ImageWitness] {
        // Enumeration reads names only. Each admitted image is inspected relative to
        // the retained descriptor, then compared to fresh rooted authorization.
        let urls = try FileManager.default.contentsOfDirectory(at: target.url,
            includingPropertiesForKeys: nil, options: [])
        guard urls.count <= 100_000 else { throw Failure.invalidInventory }
        var images: [ImageWitness] = []
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let logical = String(name.dropFirst().dropLast(".icloud".count))
                if supported(URL(fileURLWithPath: logical)) { throw Failure.invalidInventory }
            }
            guard !name.hasPrefix("."), supported(url) else { continue }
            var item = stat()
            guard Darwin.fstatat(descriptor, name, &item, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.staleSnapshot }
            // Supported directory names do not belong to the native image inventory.
            if item.st_mode & S_IFMT == S_IFDIR { continue }
            guard item.st_mode & S_IFMT == S_IFREG, item.st_nlink == 1 else { throw Failure.invalidInventory }
            let authorized = try authorizationStore.authorizeExistingPath(url.path)
            guard authorized.rootID == target.rootID, !authorized.isDirectory,
                  authorized.identity == MCPFileIdentity(device: UInt64(item.st_dev), inode: UInt64(item.st_ino)) else {
                throw Failure.staleSnapshot
            }
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if let status = values.ubiquitousItemDownloadingStatus, status != .current && status != .downloaded {
                throw Failure.invalidInventory
            }
            images.append(ImageWitness(name: name, identity: MCPPreparedXMPIdentity(item),
                changeSeconds: Int64(item.st_ctimespec.tv_sec), changeNanoseconds: Int64(item.st_ctimespec.tv_nsec)))
            guard images.count <= Self.maximumPhotos else { throw Failure.invalidInventory }
        }
        guard !images.isEmpty else { throw Failure.invalidInventory }
        return images.sorted { $0.name < $1.name }
    }

    private func supported(_ url: URL) -> Bool {
        MCPPhotoFormatCatalog.fileExtensions.contains(url.pathExtension.lowercased())
    }
}
