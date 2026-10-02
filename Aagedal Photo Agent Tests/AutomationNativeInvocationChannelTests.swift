import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Authenticated native review invocation channel")
struct AutomationNativeInvocationChannelTests {
    private typealias Channel = AutomationNativeInvocationChannel
    nonisolated private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var value: Int { lock.withLock { storage } }
        func increment() { lock.withLock { storage += 1 } }
    }

    nonisolated private struct Fixture: Sendable {
        let root: URL
        var directory: URL { root.appendingPathComponent("channel", isDirectory: true) }
        var socket: URL { directory.appendingPathComponent("review.sock") }
        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/ani-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func listener(authenticate: @escaping Channel.PeerAuthenticator = { _, role in
            guard role == .helper else { throw Channel.Failure.authenticationRequired }
        }, handler: @escaping Channel.Handler = { _ in try .init(status: .reviewRequired) }) -> Channel.Listener {
            .init(testingDirectory: directory, authenticator: authenticate, handler: handler)
        }
        func client(authenticate: @escaping Channel.PeerAuthenticator = { _, role in
            guard role == .application else { throw Channel.Failure.authenticationRequired }
        }) -> Channel.Client { .init(testingDirectory: directory, authenticator: authenticate) }
    }

    private func request() -> Channel.Request { .init(requestID: UUID(), requestEpoch: UUID()) }
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func strictRequestContainsOnlyRetainedCanonicalHandles() throws {
        let original = request(), encoded = try original.encoded()
        #expect(try Channel.Request.decode(encoded) == original)
        let valid = try object(encoded)
        for addition in ["consent", "provider", "path", "transcript", "operationID"] {
            var invalid = valid; invalid[addition] = "untrusted"
            #expect(throws: (any Error).self) { try Channel.Request.decode(json(invalid)) }
        }
        for replacement: Any in [true, "1", 2, NSNull()] {
            var invalid = valid; invalid["schemaVersion"] = replacement
            #expect(throws: (any Error).self) { try Channel.Request.decode(json(invalid)) }
        }
        var invalid = valid
        invalid["requestID"] = original.requestID.uuidString.uppercased()
        #expect(throws: (any Error).self) { try Channel.Request.decode(json(invalid)) }
        invalid = valid; invalid["kind"] = "executeVoiceTranscription"
        #expect(throws: (any Error).self) { try Channel.Request.decode(json(invalid)) }
        let duplicate = Data("{\"kind\":\"voiceTranscriptionReview\",\"requestEpoch\":\"\(original.requestEpoch.uuidString.lowercased())\",\"requestID\":\"\(original.requestID.uuidString.lowercased())\",\"schemaVersion\":1,\"schemaVersion\":1}".utf8)
        #expect(throws: (any Error).self) { try Channel.Request.decode(duplicate) }
        #expect(throws: (any Error).self) { try Channel.Request.decode(encoded + Data(" {}".utf8)) }
        #expect(throws: (any Error).self) { try Channel.Request.decode(Data(repeating: 32, count: 513)) }
    }

    @Test func responseCannotCarryConsentTextOrUnlinkedOperation() throws {
        for status in [Channel.Status.reviewRequired, .unavailable] {
            let response = try Channel.Response(status: status)
            #expect(try Channel.Response.decode(response.encoded()) == response)
            #expect(throws: Channel.Failure.invalidResponse) { try Channel.Response(status: status, operationID: UUID()) }
        }
        #expect(throws: Channel.Failure.invalidResponse) { try Channel.Response(status: .linkedOperation) }
        let response = try Channel.Response(status: .linkedOperation, operationID: UUID())
        #expect(try Channel.Response.decode(response.encoded()) == response)
        for name in ["consentGranted", "paths", "transcript", "provider"] {
            var invalid = try object(response.encoded()); invalid[name] = "private"
            #expect(throws: (any Error).self) { try Channel.Response.decode(json(invalid)) }
        }
    }

    @Test func realSocketsAuthenticateBothDirectionsAndReturnOnlyStatus() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let serverPeers = Counter(), clientPeers = Counter(), calls = Counter(), expected = request()
        let listener = fixture.listener(authenticate: { _, role in
            #expect(role == .helper); serverPeers.increment()
        }, handler: { value in
            #expect(value == expected); calls.increment(); return try .init(status: .reviewRequired)
        })
        try listener.start(); defer { listener.stop() }
        let client = fixture.client(authenticate: { _, role in
            #expect(role == .application); clientPeers.increment()
        })
        #expect(try client.invoke(expected).status == .reviewRequired)
        #expect(serverPeers.value == 3)
        #expect(clientPeers.value == 2)
        #expect(calls.value == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.socket.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func readinessPrecedesClientAuditAuthenticationAndRequestDisclosure() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let gate = DispatchSemaphore(value: 0), helperChecks = Counter(), appChecks = Counter(), calls = Counter()
        let listener = fixture.listener(authenticate: { _, _ in
            helperChecks.increment(); _ = gate.wait(timeout: .now() + 2)
        }, handler: { _ in calls.increment(); return try .init(status: .reviewRequired) })
        try listener.start(); defer { gate.signal(); listener.stop() }
        let client = fixture.client(authenticate: { _, _ in appChecks.increment() })
        #expect(throws: Channel.Failure.timedOut) { try client.invoke(request(), timeout: 0.2) }
        #expect(helperChecks.value == 1)
        // The app has accepted but has not authenticated this helper or published
        // readiness. Client-side authentication and handles must both wait.
        #expect(appChecks.value == 0)
        #expect(calls.value == 0)
        listener.stop()
    }

    @Test func kernelPeerAuditTokenIsAvailableAtClientAuthentication() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let listener = fixture.listener()
        try listener.start(); defer { listener.stop() }
        let checks = Counter()
        let client = fixture.client(authenticate: { descriptor, role in
            #expect(role == .application)
            var token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
            #expect(getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0)
            #expect(Int(size) == MemoryLayout<audit_token_t>.size)
            checks.increment()
        })
        #expect(try client.invoke(request()).status == .reviewRequired)
        #expect(checks.value == 2)
    }

    @Test func helperAndApplicationAuthenticationRefusalPrecedeHandler() throws {
        for refuseHelper in [true, false] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let calls = Counter()
            let listener = fixture.listener(authenticate: { _, _ in
                if refuseHelper { throw Channel.Failure.authenticationRequired }
            }, handler: { _ in calls.increment(); return try .init(status: .reviewRequired) })
            try listener.start(); defer { listener.stop() }
            let client = fixture.client(authenticate: { _, _ in
                if !refuseHelper { throw Channel.Failure.authenticationRequired }
            })
            #expect(throws: (any Error).self) { try client.invoke(request(), timeout: 0.5) }
            #expect(calls.value == 0)
        }
    }

    @Test func actualApplicationCannotConstructProductionHelperClient() {
        // Unit tests are hosted by the application. A production helper client
        // requires the actual current bundled helper identity, even if signed.
        #expect(throws: (any Error).self) { try Channel.Client() }
    }

    @Test func sharedOrSymlinkDirectoryIsRefusedAndPreserved() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        #expect(throws: Channel.Failure.unsafeEndpoint) { try fixture.listener().start() }
        try FileManager.default.removeItem(at: fixture.directory)
        let other = fixture.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: other)
        #expect(throws: Channel.Failure.unsafeEndpoint) { try fixture.listener().start() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test func physicalTemporaryPathIsAcceptedWhileSymlinkSpellingAndDecoratedURLsRefuse() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        // Foundation standardization may rewrite this physical path to /tmp.
        // Production must retain /private/tmp and check it with O_NOFOLLOW.
        #expect(fixture.directory.path.hasPrefix("/private/tmp/"))
        let listener = fixture.listener()
        try listener.start(); defer { listener.stop() }
        #expect(try fixture.client().invoke(request()).status == .reviewRequired)
        let alias = URL(fileURLWithPath: fixture.directory.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        let aliasClient = Channel.Client(testingDirectory: alias, authenticator: { _, _ in })
        #expect(throws: Channel.Failure.unsafeEndpoint) { try aliasClient.invoke(request()) }
        let decorated = try #require(URL(string: fixture.directory.absoluteString + "?untrusted=1"))
        let decoratedClient = Channel.Client(testingDirectory: decorated, authenticator: { _, _ in })
        #expect(throws: Channel.Failure.unsafeEndpoint) { try decoratedClient.invoke(request()) }
        #expect(try fixture.client().invoke(request()).status == .reviewRequired)
    }

    @Test func unexpectedEndpointAndOwnerSymlinkAreNeverConsumed() throws {
        for leaf in ["review.sock", "review.owner.lock"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let target = fixture.root.appendingPathComponent("preserve")
            try Data("original".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent(leaf), withDestinationURL: target)
            #expect(throws: (any Error).self) { try fixture.listener().start() }
            #expect(try Data(contentsOf: target) == Data("original".utf8))
            #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        }
    }

    @Test func competingListenerRefusesAndCleanStopPermitsRestart() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = fixture.listener(), second = fixture.listener()
        try first.start(); defer { first.stop(); second.stop() }
        #expect(throws: Channel.Failure.endpointOccupied) { try second.start() }
        #expect(try fixture.client().invoke(request()).status == .reviewRequired)
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.socket.path))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("review.owner.lock").path))
        try second.start()
        #expect(try fixture.client().invoke(request()).status == .reviewRequired)
    }

    @Test func terminatedSocketCanBeReclaimedButLiveUnownedSocketCannot() throws {
        for live in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let descriptor = try boundSocket(fixture.socket)
            var info = stat(); #expect(lstat(fixture.socket.path, &info) == 0)
            try Channel.restrictPublishedSocket(directory: fixture.directory, device: info.st_dev, inode: info.st_ino)
            if live { #expect(Darwin.listen(descriptor, 2) == 0) }
            else { Darwin.close(descriptor) }
            defer { if live { Darwin.close(descriptor) } }
            let listener = fixture.listener(); defer { listener.stop() }
            if live {
                #expect(throws: Channel.Failure.endpointOccupied) { try listener.start() }
                var retained = stat(); #expect(lstat(fixture.socket.path, &retained) == 0)
                #expect(retained.st_ino == info.st_ino)
            } else {
                try listener.start()
                #expect(try fixture.client().invoke(request()).status == .reviewRequired)
            }
        }
    }

    @Test func symlinkSwapAtPermissionPublicationDoesNotChmodTarget() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let descriptor = try boundSocket(fixture.socket); defer { Darwin.close(descriptor) }
        var info = stat(); #expect(lstat(fixture.socket.path, &info) == 0)
        let target = fixture.root.appendingPathComponent("preserve")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        #expect(throws: (any Error).self) {
            try Channel.restrictPublishedSocket(directory: fixture.directory, device: info.st_dev, inode: info.st_ino,
                testingCheckpoint: {
                    try FileManager.default.removeItem(at: fixture.socket)
                    try FileManager.default.createSymbolicLink(at: fixture.socket, withDestinationURL: target)
                })
        }
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        #expect(try Data(contentsOf: target) == Data("original".utf8))
    }

    @Test func directoryDriftBeforeRequestRefusesAndStopPreservesReplacement() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let calls = Counter(), displaced = fixture.root.appendingPathComponent("displaced")
        let listener = fixture.listener(handler: { _ in calls.increment(); return try .init(status: .reviewRequired) })
        try listener.start(); defer { listener.stop() }
        let client = fixture.client(authenticate: { _, _ in
            try FileManager.default.moveItem(at: fixture.directory, to: displaced)
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data("replacement".utf8).write(to: fixture.socket)
        })
        #expect(throws: (any Error).self) { try client.invoke(request()) }
        listener.stop()
        #expect(calls.value == 0)
        #expect(try Data(contentsOf: fixture.socket) == Data("replacement".utf8))
        #expect(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("review.sock").path))
    }

    @Test func replacedOwnerInodeRefusesHandlerAndIsPreserved() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let calls = Counter(), peers = Counter()
        let owner = fixture.directory.appendingPathComponent("review.owner.lock")
        let listener = fixture.listener(authenticate: { _, _ in
            if peers.value == 0 {
                try FileManager.default.moveItem(at: owner, to: fixture.directory.appendingPathComponent("old.lock"))
                try Data("replacement".utf8).write(to: owner)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path)
            }
            peers.increment()
        }, handler: { _ in calls.increment(); return try .init(status: .reviewRequired) })
        try listener.start(); defer { listener.stop() }
        #expect(throws: (any Error).self) { try fixture.client().invoke(request(), timeout: 0.5) }
        #expect(calls.value == 0)
        listener.stop()
        #expect(try Data(contentsOf: owner) == Data("replacement".utf8))
    }

    @Test func payloadAndConcurrentConnectionLimitsProtectHandler() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let calls = Counter(), peers = Counter()
        let listener = fixture.listener(authenticate: { _, _ in peers.increment() },
            handler: { _ in calls.increment(); return try .init(status: .reviewRequired) })
        try listener.start(); defer { listener.stop() }
        let oversized = try connectedSocket(fixture.socket); defer { Darwin.close(oversized) }
        let bytes = Data(repeating: 65, count: 514)
        _ = bytes.withUnsafeBytes { Darwin.send(oversized, $0.baseAddress!, $0.count, 0) }
        var byte: UInt8 = 0
        #expect(Darwin.recv(oversized, &byte, 1, 0) <= 0)
        #expect(calls.value == 0)
        var retained: [Int32] = []
        defer { for descriptor in retained { Darwin.close(descriptor) } }
        let baseline = peers.value
        for _ in 0..<Channel.maximumConnections { retained.append(try connectedSocket(fixture.socket)) }
        let end = Date().addingTimeInterval(1)
        while peers.value < baseline + Channel.maximumConnections, Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        #expect(peers.value == baseline + Channel.maximumConnections)
        #expect(throws: (any Error).self) { try fixture.client().invoke(request(), timeout: 0.5) }
        #expect(calls.value == 0)
    }

    @Test func clientDeadlineAndStopDoNotWaitForHandler() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let gate = DispatchSemaphore(value: 0), started = Counter()
        let listener = fixture.listener(handler: { _ in
            started.increment(); _ = gate.wait(timeout: .now() + 2); return try .init(status: .reviewRequired)
        })
        try listener.start(); defer { gate.signal(); listener.stop() }
        let begin = Date()
        #expect(throws: Channel.Failure.timedOut) { try fixture.client().invoke(request(), timeout: 0.1) }
        #expect(started.value == 1)
        listener.stop()
        #expect(Date().timeIntervalSince(begin) < 0.8)
        #expect(!FileManager.default.fileExists(atPath: fixture.socket.path))
        #expect(throws: (any Error).self) { try fixture.client().invoke(request(), timeout: 0.1) }
    }

    private func boundSocket(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Channel.Failure.unavailable }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor); throw Channel.Failure.unsafeEndpoint
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw Channel.Failure.unavailable }
        return descriptor
    }

    private func connectedSocket(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Channel.Failure.unavailable }
        var timeout = timeval(tv_sec: 2, tv_usec: 0), yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw Channel.Failure.unavailable }
        let expected = Data("{\"schemaVersion\":1,\"status\":\"peerAccepted\"}\n".utf8)
        var greeting = Data(), buffer = [UInt8](repeating: 0, count: 513)
        while greeting.count < expected.count {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(descriptor, $0.baseAddress!, $0.count, 0) }
            guard count > 0 else { Darwin.close(descriptor); throw Channel.Failure.authenticationRequired }
            greeting.append(contentsOf: buffer.prefix(count))
            guard greeting.count <= expected.count else { Darwin.close(descriptor); throw Channel.Failure.invalidMessage }
        }
        guard greeting == expected else { Darwin.close(descriptor); throw Channel.Failure.invalidMessage }
        return descriptor
    }
}
