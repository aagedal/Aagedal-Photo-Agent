import CoreFoundation
import Darwin
import Foundation
import Security

@_silgen_name("flock")
nonisolated private func nativeInvocationFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// A local, mutually authenticated request to review retained intent. This channel
/// transports no consent, provider, paths, transcript text or execution capability.
nonisolated enum AutomationNativeInvocationChannel {
    enum Failure: Error, Equatable {
        case invalidMessage, invalidResponse, unsafeEndpoint, endpointOccupied
        case authenticationRequired, unpairedExecutable, unavailable, timedOut, stopped
    }


    enum Role: Equatable, Sendable { case application, helper }
    typealias PeerAuthenticator = @Sendable (Int32, Role) throws -> Void
    typealias Handler = @Sendable (Request) throws -> Response
    static let maximumMessageBytes = 512
    static let maximumConnections = 4
    static let defaultDirectory = URL(fileURLWithPath: "/private/tmp/apa-native-\(geteuid())", isDirectory: true)
    private static let socketName = "review.sock"
    private static let ownerName = "review.owner.lock"
    /// A fixed non-sensitive readiness marker. Darwin publishes a connected
    /// listener's peer audit credentials only after accept has completed.
    private static let acceptedGreeting = Data("{\"schemaVersion\":1,\"status\":\"peerAccepted\"}".utf8)
    /// Keep the accepted peer alive until the client has authenticated it again
    /// and validated the response against the original endpoint generation.
    private static let receivedAcknowledgement = Data("{\"schemaVersion\":1,\"status\":\"peerReceipt\"}".utf8)

    struct Request: Equatable, Sendable {
        let requestID: UUID
        let requestEpoch: UUID

        init(requestID: UUID, requestEpoch: UUID) {
            self.requestID = requestID; self.requestEpoch = requestEpoch
        }

        func encoded() throws -> Data {
            try canonical(["schemaVersion": 1, "kind": "voiceTranscriptionReview",
                           "requestID": requestID.uuidString.lowercased(),
                           "requestEpoch": requestEpoch.uuidString.lowercased()])
        }

        static func decode(_ data: Data) throws -> Request {
            let object = try dictionary(data)
            guard Set(object.keys) == ["schemaVersion", "kind", "requestID", "requestEpoch"],
                  object["kind"] as? String == "voiceTranscriptionReview",
                  let id = uuid(object["requestID"]), let epoch = uuid(object["requestEpoch"]) else {
                throw Failure.invalidMessage
            }
            let request = Request(requestID: id, requestEpoch: epoch)
            // A canonical wire format rejects duplicate keys, alternate numeric
            // types, nested data, trailing values and spelling ambiguity.
            guard try request.encoded() == data else { throw Failure.invalidMessage }
            return request
        }
    }

    enum Status: String, Sendable { case reviewRequired, linkedOperation, unavailable }

    struct Response: Equatable, Sendable {
        let status: Status
        let operationID: UUID?

        init(status: Status, operationID: UUID? = nil) throws {
            guard (status == .linkedOperation) == (operationID != nil) else { throw Failure.invalidResponse }
            self.status = status; self.operationID = operationID
        }

        func encoded() throws -> Data {
            var object: [String: Any] = ["schemaVersion": 1, "status": status.rawValue]
            if let operationID { object["operationID"] = operationID.uuidString.lowercased() }
            return try canonical(object)
        }

        static func decode(_ data: Data) throws -> Response {
            let object = try dictionary(data)
            guard let name = object["status"] as? String, let status = Status(rawValue: name),
                  Set(object.keys) == (status == .linkedOperation
                    ? Set(["schemaVersion", "status", "operationID"]) : Set(["schemaVersion", "status"])) else {
                throw Failure.invalidResponse
            }
            let response = try Response(status: status, operationID: uuid(object["operationID"]))
            guard try response.encoded() == data else { throw Failure.invalidResponse }
            return response
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let text = value as? String, let value = UUID(uuidString: text),
              value.uuidString.lowercased() == text else { return nil }
        return value
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidMessage
        }
        return object
    }

    private static func canonical(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maximumMessageBytes else { throw Failure.invalidMessage }
        return data
    }

    struct Client: Sendable {
        private let directory: URL
        private let authenticate: PeerAuthenticator

        init(directory: URL = defaultDirectory) throws {
            self.directory = directory
            let pair = try SigningPair(role: .helper)
            authenticate = { descriptor, role in try pair.authenticate(descriptor, expected: role) }
        }

        /// Internal test seam. Production has no environment/configuration bypass.
        init(testingDirectory: URL, authenticator: @escaping PeerAuthenticator) {
            directory = testingDirectory; authenticate = authenticator
        }

        func invoke(_ request: Request, timeout: TimeInterval = 3) throws -> Response {
            let deadline = try Deadline(timeout)
            let anchor = try DirectoryAnchor(directory, create: false)
            let witness = try anchor.socketWitness()
            let descriptor = try makeSocket()
            defer { Darwin.close(descriptor) }
            var address = try socketAddress(directory)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw Failure.unavailable }
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw Failure.unavailable
                }
            }
            // connect may return before the app accepts, when LOCAL_PEERTOKEN
            // still refuses with ENOTCONN. Await a bounded fixed greeting, then
            // authenticate the actual kernel peer before sending request handles.
            guard try readFrame(descriptor: descriptor, deadline: deadline) == acceptedGreeting else {
                throw Failure.authenticationRequired
            }
            try authenticate(descriptor, .application)
            try anchor.validate(socket: witness)
            try writeFrame(request.encoded(), descriptor: descriptor, deadline: deadline)
            let response = try Response.decode(readFrame(descriptor: descriptor, deadline: deadline))
            try authenticate(descriptor, .application)
            try anchor.validate(socket: witness)
            try writeFrame(receivedAcknowledgement, descriptor: descriptor, deadline: deadline)
            return response
        }
    }

    final class Listener: @unchecked Sendable {
        private let directory: URL
        private let authenticate: PeerAuthenticator
        private let handler: Handler
        private let lock = NSLock()
        private var session: Session?
        private let workers = DispatchQueue(label: "com.aagedal.photo-agent.native-invocation", qos: .utility, attributes: .concurrent)

        private final class Session: @unchecked Sendable {
            let id = UUID()
            let descriptor: Int32
            let anchor: DirectoryAnchor
            let witness: FileWitness
            let owner: OwnerLease
            var connections: Set<Int32> = [] // Protected by Listener.lock.
            init(descriptor: Int32, anchor: DirectoryAnchor, witness: FileWitness, owner: OwnerLease) {
                self.descriptor = descriptor; self.anchor = anchor; self.witness = witness; self.owner = owner
            }
        }

        init(directory: URL = defaultDirectory, handler: @escaping Handler) throws {
            self.directory = directory; self.handler = handler
            let pair = try SigningPair(role: .application)
            authenticate = { descriptor, role in try pair.authenticate(descriptor, expected: role) }
        }

        /// Tests exercise real sockets and directory ownership with synthetic peers.
        /// This initializer is not reachable from client arguments or preferences.
        init(testingDirectory: URL, authenticator: @escaping PeerAuthenticator, handler: @escaping Handler) {
            directory = testingDirectory; authenticate = authenticator; self.handler = handler
        }

        func start() throws {
            try lock.withLock {
                guard session == nil else { throw Failure.endpointOccupied }
                let anchor = try DirectoryAnchor(directory, create: true)
                // The anchored lifetime flock is the evidence that no cooperating
                // listener owns this pathname. Kernel close/crash releases it.
                let owner = try anchor.acquireOwner()
                if anchor.hasSocketEntry() {
                    let stale = try anchor.socketWitness()
                    try owner.validate(anchor)
                    try requireInactiveSocket(directory)
                    try anchor.validate(socket: stale)
                    anchor.removeSocket(matching: stale)
                    guard !anchor.hasSocketEntry() else { throw Failure.endpointOccupied }
                }
                let descriptor = try makeSocket()
                var published: FileWitness?
                do {
                    var address = try socketAddress(directory)
                    let result = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    guard result == 0 else { throw Failure.endpointOccupied }
                    published = try anchor.socketWitness(requirePrivate: false)
                    try restrictPublishedSocket(directory: directory, device: published!.device, inode: published!.inode)
                    guard Darwin.listen(descriptor, Int32(maximumConnections)) == 0 else { throw Failure.unsafeEndpoint }
                    let witness = try anchor.socketWitness()
                    guard witness == published else { throw Failure.unsafeEndpoint }
                    try anchor.validate(socket: witness)
                    try owner.validate(anchor)
                    let current = Session(descriptor: descriptor, anchor: anchor, witness: witness, owner: owner)
                    session = current
                    workers.async { [weak self] in
                        while let self {
                            guard self.acceptOne(current) else { return }
                        }
                    }
                } catch {
                    Darwin.close(descriptor)
                    if let published { anchor.removeSocket(matching: published) }
                    throw error
                }
            }
        }

        func stop() {
            lock.withLock {
                guard let current = session else { return }
                session = nil
                Darwin.shutdown(current.descriptor, SHUT_RDWR)
                Darwin.close(current.descriptor)
                // Workers own their descriptors until they unwind; shutdown wakes
                // blocked IO without closing a subsequently reused descriptor.
                for descriptor in current.connections { Darwin.shutdown(descriptor, SHUT_RDWR) }
                current.anchor.removeSocket(matching: current.witness)
                current.owner.release()
            }
        }

        deinit { stop() }

        private func acceptOne(_ current: Session) -> Bool {
            // Hold the lifecycle lock through nonblocking accept: stop cannot close
            // and reuse the listener descriptor between checking and accepting.
            let descriptor: Int32? = lock.withLock {
                guard session?.id == current.id else { return nil }
                let descriptor = Darwin.accept(current.descriptor, nil, nil)
                guard descriptor >= 0 else { return -1 }
                guard current.connections.count < maximumConnections else {
                    Darwin.close(descriptor); return -1
                }
                current.connections.insert(descriptor)
                return descriptor
            }
            guard let descriptor else { return false }
            if descriptor < 0 {
                // Bounded idle wait, with no pathname-derived authentication.
                var item = pollfd(fd: current.descriptor, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&item, 1, 50)
                return true
            }
            workers.async { [self] in
                defer {
                    lock.withLock { current.connections.remove(descriptor); Darwin.close(descriptor) }
                }
                do {
                    try configureSocket(descriptor)
                    let deadline = try Deadline(3)
                    try authenticate(descriptor, .helper)
                    try requireCurrent(current)
                    try writeFrame(acceptedGreeting, descriptor: descriptor, deadline: deadline)
                    let request = try Request.decode(readFrame(descriptor: descriptor, deadline: deadline))
                    try authenticate(descriptor, .helper)
                    try requireCurrent(current)
                    let response = try handler(request)
                    try requireCurrent(current)
                    try authenticate(descriptor, .helper)
                    try writeFrame(response.encoded(), descriptor: descriptor, deadline: deadline)
                    // Closing immediately after send makes Darwin discard the
                    // client's LOCAL_PEERTOKEN before its final authentication.
                    // A bounded, fixed acknowledgement retains this live window;
                    // it conveys no consent or additional invocation authority.
                    guard try readFrame(descriptor: descriptor, deadline: deadline) == receivedAcknowledgement else {
                        throw Failure.invalidMessage
                    }
                } catch {
                    // Close without exposing signature details, private paths or
                    // arbitrary error descriptions across the trust boundary.
                }
            }
            return true
        }

        private func requireCurrent(_ current: Session) throws {
            guard lock.withLock({ session?.id == current.id }) else { throw Failure.stopped }
            try current.anchor.validate(socket: current.witness)
            try current.owner.validate(current.anchor)
        }
    }

    private struct Deadline {
        let instant: UInt64
        init(_ seconds: TimeInterval) throws {
            guard seconds.isFinite, seconds > 0, seconds <= 10 else { throw Failure.timedOut }
            instant = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        }
        func milliseconds() throws -> Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < instant else { throw Failure.timedOut }
            return Int32(min(100, max(1, (instant - now) / 1_000_000)))
        }
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        do { try configureSocket(descriptor); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }

    private static func configureSocket(_ descriptor: Int32) throws {
        var yes: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure.unavailable
        }
    }

    private static func socketAddress(_ directory: URL) throws -> sockaddr_un {
        let path = directory.appendingPathComponent(socketName).path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unsafeEndpoint }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    private static func requireInactiveSocket(_ directory: URL) throws {
        let descriptor = try makeSocket()
        defer { Darwin.close(descriptor) }
        var address = try socketAddress(directory)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // A lock alone cannot authorize deleting a live listener whose lock file
        // was replaced. Only a concrete refusal on the witnessed socket qualifies.
        guard result != 0, errno == ECONNREFUSED else { throw Failure.endpointOccupied }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: Deadline) throws {
        while true {
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, try deadline.milliseconds())
            if result < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
            if result == 0 { continue }
            if item.revents & events != 0 { return }
            throw Failure.unavailable
        }
    }

    private static func writeFrame(_ data: Data, descriptor: Int32, deadline: Deadline) throws {
        guard !data.isEmpty, data.count <= maximumMessageBytes else { throw Failure.invalidMessage }
        // One newline-terminated canonical JSON value per connection. No sessions,
        // multiplexing, reusable capability or stream of further requests exists.
        let bytes = data + Data([10])
        var offset = 0
        while offset < bytes.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw Failure.unavailable }
            guard count > 0 else { throw Failure.unavailable }
            offset += count
        }
    }

    private static func readFrame(descriptor: Int32, deadline: Deadline) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: maximumMessageBytes + 1)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress!, $0.count, 0) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw Failure.unavailable }
            guard count > 0 else { throw Failure.unavailable }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumMessageBytes + 1 else { throw Failure.invalidMessage }
            if let end = data.firstIndex(of: 10) {
                guard end == data.index(before: data.endIndex), end > data.startIndex else { throw Failure.invalidMessage }
                return Data(data[..<end])
            }
        }
    }

    private struct FileWitness: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }

    /// Also used by deterministic publication-replacement tests. This is a checked
    /// filesystem primitive, not an injectable authentication/production bypass.
    static func restrictPublishedSocket(directory: URL, device: dev_t, inode: ino_t,
                                        testingCheckpoint: (() throws -> Void)? = nil) throws {
        let anchor = try DirectoryAnchor(directory, create: false)
        let expected = try anchor.socketWitness(requirePrivate: false)
        guard expected.device == device, expected.inode == inode else { throw Failure.unsafeEndpoint }
        // Deterministic filesystem-race test checkpoint; never set by production.
        try testingCheckpoint?()
        guard fchmodat(anchor.descriptor, socketName, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.unsafeEndpoint
        }
        try anchor.validate(socket: expected)
    }

    private final class OwnerLease: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32
        let witness: FileWitness
        init(descriptor: Int32, witness: FileWitness) { self.descriptor = descriptor; self.witness = witness }
        func validate(_ anchor: DirectoryAnchor) throws {
            try lock.withLock {
                guard descriptor >= 0 else { throw Failure.stopped }
                var info = stat()
                guard fstat(descriptor, &info) == 0, FileWitness(info) == witness,
                      try anchor.ownerWitness() == witness else { throw Failure.unsafeEndpoint }
            }
        }
        func release() {
            lock.withLock {
                guard descriptor >= 0 else { return }
                Darwin.close(descriptor); descriptor = -1
            }
        }
        deinit { release() }
    }

    private final class DirectoryAnchor: @unchecked Sendable {
        let descriptor: Int32
        private let url: URL
        private let witness: FileWitness

        init(_ url: URL, create: Bool) throws {
            self.url = url
            descriptor = try Self.open(url, create: create)
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw Failure.unsafeEndpoint }
            witness = FileWitness(info)
        }
        deinit { Darwin.close(descriptor) }

        private static func open(_ url: URL, create: Bool) throws -> Int32 {
            guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil, !url.path.contains("\0") else { throw Failure.unsafeEndpoint }
            let parts = url.path.split(separator: "/")
            // Foundation's standardizedFileURL can rewrite /private/tmp to the
            // symlink spelling /tmp. Retain the supplied physical spelling and
            // let the descriptor walk enforce no-follow for every component.
            guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.unsafeEndpoint }
            var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.unsafeEndpoint }
            do {
                for (index, component) in parts.enumerated() {
                    let name = String(component), final = index == parts.count - 1
                    if final, create, mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST {
                        throw Failure.unsafeEndpoint
                    }
                    let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw Failure.unsafeEndpoint }
                    Darwin.close(descriptor); descriptor = next
                    var info = stat()
                    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                          info.st_uid == 0 || info.st_uid == geteuid() else { throw Failure.unsafeEndpoint }
                    if final {
                        guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.unsafeEndpoint }
                    } else if info.st_mode & 0o022 != 0 {
                        // Only root-owned sticky ancestors (the system temporary
                        // directory) can be writable by other users.
                        guard info.st_uid == 0, info.st_mode & S_ISVTX != 0 else { throw Failure.unsafeEndpoint }
                    }
                }
                return descriptor
            } catch { Darwin.close(descriptor); throw error }
        }

        func hasSocketEntry() -> Bool {
            var info = stat()
            if fstatat(descriptor, socketName, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            return errno != ENOENT
        }

        func acquireOwner() throws -> OwnerLease {
            let owner = openat(descriptor, ownerName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard owner >= 0 else { throw Failure.unsafeEndpoint }
            do {
                var info = stat()
                guard fstat(owner, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == geteuid(), info.st_nlink == 1,
                      info.st_mode & 0o777 == 0o600,
                      try ownerWitness() == FileWitness(info) else { throw Failure.unsafeEndpoint }
                guard nativeInvocationFlock(owner, LOCK_EX | LOCK_NB) == 0 else { throw Failure.endpointOccupied }
                guard try ownerWitness() == FileWitness(info) else { throw Failure.unsafeEndpoint }
                return OwnerLease(descriptor: owner, witness: FileWitness(info))
            } catch { Darwin.close(owner); throw error }
        }

        func ownerWitness() throws -> FileWitness {
            var info = stat()
            guard fstatat(descriptor, ownerName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_mode & 0o777 == 0o600 else { throw Failure.unsafeEndpoint }
            return FileWitness(info)
        }

        func socketWitness(requirePrivate: Bool = true) throws -> FileWitness {
            var info = stat()
            guard fstatat(descriptor, socketName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_nlink == 1,
                  !requirePrivate || info.st_mode & 0o777 == 0o600 else { throw Failure.unsafeEndpoint }
            return FileWitness(info)
        }

        func validate(socket expected: FileWitness) throws {
            let current = try Self.open(url, create: false)
            defer { Darwin.close(current) }
            var info = stat()
            guard fstat(current, &info) == 0, FileWitness(info) == witness,
                  try socketWitness() == expected else { throw Failure.unsafeEndpoint }
        }

        func removeSocket(matching expected: FileWitness) {
            // Unlink only our original inode through our retained directory. A
            // replacement directory or endpoint belongs to someone else.
            guard (try? validate(socket: expected)) != nil else { return }
            _ = unlinkat(descriptor, socketName, 0)
        }
    }

    /// Actual code signatures and kernel connection credentials establish trust.
    /// Endpoint files and UUID/checksum fields are never authentication evidence.
    private struct SigningPair: @unchecked Sendable {
        private struct Identity {
            let role: Role
            let executable: URL
            let codeHash: Data
            let requirement: SecRequirement
        }
        private let application: Identity
        private let helper: Identity
        private static let team = "3R5QGG9DW6"

        init(role: Role) throws {
            var current: SecCode?
            guard SecCodeCopySelf(SecCSFlags(), &current) == errSecSuccess, let current else {
                throw Failure.authenticationRequired
            }
            let information = try Self.information(current)
            guard let executable = information[kSecCodeInfoMainExecutable as String] as? URL else {
                throw Failure.unpairedExecutable
            }
            let macOS = executable.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
            let bundle = contents.deletingLastPathComponent()
            guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
                  bundle.pathExtension == "app", executable.path == executable.resolvingSymlinksInPath().path else {
                throw Failure.unpairedExecutable
            }
            application = try Self.identity(role: .application,
                executable: macOS.appendingPathComponent("Aagedal Photo Agent"), staticURL: bundle)
            helper = try Self.identity(role: .helper,
                executable: macOS.appendingPathComponent("photo-agent-mcp"), staticURL: macOS.appendingPathComponent("photo-agent-mcp"))
            try Self.validate(current, against: role == .application ? application : helper)
        }

        func authenticate(_ descriptor: Int32, expected role: Role) throws {
            var credentials = xucred(), size = socklen_t(MemoryLayout<xucred>.size)
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) == 0,
                  Int(size) == MemoryLayout<xucred>.size, credentials.cr_version == XUCRED_VERSION,
                  credentials.cr_uid == geteuid() else { throw Failure.authenticationRequired }
            var token = audit_token_t()
            size = socklen_t(MemoryLayout<audit_token_t>.size)
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
                  Int(size) == MemoryLayout<audit_token_t>.size else { throw Failure.authenticationRequired }
            let tokenData = withUnsafeBytes(of: &token) { Data($0) }
            var peer: SecCode?
            let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &peer) == errSecSuccess, let peer else {
                throw Failure.authenticationRequired
            }
            try Self.validate(peer, against: role == .application ? application : helper)
        }

        private static func identity(role: Role, executable: URL, staticURL: URL) throws -> Identity {
            let identifier = role == .application ? "aagedal.Aagedal-Photo-Agent" : "photo-agent-mcp"
            var requirement: SecRequirement?
            let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(rule as CFString, SecCSFlags(), &requirement) == errSecSuccess,
                  let requirement else { throw Failure.authenticationRequired }
            var code: SecStaticCode?
            guard executable.path == executable.resolvingSymlinksInPath().path,
                  SecStaticCodeCreateWithPath(staticURL as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
                throw Failure.unpairedExecutable
            }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let dictionary = info as? [String: Any] else { throw Failure.authenticationRequired }
            let hash = try codeHash(dictionary, identifier: identifier)
            return Identity(role: role, executable: executable, codeHash: hash, requirement: requirement)
        }

        private static func information(_ code: SecCode) throws -> [String: Any] {
            var info: CFDictionary?
            // Security documents that signing-information accepts both dynamic
            // and static code objects. Keep the dynamic object here so the hash
            // belongs to the running peer rather than reopened disk bytes.
            let compatible = unsafeBitCast(code, to: SecStaticCode.self)
            guard SecCodeCopySigningInformation(compatible, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let dictionary = info as? [String: Any] else { throw Failure.authenticationRequired }
            return dictionary
        }

        private static func codeHash(_ info: [String: Any], identifier: String) throws -> Data {
            guard info[kSecCodeInfoIdentifier as String] as? String == identifier,
                  info[kSecCodeInfoTeamIdentifier as String] as? String == team,
                  let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
                  flags.uint32Value & 0x0002 == 0, // Security's documented adhoc signature flag.
                  let certificates = info[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty,
                  let hash = info[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
                throw Failure.authenticationRequired
            }
            return hash
        }

        private static func validate(_ code: SecCode, against identity: Identity) throws {
            guard SecCodeCheckValidity(code, SecCSFlags(), identity.requirement) == errSecSuccess else {
                throw Failure.authenticationRequired
            }
            let info = try information(code)
            let identifier = identity.role == .application ? "aagedal.Aagedal-Photo-Agent" : "photo-agent-mcp"
            guard try codeHash(info, identifier: identifier) == identity.codeHash,
                  let executable = info[kSecCodeInfoMainExecutable as String] as? URL,
                  executable.path == identity.executable.path else { throw Failure.unpairedExecutable }
        }
    }
}
