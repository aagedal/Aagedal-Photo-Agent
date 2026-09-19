import Foundation

/// Evidence belongs to the bytes that were decoded, not a later read of the same path.
nonisolated struct TemplateFileAuthority: Equatable, Sendable {
    let directoryIdentity: TemplateDirectoryIdentity
    let fileURL: URL
    let bytes: Data
}

nonisolated struct TemplateDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let created: Date?

    static func read(at url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return Self(device: device.uint64Value, inode: inode.uint64Value,
                    created: attributes[.creationDate] as? Date)
    }
}

nonisolated struct TemplateFileInventory<Value: Sendable>: Sendable {
    let templates: [Value]
    let authorities: [UUID: TemplateFileAuthority]
    var occupiedFileIDs: Set<UUID> = []
}

nonisolated extension TemplateFileInventory where Value: Decodable & Identifiable, Value.ID == UUID {
    static func read(at directory: URL, sorted: @Sendable ([Value]) -> [Value]) throws -> Self {
        let identity = try TemplateDirectoryIdentity.read(at: directory)
        let files = try CloudCoordinatedIO.contentsOfDirectory(at: directory)
            .filter { $0.pathExtension.lowercased() == "json" }
        var templates: [Value] = []
        var authorities: [UUID: TemplateFileAuthority] = [:]
        var seen: Set<UUID> = []
        var occupiedFileIDs: Set<UUID> = []
        for file in files {
            // Physical occupancy protects unreadable or mismatched documents too.
            // On case-insensitive filesystems, UUID spelling must not bypass it.
            if let fileID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
                occupiedFileIDs.insert(fileID)
            }
            guard let bytes = try? CloudCoordinatedIO.readData(at: file),
                  let value = try? JSONDecoder().decode(Value.self, from: bytes) else { continue }
            templates.append(value)
            // Mutators address UUID.json. Noncanonical and duplicate records remain
            // visible but cannot confer permission to mutate a different file.
            let canonical = directory.appendingPathComponent("\(value.id.uuidString).json")
            if seen.insert(value.id).inserted, file.standardizedFileURL == canonical.standardizedFileURL {
                authorities[value.id] = TemplateFileAuthority(directoryIdentity: identity, fileURL: canonical, bytes: bytes)
            } else {
                authorities[value.id] = nil
            }
        }
        guard try TemplateDirectoryIdentity.read(at: directory) == identity else {
            throw CocoaError(.fileReadUnknown)
        }
        return Self(templates: sorted(templates), authorities: authorities, occupiedFileIDs: occupiedFileIDs)
    }
}
