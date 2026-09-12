import CryptoKit
import Darwin
import Dispatch
import Foundation
import ImageIO

nonisolated struct KnownPeoplePackageWriteReceipt: Sendable {
    let destinationURL: URL
    let revision: String
    let replacedExistingDirectory: Bool
    /// The atomic rename succeeded. A later sync, cleanup or cancellation cannot undo this fact.
    let parentDirectorySynced: Bool
    /// Held-descriptor readback proved both the installed bytes and any displaced package.
    let installedSnapshotVerified: Bool
}

nonisolated struct KnownPeoplePackageWriteResult: Sendable {
    let receipt: KnownPeoplePackageWriteReceipt?
    let wasCancelled: Bool
    let failure: String?
    /// Never automatically remove these paths after returning; they may hold the prior package.
    let recoveryDirectories: [URL]
    var completed: Bool { receipt != nil && failure == nil && !wasCancelled }
}

nonisolated struct KnownPeoplePackageDirectoryIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    func sameDirectory(as other: Self) -> Bool { device == other.device && inode == other.inode }
}

nonisolated struct KnownPeoplePackageInstallPlan: Sendable {
    let parent: KnownPeoplePackageParentTransaction
    let stageName: String
    let destinationName: String
    let stageIdentity: KnownPeoplePackageDirectoryIdentity
    let destinationIdentity: KnownPeoplePackageDirectoryIdentity?
}

nonisolated final class KnownPeoplePackageParentTransaction: @unchecked Sendable {
    let descriptor: Int32
    let initialURL: URL
    let identity: KnownPeoplePackageDirectoryIdentity
    private let processLock: DispatchSemaphore

    init(descriptor: Int32, initialURL: URL, identity: KnownPeoplePackageDirectoryIdentity,
         processLock: DispatchSemaphore) {
        self.descriptor = descriptor
        self.initialURL = initialURL
        self.identity = identity
        self.processLock = processLock
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
        processLock.signal()
    }
}

nonisolated final class KnownPeoplePackageHeldDirectory: @unchecked Sendable {
    let descriptor: Int32
    let identity: KnownPeoplePackageDirectoryIdentity

    init(descriptor: Int32, identity: KnownPeoplePackageDirectoryIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit { close(descriptor) }
}

/// Hooks are synchronous and run on the writer actor. Install must invoke onCommitted
/// immediately after rename succeeds, before any fallible sync/readback or injected hook.
nonisolated struct KnownPeoplePackageWriteAccess: Sendable {
    var openParent: @Sendable (URL) throws -> KnownPeoplePackageParentTransaction = KnownPeoplePackageWriterFilesystem.openParent
    var createStage: @Sendable (KnownPeoplePackageParentTransaction, String) throws -> KnownPeoplePackageHeldDirectory = KnownPeoplePackageWriterFilesystem.createStage
    var openDirectory: @Sendable (KnownPeoplePackageParentTransaction, String) throws -> KnownPeoplePackageHeldDirectory? = KnownPeoplePackageWriterFilesystem.openDirectory
    var writeFile: @Sendable (Data, String, KnownPeoplePackageHeldDirectory) throws -> Void = KnownPeoplePackageWriterFilesystem.writeFile
    var inspect: @Sendable (URL) throws -> KnownPeoplePackageDirectoryIdentity? = KnownPeoplePackageWriterFilesystem.inspect
    var inspectAncestor: @Sendable (URL) throws -> KnownPeoplePackageDirectoryIdentity? = KnownPeoplePackageWriterFilesystem.inspectFollowing
    var install: @Sendable (KnownPeoplePackageInstallPlan, @Sendable () -> Void) throws -> Void = KnownPeoplePackageWriterFilesystem.install
    var syncParent: @Sendable (KnownPeoplePackageParentTransaction) throws -> Void = KnownPeoplePackageWriterFilesystem.syncDirectory
    var removeOwned: @Sendable (KnownPeoplePackageParentTransaction, String, KnownPeoplePackageDirectoryIdentity) throws -> Void = KnownPeoplePackageWriterFilesystem.removeOwned
    var beforeCommit: @Sendable () throws -> Void = {}
    /// Test/fault boundary. Production leaves this empty, then performs held-FD validation.
    var beforeRenameValidation: @Sendable () throws -> Void = {}
    var afterCommit: @Sendable () throws -> Void = {}
    /// Runs before the single cancellation checkpoint that admits destructive cleanup.
    var beforeCleanupRemoval: @Sendable () throws -> Void = {}
}

/// Exports captured bytes only. No ZIP extraction, Known People store mutation or UI routing.
/// The parent advisory lock serializes cooperating writer instances. Non-cooperating same-user
/// mutation is outside this guarantee: held-descriptor checks detect changes observed at each
/// boundary, but POSIX has no atomic compare-and-unlink operation for the final cleanup step.
actor KnownPeoplePackageDirectoryWriter {
    private let access: KnownPeoplePackageWriteAccess
    init(access: KnownPeoplePackageWriteAccess = .init()) { self.access = access }

    func write(snapshot: KnownPeoplePackageSnapshot, destinationURL: URL) async -> KnownPeoplePackageWriteResult {
        var parentTransaction: KnownPeoplePackageParentTransaction?
        var stageName: String?
        var stageDirectory: KnownPeoplePackageHeldDirectory?
        var destinationDirectory: KnownPeoplePackageHeldDirectory?
        var previousDestination: KnownPeoplePackageDirectoryIdentity?
        var previousFiles: [String: Data]?
        var installedDestination: URL?
        var installedSnapshotVerified = false
        var synced = false
        let commit = KnownPeoplePackageCommitFlag()
        var failure: String?
        var cancelled = false
        var recovery: [URL] = []
        do {
            try Task.checkCancellation()
            try KnownPeoplePackageSnapshotValidation.validate(snapshot)
            guard snapshot.sourceDirectoryURL.isFileURL else {
                throw KnownPeoplePackageWriterError.invalidSourceURL
            }
            guard destinationURL.isFileURL else {
                throw KnownPeoplePackageWriterError.invalidDestinationURL
            }
            guard destinationURL.pathExtension == "aagedalpeople" else {
                throw KnownPeoplePackageWriterError.invalidDestinationExtension(destinationURL.pathExtension)
            }
            let source = snapshot.sourceDirectoryURL
            // Resolve the existing parent, but never resolve a destination leaf symlink.
            let parent = destinationURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let destination = parent.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
            guard let sourceID = try access.inspect(source) else {
                throw KnownPeoplePackageWriterError.sourceUnavailable
            }
            guard sourceID.device == snapshot.sourceDevice, sourceID.inode == snapshot.sourceInode else {
                throw KnownPeoplePackageWriterError.changedDestination
            }
            let parentHandle = try access.openParent(parent)
            parentTransaction = parentHandle
            let destinationName = destination.lastPathComponent
            destinationDirectory = try access.openDirectory(parentHandle, destinationName)
            previousDestination = destinationDirectory?.identity
            try rejectOverlap(source: source, sourceID: sourceID, destination: destination,
                              destinationID: previousDestination)
            if let destinationDirectory {
                previousFiles = try await KnownPeoplePackageDirectoryReader().read(
                    heldDirectoryDescriptor: destinationDirectory.descriptor,
                    sourceURL: destination
                ).files
            }
            let stagingName = ".KnownPeople-export-\(UUID().uuidString)"
            stageName = stagingName
            let createdStage = try access.createStage(parentHandle, stagingName)
            stageDirectory = createdStage
            for path in snapshot.files.keys.sorted() {
                try Task.checkCancellation()
                guard let bytes = snapshot.files[path] else { throw KnownPeoplePackageWriterError.invalidSnapshot }
                try access.writeFile(bytes, path, createdStage)
            }
            // Validate the actual staging tree, including no extra/link carriers, before rename.
            let staged = try await KnownPeoplePackageDirectoryReader().read(
                heldDirectoryDescriptor: createdStage.descriptor,
                sourceURL: parent.appendingPathComponent(stagingName, isDirectory: true)
            )
            guard staged.files == snapshot.files else { throw KnownPeoplePackageWriterError.invalidSnapshot }
            try access.beforeCommit()
            try Task.checkCancellation()
            // Revalidate after both admission hooks through the held directory descriptors.
            let final = try await KnownPeoplePackageDirectoryReader().read(
                heldDirectoryDescriptor: createdStage.descriptor,
                sourceURL: parent.appendingPathComponent(stagingName, isDirectory: true)
            )
            guard final.files == snapshot.files else { throw KnownPeoplePackageWriterError.invalidSnapshot }
            if let previousFiles, let destinationDirectory {
                let current = try await KnownPeoplePackageDirectoryReader().read(
                    heldDirectoryDescriptor: destinationDirectory.descriptor,
                    sourceURL: destination
                )
                guard current.files == previousFiles else { throw KnownPeoplePackageWriterError.changedDestination }
            }
            try access.beforeRenameValidation()
            let renameStage = try await KnownPeoplePackageDirectoryReader().read(
                heldDirectoryDescriptor: createdStage.descriptor,
                sourceURL: parent.appendingPathComponent(stagingName, isDirectory: true)
            )
            guard renameStage.files == snapshot.files else { throw KnownPeoplePackageWriterError.invalidSnapshot }
            if let previousFiles, let destinationDirectory {
                let renameDestination = try await KnownPeoplePackageDirectoryReader().read(
                    heldDirectoryDescriptor: destinationDirectory.descriptor,
                    sourceURL: destination
                )
                guard renameDestination.files == previousFiles else {
                    throw KnownPeoplePackageWriterError.changedDestination
                }
            }
            try Task.checkCancellation()
            try access.install(KnownPeoplePackageInstallPlan(parent: parentHandle,
                stageName: stagingName, destinationName: destinationName,
                stageIdentity: createdStage.identity, destinationIdentity: previousDestination)) {
                commit.markCommitted()
            }
            guard commit.isCommitted else { throw KnownPeoplePackageWriterError.io }
            installedDestination = try KnownPeoplePackageWriterFilesystem.entryURL(parentHandle, destinationName)
            // The held descriptors continue to name the trees after the swap. Confirm that the
            // installed tree is still the exact captured snapshot and the recovery tree is exact.
            let installed = try await KnownPeoplePackageDirectoryReader().read(
                heldDirectoryDescriptor: createdStage.descriptor,
                sourceURL: installedDestination!
            )
            guard installed.files == snapshot.files else { throw KnownPeoplePackageWriterError.changedDestination }
            if let previousFiles, let destinationDirectory {
                let displaced = try await KnownPeoplePackageDirectoryReader().read(
                    heldDirectoryDescriptor: destinationDirectory.descriptor,
                    sourceURL: try KnownPeoplePackageWriterFilesystem.entryURL(parentHandle, stagingName)
                )
                guard displaced.files == previousFiles else { throw KnownPeoplePackageWriterError.changedDestination }
            }
            installedSnapshotVerified = true
            try access.syncParent(parentHandle)
            synced = true
            // The receipt reports the final validation state, so crossing the last mutation
            // boundary invalidates the earlier proof until the checks below pass again.
            installedSnapshotVerified = false
            try access.afterCommit()
            // A fault hook or non-cooperating same-user writer may change the visible entry
            // after the first post-swap readback. Do not discard the displaced package until
            // the destination still names the installed directory and its bytes revalidate.
            guard let finalDestination = try access.openDirectory(parentHandle, destinationName),
                  finalDestination.identity.sameDirectory(as: createdStage.identity) else {
                throw KnownPeoplePackageWriterError.changedDestination
            }
            let finalInstalled = try await KnownPeoplePackageDirectoryReader().read(
                heldDirectoryDescriptor: createdStage.descriptor,
                sourceURL: installedDestination!
            )
            guard finalInstalled.files == snapshot.files else {
                throw KnownPeoplePackageWriterError.changedDestination
            }
            installedSnapshotVerified = true
            try Task.checkCancellation()
        } catch {
            cancelled = error is CancellationError
            if !(error is CancellationError) { failure = error.localizedDescription }
        }
        if let parent = parentTransaction, let name = stageName {
            let stage = (try? KnownPeoplePackageWriterFilesystem.entryURL(parent, name))
                ?? parent.initialURL.appendingPathComponent(name, isDirectory: true)
            // After a swap, this path holds the OLD destination. After exclusive rename,
            // it no longer exists. Never pass the newly installed destination to cleanup.
            let expected = commit.isCommitted ? previousDestination : stageDirectory?.identity
            if commit.isCommitted, previousDestination != nil, failure != nil || cancelled {
                recovery.append(stage)
            } else if let expected {
                do {
                    if commit.isCommitted, let previousFiles {
                        guard let destinationDirectory else { throw KnownPeoplePackageWriterError.changedDestination }
                        let old = try await KnownPeoplePackageDirectoryReader().read(
                            heldDirectoryDescriptor: destinationDirectory.descriptor,
                            sourceURL: stage
                        )
                        guard old.files == previousFiles else { throw KnownPeoplePackageWriterError.changedDestination }
                    }
                    if commit.isCommitted {
                        try access.beforeCleanupRemoval()
                        do {
                            try Task.checkCancellation()
                        } catch {
                            cancelled = true
                            recovery.append(stage)
                            throw KnownPeoplePackageCleanupCancelled()
                        }
                    }
                    try access.removeOwned(parent, name, expected)
                }
                catch is KnownPeoplePackageCleanupCancelled {}
                catch is CancellationError {
                    cancelled = true
                    recovery.append(stage)
                }
                catch {
                    recovery.append(stage)
                    let cleanup = "Cleanup could not verify or remove the temporary or previous package at \(stage.path): \(error.localizedDescription)"
                    failure = failure.map { $0 + " " + cleanup } ?? cleanup
                }
            } else if !commit.isCommitted {
                recovery.append(stage)
                failure = failure ?? "The staging directory could not be verified for cleanup."
            }
        }
        if commit.isCommitted, installedDestination == nil, let parent = parentTransaction {
            installedDestination = try? KnownPeoplePackageWriterFilesystem.entryURL(
                parent, destinationURL.lastPathComponent
            )
        }
        let receipt = commit.isCommitted ? installedDestination.map {
            KnownPeoplePackageWriteReceipt(destinationURL: $0, revision: snapshot.manifest.revision,
                replacedExistingDirectory: previousDestination != nil, parentDirectorySynced: synced,
                installedSnapshotVerified: installedSnapshotVerified)
        } : nil
        return KnownPeoplePackageWriteResult(receipt: receipt, wasCancelled: cancelled,
            failure: failure, recoveryDirectories: recovery)
    }

    private func rejectOverlap(source: URL, sourceID: KnownPeoplePackageDirectoryIdentity,
                               destination: URL, destinationID: KnownPeoplePackageDirectoryIdentity?) throws {
        if let destinationID, sourceID.sameDirectory(as: destinationID) {
            throw KnownPeoplePackageWriterError.sourceDestinationOverlap
        }
        // Compare ancestor inode identities as well as paths, including case/volume aliases.
        var cursor = destination.deletingLastPathComponent()
        while true {
            if let id = try access.inspectAncestor(cursor), id.sameDirectory(as: sourceID) {
                throw KnownPeoplePackageWriterError.sourceDestinationOverlap
            }
            if cursor.path == "/" { break }
            cursor.deleteLastPathComponent()
        }
        if let destinationID {
            cursor = source.deletingLastPathComponent()
            while true {
                if let id = try access.inspectAncestor(cursor), id.sameDirectory(as: destinationID) {
                    throw KnownPeoplePackageWriterError.sourceDestinationOverlap
                }
                if cursor.path == "/" { break }
                cursor.deleteLastPathComponent()
            }
        }
    }
}

nonisolated private struct KnownPeoplePackageCleanupCancelled: Error {}

nonisolated private final class KnownPeoplePackageParentLockRegistry: @unchecked Sendable {
    static let shared = KnownPeoplePackageParentLockRegistry()
    private let registryLock = NSLock()
    private var locks: [String: DispatchSemaphore] = [:]

    func acquire(_ identity: KnownPeoplePackageDirectoryIdentity) -> DispatchSemaphore {
        let key = "\(identity.device):\(identity.inode)"
        let lock = registryLock.withLock {
            if let existing = locks[key] { return existing }
            let created = DispatchSemaphore(value: 1)
            locks[key] = created
            return created
        }
        lock.wait()
        return lock
    }
}

nonisolated enum KnownPeoplePackageWriterFilesystem {
    static func inspect(_ url: URL) throws -> KnownPeoplePackageDirectoryIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw KnownPeoplePackageWriterError.io
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw KnownPeoplePackageWriterError.notDirectory(url.path)
        }
        return identity(info)
    }

    /// Ancestor checks may cross ordinary filesystem aliases such as /tmp -> /private/tmp.
    /// Leaf admission continues to use lstat above so a source or destination symlink is refused.
    static func inspectFollowing(_ url: URL) throws -> KnownPeoplePackageDirectoryIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw KnownPeoplePackageWriterError.io
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw KnownPeoplePackageWriterError.notDirectory(url.path)
        }
        return identity(info)
    }

    private static func identity(_ info: stat) -> KnownPeoplePackageDirectoryIdentity {
        KnownPeoplePackageDirectoryIdentity(device: info.st_dev, inode: info.st_ino,
            modificationSeconds: info.st_mtimespec.tv_sec, modificationNanoseconds: info.st_mtimespec.tv_nsec,
            changeSeconds: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec)
    }

    static func openParent(_ url: URL) throws -> KnownPeoplePackageParentTransaction {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KnownPeoplePackageWriterError.parentUnavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw KnownPeoplePackageWriterError.io
        }
        let heldIdentity = identity(info)
        let processLock = KnownPeoplePackageParentLockRegistry.shared.acquire(heldIdentity)
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            processLock.signal()
            throw KnownPeoplePackageWriterError.io
        }
        guard let pathIdentity = try inspect(url), pathIdentity.sameDirectory(as: heldIdentity) else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            processLock.signal()
            throw KnownPeoplePackageWriterError.changedDestination
        }
        return KnownPeoplePackageParentTransaction(descriptor: descriptor, initialURL: url,
            identity: heldIdentity, processLock: processLock)
    }

    static func openDirectory(_ parent: KnownPeoplePackageParentTransaction,
                              _ name: String) throws -> KnownPeoplePackageHeldDirectory? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.contains("\0") else {
            throw KnownPeoplePackageWriterError.invalidDestination
        }
        guard let before = try entryIdentity(parent, name) else { return nil }
        let descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KnownPeoplePackageWriterError.changedDestination }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw KnownPeoplePackageWriterError.io
        }
        let after = identity(info)
        guard before.sameDirectory(as: after) else {
            close(descriptor)
            throw KnownPeoplePackageWriterError.changedDestination
        }
        return KnownPeoplePackageHeldDirectory(descriptor: descriptor, identity: after)
    }

    static func createStage(_ parent: KnownPeoplePackageParentTransaction,
                            _ name: String) throws -> KnownPeoplePackageHeldDirectory {
        guard mkdirat(parent.descriptor, name, S_IRWXU) == 0,
              let directory = try openDirectory(parent, name) else {
            throw KnownPeoplePackageWriterError.io
        }
        return directory
    }

    static func writeFile(_ data: Data, _ path: String,
                          _ stage: KnownPeoplePackageHeldDirectory) throws {
        let root = dup(stage.descriptor)
        guard root >= 0 else { throw KnownPeoplePackageWriterError.io }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, identity(info).sameDirectory(as: stage.identity) else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw KnownPeoplePackageWriterError.invalidSnapshot
        }
        let directory: Int32
        if parts.count == 2 {
            if mkdirat(root, parts[0], S_IRWXU) != 0, errno != EEXIST { throw KnownPeoplePackageWriterError.io }
            directory = openat(root, parts[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        } else { directory = dup(root) }
        guard directory >= 0 else { throw KnownPeoplePackageWriterError.io }
        defer { close(directory) }
        let file = openat(directory, parts[parts.count - 1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard file >= 0 else { throw KnownPeoplePackageWriterError.io }
        defer { close(file) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw KnownPeoplePackageWriterError.io }
                offset += amount
            }
        }
        guard fsync(file) == 0, fsync(directory) == 0, fsync(root) == 0 else { throw KnownPeoplePackageWriterError.io }
    }

    static func install(_ plan: KnownPeoplePackageInstallPlan, onCommitted: @Sendable () -> Void) throws {
        let parent = plan.parent
        guard try entryIdentity(parent, plan.stageName)?.sameDirectory(as: plan.stageIdentity) == true else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        let currentDestination = try entryIdentity(parent, plan.destinationName)
        if let expectedDestination = plan.destinationIdentity {
            guard currentDestination?.sameDirectory(as: expectedDestination) == true else {
                throw KnownPeoplePackageWriterError.changedDestination
            }
        } else if currentDestination != nil {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        // Swap leaves the previous destination at the stage path. Neither variant
        // exposes an incomplete destination or removes the old tree before commit.
        let flags = plan.destinationIdentity == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renameatx_np(parent.descriptor, plan.stageName,
                           parent.descriptor, plan.destinationName, flags) == 0 else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        onCommitted()
        guard try entryIdentity(parent, plan.destinationName)?.sameDirectory(as: plan.stageIdentity) == true else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        if let destinationIdentity = plan.destinationIdentity {
            guard try entryIdentity(parent, plan.stageName)?.sameDirectory(as: destinationIdentity) == true else {
                throw KnownPeoplePackageWriterError.changedDestination
            }
        }
    }

    static func syncDirectory(_ parent: KnownPeoplePackageParentTransaction) throws {
        guard fsync(parent.descriptor) == 0 else { throw KnownPeoplePackageWriterError.io }
    }

    static func removeOwned(_ parent: KnownPeoplePackageParentTransaction, _ name: String,
                            _ expected: KnownPeoplePackageDirectoryIdentity) throws {
        guard let current = try entryIdentity(parent, name) else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        guard current.sameDirectory(as: expected) else { throw KnownPeoplePackageWriterError.changedDestination }
        let descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KnownPeoplePackageWriterError.changedDestination }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, identity(info).sameDirectory(as: expected) else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
        try removeContents(descriptor)
        guard try entryIdentity(parent, name)?.sameDirectory(as: expected) == true,
              unlinkat(parent.descriptor, name, AT_REMOVEDIR) == 0 else {
            throw KnownPeoplePackageWriterError.changedDestination
        }
    }

    static func entryURL(_ parent: KnownPeoplePackageParentTransaction, _ name: String) throws -> URL {
        try directoryURL(parent.descriptor)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func directoryURL(_ directory: KnownPeoplePackageHeldDirectory) throws -> URL {
        try directoryURL(directory.descriptor)
    }

    private static func directoryURL(_ descriptor: Int32) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) != -1 else {
            throw KnownPeoplePackageWriterError.io
        }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }

    private static func entryIdentity(_ parent: KnownPeoplePackageParentTransaction,
                                      _ name: String) throws -> KnownPeoplePackageDirectoryIdentity? {
        var info = stat()
        guard fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw KnownPeoplePackageWriterError.io
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw KnownPeoplePackageWriterError.notDirectory(name)
        }
        return identity(info)
    }

    /// Descriptor-relative unlinking never follows a child symlink. The parent lock protects
    /// cooperating writers; a non-cooperating same-user process can still race a final unlink,
    /// in which case identity rechecks make the operation fail whenever the change is observable.
    private static func removeContents(_ descriptor: Int32) throws {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw KnownPeoplePackageWriterError.io
        }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                closedir(stream)
                throw KnownPeoplePackageWriterError.io
            }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(stream)
        for name in names {
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw KnownPeoplePackageWriterError.changedDestination
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                let expected = identity(info)
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw KnownPeoplePackageWriterError.changedDestination }
                var opened = stat()
                guard fstat(child, &opened) == 0, identity(opened).sameDirectory(as: expected) else {
                    close(child)
                    throw KnownPeoplePackageWriterError.changedDestination
                }
                do {
                    try removeContents(child)
                    close(child)
                } catch {
                    close(child)
                    throw error
                }
                var current = stat()
                guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      identity(current).sameDirectory(as: expected),
                      unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw KnownPeoplePackageWriterError.changedDestination
                }
            } else {
                let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard file >= 0 else { throw KnownPeoplePackageWriterError.changedDestination }
                var opened = stat()
                let openedOK = fstat(file, &opened) == 0
                close(file)
                var current = stat()
                guard openedOK, fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      identity(opened).sameDirectory(as: identity(current)),
                      unlinkat(descriptor, name, 0) == 0 else {
                    throw KnownPeoplePackageWriterError.changedDestination
                }
            }
        }
    }
}

nonisolated private final class KnownPeoplePackageCommitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCommitted: Bool { lock.withLock { value } }
    func markCommitted() { lock.withLock { value = true } }
}

nonisolated enum KnownPeoplePackageWriterError: LocalizedError {
    case invalidSnapshot, invalidDestination, invalidSourceURL, invalidDestinationURL, notDirectory(String)
    case invalidDestinationExtension(String), sourceUnavailable, parentUnavailable
    case sourceDestinationOverlap, changedDestination, io
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "The captured Known People package is inconsistent or invalid."
        case .invalidDestination: "Choose a regular destination directory package ending in .aagedalpeople."
        case .invalidSourceURL: "The admitted source package is not a file URL."
        case .invalidDestinationURL: "The destination package is not a file URL."
        case .notDirectory(let path): "The filesystem entry at \(path) is not a regular directory."
        case .invalidDestinationExtension(let value):
            "The destination extension is \(value.isEmpty ? "missing" : value); choose a package ending in .aagedalpeople."
        case .sourceUnavailable: "The admitted source package is no longer available as a regular directory."
        case .parentUnavailable: "The destination parent is no longer available as a regular directory."
        case .sourceDestinationOverlap: "The destination overlaps the source package. Choose another location."
        case .changedDestination: "The source staging or destination directory changed before export could commit."
        case .io: "The Known People package filesystem operation failed."
        }
    }
}

/// Re-admit raw bytes and redundant decoded views before touching the filesystem.
/// Callers cannot forge a snapshot memberwise initializer into an export capability.
nonisolated enum KnownPeoplePackageSnapshotValidation {
    static func validate(_ snapshot: KnownPeoplePackageSnapshot) throws {
        guard let manifestBytes = snapshot.files["manifest.json"], let peopleBytes = snapshot.files["people.json"] else {
            throw KnownPeoplePackageWriterError.invalidSnapshot
        }
        let manifest = try KnownPeoplePackageManifest.decode(manifestBytes)
        let payload = try KnownPeoplePackagePayload.decode(peopleBytes)
        try manifest.validate(payload: payload)
        guard snapshot.manifest == manifest, snapshot.payload == payload,
              Set(snapshot.files.keys) == Set(manifest.files.map(\.path)).union(["manifest.json"]) else {
            throw KnownPeoplePackageWriterError.invalidSnapshot
        }
        for file in manifest.files {
            try Task.checkCancellation()
            guard let bytes = snapshot.files[file.path], bytes.count == file.byteCount,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw KnownPeoplePackageWriterError.invalidSnapshot
            }
            if file.path.hasSuffix(".fem2") { _ = try FaceEmbeddingInterchangeCodec.validate(bytes) }
            if file.path.hasSuffix(".jpg") { try validateThumbnail(bytes) }
        }
        let editor: KnownPeoplePackageEditorPayload?
        if let descriptor = manifest.editorPayload {
            guard let bytes = snapshot.files[descriptor.path] else { throw KnownPeoplePackageWriterError.invalidSnapshot }
            editor = try KnownPeoplePackageEditorPayload.decode(bytes, manifest: manifest, payload: payload)
        } else { editor = nil }
        guard snapshot.editor == editor, snapshot.people.count == payload.people.count else {
            throw KnownPeoplePackageWriterError.invalidSnapshot
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let exportedAt = formatter.date(from: manifest.exportedAt) else { throw KnownPeoplePackageWriterError.invalidSnapshot }
        for (person, core) in zip(snapshot.people, payload.people) {
            let details = editor?.people[core.id.uuidString.lowercased()]
            guard person.id == core.id, person.name == core.name, person.role == details?.role,
                  person.notes == details?.notes, person.representativeThumbnailID == details?.representativeThumbnailID,
                  person.createdAt == (details.map { Date(timeIntervalSinceReferenceDate: $0.createdAt) } ?? exportedAt),
                  person.updatedAt == (details.map { Date(timeIntervalSinceReferenceDate: $0.updatedAt) } ?? exportedAt),
                  person.embeddings.count == core.examples.count else { throw KnownPeoplePackageWriterError.invalidSnapshot }
            for (embedding, example) in zip(person.embeddings, core.examples) {
                let metadata = editor?.examples[example.id.uuidString.lowercased()]
                let mode: FaceRecognitionMode?
                switch metadata?.recognitionMode {
                case .vision: mode = .visionFeaturePrint
                case .faceClothing: mode = .faceAndClothing
                case nil: mode = nil
                }
                guard embedding.id == example.id, embedding.featurePrintData == snapshot.files[example.embeddingPath],
                      embedding.sourceDescription == metadata?.sourceDescription, embedding.recognitionMode == mode,
                      embedding.addedAt == (metadata.map { Date(timeIntervalSinceReferenceDate: $0.addedAt) } ?? exportedAt),
                      embedding.provenance == .current else { throw KnownPeoplePackageWriterError.invalidSnapshot }
            }
        }
        _ = try KnownPeopleInterchangeEligibility.validate(people: snapshot.people)
    }

    private static func validateThumbnail(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_777_216,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil else { throw KnownPeoplePackageWriterError.invalidSnapshot }
    }
}
