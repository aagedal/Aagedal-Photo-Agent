import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Delivery FTP transport factory")
struct DeliveryFTPTransportFactoryTests {
    nonisolated private static let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    nonisolated private static let secret = "credential-canary"

    @Test("canonical UUID selects immutable inventory and resolves only its Keychain account")
    func canonicalLookupAndImmutableInventory() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = DeliveryFTPCapture()
        var connection = makeConnection()
        let transport = DeliveryFTPTransportFactory.make(
            connections: [connection],
            secretLoader: .init { key in
                capture.recordKey(key)
                return Self.secret
            },
            processRunner: .init { _, arguments in
                capture.recordArguments(arguments)
                return .init(terminationStatus: 0)
            }
        )

        // The caller's mutable copy cannot alter the already-built transport inventory.
        connection.host = "mutated.invalid"
        try await transport.upload(makeTransfer(file: file))

        #expect(capture.keys == [makeConnection().keychainKey])
        let arguments = try #require(capture.argumentVectors.first)
        #expect(arguments.contains("ftp://original.example:21/desk/news.jpg"))
        #expect(!arguments.contains(where: { $0.contains("mutated.invalid") }))
        #expect(!arguments.contains(where: { $0.contains(Self.secret) }))
    }

    @Test("noncanonical, unknown, and duplicate UUID inventory entries fail closed")
    func UUIDFailures() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = makeConnection()
        let runner = FTPService.DeliveryProcessRunner { _, _ in
            Issue.record("Unsafe lookup reached the process runner")
            return .init(terminationStatus: 0)
        }

        for (identifier, inventory, expected) in [
            ("{\(Self.identifier.uuidString.lowercased())}", [connection], DeliveryFTPTransportError.invalidConnectionIdentifier),
            (UUID().uuidString.lowercased(), [connection], .connectionUnavailable),
            (Self.identifier.uuidString.lowercased(), [connection, connection], .connectionUnavailable),
        ] {
            let transport = DeliveryFTPTransportFactory.make(
                connections: inventory,
                secretLoader: .init { _ in Self.secret },
                processRunner: runner
            )
            do {
                try await transport.upload(makeTransfer(file: file, connectionIdentifier: identifier))
                Issue.record("Invalid connection inventory unexpectedly uploaded")
            } catch let error as DeliveryFTPTransportError {
                #expect(error == expected)
            }
        }
    }

    @Test("missing credential is sanitized and prevents process launch")
    func missingCredential() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = DeliveryFTPTransportFactory.make(
            connections: [makeConnection()],
            secretLoader: .init { _ in nil },
            processRunner: .init { _, _ in
                Issue.record("Missing credential reached process runner")
                return .init(terminationStatus: 0)
            }
        )
        await expectUploadError(.credentialUnavailable, transport: transport, transfer: makeTransfer(file: file))
    }

    @Test("staged filename and remote path are validated before secret lookup")
    func pathSafety() async throws {
        let file = try makeFile(name: "actual.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = DeliveryFTPCapture()
        let transport = DeliveryFTPTransportFactory.make(
            connections: [makeConnection()],
            secretLoader: .init { _ in
                capture.recordKey("unexpected")
                return Self.secret
            },
            processRunner: .init { _, _ in
                Issue.record("Unsafe path reached process runner")
                return .init(terminationStatus: 0)
            }
        )

        await expectUploadError(
            .unsafeTransfer,
            transport: transport,
            transfer: makeTransfer(file: file, outputFilename: "renamed.jpg")
        )
        await expectUploadError(
            .unsafeTransfer,
            transport: transport,
            transfer: makeTransfer(file: file, outputFilename: "actual.jpg", remoteDirectory: "/desk/../escape")
        )
        #expect(capture.keys.isEmpty)
    }

    @Test("same-size local byte substitution is refused before secret lookup")
    func exactLocalEvidenceBoundary() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let capture = DeliveryFTPCapture()
        let transport = DeliveryFTPTransportFactory.make(
            connections: [makeConnection()],
            secretLoader: .init { _ in
                capture.recordKey("unexpected")
                return Self.secret
            },
            processRunner: .init { _, _ in
                Issue.record("Changed bytes reached the process runner")
                return .init(terminationStatus: 0)
            }
        )
        try Data("evil".utf8).write(to: file)

        await expectUploadError(
            .unsafeTransfer,
            transport: transport,
            transfer: makeTransfer(file: file)
        )
        #expect(capture.keys.isEmpty)
    }

    enum ProtocolCase: Sendable {
        case ftp
        case ftps
        case sftp
    }

    @Test("FTP, explicit FTPS, and SFTP preserve security-critical curl flags", arguments: [
        ProtocolCase.ftp, .ftps, .sftp,
    ])
    func protocolFlags(protocolCase: ProtocolCase) async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = DeliveryFTPCapture()
        var connection = makeConnection()
        switch protocolCase {
        case .ftp: break
        case .ftps: connection.useTLS = true
        case .sftp:
            connection.useSFTP = true
            connection.port = 22
        }
        let transport = DeliveryFTPTransportFactory.make(
            connections: [connection],
            secretLoader: .init { _ in Self.secret },
            processRunner: .init { _, arguments in
                capture.recordArguments(arguments)
                return .init(terminationStatus: 0)
            }
        )
        try await transport.upload(makeTransfer(file: file))
        let arguments = try #require(capture.argumentVectors.first)
        switch protocolCase {
        case .ftp:
            #expect(arguments.contains("--ftp-create-dirs"))
            #expect(!arguments.contains("--ssl-reqd"))
            #expect(arguments.contains(where: { $0.hasPrefix("ftp://") }))
        case .ftps:
            #expect(arguments.contains("--ftp-create-dirs"))
            #expect(arguments.contains("--ssl-reqd"))
            #expect(arguments.contains(where: { $0.hasPrefix("ftp://") }))
        case .sftp:
            #expect(!arguments.contains("--ftp-create-dirs"))
            #expect(!arguments.contains("--ssl-reqd"))
            #expect(arguments.contains(where: { $0.hasPrefix("sftp://") }))
        }
    }

    @Test("remote probe maps size, missing, and unavailable without claiming verification")
    func remoteObservationMapping() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let cases: [(FTPService.DeliveryProcessResult, DeliveryRemoteStatObservation)] = [
            (.init(terminationStatus: 0, standardOutput: "Content-Length: 4\r\n"), .exists(byteCount: 4)),
            (.init(terminationStatus: 0, standardOutput: "Server: example\r\n"), .exists(byteCount: nil)),
            (.init(terminationStatus: 78, standardError: "credential-canary remote path"), .missing),
            (.init(terminationStatus: 67, standardError: "credential-canary login"), .unavailable),
        ]

        for (result, expected) in cases {
            let transport = DeliveryFTPTransportFactory.make(
                connections: [makeConnection()],
                secretLoader: .init { _ in Self.secret },
                processRunner: .init { _, arguments in
                    #expect(arguments.contains("--head"))
                    #expect(!arguments.contains(where: { $0.contains(Self.secret) }))
                    return result
                }
            )
            let observed = try await transport.remoteStat!(makeTransfer(file: file))
            #expect(observed == expected)
        }
    }

    @Test("an active file completes in the coordinator-style uncancelled task boundary")
    func activeFileCompletesAcrossWaiterCancellation() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = DeliveryFTPCapture()
        let transport = DeliveryFTPTransportFactory.make(
            connections: [makeConnection()],
            secretLoader: .init { _ in Self.secret },
            processRunner: .init { _, _ in
                try await Task.sleep(for: .milliseconds(100))
                capture.markCompleted()
                return .init(terminationStatus: 0)
            }
        )
        let transfer = makeTransfer(file: file)
        let activeFile = Task.detached { try await transport.upload(transfer) }
        let cancelledWaiter = Task { try await activeFile.value }
        cancelledWaiter.cancel()
        try await activeFile.value
        #expect(capture.completed)
    }

    @Test("underlying process diagnostics and credentials never escape outward")
    func failureIsSanitized() async throws {
        let file = try makeFile(name: "news.jpg", bytes: Data("news".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = DeliveryFTPTransportFactory.make(
            connections: [makeConnection()],
            secretLoader: .init { _ in Self.secret },
            processRunner: .init { _, _ in
                throw NSError(
                    domain: "server \(Self.secret) reporter@example.invalid",
                    code: 1
                )
            }
        )
        do {
            try await transport.upload(makeTransfer(file: file))
            Issue.record("Failed process unexpectedly uploaded")
        } catch let error as DeliveryFTPTransportError {
            #expect(error == .uploadFailed)
            let text = error.localizedDescription
            #expect(!text.contains(Self.secret))
            #expect(!text.contains("reporter"))
            #expect(!text.contains("example.invalid"))
        }
    }

    private func makeConnection() -> FTPConnection {
        FTPConnection(
            id: Self.identifier,
            name: "Desk",
            host: "original.example",
            port: 21,
            username: "reporter",
            remotePath: "/inventory-default"
        )
    }

    private func makeFile(name: String, bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeliveryFTP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file)
        return file
    }

    private func makeTransfer(
        file: URL,
        connectionIdentifier: String = Self.identifier.uuidString.lowercased(),
        outputFilename: String = "news.jpg",
        remoteDirectory: String = "/desk"
    ) -> DeliveryUploadTransfer {
        DeliveryUploadTransfer(
            connectionIdentifier: connectionIdentifier,
            remoteDirectory: remoteDirectory,
            outputFilename: outputFilename,
            localURL: file,
            expectedByteCount: 4,
            expectedSHA256: "19fba0e995b9794fc2c26217bf3b725c2f0d9eeda16719fe75e3ba23ca73bfc4"
        )
    }

    private func expectUploadError(
        _ expected: DeliveryFTPTransportError,
        transport: DeliveryUploadTransport,
        transfer: DeliveryUploadTransfer
    ) async {
        do {
            try await transport.upload(transfer)
            Issue.record("Invalid transfer unexpectedly uploaded")
        } catch let error as DeliveryFTPTransportError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }
}

private nonisolated final class DeliveryFTPCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedKeys: [String] = []
    private var storedArgumentVectors: [[String]] = []
    private var didComplete = false

    func recordKey(_ key: String) { lock.withLock { storedKeys.append(key) } }
    func recordArguments(_ arguments: [String]) {
        lock.withLock { storedArgumentVectors.append(arguments) }
    }
    func markCompleted() { lock.withLock { didComplete = true } }

    var keys: [String] { lock.withLock { storedKeys } }
    var argumentVectors: [[String]] { lock.withLock { storedArgumentVectors } }
    var completed: Bool { lock.withLock { didComplete } }
}
