import AppKit
import Observation

/// One top-level row of the sidebar's Locations tree: the home folder or a mounted volume.
nonisolated struct SidebarLocation: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case home
        case startupVolume
        case internalVolume
        case externalVolume
        case removableVolume
        case networkVolume
    }

    let url: URL
    let name: String
    let kind: Kind
    /// Eject/unmount is offered for these (external, removable and network volumes).
    let isEjectable: Bool

    var id: URL { url }

    var systemImage: String {
        switch kind {
        case .home: "house"
        case .startupVolume, .internalVolume: "internaldrive"
        case .externalVolume: "externaldrive"
        case .removableVolume: "sdcard"
        case .networkVolume: "network"
        }
    }
}

/// The Locations tree's roots, like Bridge's Folders panel: the home folder, then every
/// browsable mounted volume. Follows mounts, unmounts and renames.
@MainActor
@Observable
final class SidebarLocations {
    static let shared = SidebarLocations()

    private(set) var roots: [SidebarLocation] = []

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let listRoots: @Sendable () async -> [SidebarLocation]

    init(
        observesWorkspace: Bool = true,
        listRoots: @escaping @Sendable () async -> [SidebarLocation] = { await SidebarLocations.currentRoots() }
    ) {
        self.listRoots = listRoots
        guard observesWorkspace else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    /// Re-lists the roots off MainActor (volume resource values can block on network mounts).
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, listRoots] in
            let roots = await listRoots()
            guard !Task.isCancelled, let self else { return }
            if roots != self.roots { self.roots = roots }
            self.refreshTask = nil
        }
    }

    /// Awaits the in-flight refresh (tests).
    func waitForRefresh() async {
        await refreshTask?.value
    }

    /// Unmounts and ejects a volume off MainActor (a busy volume can block). Returns a message
    /// to show when it fails; the unmount notification refreshes the roots.
    func eject(_ location: SidebarLocation) async -> String? {
        let url = location.url
        let name = location.name
        return await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return "Could not eject “\(name)”: \(error.localizedDescription)"
            }
        }.value
    }

    /// The root whose tree contains `url`: the deepest one, so a folder in the home folder
    /// is revealed under Home rather than under the startup volume.
    func root(containing url: URL) -> SidebarLocation? {
        Self.root(containing: url, in: roots)
    }

    nonisolated static func root(containing url: URL, in roots: [SidebarLocation]) -> SidebarLocation? {
        let path = url.standardizedFileURL.path
        return roots
            .filter { isPath(path, atOrBelow: $0.url.standardizedFileURL.path) }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
    }

    nonisolated static func isPath(_ path: String, atOrBelow ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    @concurrent
    nonisolated static func currentRoots() async -> [SidebarLocation] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [SidebarLocation(url: home, name: home.lastPathComponent, kind: .home, isEjectable: false)]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        var others: [SidebarLocation] = []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false else { continue }
            let name = values.volumeLocalizedName ?? volume.lastPathComponent
            let kind: SidebarLocation.Kind
            if values.volumeIsRootFileSystem == true {
                kind = .startupVolume
            } else if values.volumeIsLocal == false {
                kind = .networkVolume
            } else if values.volumeIsRemovable == true {
                kind = .removableVolume
            } else if values.volumeIsInternal == true {
                kind = .internalVolume
            } else {
                kind = .externalVolume
            }
            let location = SidebarLocation(
                url: volume, name: name, kind: kind,
                isEjectable: kind != .startupVolume && kind != .internalVolume
                    || values.volumeIsEjectable == true
            )
            if kind == .startupVolume {
                roots.append(location)
            } else {
                others.append(location)
            }
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return roots + others
    }
}
