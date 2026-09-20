import CoreFoundation
import Darwin
import Foundation

/// Create-only access to the shared Team record format. No caller-controlled filesystem paths.
nonisolated struct MCPTeamLibrary: Sendable {
    static let didCreateNotification = "com.aagedal.photo-agent.teams-created"
    enum Failure: String, LocalizedError {
        case teamCreationDisabled = "team_creation_disabled"
        case cloudLibraryUnavailable = "cloud_library_unavailable"
        case invalidArguments = "invalid_arguments"
        case teamAlreadyExists = "team_already_exists"
        case storageUnavailable = "team_storage_unavailable"
        case reviewQueueFull = "team_review_queue_full"

        var errorDescription: String? {
            switch self {
            case .teamCreationDisabled: "Enable local automation and Allow team creation in Photo Agent Settings."
            case .cloudLibraryUnavailable: "Team creation requires Teams iCloud sync to be off; the cloud library was not modified."
            case .invalidArguments: "Supply a UUID teamID, nonempty name, supported sport, RGB colours in 0...1 and up to 1,000 uniquely numbered players (0...9999) with nonempty names."
            case .teamAlreadyExists: "This teamID already exists with different content or was deleted. Use a new UUID to create another team."
            case .storageUnavailable: "The Teams storage is unavailable or changed. Refresh the review and try again."
            case .reviewQueueFull: "Review pending team imports in Photo Agent before submitting more teams."
            }
        }
    }

    let authorizationStore: MCPAuthorizationStore
    var resolveDirectory: @Sendable () throws -> URL = Self.localDirectory
    var resolveReviewDirectory: @Sendable () throws -> URL = MCPTeamReviewQueue.defaultDirectory

    static func localDirectory() throws -> URL {
        let cloud = CFPreferencesCopyAppValue("teams.iCloudEnabled" as CFString, MCPServerConstants.preferencesSuiteName as CFString)
        guard cloud == nil || (cloud as? Bool) == false else { throw Failure.cloudLibraryUnavailable }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.storageUnavailable
        }
        return base.appendingPathComponent("Aagedal Photo Agent/Teams/teams", isDirectory: true)
    }

    static var properties: [String: MCPJSONValue] {
        let color: MCPJSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array(["r", "g", "b"].map(MCPJSONValue.string)),
            "properties": .object(Dictionary(uniqueKeysWithValues: ["r", "g", "b"].map {
                ($0, .object(["type": .string("number"), "minimum": .integer(0), "maximum": .integer(1)]))
            })),
        ])
        let name: MCPJSONValue = .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(256)])
        return [
            "teamID": .object(["type": .string("string"), "format": .string("uuid"), "description": .string("Client-generated UUID; reuse the same ID and content when retrying.")]),
            "name": name,
            "sport": .object(["type": .string("string"), "enum": .array(TeamSport.allCases.map { .string($0.rawValue) })]),
            "primaryColor": color, "secondaryColor": color, "goalkeeperColor": color,
            "roster": .object([
                "type": .string("array"), "maxItems": .integer(1_000),
                "items": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "required": .array([.string("number"), .string("playerName")]),
                    "properties": .object([
                        "number": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(9999)]),
                        "playerName": name,
                    ]),
                ]),
            ]),
        ]
    }

    static func parse(_ arguments: [String: MCPJSONValue]) throws -> Team {
        func name(_ value: MCPJSONValue?) throws -> String {
            guard let raw = value?.stringValue else { throw Failure.invalidArguments }
            let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, raw.count <= 256, raw.utf8.count <= 1_024, !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalidArguments }
            return result
        }
        func color(_ value: MCPJSONValue?) throws -> TeamKitColor {
            guard let object = value?.objectValue, Set(object.keys) == ["r", "g", "b"] else { throw Failure.invalidArguments }
            func component(_ key: String) throws -> Double {
                let number: Double
                switch object[key] {
                case .integer(let value): number = Double(value)
                case .number(let value): number = value
                default: throw Failure.invalidArguments
                }
                guard number.isFinite, (0...1).contains(number) else { throw Failure.invalidArguments }
                return number
            }
            return try TeamKitColor(r: component("r"), g: component("g"), b: component("b"))
        }
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)),
              let idString = arguments["teamID"]?.stringValue, let id = UUID(uuidString: idString),
              let sportString = arguments["sport"]?.stringValue, let sport = TeamSport(rawValue: sportString),
              case .array(let rows) = arguments["roster"], rows.count <= 1_000 else { throw Failure.invalidArguments }
        var numbers = Set<Int64>()
        let roster = try rows.map { row -> RosterPlayer in
            guard let object = row.objectValue, Set(object.keys) == ["number", "playerName"],
                  case .integer(let number) = object["number"], (0...9999).contains(number),
                  numbers.insert(number).inserted else { throw Failure.invalidArguments }
            return try RosterPlayer(number: Int(number), playerName: name(object["playerName"]))
        }.sorted { $0.number < $1.number }
        return try Team(id: id, name: name(arguments["name"]), primaryColor: color(arguments["primaryColor"]),
                        secondaryColor: arguments["secondaryColor"].map { try color($0) },
                        goalkeeperColor: arguments["goalkeeperColor"].map { try color($0) }, sport: sport, roster: roster)
    }

    func create(arguments: [String: MCPJSONValue]) throws -> [String: MCPJSONValue] {
        let configuration = try authorizationStore.load()
        guard configuration.isEnabled, configuration.allowsTeamCreation == true else { throw Failure.teamCreationDisabled }
        let team = try Self.parse(arguments)
        let directory: URL
        do { directory = try resolveDirectory() }
        catch Failure.cloudLibraryUnavailable {
            return try MCPTeamReviewQueue(directory: resolveReviewDirectory()).submit(arguments: arguments, authorizationStore: authorizationStore)
        }
        // Once queued, retries keep their manual-review lifecycle even if sync is switched off.
        let reviewDirectory = try resolveReviewDirectory()
        if directory != reviewDirectory,
           FileManager.default.fileExists(atPath: reviewDirectory.appendingPathComponent(team.id.uuidString + ".json").path) {
            return try MCPTeamReviewQueue(directory: reviewDirectory).submit(arguments: arguments, authorizationStore: authorizationStore)
        }
        let reservation = try MCPProcessReservation.acquireFolder(directory)
        defer { reservation.release() }
        // Walk from / with no-follow descriptors; never follow a replaced ancestor or file.
        var descriptors = [Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)]
        defer { descriptors.reversed().forEach { _ = Darwin.close($0) } }
        guard descriptors[0] >= 0 else { throw Failure.storageUnavailable }
        let components = directory.pathComponents.dropFirst()
        for component in components {
            let parent = descriptors.last!
            if Darwin.mkdirat(parent, component, 0o700) != 0 && errno != EEXIST { throw Failure.storageUnavailable }
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.storageUnavailable }
            descriptors.append(next)
        }
        let fd = descriptors.last!
        let filename = team.id.uuidString + ".json"
        var info = stat()
        guard Darwin.fstatat(fd, team.id.uuidString + ".deleted", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw Failure.teamAlreadyExists }
        let existing = Darwin.openat(fd, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 {
            let handle = FileHandle(fileDescriptor: existing, closeOnDealloc: true)
            defer { try? handle.close() }
            guard Darwin.fstat(existing, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, info.st_size <= 2_097_152,
                  let bytes = try handle.read(upToCount: 2_097_153), bytes.count <= 2_097_152,
                  let saved = try? JSONDecoder().decode(Team.self, from: bytes) else { throw Failure.storageUnavailable }
            guard saved.id == team.id, saved.name == team.name, saved.sport == team.sport,
                  saved.primaryColor == team.primaryColor, saved.secondaryColor == team.secondaryColor,
                  saved.goalkeeperColor == team.goalkeeperColor,
                  saved.roster.sorted(by: { $0.number < $1.number }).map({ "\($0.number):\($0.playerName)" }) == team.roster.map({ "\($0.number):\($0.playerName)" }) else { throw Failure.teamAlreadyExists }
            try validate(configuration: configuration, directory: directory, descriptors: descriptors)
            return result(team, created: false)
        }
        guard errno == ENOENT else { throw Failure.storageUnavailable }
        let temporary = ".mcp-\(UUID().uuidString).tmp"
        let output = Darwin.openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.storageUnavailable }
        defer { _ = Darwin.unlinkat(fd, temporary, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(team))
        try handle.synchronize()
        try validate(configuration: configuration, directory: directory, descriptors: descriptors)
        // Atomic publication that cannot overwrite an existing record, including a racing writer.
        guard Darwin.linkat(fd, temporary, fd, filename, 0) == 0 else {
            throw errno == EEXIST ? Failure.teamAlreadyExists : Failure.storageUnavailable
        }
        _ = Darwin.unlinkat(fd, temporary, 0)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(Self.didCreateNotification), object: nil, userInfo: nil, deliverImmediately: true)
        return result(team, created: true)
    }

    private func validate(configuration: MCPAuthorizationConfiguration, directory: URL, descriptors: [Int32]) throws {
        guard try authorizationStore.load() == configuration, try resolveDirectory() == directory else { throw Failure.teamCreationDisabled }
        for (index, component) in directory.pathComponents.dropFirst().enumerated() {
            var pathInfo = stat(), openedInfo = stat()
            guard Darwin.fstatat(descriptors[index], component, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  Darwin.fstat(descriptors[index + 1], &openedInfo) == 0,
                  (pathInfo.st_mode & S_IFMT) == S_IFDIR,
                  pathInfo.st_dev == openedInfo.st_dev, pathInfo.st_ino == openedInfo.st_ino else { throw Failure.storageUnavailable }
        }
    }

    private func result(_ team: Team, created: Bool) -> [String: MCPJSONValue] {
        ["teamID": .string(team.id.uuidString.lowercased()), "name": .string(team.name),
         "playerCount": .integer(Int64(team.roster.count)), "created": .bool(created), "storage": .string("local")]
    }
}

/// Local, immutable requests awaiting an in-app decision. The helper never touches iCloud.
nonisolated struct MCPTeamReviewQueue: Sendable {
    let directory: URL

    static func defaultDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MCPTeamLibrary.Failure.storageUnavailable
        }
        return base.appendingPathComponent("Aagedal Photo Agent/Automation/TeamImports", isDirectory: true)
    }

    func submit(arguments: [String: MCPJSONValue], authorizationStore: MCPAuthorizationStore) throws -> [String: MCPJSONValue] {
        // Reuse the validated, atomic create-only writer for the local proposal, never the cloud library.
        let team = try MCPTeamLibrary.parse(arguments)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        if !entries.contains(where: { $0.lastPathComponent == team.id.uuidString + ".json" }) {
            var pendingCount = 0
            for entry in entries where entry.pathExtension == "json" {
                if let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent), try decision(for: id) == nil {
                    pendingCount += 1
                }
                guard pendingCount < 256 else { throw MCPTeamLibrary.Failure.reviewQueueFull }
            }
        }
        let writer = MCPTeamLibrary(authorizationStore: authorizationStore, resolveDirectory: { directory }, resolveReviewDirectory: { directory })
        _ = try writer.create(arguments: arguments)
        let status = try decision(for: team.id) ?? "awaiting_confirmation"
        return ["teamID": .string(team.id.uuidString.lowercased()), "name": .string(team.name),
                "playerCount": .integer(Int64(team.roster.count)), "status": .string(status),
                "created": .bool(status == "accepted"), "storage": .string("app-managed"),
                "nextAction": .string(status == "awaiting_confirmation"
                    ? "Open Teams in Photo Agent, choose Review Imports, inspect the roster and click Add Team. The app saves to the selected local or iCloud library. Retry this call with the same teamID and content to check the outcome."
                    : "This request has already been reviewed in Photo Agent.")]
    }

    func pending() throws -> [Team] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var teams: [Team] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                  try decision(for: id) == nil else { continue }
            guard teams.count < 256 else { throw MCPTeamLibrary.Failure.storageUnavailable }
            let data = try read(entry, limit: 2_097_152)
            let team = try JSONDecoder().decode(Team.self, from: data)
            guard team.id == id, team.roster.allSatisfy({ $0.knownPersonID == nil }) else {
                throw MCPTeamLibrary.Failure.invalidArguments
            }
            teams.append(team)
        }
        return teams.sorted { $0.createdAt < $1.createdAt }
    }

    func decision(for id: UUID) throws -> String? {
        let url = receiptURL(id)
        var info = stat()
        if Darwin.lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw MCPTeamLibrary.Failure.storageUnavailable }
            return nil
        }
        let data = try read(url, limit: 32)
        guard let status = String(data: data, encoding: .utf8), ["accepted", "rejected"].contains(status) else {
            throw MCPTeamLibrary.Failure.storageUnavailable
        }
        return status
    }

    /// Called only by the app following a local UI decision, never exposed as an MCP tool.
    func finish(_ team: Team, accepted: Bool) throws {
        let requested = accepted ? "accepted" : "rejected"
        if let existing = try decision(for: team.id) {
            guard existing == requested else { throw MCPTeamLibrary.Failure.teamAlreadyExists }
            return
        }
        try Data(requested.utf8).write(to: receiptURL(team.id), options: .atomic)
    }

    private func receiptURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".decision")
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MCPTeamLibrary.Failure.storageUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size <= limit, let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw MCPTeamLibrary.Failure.storageUnavailable
        }
        return data
    }
}
