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

    @Test("Typed draft scalars preserve production values, absence, and explicit clears")
    func inspectsTypedDraftScalars() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: photo)
        let folder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sidecar = folder.appendingPathComponent("frame.jpg.meta.json")
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        func write(_ fields: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "sourceFile": "frame.jpg", "pendingChanges": true, "metadata": fields,
            ]).write(to: sidecar)
        }
        var metadata = IPTCMetadata()
        metadata.digitalSourceType = .digitalCapture
        metadata.captureDate = "2026-09-19T12:34:56+02:00"
        metadata.urgency = 0
        metadata.rating = -1
        metadata.label = ""
        metadata.latitude = 59.91
        metadata.longitude = -10.75
        let encoded = try JSONEncoder().encode(metadata)
        try write(try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any]))
        let expected = try #require(JSONDecoder().decode(MCPJSONValue.self, from: encoded).objectValue)
        let fields = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"]?.objectValue)
        for key in ["digitalSourceType", "captureDate", "urgency", "rating", "label", "latitude", "longitude"] {
            #expect(fields[key] == expected[key])
        }
        try write(["rating": NSNull(), "urgency": NSNull(), "latitude": NSNull(), "label": NSNull()])
        #expect(try facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"] == .object([:]))
        // Inspection preserves legacy/current creator keys independently and does not claim
        // enum or editor-range validation of stored draft values.
        try write(["creator": " Legacy ", "creators": [], "digitalSourceType": "future-kind",
                   "rating": 42, "urgency": -2, "latitude": 0, "longitude": 180])
        let raw = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"]?.objectValue)
        #expect(raw["creator"] == .string(" Legacy "))
        #expect(raw["creators"] == .array([]))
        #expect(raw["digitalSourceType"] == .string("future-kind"))
        #expect(raw["rating"] == .integer(42))
        #expect(raw["urgency"] == .integer(-2))
        #expect(raw["latitude"] == .number(0))
        #expect(raw["longitude"] == .number(180))
        let invalid: [[String: Any]] = [
            ["rating": true], ["urgency": false], ["rating": "5"], ["urgency": 1.5],
            ["rating": 1e30], ["latitude": true], ["longitude": "10.7"], ["latitude": []],
            ["label": 2], ["captureDate": 123], ["digitalSourceType": [:]], ["creator": []],
            ["label": String(repeating: "ø", count: 16_385)],
            ["description": String(repeating: "a", count: 32_768),
             "label": String(repeating: "b", count: 32_768), "captureDate": "overflow"],
        ]
        for fields in invalid {
            try write(fields)
            #expect(throws: MCPAutomationReadError.unreadableDraft) {
                _ = try facade.inspectAppPhotoDraft(path: photo.path)
            }
            let lease = try MCPProcessReservation.acquirePhoto(photo)
            lease.release()
        }
    }

    @Test("Structured editorial draft records preserve production pairing, order, and clears")
    func inspectsStructuredDraftRecords() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: photo)
        let folder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sidecar = folder.appendingPathComponent("frame.jpg.meta.json")
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        var metadata = IPTCMetadata()
        metadata.imageSuppliers = [.init(identifier: "agency:1", name: "News, North"), .init(name: "Second")]
        metadata.locationsCreated = [.init(identifiers: ["place:1"], city: "Oslo", latitude: 59.9, longitude: 10.7)]
        metadata.locationsShown = []
        metadata.creatorContactInfo = .init(addressLines: ["First", "Second"], emails: ["news@example.test"])
        metadata.mediaTopics = [.init(termIdentifier: "urn:topic:1", name: "Topic")]
        metadata.genres = []
        let encoded = try JSONEncoder().encode(metadata)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let expected = try #require(JSONDecoder().decode(MCPJSONValue.self, from: encoded).objectValue)
        func write(_ fields: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "sourceFile": "frame.jpg", "pendingChanges": true, "metadata": fields,
            ]).write(to: sidecar)
        }
        try write(object)
        let fields = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"]?.objectValue)
        for key in ["imageSuppliers", "locationsCreated", "locationsShown", "creatorContactInfo", "mediaTopics", "genres"] {
            #expect(fields[key] == expected[key])
        }
        try write(["imageSuppliers": NSNull(), "creatorContactInfo": [:], "locationsShown": []])
        let cleared = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"]?.objectValue)
        #expect(cleared["imageSuppliers"] == nil)
        #expect(cleared["creatorContactInfo"] == .object([:]))
        #expect(cleared["locationsShown"] == .array([]))
        try write(["imageSuppliers": [["name": "Agency", "privateExtension": "secret"]]])
        let filtered = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"]?.objectValue)
        #expect(filtered["imageSuppliers"] == .array([.object(["name": .string("Agency")])]))

        let invalid: [[String: Any]] = [
            ["imageSuppliers": "flattened"], ["imageSuppliers": [["name": 1]]],
            ["locationsShown": [["latitude": true]]], ["locationsCreated": [["longitude": "10.7"]]],
            ["creatorContactInfo": ["emails": [1]]], ["creatorContactInfo": []],
            ["mediaTopics": [["name": "missing identifier"]]], ["genres": [["termIdentifier": NSNull()]]],
            ["imageSuppliers": Array(repeating: ["name": "a"], count: 129)],
            ["locationsShown": [["identifiers": Array(repeating: "a", count: 129)]]],
            ["creatorContactInfo": ["emails": [String(repeating: "ø", count: 513)]]],
            ["imageSuppliers": [["name": String(repeating: "ø", count: 16_385)]]],
            ["description": String(repeating: "a", count: 32_768),
             "imageSuppliers": [["name": String(repeating: "b", count: 32_768), "identifier": "overflow"]]],
        ]
        for fields in invalid {
            try write(fields)
            #expect(throws: MCPAutomationReadError.unreadableDraft) {
                _ = try facade.inspectAppPhotoDraft(path: photo.path)
            }
            let lease = try MCPProcessReservation.acquirePhoto(photo)
            lease.release()
        }
    }

    @Test("Draft Title alternatives preserve order, clears, and Headline independently")
    func inspectsLocalizedDraftTitles() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: photo)
        let folder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sidecar = folder.appendingPathComponent("frame.jpg.meta.json")
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        let titles = [LocalizedMetadataText(languageTag: "nb", value: "Norsk tittel"),
                      LocalizedMetadataText(languageTag: "x-default", value: "English title")]
        let encoded = try JSONEncoder().encode(titles)
        let alternatives = try JSONSerialization.jsonObject(with: encoded)
        for value in [alternatives, [], NSNull()] as [Any] {
            let record: [String: Any] = [
                "schemaVersion": 1, "sourceFile": "frame.jpg", "pendingChanges": true,
                "metadata": ["title": "Independent headline", "localizedTitles": value],
            ]
            try JSONSerialization.data(withJSONObject: record).write(to: sidecar)
            let fields = try #require(facade.inspectAppPhotoDraft(path: photo.path).objectValue?["fields"]?.objectValue)
            #expect(fields["title"] == .string("Independent headline"))
            if value is NSNull {
                #expect(fields["localizedTitles"] == nil)
            } else {
                let expected = try JSONDecoder().decode(MCPJSONValue.self, from: JSONSerialization.data(withJSONObject: value))
                #expect(fields["localizedTitles"] == expected)
            }
        }
        let invalidTitles: [Any] = [
            Array(repeating: ["languageTag": "en", "value": "title"], count: 129),
            [["languageTag": String(repeating: "n", count: 1_025), "value": "title"]],
            [["languageTag": "en", "value": String(repeating: "ø", count: 16_385)]],
            Array(repeating: ["languageTag": "en", "value": String(repeating: "a", count: 32_768)], count: 2),
        ]
        for value in invalidTitles {
            let record: [String: Any] = [
                "schemaVersion": 1, "sourceFile": "frame.jpg", "pendingChanges": true,
                "metadata": ["localizedTitles": value],
            ]
            try JSONSerialization.data(withJSONObject: record).write(to: sidecar)
            #expect(throws: MCPAutomationReadError.unreadableDraft) {
                _ = try facade.inspectAppPhotoDraft(path: photo.path)
            }
        }
    }

    @Test("Draft reads refuse coerced headers and malformed localized Title", arguments: [
        #"{"schemaVersion":true,"pendingChanges":true,"metadata":{}}"#,
        #"{"schemaVersion":1,"pendingChanges":1,"metadata":{}}"#,
        #"{"schemaVersion":"1","pendingChanges":true,"metadata":{}}"#,
        #"{"version":true,"pendingChanges":true,"metadata":{}}"#,
        #"{"schemaVersion":1,"pendingChanges":true,"metadata":{"localizedTitles":[{"languageTag":"en","value":7}]}}"#,
        #"{"schemaVersion":1,"pendingChanges":true,"metadata":{"localizedTitles":[{"value":"missing language"}]}}"#,
        #"{"schemaVersion":1,"pendingChanges":true,"metadata":{"localizedTitles":"invalid"}}"#,
    ])
    func refusesMalformedDraftTypes(record: String) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("image".utf8).write(to: photo)
        let folder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sidecar = folder.appendingPathComponent("frame.jpg.meta.json")
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        var object = try #require(JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any])
        object["sourceFile"] = "frame.jpg"
        try JSONSerialization.data(withJSONObject: object).write(to: sidecar)
        #expect(throws: MCPAutomationReadError.unreadableDraft) {
            _ = try facade.inspectAppPhotoDraft(path: photo.path)
        }
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
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

    @Test("An earlier carrier change prevents publishing combined photo evidence")
    func refusesCrossCarrierChange() throws {
        for carrier in ["source", "xmp", "app", "new-xmp"] {
            let root = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let photo = root.appendingPathComponent("frame.jpg")
            let xmp = root.appendingPathComponent("frame.xmp")
            let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
            let app = privateFolder.appendingPathComponent("frame.jpg.meta.json")
            try Data("image-one".utf8).write(to: photo)
            try Data("xmp-one".utf8).write(to: xmp)
            try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
            try Data(#"{"schemaVersion":1,"sourceFile":"frame.jpg","pendingChanges":false,"metadata":{"title":"one"}}"#.utf8)
                .write(to: app)
            if carrier == "new-xmp" { try FileManager.default.removeItem(at: xmp) }
            let authorization = store()
            try authorization.addRoot(root)
            try authorization.setEnabled(true)
            let facade = MCPAutomationFacade(authorizationStore: authorization) {
                let target = switch carrier {
                case "source": photo
                case "app": app
                default: xmp
                }
                try? Data("changed-at-checkpoint".utf8).write(to: target)
            }
            #expect(throws: MCPAutomationReadError.photoChanged) {
                _ = try facade.inspectAppPhotoDraft(path: photo.path)
            }
        }
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

    @Test("Parsed snapshot publication retains the photo lease and releases it after success or failure",
          arguments: [false, true])
    func parsedPublicationLease(parserFails: Bool) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("source".utf8).write(to: photo)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let parse = {
            try facade.withPhotoSnapshot(path: photo.path) { snapshot in
                #expect(throws: (any Error).self) { try MCPProcessReservation.acquirePhoto(photo) }
                #expect(snapshot.sourceBytes == Data("source".utf8))
                if parserFails { throw MCPAutomationReadError.unreadableDraft }
                return "parsed"
            }
        }
        if parserFails {
            #expect(throws: MCPAutomationReadError.self) { try parse() }
        } else {
            #expect(try parse() == "parsed")
        }
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
    }

    @Test("Changes during parsing refuse provisional results",
          arguments: ["source", "xmp", "new-xmp", "app", "new-app", "authorization", "ancestor"])
    func parsedPublicationRevalidation(change: String) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let photo = folder.appendingPathComponent("frame.jpg")
        let xmp = folder.appendingPathComponent("frame.xmp")
        let appFolder = folder.appendingPathComponent(".photo_metadata")
        let app = appFolder.appendingPathComponent("frame.jpg.meta.json")
        try Data("source".utf8).write(to: photo)
        if change == "xmp" { try Data("xmp".utf8).write(to: xmp) }
        let draft = Data("{\"schemaVersion\":1,\"sourceFile\":\"frame.jpg\",\"pendingChanges\":true,\"metadata\":{}}".utf8)
        if change == "app" {
            try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: false)
            try draft.write(to: app)
        }
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        #expect(throws: (any Error).self) {
            try facade.withPhotoSnapshot(path: photo.path) { _ in
                switch change {
                case "source": try Data("changed".utf8).write(to: photo)
                case "xmp", "new-xmp": try Data("changed".utf8).write(to: xmp)
                case "app": try Data("changed".utf8).write(to: app)
                case "new-app":
                    try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: false)
                    try draft.write(to: app)
                case "authorization": try store.setEnabled(false)
                default:
                    try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("moved"))
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    try Data("source".utf8).write(to: photo)
                }
                return "must not be published"
            }
        }
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
    }

    @Test("Parser snapshots retain exact carrier bytes and matching revisions", arguments: ["current", "legacy", "foreign", "absent"])
    func capturesImmutableParserInput(carrier: String) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        let xmp = root.appendingPathComponent("frame.xmp")
        let source = Data([0, 255, 1, 2, 3])
        let xmpData = Data("<xmp>exact Unicode: æøå</xmp>".utf8)
        try source.write(to: photo)
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let xmpDate = sourceDate.addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: sourceDate], ofItemAtPath: photo.path)
        if carrier != "absent" {
            try xmpData.write(to: xmp)
            try FileManager.default.setAttributes([.modificationDate: xmpDate], ofItemAtPath: xmp.path)
        }
        let owned = carrier == "current" || carrier == "legacy"
        let owner = owned ? "frame.jpg" : "other.jpg"
        let draft = Data("{\"schemaVersion\":1,\"sourceFile\":\"\(owner)\",\"pendingChanges\":true,\"metadata\":{\"caption\":\"exact\"}}".utf8)
        if carrier != "absent" {
            let folder = root.appendingPathComponent(".photo_metadata")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try draft.write(to: folder.appendingPathComponent(carrier == "current" ? "frame.jpg.meta.json" : "frame.meta.json"))
        }
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let snapshot = try facade.capturePhotoSnapshot(path: photo.path)
        let revision = try #require(facade.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(snapshot.sourceBytes == source)
        #expect(snapshot.xmpBytes == (carrier == "absent" ? nil : xmpData))
        #expect(snapshot.appSidecarBytes == (owned ? draft : nil))
        #expect(revision["sourceRevision"] == .string(snapshot.sourceRevision))
        #expect(revision["xmpSidecarRevision"] == .string(snapshot.xmpSidecarRevision))
        #expect(revision["appSidecarRevision"] == .string(snapshot.appSidecarRevision))
        #expect(snapshot.sourceModificationDate == sourceDate)
        #expect(snapshot.xmpModificationDate == (carrier == "absent" ? nil : xmpDate))
        try Data("replacement".utf8).write(to: photo)
        #expect(snapshot.sourceBytes == source)
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
    }

    @Test("Parser snapshots distinguish empty carriers from absent carriers", arguments: [0, Int(MCPPhotoCarrierSnapshot.maximumXMPBytes)])
    func admitsBoundedParserInput(xmpSize: Int) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        let xmp = root.appendingPathComponent("frame.xmp")
        try Data().write(to: photo)
        let bytes = Data(repeating: 32, count: xmpSize)
        try bytes.write(to: xmp)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store)
        let present = try facade.capturePhotoSnapshot(path: photo.path)
        #expect(present.sourceBytes.isEmpty)
        #expect(present.xmpBytes == bytes)
        #expect(present.xmpModificationDate != nil)
        try FileManager.default.removeItem(at: xmp)
        let absent = try facade.capturePhotoSnapshot(path: photo.path)
        #expect(absent.xmpBytes == nil)
        #expect(absent.xmpSidecarRevision != present.xmpSidecarRevision)
    }

    @Test("Parser snapshots refuse oversized source and XMP before allocating their bytes", arguments: ["source", "xmp"])
    func refusesOversizedParserInput(carrier: String) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("photo".utf8).write(to: photo)
        let oversized = carrier == "source" ? photo : root.appendingPathComponent("frame.xmp")
        if carrier == "xmp" { try Data().write(to: oversized) }
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(carrier == "source"
            ? MCPPhotoCarrierSnapshot.maximumSourceBytes + 1
            : MCPPhotoCarrierSnapshot.maximumXMPBytes + 1))
        try handle.close()
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        #expect(throws: MCPAutomationReadError.unsafeCarrier) {
            _ = try MCPAutomationFacade(authorizationStore: store).capturePhotoSnapshot(path: photo.path)
        }
        if carrier == "xmp" {
            // Revision-only inspection still streams carriers beyond the parser retention cap.
            #expect(try MCPAutomationFacade(authorizationStore: store)
                .inspectPhotoRevision(path: photo.path).objectValue?["xmpSidecarPresent"] == .bool(true))
        }
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
    }

    @Test("Parser snapshots refuse a changed carrier or revoked authorization before publication", arguments: ["source", "xmp", "app", "authorization"])
    func refusesChangedParserSnapshot(carrier: String) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        let xmp = root.appendingPathComponent("frame.xmp")
        let folder = root.appendingPathComponent(".photo_metadata")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let app = folder.appendingPathComponent("frame.jpg.meta.json")
        try Data("photo".utf8).write(to: photo)
        try Data("xmp".utf8).write(to: xmp)
        try Data(#"{"schemaVersion":1,"sourceFile":"frame.jpg","pendingChanges":true,"metadata":{}}"#.utf8).write(to: app)
        let store = store()
        try store.addRoot(root)
        try store.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: store, onCaptureCheckpoint: {
            do {
                if carrier == "authorization" { try store.setEnabled(false) }
                else { try Data("changed".utf8).write(to: carrier == "source" ? photo : carrier == "xmp" ? xmp : app) }
            } catch { Issue.record("Could not inject snapshot change: \(error)") }
        })
        if carrier == "authorization" {
            #expect(throws: MCPAuthorizationError.disabled) { _ = try facade.capturePhotoSnapshot(path: photo.path) }
        } else {
            #expect(throws: MCPAutomationReadError.photoChanged) { _ = try facade.capturePhotoSnapshot(path: photo.path) }
        }
        let lease = try MCPProcessReservation.acquirePhoto(photo)
        lease.release()
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

    @Test("FIFO sidecars are refused without waiting for a writer", arguments: ["xmp", "current", "legacy"])
    func refusesFIFOWithoutBlocking(carrier: String) throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.jpg")
        try Data("photo".utf8).write(to: photo)
        let privateFolder = root.appendingPathComponent(".photo_metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: false)
        let fifo = carrier == "xmp" ? root.appendingPathComponent("frame.xmp")
            : privateFolder.appendingPathComponent(carrier == "current" ? "frame.jpg.meta.json" : "frame.meta.json")
        try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authorization)
        let completed = DispatchSemaphore(value: 0)
        let outcome = DataBox()
        DispatchQueue.global().async {
            defer { completed.signal() }
            do {
                _ = try facade.inspectPhotoRevision(path: photo.path)
                outcome.write(Data("unexpected-success".utf8))
            } catch MCPAutomationReadError.unsafeCarrier {
                outcome.write(Data("unsafe-carrier".utf8))
            } catch {
                outcome.write(Data("unexpected-error".utf8))
            }
        }
        let finishedWithoutWriter = completed.wait(timeout: .now() + 2) == .success
        #expect(finishedWithoutWriter)
        if !finishedWithoutWriter {
            // Unblock the old implementation so a regression fails instead of hanging the suite.
            let rescue = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            defer { if rescue >= 0 { _ = Darwin.close(rescue) } }
            try #require(completed.wait(timeout: .now() + 2) == .success)
        }
        #expect(outcome.read() == Data("unsafe-carrier".utf8))
        try FileManager.default.removeItem(at: fifo)
        // The refusal must also release the shared photo lease for the next request.
        #expect(try facade.inspectPhotoRevision(path: photo.path).objectValue?["appSidecarDraftState"] == .string("absent"))
    }

    @Test("Carrier streaming accepts short chunks and limits each read to the captured length")
    func boundedCarrierShortReads() throws {
        var remaining = 1_048_579
        var consumed = 0
        var requests: [Int] = []
        try MCPBoundedCarrierReader.read(byteCount: Int64(remaining), readChunk: { requested in
            requests.append(requested)
            let count = min(remaining, min(requested, 524_288))
            remaining -= count
            return Data(repeating: 42, count: count)
        }, consume: { consumed += $0.count })
        #expect(consumed == 1_048_579)
        #expect(requests == [1_048_576, 524_291, 3, 1])
    }

    @Test("Carrier growth is bounded to one probe byte and never consumed as evidence")
    func boundedCarrierGrowth() throws {
        var requestedBytes = 0
        var consumed = 0
        #expect(throws: MCPAutomationReadError.photoChanged) {
            try MCPBoundedCarrierReader.read(byteCount: 3, readChunk: { requested in
                requestedBytes += requested
                // Models a writer that always supplies more bytes, never EOF.
                return Data(repeating: 42, count: requested)
            }, consume: { consumed += $0.count })
        }
        #expect(requestedBytes == 4)
        #expect(consumed == 3)
    }

    @Test("Carrier truncation and invalid sizes refuse evidence")
    func boundedCarrierTruncation() throws {
        #expect(throws: MCPAutomationReadError.photoChanged) {
            try MCPBoundedCarrierReader.read(byteCount: 1, readChunk: { _ in nil }, consume: { _ in
                Issue.record("A truncated carrier must not publish bytes")
            })
        }
        #expect(throws: MCPAutomationReadError.unsafeCarrier) {
            try MCPBoundedCarrierReader.read(byteCount: -1, readChunk: { _ in
                Issue.record("An invalid captured size must not read")
                return nil
            }, consume: { _ in })
        }
        try MCPBoundedCarrierReader.read(byteCount: 0, readChunk: { requested in
            #expect(requested == 1)
            return nil
        }, consume: { _ in Issue.record("An empty carrier must not publish bytes") })
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

    @Test("Retargeting a nested ancestor during carrier capture refuses publication")
    func refusesRetargetedPhotoAncestor() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("case", isDirectory: true)
        let nested = parent.appendingPathComponent("selection", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let photo = nested.appendingPathComponent("frame.jpg")
        let xmp = nested.appendingPathComponent("frame.xmp")
        try Data("original photo".utf8).write(to: photo)
        try Data("original sidecar".utf8).write(to: xmp)
        let authorization = store()
        try authorization.addRoot(root)
        try authorization.setEnabled(true)
        let stable = MCPAutomationFacade(authorizationStore: authorization)
        let before = try #require(stable.inspectPhotoRevision(path: photo.path).objectValue)

        let relocated = root.appendingPathComponent("relocated", isDirectory: true)
        let replacement = parent.appendingPathComponent("selection", isDirectory: true)
        let racing = MCPAutomationFacade(authorizationStore: authorization) {
            try! FileManager.default.moveItem(at: nested, to: relocated)
            try! FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            try! Data("replacement photo".utf8).write(to: replacement.appendingPathComponent("frame.jpg"))
        }
        #expect(throws: MCPAutomationReadError.photoChanged) {
            _ = try racing.inspectPhotoRevision(path: photo.path)
        }
        try FileManager.default.removeItem(at: replacement)
        try FileManager.default.moveItem(at: relocated, to: nested)
        let after = try #require(stable.inspectPhotoRevision(path: photo.path).objectValue)
        #expect(after["sourceRevision"] == before["sourceRevision"])
        #expect(after["xmpSidecarRevision"] == before["xmpSidecarRevision"])
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
