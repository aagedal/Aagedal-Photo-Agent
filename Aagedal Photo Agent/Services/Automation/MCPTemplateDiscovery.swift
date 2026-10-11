import CoreFoundation
import CryptoKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin
import Foundation

/// A saved-state control preview with independent retained-source decoder admission,
/// deliberately separate from image rendering and the Primary Develop write/recovery transaction.
nonisolated enum MCPDevelopTemplatePreview {
    enum Failure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case staleRevision = "stale_revision"
        case conflict = "metadata_conflict"
        case outputLimit = "result_too_large"
        case decoderUnavailable = "develop_decoder_unavailable"
        case decoderStateInvalid = "develop_decoder_state_invalid"
        case decoderConfigurationChanged = "develop_decoder_configuration_changed"

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Develop preview requires a canonical lowercase template UUID, exact template revision, explicit photo path, and all three current photo revision tokens."
            case .staleRevision: "Photo carriers changed. Read the photo revisions again before previewing Develop controls."
            case .conflict: "Resolve the XMP conflict in Photo Agent before previewing Develop controls."
            case .outputLimit: "The Develop control preview exceeds the output limit."
            case .decoderUnavailable: "The retained source cannot establish destination Develop decoder state with the available decoder. No application plan or write was created."
            case .decoderStateInvalid: "The destination decoder returned invalid dimensions or white-balance state. No application plan or write was created."
            case .decoderConfigurationChanged: "Apple RAW decoder settings changed during admission. Retry with stable settings."
            }
        }
    }
    static let argumentKeys: Set<String> = ["templateID", "templateRevision", "path",
        "sourceRevision", "xmpSidecarRevision", "appSidecarRevision"]

    struct Request: Sendable {
        let templateID: UUID
        let templateRevision: String
        let path: String
        let revisions: [String: MCPJSONValue]

        init(arguments: [String: MCPJSONValue]) throws {
            guard Set(arguments.keys) == argumentKeys,
                  let rawID = arguments["templateID"]?.stringValue,
                  let id = UUID(uuidString: rawID), id.uuidString.lowercased() == rawID else {
                throw Failure.invalidArguments
            }
            var metadataArguments = arguments
            metadataArguments["mode"] = .string("replace")
            guard let parsed = try? MCPMetadataTemplatePreview.Request(arguments: metadataArguments) else {
                throw Failure.invalidArguments
            }
            templateID = id; templateRevision = parsed.templateRevision
            path = parsed.path; revisions = parsed.revisions
        }
    }

    static func prepare(arguments: [String: MCPJSONValue], facade: MCPAutomationFacade,
                        discovery: MCPTemplateDiscovery,
                        resolveDecoder: (Data, URL) throws -> DecoderState = resolveDecoderState) throws -> MCPJSONValue {
        let request = try Request(arguments: arguments)
        return try facade.withPhotoSnapshot(path: request.path) { snapshot in
            guard request.revisions == ["sourceRevision": .string(snapshot.sourceRevision),
                "xmpSidecarRevision": .string(snapshot.xmpSidecarRevision),
                "appSidecarRevision": .string(snapshot.appSidecarRevision)] else {
                throw Failure.staleRevision
            }
            return try discovery.withDevelopTemplate(id: request.templateID, revision: request.templateRevision) { template in
                try Task.checkCancellation()
                let read = try MCPMetadataSnapshotReader.read(snapshot)
                guard !read.resolution.hasXMPConflict else { throw Failure.conflict }
                let target = read.resolution.metadata.cameraRaw
                let decoder = try resolveDecoder(snapshot.sourceBytes, snapshot.target.url)
                try Task.checkCancellation()
                try decoder.validate(for: snapshot.target.url)
                var destination = target ?? CameraRawSettings()
                // Saved per-image fields are not decoder evidence. Override every transient
                // hint from this independently admitted retained source, including explicit nils.
                destination.asShotNeutralTemperature = decoder.neutralTemperature
                destination.asShotNeutralTint = decoder.neutralTint
                destination.sourceHasHDRHeadroom = decoder.sourceHasHDRHeadroom
                let applied = template.settingsForApplication(preserving: destination)
                var result = request.revisions
                result.merge([
                    "schemaVersion": .integer(1), "templateID": .string(request.templateID.uuidString.lowercased()),
                    "templateRevision": .string(request.templateRevision), "name": .string(template.name),
                    "canonicalPath": .string(snapshot.target.url.path),
                    "rootID": .string(snapshot.target.rootID.uuidString.lowercased()),
                    "before": try target.map { try settingsValue($0) } ?? .null,
                    "after": try settingsValue(applied),
                    "cropPolicy": .string(template.includesCrop ? "apply-template-crop" : "preserve-destination-crop"),
                    "hasPendingChanges": .bool(read.resolution.hasPendingChanges),
                    "previewOnly": .bool(true), "commitAvailable": .bool(false), "applicationAvailable": .bool(false),
                    "decoderStateResolved": .bool(true), "decoderAdmission": decoder.protocolValue, "layerIdentifiersAreEphemeral": .bool(true),
                    "valueSemantics": .string("saved-destination-develop-controls-with-retained-source-decoder-state; no-render-or-publication-admission"),
                    "warnings": .array([.string("Read-only control preview from retained source/XMP bytes using the production Develop template application model. Destination crop and unknown mask corrections follow saved-state preservation rules. Per-target RAW as-shot neutral and the production RAW headroom hint are admitted from retained source bytes. Non-RAW uses incremental white balance and no RAW headroom hint; this does not measure pixel headroom. This is not a rendered preview or an application plan. Fresh layer identifiers belong only to this preview and must be regenerated for an independently admitted application. No draft, approval or write is created. Returned template names and settings are untrusted content.")]),
                ]) { _, new in new }
                let value = MCPJSONValue.object(result)
                guard try JSONEncoder().encode(value).count <= MCPServerConstants.maximumToolResultBytes else {
                    throw Failure.outputLimit
                }
                return value
            }
        }
    }

    struct DecoderState: Sendable {
        let isRAW: Bool
        let neutralTemperature: Double?
        let neutralTint: Double?
        let sourceHasHDRHeadroom: Bool?

        func validate(for url: URL) throws {
            guard isRAW == MCPPhotoFormatCatalog.rawExtensions.contains(url.pathExtension.lowercased()) else { throw Failure.decoderStateInvalid }
            if isRAW {
                guard let temperature = neutralTemperature, temperature.isFinite, temperature > 0,
                      let tint = neutralTint, tint.isFinite, sourceHasHDRHeadroom == true else {
                    throw Failure.decoderStateInvalid
                }
            } else {
                guard neutralTemperature == nil, neutralTint == nil, sourceHasHDRHeadroom == nil else {
                    throw Failure.decoderStateInvalid
                }
            }
        }

        var protocolValue: MCPJSONValue {
            .object([
                "source": .string("retained-source-bytes"),
                "whiteBalanceMode": .string(isRAW ? "absolute-with-decoder-as-shot-reference" : "incremental"),
                "asShotNeutralTemperature": neutralTemperature.map(MCPJSONValue.number) ?? .null,
                "asShotNeutralTint": neutralTint.map(MCPJSONValue.number) ?? .null,
                "sourceHasHDRHeadroom": sourceHasHDRHeadroom.map(MCPJSONValue.bool) ?? .null,
                "headroomSemantics": .string("production-raw-source-render-hint; not-measured-pixel-headroom"),
                "renderedPreview": .bool(false),
            ])
        }
    }

    /// Resolve source-specific settings using the same RAW configuration as Develop.
    /// ImageIO's bounded thumbnail proves raster decodability; no destination URL is opened.
    static func resolveDecoderState(data: Data, url: URL) throws -> DecoderState {
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            throw Failure.decoderUnavailable
        }
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000, width * height <= 1_000_000_000 else {
            throw Failure.decoderStateInvalid
        }
        let state: DecoderState
        if MCPPhotoFormatCatalog.rawExtensions.contains(url.pathExtension.lowercased()) {
            let configuration = try rawConfiguration()
            let hint = CGImageSourceGetType(source).map { $0 as String }
            // CIRAWFilter also accepts ordinary raster data. A RAW extension alone
            // cannot justify scene-referred headroom or an as-shot RAW reference.
            guard let hint, let detectedType = UTType(hint), detectedType.conforms(to: .rawImage) else {
                throw Failure.decoderUnavailable
            }
            guard let filter = CIRAWFilter(imageData: data, identifierHint: hint),
                  let decoded = RAWSourceDecoder.decode(filter, draftMode: false, maxPixelSize: 64,
                nativeLongestSide: CGFloat(max(width, height)), profile: RAWDecodeProfile(storedRawValue: configuration.profile ?? "") ?? .camera,
                decoderPreference: RAWDecoderVersionPreference(rawValue: configuration.decoder ?? "") ?? .auto),
                  !decoded.image.extent.isInfinite, !decoded.image.extent.isEmpty,
                  max(decoded.image.extent.width, decoded.image.extent.height) <= 4096 else {
                throw Failure.decoderUnavailable
            }
            // Force a bounded raster so a lazy output graph alone cannot admit a broken decoder.
            let extent = decoded.image.extent
            let scale = min(1, 64 / max(extent.width, extent.height))
            let thumbnail = decoded.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            try Task.checkCancellation()
            guard CIContext(options: [.cacheIntermediates: false]).createCGImage(thumbnail,
                from: thumbnail.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)) != nil else {
                throw Failure.decoderUnavailable
            }
            try Task.checkCancellation()
            guard try rawConfiguration() == configuration else { throw Failure.decoderConfigurationChanged }
            state = DecoderState(isRAW: true, neutralTemperature: Double(decoded.neutralTemperature),
                neutralTint: Double(decoded.neutralTint), sourceHasHDRHeadroom: true)
        } else {
            let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true]
            guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) != nil else {
                throw Failure.decoderUnavailable
            }
            // Develop's non-RAW projection explicitly clears the RAW source hint. The
            // HDR-first raster loader may preserve HDR pixels, but this flag is RAW-only.
            state = DecoderState(isRAW: false, neutralTemperature: nil, neutralTint: nil,
                sourceHasHDRHeadroom: nil)
        }
        try Task.checkCancellation()
        try state.validate(for: url)
        return state
    }

    private struct RAWConfiguration: Equatable {
        let profile: String?
        let decoder: String?
    }

    private static func rawConfiguration() throws -> RAWConfiguration {
        let domain = MCPServerConstants.preferencesSuiteName as CFString
        let profile = CFPreferencesCopyAppValue(UserDefaultsKeys.rawDecodeProfile as CFString, domain)
        let decoder = CFPreferencesCopyAppValue(UserDefaultsKeys.rawDecoderVersionPreference as CFString, domain)
        guard profile == nil || profile is String, decoder == nil || decoder is String else {
            throw Failure.decoderStateInvalid
        }
        return RAWConfiguration(profile: profile as? String, decoder: decoder as? String)
    }

    private static func settingsValue(_ settings: CameraRawSettings) throws -> MCPJSONValue {
        try JSONDecoder().decode(MCPJSONValue.self, from: JSONEncoder().encode(settings))
    }
}

nonisolated enum MCPTemplateDiscoveryError: LocalizedError {
    case customFolderRequired, localStorageUnavailable, staleBookmark, invalidInventory, inventoryChanged, limitExceeded

    var errorDescription: String? {
        switch self {
        case .customFolderRequired:
            "Template discovery requires iCloud template sync to be disabled. Authorize the active local Templates folder for local automation."
        case .localStorageUnavailable:
            "The default local Templates location is unavailable. Configure a custom Templates folder and authorize it for local automation."
        case .staleBookmark:
            "The custom Templates folder bookmark is stale or unavailable. Choose the folder again in Settings."
        case .invalidInventory:
            "The template inventory contains an unreadable, unsupported, unsafe, or ambiguous document. Resolve it in Photo Agent before retrying."
        case .inventoryChanged:
            "The template folder or its contents changed during discovery. Retry after it is stable."
        case .limitExceeded:
            "The template inventory exceeds the bounded discovery limits."
        }
    }
}

/// The helper deliberately does not use AppPaths: that resolver creates directories,
/// falls back to private storage, and reads the helper's own defaults domain.
nonisolated struct MCPTemplateDiscovery: Sendable {
    enum DevelopInspectionFailure: String, LocalizedError {
        case invalidArguments = "invalid_arguments"
        var errorDescription: String? {
            "Develop inspection requires only a canonical lowercase template UUID and exact SHA-256 revision from list_templates."
        }
    }
    struct Scope: Sendable {
        let directory: URL
        let release: @Sendable () -> Void
        var routing: Routing? = nil
    }

    enum Routing: Equatable, Sendable {
        case localDefault
        case custom(Data)
    }

    let authorizationStore: MCPAuthorizationStore
    var resolveScope: @Sendable () throws -> Scope = Self.configuredScope
    var checkpoint: @Sendable () -> Void = {}

    static func configuredScope() throws -> Scope {
        let domain = MCPServerConstants.preferencesSuiteName as CFString
        let cloudValue = CFPreferencesCopyAppValue("templates.iCloudEnabled" as CFString, domain)
        let bookmarkValue = CFPreferencesCopyAppValue("templatesFolderBookmark" as CFString, domain)
        // A malformed saved setting must not silently select a different library.
        guard cloudValue == nil || cloudValue is Bool else {
            throw MCPTemplateDiscoveryError.customFolderRequired
        }
        guard bookmarkValue == nil || bookmarkValue is Data else {
            throw MCPTemplateDiscoveryError.staleBookmark
        }
        return try configuredScope(
            iCloudEnabled: (cloudValue as? Bool) == true,
            bookmark: bookmarkValue as? Data,
            applicationSupportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
    }

    /// Resolves routing only: discovery never creates a missing library and never
    /// falls back from a configured bookmark or iCloud route to another location.
    /// The app and helper are unsandboxed and use the same user Application Support
    /// directory. Its location is not authorization; list still requires an
    /// explicit authorized root before opening it.
    static func configuredScope(iCloudEnabled: Bool, bookmark: Data?, applicationSupportDirectory: URL?) throws -> Scope {
        guard !iCloudEnabled else { throw MCPTemplateDiscoveryError.customFolderRequired }
        guard let data = bookmark else {
            guard let base = applicationSupportDirectory else {
                throw MCPTemplateDiscoveryError.localStorageUnavailable
            }
            return Scope(directory: base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
                .appendingPathComponent("Templates", isDirectory: true), release: {}, routing: .localDefault)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
            throw MCPTemplateDiscoveryError.staleBookmark
        }
        let started = url.startAccessingSecurityScopedResource()
        return Scope(directory: url, release: { if started { url.stopAccessingSecurityScopedResource() } }, routing: .custom(data))
    }

    func list(kind: String) throws -> [String: MCPJSONValue] {
        try withInventory(kind: kind) { first in
            [
                "kind": .string(kind),
                "templates": .array(first.sorted { $0.id < $1.id }.map { entry in
                    .object(["id": .string(entry.id), "name": .string(entry.name),
                             "schemaVersion": .integer(1), "revision": .string(entry.revision)])
                }),
                "discoveryOnly": .bool(true),
                "applicationAuthorized": .bool(false),
            ]
        }
    }

    /// Retains the exact inventory and its authority through the preview body.
    func withMetadataTemplate<T>(id: UUID, revision: String,
                                 body: (Data) throws -> T) throws -> T {
        try withInventory(kind: "metadata") { entries in
            guard let entry = entries.first(where: { $0.id == id.uuidString.lowercased() }),
                  entry.revision == revision else {
                throw MCPMetadataTemplatePreview.Failure.staleTemplate
            }
            return try body(entry.data)
        }
    }

    /// Destination previews keep the photo carriers retained through the complete
    /// template inventory/authority checks; the outer facade then validates the photo.
    func withDevelopTemplate<T>(id: UUID, revision: String,
                               body: (DevelopTemplate) throws -> T) throws -> T {
        try withInventory(kind: "develop") { entries in
            guard let entry = entries.first(where: { $0.id == id.uuidString.lowercased() }),
                  entry.revision == revision else { throw MCPMetadataTemplatePreview.Failure.staleTemplate }
            guard let template = try? JSONDecoder().decode(DevelopTemplate.self, from: entry.data),
                  template.id == id else { throw MCPTemplateDiscoveryError.invalidInventory }
            return try body(template)
        }
    }

    /// Returns the production-decoded control snapshot, never an application plan.
    /// Destination decoder state and fresh layer identifiers can only be resolved
    /// by a later explicit-photo executor; the template alone cannot establish them.
    func inspectDevelopTemplate(arguments: [String: MCPJSONValue]) throws -> [String: MCPJSONValue] {
        guard Set(arguments.keys) == ["templateID", "templateRevision"],
              let rawID = arguments["templateID"]?.stringValue,
              let id = UUID(uuidString: rawID), id.uuidString.lowercased() == rawID,
              let revision = arguments["templateRevision"]?.stringValue,
              revision.utf8.count == 71, revision.hasPrefix("sha256:"),
              revision.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DevelopInspectionFailure.invalidArguments
        }
        return try withInventory(kind: "develop") { entries in
            guard let entry = entries.first(where: { $0.id == id.uuidString.lowercased() }),
                  entry.revision == revision else { throw MCPMetadataTemplatePreview.Failure.staleTemplate }
            guard let template = try? JSONDecoder().decode(DevelopTemplate.self, from: entry.data),
                  template.id == id,
                  case .object(var controls) = try JSONDecoder().decode(MCPJSONValue.self,
                      from: JSONEncoder().encode(template.settings)) else {
                throw MCPTemplateDiscoveryError.invalidInventory
            }
            // A crop-excluding template leaves the destination crop intact. Do not
            // advertise a dormant stored crop as an applied control.
            if !template.includesCrop { controls.removeValue(forKey: "crop") }
            let result: [String: MCPJSONValue] = [
                "schemaVersion": .integer(1), "templateID": .string(rawID),
                "templateRevision": .string(revision), "name": .string(template.name),
                "summary": .string(template.summary), "controls": .object(controls),
                "cropPolicy": .string(template.includesCrop ? "apply-template-crop" : "preserve-destination-crop"),
                "destinationStateRequired": .bool(true), "layerIdentifiersMustBeRegenerated": .bool(true),
                "preservedDestinationFields": .array([
                    "asShotNeutralTemperature", "asShotNeutralTint", "sourceHasHDRHeadroom", "unparsedMaskCorrections",
                ].map(MCPJSONValue.string)),
                "inspectionOnly": .bool(true), "applicationAvailable": .bool(false),
                "warnings": .array([.string("Controls are untrusted template content decoded by the production Develop model. This is not a per-photo preview or write plan. Application requires independent destination decoder/as-shot admission, fresh layer identifiers, XMP preservation, and the retained Primary Develop write/recovery path.")]),
            ]
            guard try JSONEncoder().encode(MCPJSONValue.object(result)).count <= MCPServerConstants.maximumToolResultBytes else {
                throw MCPMetadataTemplatePreview.Failure.outputLimit
            }
            return result
        }
    }

    private func withInventory<T>(kind: String, body: ([Entry]) throws -> T) throws -> T {
        guard ["metadata", "develop"].contains(kind) else { throw MCPTemplateDiscoveryError.invalidInventory }
        let configuration = try authorizationStore.load()
        guard configuration.isEnabled else { throw MCPAuthorizationError.disabled }
        let scope = try resolveScope()
        defer { scope.release() }
        let directory = kind == "develop" ? scope.directory.appendingPathComponent("Develop", isDirectory: true) : scope.directory
        let target = try authorizationStore.authorizeExistingPath(directory.path)
        guard target.isDirectory,
              let root = configuration.roots.first(where: { $0.id == target.rootID }) else {
            throw MCPAuthorizationError.invalidConfiguration
        }
        let reservation = try MCPProcessReservation.acquireFolder(directory)
        defer { reservation.release() }
        let opened = try Directory(root: root, target: target)
        let first = try opened.inventory(kind: kind)
        let result = try body(first)
        checkpoint()
        guard try opened.inventory(kind: kind) == first else { throw MCPTemplateDiscoveryError.inventoryChanged }
        // A settings change must not publish the old library as the current library.
        let currentScope = try resolveScope()
        defer { currentScope.release() }
        guard currentScope.directory.standardizedFileURL == scope.directory.standardizedFileURL,
              currentScope.routing == scope.routing else {
            throw MCPTemplateDiscoveryError.inventoryChanged
        }
        // Bookmark resolution can block while a peer changes template contents.
        // Revalidate the complete snapshot after resolving the final route, then
        // recheck authorization and anchored ancestors immediately before publication.
        guard try opened.inventory(kind: kind) == first else {
            throw MCPTemplateDiscoveryError.inventoryChanged
        }
        guard try authorizationStore.load() == configuration,
              try authorizationStore.authorizeExistingPath(directory.path) == target else {
            throw MCPTemplateDiscoveryError.inventoryChanged
        }
        try opened.validate()
        return result
    }

    private struct Entry: Equatable {
        let id: String
        let name: String
        let revision: String
        let device: Int32
        let inode: UInt64
        let data: Data
    }

    /// Keep all ancestors open and read only descriptor-relative, no-follow files.
    /// No directory/file names or template field values are returned to the client.
    private final class Directory {
        let root: MCPAuthorizedRoot
        let components: [String]
        var descriptors: [Int32] = []
        var descriptor: Int32 { descriptors.last! }

        init(root: MCPAuthorizedRoot, target: MCPAuthorizedTarget) throws {
            self.root = root
            let rootComponents = URL(fileURLWithPath: root.canonicalPath).pathComponents
            let targetComponents = target.url.pathComponents
            guard Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
                throw MCPTemplateDiscoveryError.inventoryChanged
            }
            components = Array(targetComponents.dropFirst(rootComponents.count))
            let first = Darwin.open(root.canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard first >= 0 else { throw MCPTemplateDiscoveryError.inventoryChanged }
            descriptors.append(first)
            do {
                for component in components {
                    let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw MCPTemplateDiscoveryError.inventoryChanged }
                    descriptors.append(next)
                }
                try validate()
                var info = stat()
                guard Darwin.fstat(descriptor, &info) == 0,
                      UInt64(info.st_dev) == target.identity.device, UInt64(info.st_ino) == target.identity.inode else {
                    throw MCPTemplateDiscoveryError.inventoryChanged
                }
            } catch {
                for fd in descriptors { _ = Darwin.close(fd) }
                descriptors = []
                throw error
            }
        }

        deinit { for fd in descriptors { _ = Darwin.close(fd) } }

        func validate() throws {
            var entry = stat()
            var opened = stat()
            guard Darwin.lstat(root.canonicalPath, &entry) == 0,
                  (entry.st_mode & S_IFMT) == S_IFDIR,
                  UInt64(entry.st_dev) == root.identity.device, UInt64(entry.st_ino) == root.identity.inode else {
                throw MCPTemplateDiscoveryError.inventoryChanged
            }
            for (index, fd) in descriptors.enumerated() {
                if index > 0 {
                    guard Darwin.fstatat(descriptors[index - 1], components[index - 1], &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw MCPTemplateDiscoveryError.inventoryChanged
                    }
                }
                guard Darwin.fstat(fd, &opened) == 0, (entry.st_mode & S_IFMT) == S_IFDIR,
                      opened.st_dev == entry.st_dev, opened.st_ino == entry.st_ino else {
                    throw MCPTemplateDiscoveryError.inventoryChanged
                }
            }
        }

        func names() throws -> [String] {
            // A fresh open file description avoids sharing the directory stream offset.
            let scan = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scan >= 0 else { throw MCPTemplateDiscoveryError.invalidInventory }
            guard let stream = Darwin.fdopendir(scan) else {
                _ = Darwin.close(scan)
                throw MCPTemplateDiscoveryError.invalidInventory
            }
            defer { Darwin.closedir(stream) }
            var names: [String] = []
            var count = 0
            while true {
                errno = 0
                guard let item = Darwin.readdir(stream) else {
                    guard errno == 0 else { throw MCPTemplateDiscoveryError.invalidInventory }
                    break
                }
                count += 1
                guard count <= 4096 else { throw MCPTemplateDiscoveryError.limitExceeded }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if (name as NSString).pathExtension.lowercased() == "json" { names.append(name) }
            }
            guard names.count <= 256 else { throw MCPTemplateDiscoveryError.limitExceeded }
            return names.sorted()
        }

        func inventory(kind: String) throws -> [Entry] {
            let before = try names()
            var entries: [Entry] = []
            var seen: Set<UUID> = []
            var totalBytes = 0
            for name in before {
                let fd = Darwin.openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw MCPTemplateDiscoveryError.invalidInventory }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard Darwin.fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_nlink == 1, info.st_size >= 0, info.st_size <= 1_048_576 else {
                    throw MCPTemplateDiscoveryError.invalidInventory
                }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                totalBytes += data.count
                guard data.count <= 1_048_576, totalBytes <= 8_388_608 else {
                    throw MCPTemplateDiscoveryError.limitExceeded
                }
                var after = stat()
                var path = stat()
                guard Darwin.fstat(fd, &after) == 0,
                      Darwin.fstatat(descriptor, name, &path, AT_SYMLINK_NOFOLLOW) == 0,
                      same(info, after), same(after, path), data.count == after.st_size else {
                    throw MCPTemplateDiscoveryError.inventoryChanged
                }
                guard let object = try? JSONDecoder().decode(MCPJSONValue.self, from: data).objectValue,
                      object["schemaVersion"] == nil || object["schemaVersion"] == .integer(1),
                      let idString = object["id"]?.stringValue, let id = UUID(uuidString: idString),
                      name == "\(id.uuidString).json", seen.insert(id).inserted,
                      let title = object["name"]?.stringValue, title.utf8.count <= 1024 else {
                    throw MCPTemplateDiscoveryError.invalidInventory
                }
                if kind == "metadata" {
                    let type = object["templateType"] ?? object["presetType"]
                    guard type == .string("Full") || type == .string("Per Field") else {
                        throw MCPTemplateDiscoveryError.invalidInventory
                    }
                    if let fields = object["fields"] {
                        guard case .array(let values) = fields,
                              values.allSatisfy({ value in
                                  guard let field = value.objectValue,
                                        let id = field["id"]?.stringValue, UUID(uuidString: id) != nil else { return false }
                                  return field["fieldKey"]?.stringValue != nil && field["templateValue"]?.stringValue != nil
                              }) else { throw MCPTemplateDiscoveryError.invalidInventory }
                    }
                } else {
                    guard object["settings"]?.objectValue != nil else { throw MCPTemplateDiscoveryError.invalidInventory }
                }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                entries.append(Entry(id: id.uuidString.lowercased(), name: title, revision: "sha256:\(hash)", device: info.st_dev, inode: info.st_ino, data: data))
            }
            guard try names() == before else { throw MCPTemplateDiscoveryError.inventoryChanged }
            try validate()
            return entries
        }

        private func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
                && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
                && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
                && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
    }
}
