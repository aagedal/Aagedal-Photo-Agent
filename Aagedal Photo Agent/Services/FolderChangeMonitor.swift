import CoreServices
import Foundation
import os

nonisolated private let folderChangeLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "FolderChangeMonitor"
)

/// Watches one folder tree for file changes. FSEvents is used instead of a vnode
/// directory source so modifications to existing files and nested sidecar files are
/// delivered as well as additions/removals in the root directory.
nonisolated final class FolderChangeMonitor: @unchecked Sendable {
    private let callbackQueue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
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
        let callback: FSEventStreamCallback = { _, info, eventCount, _, eventFlags, _ in
            guard eventCount > 0, let info else { return }
            let monitor = Unmanaged<FolderChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.receive(eventCount: eventCount, flags: eventFlags)
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
        folderChangeLog.debug("Watching \(url.path, privacy: .public)")
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
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        for index in 0..<eventCount {
            if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 {
                onChange()
                return
            }
        }
    }
}
