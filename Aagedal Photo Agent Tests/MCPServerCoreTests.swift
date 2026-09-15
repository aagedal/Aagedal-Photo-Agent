import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Local MCP transport and authorization")
struct MCPServerCoreTests {
    nonisolated final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?

        func read() -> Data? { lock.withLock { value } }
        func write(_ newValue: Data?) { lock.withLock { value = newValue } }
    }

    private func store(box: DataBox = DataBox()) -> MCPAuthorizationStore {
        MCPAuthorizationStore(
            readConfigurationData: { box.read() },
            writeConfigurationData: { box.write($0) }
        )
    }

    private func temporaryFolder(_ suffix: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-mcp-tests-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test("Automation is disabled until the user explicitly opts in")
    func disabledByDefault() throws {
        let store = store()
        #expect(try store.load() == MCPAuthorizationConfiguration())
        #expect(throws: MCPAuthorizationError.disabled) {
            _ = try store.authorizeExistingPath("/tmp")
        }
    }

    @Test("The filesystem root is too broad to authorize")
    func rejectsFilesystemRoot() throws {
        #expect(throws: MCPAuthorizationError.rootTooBroad) {
            _ = try store().addRoot(URL(fileURLWithPath: "/", isDirectory: true))
        }
    }

    @Test("A canonical regular file under an unchanged authorized folder is admitted")
    func admitsAuthorizedRegularFile() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("pixels".utf8).write(to: photo)

        let store = store()
        let grant = try store.addRoot(root)
        try store.setEnabled(true)
        let target = try store.authorizeExistingPath(photo.path)

        #expect(target.url == photo.standardizedFileURL)
        #expect(target.rootID == grant.id)
        #expect(!target.isDirectory)
    }

    @Test("Traversal, links, special files, and app-private folders are refused")
    func rejectsUnsafeTargets() throws {
        let root = try temporaryFolder()
        let outside = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let safe = root.appendingPathComponent("safe.jpg")
        try Data("safe".utf8).write(to: safe)
        let outsideFile = outside.appendingPathComponent("outside.jpg")
        try Data("outside".utf8).write(to: outsideFile)
        let link = root.appendingPathComponent("linked.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        let hardlink = root.appendingPathComponent("hardlinked.jpg")
        try FileManager.default.linkItem(at: outsideFile, to: hardlink)
        let fifo = root.appendingPathComponent("pipe")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let privateFile = privateFolder.appendingPathComponent("frame.json")
        try Data().write(to: privateFile)

        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)

        #expect(throws: MCPAuthorizationError.traversal) {
            _ = try store.authorizeExistingPath("\(root.path)/../\(root.lastPathComponent)/safe.jpg")
        }
        #expect(throws: MCPAuthorizationError.aliasOrSymbolicLink) {
            _ = try store.authorizeExistingPath(link.path)
        }
        #expect(throws: MCPAuthorizationError.aliasOrSymbolicLink) {
            _ = try store.authorizeExistingPath(hardlink.path)
        }
        #expect(throws: MCPAuthorizationError.specialFile) {
            _ = try store.authorizeExistingPath(fifo.path)
        }
        #expect(throws: MCPAuthorizationError.privateAppStorage) {
            _ = try store.authorizeExistingPath(privateFile.path)
        }
        #expect(throws: MCPAuthorizationError.outsideAuthorizedRoots) {
            _ = try store.authorizeExistingPath(outsideFile.path)
        }
    }

    @Test("Replacing an authorized folder at the same path revokes the grant")
    func rejectsReplacedRoot() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Authorized", isDirectory: true)
        let moved = parent.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let replacement = root.appendingPathComponent("frame.jpg")
        try Data().write(to: replacement)

        #expect(throws: MCPAuthorizationError.rootChanged) {
            _ = try store.authorizeExistingPath(replacement.path)
        }
    }

    @Test("Photo and folder reservations refuse overlap and release after completion")
    func reservationsRefuseOverlap() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = folder.appendingPathComponent("frame.jpg")
        let raw = folder.appendingPathComponent("frame.cr2")
        let other = folder.appendingPathComponent("other.jpg")
        for url in [jpeg, raw, other] { try Data("pixels".utf8).write(to: url) }

        let photoLease = try MCPProcessReservation.acquirePhoto(jpeg)
        defer { photoLease.release() }
        #expect(throws: MCPProcessReservationError.busy) {
            _ = try MCPProcessReservation.acquirePhoto(raw)
        }
        #expect(throws: MCPProcessReservationError.busy) {
            _ = try MCPProcessReservation.acquireFolder(folder)
        }
        let otherLease = try MCPProcessReservation.acquirePhoto(other)
        otherLease.release()
        photoLease.release()
        let folderLease = try MCPProcessReservation.acquireFolder(folder)
        #expect(throws: MCPProcessReservationError.busy) {
            _ = try MCPProcessReservation.acquirePhoto(other)
        }
        folderLease.release()
        let released = try MCPProcessReservation.acquirePhoto(raw)
        released.release()
    }

    @Test("Initialize negotiation and tool discovery use bounded read-only contracts")
    func initializeAndListTools() throws {
        let store = store()
        let session = MCPServerSession(authorizationStore: store)
        let initialize = try #require(session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8
        )))
        let initializeJSON = try json(initialize)
        #expect(initializeJSON["jsonrpc"] as? String == "2.0")
        #expect((initializeJSON["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServerConstants.latestProtocolVersion)

        #expect(session.response(forLine: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        let response = try #require(session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}"#.utf8
        )))
        let result = try #require((try json(response))["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == [
            "get_server_capabilities", "list_supported_photo_formats", "list_authorized_roots", "inspect_path_authorization",
            "inspect_photo_revision", "inspect_app_photo_draft",
        ])
        for tool in tools {
            let annotations = try #require(tool["annotations"] as? [String: Any])
            #expect(annotations["readOnlyHint"] as? Bool == true)
            #expect(annotations["destructiveHint"] as? Bool == false)
            #expect(annotations["openWorldHint"] as? Bool == false)
        }
    }

    @Test("Owned JSON draft inspection exposes only bounded descriptive fields and is not effective IPTC")
    func inspectsOwnedDescriptiveDraft() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: photo)
        let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let app = privateFolder.appendingPathComponent("frame.jpg.meta.json")
        let authorization = store()
        try authorization.addRoot(root)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        #expect(throws: MCPAuthorizationError.disabled) {
            _ = try facade.inspectAppPhotoDraft(path: photo.path)
        }
        try authorization.setEnabled(true)

        let absent = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue)
        #expect(absent["appSidecarDraftState"] == .string("absent"))
        #expect(absent["fields"] == .object([:]))
        let document: [String: Any] = [
            "schemaVersion": 1, "sourceFile": "frame.jpg", "pendingChanges": true,
            "metadata": [
                "title": "Reporter caption", "description": "The mayor speaks.",
                "keywords": ["city", "opening"], "personShown": ["Mayor A"],
                "cameraRaw": "must not appear", "unknownFutureField": "private extension",
            ],
            "voiceMemoTranscript": "private transcript", "history": ["private history"],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: app)
        let result = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue)
        #expect(result["appSidecarDraftState"] == .string("pending"))
        #expect(result["effectiveIPTCResolved"] == .bool(false))
        #expect(result["sourceRevision"]?.stringValue?.count == 64)
        #expect(result["appSidecarRevision"]?.stringValue?.count == 64)
        let fields = try #require(result["fields"]?.objectValue)
        #expect(fields["title"] == .string("Reporter caption"))
        #expect(fields["keywords"] == .array([.string("city"), .string("opening")]))
        #expect(fields["personShown"] == .array([.string("Mayor A")]))
        #expect(fields["cameraRaw"] == nil)
        let text = String(describing: result)
        #expect(!text.contains("private transcript"))
        #expect(!text.contains("private history"))
        #expect(!text.contains("private extension"))

        var newer = document
        newer["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: newer).write(to: app)
        #expect(throws: MCPAutomationReadError.unreadableDraft) {
            _ = try facade.inspectAppPhotoDraft(path: photo.path)
        }
        #expect(try facade.inspectPhotoRevision(path: photo.path).objectValue?["appSidecarDraftState"] == .string("unsupported-schema"))
    }

    @Test("Revision tokens detect an in-place rewrite of identical bytes after modification time is restored")
    func detectsRestoredModificationTime() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("first".utf8).write(to: photo)
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        let first = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        var original = stat()
        #expect(Darwin.lstat(photo.path, &original) == 0)

        let descriptor = Darwin.open(photo.path, O_WRONLY)
        #expect(descriptor >= 0)
        defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
        Darwin.usleep(2_000)
        let replacement = Array("first".utf8)
        #expect(replacement.withUnsafeBytes { Darwin.pwrite(descriptor, $0.baseAddress, replacement.count, 0) } == replacement.count)
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(times.withUnsafeMutableBufferPointer {
            Darwin.utimensat(AT_FDCWD, photo.path, $0.baseAddress, 0)
        } == 0)
        var rewritten = stat()
        #expect(Darwin.lstat(photo.path, &rewritten) == 0)
        #expect(original.st_ino == rewritten.st_ino)
        #expect(original.st_size == rewritten.st_size)
        #expect(original.st_mtimespec.tv_sec == rewritten.st_mtimespec.tv_sec)
        #expect(original.st_mtimespec.tv_nsec == rewritten.st_mtimespec.tv_nsec)
        #expect(original.st_ctimespec.tv_sec != rewritten.st_ctimespec.tv_sec
            || original.st_ctimespec.tv_nsec != rewritten.st_ctimespec.tv_nsec)
        let second = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(second["sourceRevision"] != first["sourceRevision"])
    }

    @Test("Revision inspection binds source, XMP, and owned JSON changes to separate opaque tokens")
    func inspectsPhotoRevision() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        let xmp = root.appendingPathComponent("frame.xmp")
        let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let app = privateFolder.appendingPathComponent("frame.jpg.meta.json")
        try Data("photo-a".utf8).write(to: photo)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)

        let first = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(first["appSidecarPresent"] == .bool(false))
        #expect(first["appSidecarDraftState"] == .string("absent"))
        #expect(first["xmpSidecarPresent"] == .bool(false))
        #expect(first["sourceRevision"]?.stringValue?.count == 64)
        let session = MCPServerSession(authorizationStore: store)
        _ = session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8
        ))
        _ = session.response(forLine: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let protocolLine = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"inspect_photo_revision","arguments":{"path":"\#(photo.path)"}}}"#
        let protocolResponse = try #require(session.response(forLine: Data(protocolLine.utf8)))
        let protocolResult = try #require((try json(protocolResponse))["result"] as? [String: Any])
        let structured = try #require(protocolResult["structuredContent"] as? [String: Any])
        #expect(protocolResult["isError"] as? Bool == false)
        #expect(structured["sourceRevision"] as? String == first["sourceRevision"]?.stringValue)
        try Data("<xmp>one</xmp>".utf8).write(to: xmp)
        let second = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(second["sourceRevision"] == first["sourceRevision"])
        #expect(second["xmpSidecarRevision"] != first["xmpSidecarRevision"])
        try Data(#"{"schemaVersion":1,"sourceFile":"frame.jpg","pendingChanges":true,"metadata":{"description":"private caption"}}"#.utf8)
            .write(to: app)
        let third = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(third["appSidecarPresent"] == .bool(true))
        #expect(third["appSidecarDraftState"] == .string("pending"))
        #expect(third["appSidecarRevision"] != second["appSidecarRevision"])
        #expect(!String(describing: third).contains("private caption"))
        try Data("photo-b".utf8).write(to: photo)
        let fourth = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(fourth["sourceRevision"] != third["sourceRevision"])
        #expect(fourth["appSidecarRevision"] == third["appSidecarRevision"])
        let replaced = root.appendingPathComponent("replaced.jpg")
        try FileManager.default.moveItem(at: photo, to: replaced)
        try Data("photo-b".utf8).write(to: photo)
        let fifth = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(fifth["sourceRevision"] != fourth["sourceRevision"])
        #expect(fifth["appSidecarRevision"] == fourth["appSidecarRevision"])
    }

    @Test("Owned sidecar state is bounded, and two owned naming generations are refused")
    func inspectsOwnedDraftStateAndRejectsAmbiguousCarriers() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let current = privateFolder.appendingPathComponent("frame.jpg.meta.json")
        let legacy = privateFolder.appendingPathComponent("frame.meta.json")
        try Data("pixels".utf8).write(to: photo)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)

        try Data(#"{"schemaVersion":1,"sourceFile":"frame.jpg","pendingChanges":false}"#.utf8).write(to: current)
        let saved = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(saved["appSidecarDraftState"] == .string("saved"))
        try Data(#"{"version":1,"sourceFile":"frame.jpg","pendingChanges":false,"orientationDraft":{}}"#.utf8).write(to: current)
        let orientationDraft = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(orientationDraft["appSidecarDraftState"] == .string("pending"))
        try Data(#"{"schemaVersion":2,"sourceFile":"frame.jpg","pendingChanges":true}"#.utf8).write(to: current)
        let newer = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(newer["appSidecarDraftState"] == .string("unsupported-schema"))
        try Data(#"{"schemaVersion":1,"sourceFile":"other.jpg","pendingChanges":true}"#.utf8).write(to: legacy)
        let foreign = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(foreign["appSidecarDraftState"] == .string("unsupported-schema"))
        try Data(#"{"schemaVersion":1,"sourceFile":"frame.jpg","pendingChanges":true}"#.utf8).write(to: legacy)
        #expect(throws: MCPAutomationReadError.unsafeCarrier) {
            _ = try facade.inspectPhotoRevision(path: photo.path)
        }
    }

    @Test("Revision inspection refuses busy photos and unrelated or linked metadata carriers")
    func refusesUnsafeRevisionInspection() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        let xmp = root.appendingPathComponent("frame.xmp")
        let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let app = privateFolder.appendingPathComponent("frame.jpg.meta.json")
        try Data("photo".utf8).write(to: photo)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        #expect(throws: MCPProcessReservationError.busy) {
            _ = try facade.inspectPhotoRevision(path: photo.path)
        }
        lease.release()
        try Data(#"{"sourceFile":"different.jpg"}"#.utf8).write(to: app)
        #expect(throws: MCPAutomationReadError.unsafeCarrier) {
            _ = try facade.inspectPhotoRevision(path: photo.path)
        }
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(at: xmp, withDestinationURL: photo)
        #expect(throws: MCPAutomationReadError.unsafeCarrier) {
            _ = try facade.inspectPhotoRevision(path: photo.path)
        }
    }

    @Test("Nested photo and carriers are read from the granted root; linked private storage is refused")
    func anchoredNestedRevisionInspection() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let photo = nested.appendingPathComponent("frame.jpg")
        let xmp = nested.appendingPathComponent("frame.xmp")
        try Data("pixels".utf8).write(to: photo)
        try Data("sidecar".utf8).write(to: xmp)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let first = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(first["xmpSidecarPresent"] == .bool(true))
        #expect(first["appSidecarPresent"] == .bool(false))

        let outside = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: outside) }
        let linkedPrivate = nested.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedPrivate, withDestinationURL: outside)
        #expect(throws: MCPAutomationReadError.unsafeCarrier) {
            _ = try facade.inspectPhotoRevision(path: photo.path)
        }
    }

    @Test("Format discovery uses the exact GUI admission catalog and does not claim universal embedded writes")
    func discoversInputFormats() throws {
        let session = MCPServerSession(authorizationStore: store())
        _ = session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8
        ))
        _ = session.response(forLine: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        let response = try #require(session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_supported_photo_formats","arguments":{}}}"#.utf8
        )))
        let result = try #require((try json(response))["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(Set(try #require(structured["inputExtensions"] as? [String])) == SupportedImageFormats.fileExtensions)
        #expect(Set(try #require(structured["rawSidecarExtensions"] as? [String])) == SupportedImageFormats.rawExtensions)
        #expect(structured["embeddedWriteSupport"] as? String == "format-and-carrier-dependent")
        #expect(result["isError"] as? Bool == false)
    }

    @Test("Malformed tool-call shapes and unknown names fail at the protocol boundary")
    func rejectsMalformedToolCalls() throws {
        let session = MCPServerSession(authorizationStore: store())
        _ = session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#.utf8
        ))
        _ = session.response(forLine: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        for call in [
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"unknown","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_supported_photo_formats","arguments":[]}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":""}}"#,
        ] {
            let response = try #require(session.response(forLine: Data(call.utf8)))
            #expect((try json(response)["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        let extra = try #require(session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_supported_photo_formats","arguments":{"path":"/tmp"}}}"#.utf8
        )))
        let result = try #require((try json(extra))["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect((result["structuredContent"] as? [String: Any])?["code"] as? String == "invalid_arguments")
    }

    @Test("Malformed input, lifecycle misuse, unsupported methods, and notifications follow JSON-RPC")
    func protocolErrorsAndNotifications() throws {
        let session = MCPServerSession(authorizationStore: store())
        let malformed = try #require(session.response(forLine: Data("{".utf8)))
        #expect((try json(malformed)["error"] as? [String: Any])?["code"] as? Int == -32700)
        let earlyList = try #require(session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8
        )))
        #expect((try json(earlyList)["error"] as? [String: Any])?["code"] as? Int == -32002)
        let unknown = try #require(session.response(forLine: Data(
            #"{"jsonrpc":"2.0","id":2,"method":"unknown"}"#.utf8
        )))
        #expect((try json(unknown)["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(session.response(forLine: Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.utf8)) == nil)
    }

    @Test("STDIO emits newline-delimited protocol bytes only and accepts EOF after a final message")
    func stdioIsProtocolClean() throws {
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let request = #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        try input.fileHandleForWriting.close()

        MCPStdioServer(session: MCPServerSession(authorizationStore: store())).run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let diagnosticData = diagnostics.fileHandleForReading.readDataToEndOfFile()
        let outputString = try #require(String(data: outputData, encoding: .utf8))

        #expect(outputString.hasSuffix("\n"))
        #expect(outputString.split(separator: "\n").count == 1)
        #expect(try json(Data(outputString.dropLast().utf8))["jsonrpc"] as? String == "2.0")
        #expect(diagnosticData.isEmpty)
    }

    @Test("STDIO bounds complete lines and resumes at EOF without leaking diagnostics")
    func stdioBoundsLinesAndProcessesFinalRequest() throws {
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        let oversized = String(repeating: "x", count: 160)
        let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        try input.fileHandleForWriting.write(contentsOf: Data((initialize + "\r\n" + oversized + "\n" + ping).utf8))
        try input.fileHandleForWriting.close()
        MCPStdioServer(session: MCPServerSession(authorizationStore: store()), maximumMessageBytes: 128).run(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            diagnostics: diagnostics.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        try diagnostics.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let lines = try #require(String(data: bytes, encoding: .utf8)).split(separator: "\n")
        #expect(lines.count == 3)
        let responses = try lines.map { try json(Data($0.utf8)) }
        #expect((responses[0]["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        #expect((responses[1]["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect((responses[2]["result"] as? [String: Any])?.isEmpty == true)
        #expect(diagnostics.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test("The app bundle contains a launchable hardened-runtime MCP helper")
    func bundledHelperLaunches() throws {
        let helper = try #require(Bundle.main.url(forAuxiliaryExecutable: "photo-agent-mcp"))
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))

        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let process = Process()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        let request = #"{"jsonrpc":"2.0","id":"bundle","method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let response = output.fileHandleForReading.readDataToEndOfFile()
        let error = diagnostics.fileHandleForReading.readDataToEndOfFile()
        let line = try #require(String(data: response, encoding: .utf8))
        #expect(line.hasSuffix("\n"))
        #expect(try json(Data(line.dropLast().utf8))["jsonrpc"] as? String == "2.0")
        #expect(error.isEmpty)

        let signature = Process()
        let signatureOutput = Pipe()
        signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signature.arguments = ["--display", "--verbose=4", helper.path]
        signature.standardOutput = signatureOutput
        signature.standardError = signatureOutput
        try signature.run()
        signature.waitUntilExit()
        let signatureText = try #require(String(
            data: signatureOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ))
        #expect(signature.terminationStatus == 0)
        #expect(signatureText.contains("flags=0x10000(runtime)"))
        #expect(signatureText.contains("TeamIdentifier=3R5QGG9DW6"))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
