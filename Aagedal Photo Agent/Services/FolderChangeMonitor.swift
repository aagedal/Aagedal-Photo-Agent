import CoreServices
import Foundation
import os

nonisolated private let folderChangeLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "FolderChangeMonitor"
)

/// One FSEvents delivery after history-only markers have been removed.
nonisolated struct FolderChangeBatch: Sendable {
    let paths: Set<URL>
    let requiresFullRescan: Bool
}

/// Downstream work required for a folder-change batch.
///
/// Analysis and version owners observe dedicated notifications. Browser content continues through
/// the existing debounced image diff, while unrelated hidden bookkeeping can be ignored.
nonisolated struct BrowserFolderChangeImpact: OptionSet, Sendable {
    let rawValue: Int

    static let browserContent = BrowserFolderChangeImpact(rawValue: 1 << 0)
    static let analysisStore = BrowserFolderChangeImpact(rawValue: 1 << 1)
    static let versionStore = BrowserFolderChangeImpact(rawValue: 1 << 2)
    static let all: BrowserFolderChangeImpact = [
        .browserContent,
        .analysisStore,
        .versionStore
    ]

    static func classify(
        _ batch: FolderChangeBatch,
        monitoredRoot: URL
    ) -> BrowserFolderChangeImpact {
        guard !batch.requiresFullRescan else { return .all }
        guard !batch.paths.isEmpty else { return .browserContent }

        let rootComponents = monitoredRoot.standardizedFileURL.pathComponents
        var impact: BrowserFolderChangeImpact = []
        for path in batch.paths {
            let components = path.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents) else {
                impact.insert(.browserContent)
                continue
            }
            let relative = components.dropFirst(rootComponents.count)
            guard let first = relative.first else {
                impact.insert(.browserContent)
                continue
            }

            switch first {
            case ".photo_analysis":
                impact.insert(.analysisStore)
            case ".photo_versions":
                impact.insert(.versionStore)
            case ".photo_metadata", ".face_data":
                // Existing app data can affect visible metadata, badges, or face navigation.
                impact.insert(.browserContent)
            default:
                // Ordinary content changes require the image diff. Other dotfiles are Finder,
                // cloud-provider, or atomic-write bookkeeping with no browser-visible effect.
                if !first.hasPrefix(".") {
                    impact.insert(.browserContent)
                }
            }
        }
        return impact
    }
}

nonisolated struct HiddenFolderStoreChange: Sendable {
    let folderURL: URL
    let changedPaths: Set<URL>
}

/// One requested monitor setup. The callback is value-captured before the request crosses the
/// actor boundary, so monitor construction never needs to reach back into MainActor state.
nonisolated struct FolderChangeMonitorRequest: Sendable {
    let folderURL: URL
    let onChange: @Sendable (FolderChangeBatch) -> Void
}

/// Immutable setup evidence returned to the MainActor coordinator.
nonisolated enum FolderChangeMonitorCreationResult: Sendable {
    case created(FolderChangeMonitor)
    case unavailable
    case cancelledBeforeSetup
    case cancelledAfterSetup
}

extension Notification.Name {
    static let analysisStoreDidChange = Notification.Name("analysisStoreDidChange")
    static let versionStoreDidChange = Notification.Name("versionStoreDidChange")
}

/// Serializes the directory probe and FSEvents setup away from MainActor. Foundation and
/// FSEventStream creation are synchronous and cannot be interrupted once entered, so cancellation
/// is sampled on both sides and a monitor created by stale work is stopped before returning.
actor FolderChangeMonitorService {
    static let shared = FolderChangeMonitorService()

    typealias Factory = @Sendable (FolderChangeMonitorRequest) -> FolderChangeMonitor?

    private let factory: Factory
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "FolderChangeMonitorSetup"
    )

    init(factory: @escaping Factory = { request in
        FolderChangeMonitor(url: request.folderURL, onChange: request.onChange)
    }) {
        self.factory = factory
    }

    func createMonitor(
        _ request: FolderChangeMonitorRequest
    ) -> FolderChangeMonitorCreationResult {
        let interval = signposter.beginInterval(
            "Create",
            id: signposter.makeSignpostID()
        )
        guard !Task.isCancelled else {
            signposter.endInterval("Create", interval, "result=cancelled stage=before")
            return .cancelledBeforeSetup
        }

        let monitor = factory(request)
        guard !Task.isCancelled else {
            monitor?.cancel()
            signposter.endInterval("Create", interval, "result=cancelled stage=after")
            return .cancelledAfterSetup
        }
        guard let monitor else {
            signposter.endInterval("Create", interval, "result=unavailable")
            return .unavailable
        }

        signposter.endInterval("Create", interval, "result=created")
        return .created(monitor)
    }
}

/// Watches one folder tree for file changes. FSEvents is used instead of a vnode
/// directory source so modifications to existing files and nested sidecar files are
/// delivered as well as additions/removals in the root directory.
nonisolated final class FolderChangeMonitor: @unchecked Sendable {
    private let callbackQueue: DispatchQueue
    private let onChange: @Sendable (FolderChangeBatch) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init?(url: URL, onChange: @escaping @Sendable (FolderChangeBatch) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        self.callbackQueue = DispatchQueue(
            label: "com.aagedal.photo-agent.folder-events.\(UUID().uuidString)",
            qos: .utility
        )
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard eventCount > 0, let info else { return }
            let monitor = Unmanaged<FolderChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.receive(
                eventCount: eventCount,
                paths: eventPaths,
                flags: eventFlags
            )
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            createFlags
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        guard FSEventStreamStart(stream) else {
            self.stream = nil
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        folderChangeLog.debug("Watching \(url.path, privacy: .private(mask: .hash))")
    }

    deinit {
        cancel()
    }

    func cancel() {
        let stream = lock.withLock { () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func receive(
        eventCount: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let pathPointers = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        var changedPaths: Set<URL> = []
        var requiresFullRescan = false

        for index in 0..<eventCount {
            let eventFlags = flags[index]
            guard eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 else {
                continue
            }
            if let path = pathPointers[index] {
                changedPaths.insert(URL(fileURLWithPath: String(cString: path)))
            }
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
            )
            if eventFlags & rescanFlags != 0 {
                requiresFullRescan = true
            }
        }

        if !changedPaths.isEmpty || requiresFullRescan {
            onChange(FolderChangeBatch(
                paths: changedPaths,
                requiresFullRescan: requiresFullRescan
            ))
        }
    }
}
