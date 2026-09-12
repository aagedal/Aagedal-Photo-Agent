import Darwin
import Foundation

nonisolated enum KnownPeoplePackageAdmissionFailure: Error {
    case unsupportedName, unsafeSource, changedSource, io
}

nonisolated struct KnownPeoplePackageAdmissionProvenance: Sendable {
    enum Kind: Sendable { case directoryPackage, archive }
    let kind: Kind
    let sourceURL: URL
    let sourceDevice: Int32
    let sourceInode: UInt64
    let archiveByteCount: Int?
    let archiveSHA256: String?
}

/// Validated schema-2 bytes for managed import planning. This deliberately does not expose
/// an export-ready directory snapshot: archive extraction has already been removed when
/// admission succeeds. The original selected input is retained as separate provenance.
nonisolated final class KnownPeopleManagedImportAdmission: Sendable {
    let provenance: KnownPeoplePackageAdmissionProvenance
    private let snapshot: KnownPeoplePackageSnapshot
    var manifest: KnownPeoplePackageManifest { snapshot.manifest }
    var payload: KnownPeoplePackagePayload { snapshot.payload }
    var editor: KnownPeoplePackageEditorPayload? { snapshot.editor }
    var files: [String: Data] { snapshot.files }
    var people: [KnownPerson] { snapshot.people }

    init(snapshot: KnownPeoplePackageSnapshot, provenance: KnownPeoplePackageAdmissionProvenance) {
        self.snapshot = snapshot
        self.provenance = provenance
    }

    func planReplacement(route: KnownPeopleManagedStoreRoute) async throws -> KnownPeopleManagedStoreReplacementPlan {
        try await KnownPeopleManagedStoreReplacement().plan(snapshot: snapshot, route: route)
    }

    @MainActor
    func planReplacement(owner: KnownPeopleService, routingActive: Bool) async throws -> KnownPeopleManagedStoreReplacementPlan {
        try await owner.planManagedStoreReplacement(snapshot: snapshot, routingActive: routingActive)
    }
}

nonisolated struct KnownPeoplePackageAdmissionResult: Sendable {
    let admission: KnownPeopleManagedImportAdmission?
    let wasCancelled: Bool
    let failure: String?
    /// Private extraction trees whose owned cleanup did not finish. No managed store or
    /// selected source is deleted by this boundary.
    let recoveryDirectories: [URL]
    var completed: Bool { admission != nil && !wasCancelled && failure == nil && recoveryDirectories.isEmpty }
}

/// Exact dispatch for schema-2 manual inputs. Legacy ZIP/schema-1 APIs are separate and
/// remain untouched; neither extensions nor file kinds are guessed from archive contents.
actor KnownPeoplePackageAdmissionService {
    private let archiveAccess: KnownPeoplePackageArchiveAccess
    private let temporaryParentURL: URL
    init(archiveAccess: KnownPeoplePackageArchiveAccess = .init(),
         temporaryParentURL: URL = FileManager.default.temporaryDirectory) {
        self.archiveAccess = archiveAccess
        self.temporaryParentURL = temporaryParentURL
    }

    func admit(at sourceURL: URL) async -> KnownPeoplePackageAdmissionResult {
        do {
            try Task.checkCancellation()
            let source = try KnownPeoplePackageAdmissionSource(sourceURL)
            switch source.kind {
            case .archive:
                return await KnownPeoplePackageArchive(access: archiveAccess).admitArchive(
                    at: sourceURL, temporaryParentURL: temporaryParentURL)
            case .directoryPackage:
                let snapshot = try await KnownPeoplePackageDirectoryReader().read(
                    heldDirectoryDescriptor: source.descriptor, sourceURL: source.url)
                try Task.checkCancellation()
                try source.verifyPath()
                let admission = KnownPeopleManagedImportAdmission(snapshot: snapshot, provenance: source.provenance())
                return .init(admission: admission, wasCancelled: false, failure: nil, recoveryDirectories: [])
            }
        } catch {
            return .init(admission: nil, wasCancelled: error is CancellationError,
                         failure: error is CancellationError ? nil : String(describing: error), recoveryDirectories: [])
        }
    }
}

/// Opens every lexical component without following links. Checking only the leaf would
/// accept aliases through an ancestor; resolving the path before admission would hide them.
nonisolated final class KnownPeoplePackageAdmissionSource: @unchecked Sendable {
    let url: URL
    let kind: KnownPeoplePackageAdmissionProvenance.Kind
    let descriptor: Int32
    private let identity: stat
    deinit { close(descriptor) }

    init(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
              !url.path.contains("\0"), url.path.hasPrefix("/") else { throw KnownPeoplePackageAdmissionFailure.unsafeSource }
        let parts = url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { throw KnownPeoplePackageAdmissionFailure.unsafeSource }
        let leaf = parts.last!
        let kind: KnownPeoplePackageAdmissionProvenance.Kind
        if leaf.hasSuffix(".aagedalpeople.zip"), leaf.count > ".aagedalpeople.zip".count { kind = .archive }
        else if leaf.hasSuffix(".aagedalpeople"), leaf.count > ".aagedalpeople".count { kind = .directoryPackage }
        else { throw KnownPeoplePackageAdmissionFailure.unsupportedName }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { throw KnownPeoplePackageAdmissionFailure.io }
        var adopted = false
        defer { if !adopted { close(current) } }
        for (index, part) in parts.enumerated() {
            let directory = index < parts.count - 1 || kind == .directoryPackage
            let next = openat(current, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
            guard next >= 0 else { throw KnownPeoplePackageAdmissionFailure.unsafeSource }
            close(current); current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0,
              (kind == .directoryPackage ? info.st_mode & S_IFMT == S_IFDIR : info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1),
              try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else {
            throw KnownPeoplePackageAdmissionFailure.unsafeSource
        }
        self.url = URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: kind == .directoryPackage)
        self.kind = kind; descriptor = current; identity = info; adopted = true
    }

    func verifyPath() throws {
        let current = try KnownPeoplePackageAdmissionSource(url)
        guard current.kind == kind, current.identity.st_dev == identity.st_dev, current.identity.st_ino == identity.st_ino,
              current.identity.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
              current.identity.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
              current.identity.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
              current.identity.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec else {
            throw KnownPeoplePackageAdmissionFailure.changedSource
        }
    }

    func provenance(archiveByteCount: Int? = nil, archiveSHA256: String? = nil) -> KnownPeoplePackageAdmissionProvenance {
        .init(kind: kind, sourceURL: url, sourceDevice: identity.st_dev, sourceInode: identity.st_ino,
              archiveByteCount: archiveByteCount, archiveSHA256: archiveSHA256)
    }
}
