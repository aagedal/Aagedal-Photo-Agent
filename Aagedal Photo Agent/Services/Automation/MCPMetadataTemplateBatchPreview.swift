import Foundation

/// Bounded all-or-error preview. Every photo reservation and anchored carrier snapshot
/// remains retained through template inventory revalidation. No partial result escapes.
nonisolated enum MCPMetadataTemplateBatchPreview {
    static let maximumPhotos = 8
    static let maximumRetainedBytes = 268_435_456
    static let argumentKeys: Set<String> = ["templateID", "templateRevision", "mode", "photos"]
    static let photoKeys: Set<String> = ["path", "sourceRevision", "xmpSidecarRevision", "appSidecarRevision"]

    static func requests(arguments: [String: MCPJSONValue]) throws -> [MCPMetadataTemplatePreview.Request] {
        guard Set(arguments.keys) == argumentKeys,
              case .array(let photos) = arguments["photos"], !photos.isEmpty,
              photos.count <= maximumPhotos else { throw MCPMetadataTemplatePreview.Failure.invalidArguments }
        var identities = Set<String>()
        return try photos.map { photo in
            guard let object = photo.objectValue, Set(object.keys) == photoKeys else {
                throw MCPMetadataTemplatePreview.Failure.invalidArguments
            }
            var single = arguments
            single.removeValue(forKey: "photos")
            single.merge(object) { _, new in new }
            let request = try MCPMetadataTemplatePreview.Request(arguments: single)
            // RAW/JPEG siblings share XMP and the production reservation. Reject them
            // together rather than trying to acquire our own already-held lease.
            let key = URL(fileURLWithPath: request.path).standardizedFileURL.deletingPathExtension().path.lowercased()
            guard identities.insert(key).inserted else { throw MCPMetadataTemplatePreview.Failure.invalidArguments }
            return request
        }
    }

    static func prepare(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade,
                        discovery: MCPTemplateDiscovery,
                        maximumBytes: Int = maximumRetainedBytes) throws -> MCPJSONValue {
        let requests = try requests(arguments: arguments)
        let ordered = requests.indices.sorted { requests[$0].path < requests[$1].path }
        let limit = min(max(0, maximumBytes), maximumRetainedBytes)
        var snapshots: [Int: MCPPhotoCarrierSnapshot] = [:]

        func retain(_ position: Int, bytes: Int) throws -> MCPJSONValue {
            try Task.checkCancellation()
            if position < ordered.count {
                let index = ordered[position]
                return try facade.withPhotoSnapshot(path: requests[index].path) { snapshot in
                    let count = snapshot.sourceBytes.count + (snapshot.xmpBytes?.count ?? 0) + (snapshot.appSidecarBytes?.count ?? 0)
                    guard count <= limit - bytes else { throw MCPMetadataTemplatePreview.Failure.outputLimit }
                    guard requests[index].revisions == ["sourceRevision": .string(snapshot.sourceRevision),
                        "xmpSidecarRevision": .string(snapshot.xmpSidecarRevision),
                        "appSidecarRevision": .string(snapshot.appSidecarRevision)] else {
                        throw MCPMetadataTemplatePreview.Failure.staleRevision
                    }
                    snapshots[index] = snapshot
                    defer { snapshots.removeValue(forKey: index) }
                    return try retain(position + 1, bytes: bytes + count)
                }
            }
            let first = requests[0]
            return try discovery.withMetadataTemplate(id: first.templateID, revision: first.templateRevision) { data in
                let fields = try MCPMetadataTemplatePreview.templateFields(data)
                let previews = try requests.indices.map { index -> MCPJSONValue in
                    try Task.checkCancellation()
                    guard let snapshot = snapshots[index] else { throw MCPMetadataTemplatePreview.Failure.invalidArguments }
                    return try MCPMetadataTemplatePreview.preview(request: requests[index], templateFields: fields,
                        metadata: MCPMetadataSnapshotReader.read(snapshot).protocolValue())
                }
                let result = MCPJSONValue.object([
                    "schemaVersion": .integer(1), "previewOnly": .bool(true), "commitAvailable": .bool(false),
                    "photos": .array(previews), "photoCount": .integer(Int64(previews.count)),
                    "warnings": .array([.string("Read-only batch preview in requested order. Every photo and the exact template are revalidated; no plan, approval, pending draft or publication is created.")]),
                ])
                guard try JSONEncoder().encode(result).count <= MCPServerConstants.maximumToolResultBytes else {
                    throw MCPMetadataTemplatePreview.Failure.outputLimit
                }
                return result
            }
        }
        return try retain(0, bytes: 0)
    }
}
