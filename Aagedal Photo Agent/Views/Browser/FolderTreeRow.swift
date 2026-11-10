import SwiftUI
import UniformTypeIdentifiers

enum SidebarFolderSection {
    case favoriteRoot
    case favoriteChild
    case locationRoot
    case locationChild
}

/// Stable SwiftUI identity for a folder row within one rendered sidebar tree.
/// The URL alone is insufficient when overlapping favorites render the same
/// folder (and therefore the same children) in multiple expanded subtrees.
struct SidebarFolderRowIdentity: Hashable {
    let tree: SidebarTree
    let url: URL
}

struct FolderTreeRow: View {
    @Environment(AppCommandRouter.self) private var commandRouter
    let url: URL
    let depth: Int
    let section: SidebarFolderSection
    /// Identifies this rendered tree occurrence. Favorite roots can overlap, so
    /// the same URL may legitimately appear in more than one favorite subtree.
    let tree: SidebarTree
    let isRootOfSection: Bool
    /// Owns the folder-tree state (favorites, opens, expansion, subfolders). In split
    /// view this is always the primary pane, so the sidebar stays stable regardless of
    /// which pane is focused.
    @Bindable var viewModel: BrowserViewModel
    /// The active pane's current folder — drives the highlight, independent of which
    /// pane backs the tree.
    let currentFolderURL: URL?
    /// Folders shown by the other on-screen panes in split view; marked more quietly.
    var otherPaneFolderURLs: Set<URL> = []
    /// Several panes are open, so "which folder is the active pane" needs a stronger cue
    /// than the single-browser tint: a solid selection fill.
    var emphasizesCurrent: Bool = false
    /// Opens a folder into the active pane (and reveals it in the shared sidebar).
    let openFolder: (URL) -> Void
    let revealInFinder: (URL) -> Void
    /// Locations roots: the home folder or volume this row stands for (name, icon, eject).
    var location: SidebarLocation? = nil
    var ejectLocation: ((SidebarLocation) -> Void)? = nil

    @State private var isDropHighlighted = false
    @State private var isHovered = false
    /// AppKit drag source: SwiftUI's `.onDrag` can't refuse drops on other apps (privacy).
    @State private var dragSource = FolderRowDragSource()

    /// Compared by path: a folder opened from the Open panel or Open Recent has no trailing
    /// slash, while the tree's directory listings do.
    private var path: String { url.standardizedFileURL.path }

    private var isCurrent: Bool {
        currentFolderURL?.standardizedFileURL.path == path
    }

    private var isInOtherPane: Bool {
        !isCurrent && otherPaneFolderURLs.contains { $0.standardizedFileURL.path == path }
    }

    private var displayName: String {
        location?.name ?? url.lastPathComponent
    }

    /// Solid accent selection (active pane's folder in split view).
    private var isStrongCurrent: Bool {
        isCurrent && emphasizesCurrent
    }

    private var rowFill: Color {
        if isStrongCurrent { return Color.accentColor }
        if isCurrent { return Color.accentColor.opacity(0.15) }
        if isDropHighlighted { return Color.accentColor.opacity(0.1) }
        if isInOtherPane { return Color.primary.opacity(0.08) }
        return Color.clear
    }

    private var isExpanded: Bool {
        viewModel.isExpanded(url, in: tree)
    }

    private var hasOrMayHaveChildren: Bool {
        guard let cached = viewModel.subfoldersByOpenFolder[url] else { return false }
        return !cached.isEmpty
    }

    private var isFavoriteSection: Bool {
        section == .favoriteRoot || section == .favoriteChild
    }

    private var childSection: SidebarFolderSection {
        switch section {
        case .favoriteRoot, .favoriteChild: .favoriteChild
        case .locationRoot, .locationChild: .locationChild
        }
    }

    var body: some View {
        rowContent
            .padding(.leading, 8 + CGFloat(depth) * 16)
            .padding(.trailing, 8)
            .contextMenu { contextMenuItems }
            // Scroll target for `BrowserViewModel.sidebarRevealRequest`.
            .id(SidebarFolderRowIdentity(tree: tree, url: url))

        if isExpanded {
            if let children = viewModel.subfoldersByOpenFolder[url], !children.isEmpty {
                let childRows = children.map {
                    SidebarFolderRowIdentity(tree: tree, url: $0)
                }
                ForEach(childRows, id: \.self) { childRow in
                    FolderTreeRow(
                        url: childRow.url,
                        depth: depth + 1,
                        section: childSection,
                        tree: tree,
                        isRootOfSection: false,
                        viewModel: viewModel,
                        currentFolderURL: currentFolderURL,
                        otherPaneFolderURLs: otherPaneFolderURLs,
                        emphasizesCurrent: emphasizesCurrent,
                        openFolder: openFolder,
                        revealInFinder: revealInFinder
                    )
                }
            } else if viewModel.subfoldersByOpenFolder[url] == nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 8 + CGFloat(depth + 1) * 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 1)
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 4) {
            if hasOrMayHaveChildren {
                Button {
                    viewModel.toggleFolderExpansion(url, in: tree)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(isStrongCurrent ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        // Hit target much larger than the glyph, so expanding
                        // doesn't get mistaken for a click that opens the folder.
                        // Height matches the text line so it doesn't tax row height.
                        .frame(width: 20, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(displayName)" : "Expand \(displayName)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Collapse \(displayName)" : "Expand \(displayName)")
            } else {
                Spacer()
                    .frame(width: 20)
            }

            Image(systemName: location?.systemImage
                  ?? (isCurrent || isInOtherPane || isRootOfSection ? "folder.fill" : "folder"))
                .foregroundStyle(isStrongCurrent ? Color.white : isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(displayName)
                .font(.callout)
                .fontWeight(isStrongCurrent ? .semibold : nil)
                .foregroundStyle(isStrongCurrent ? Color.white : isCurrent ? Color.accentColor : Color.primary)
                // The row's tap gesture opens the folder; VoiceOver needs the same action here,
                // separate from the expand and close buttons in the row.
                .accessibilityLabel(location == nil ? "Folder \(displayName)" : displayName)
                .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
                .accessibilityValue(isStrongCurrent ? "Shown in active pane" : isInOtherPane ? "Shown in another pane" : "")
                .accessibilityAction { openFolder(url) }
            Spacer()

            if isInOtherPane {
                Image(systemName: "rectangle.split.2x1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Shown in another pane")
                    .accessibilityHidden(true)
            }

            if let location, location.isEjectable, let ejectLocation {
                Button {
                    ejectLocation(location)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isStrongCurrent ? Color.white.opacity(0.85) : Color.secondary)
                .opacity(isHovered || isCurrent ? 1 : 0.6)
                .help("Eject \(location.name)")
                .accessibilityLabel("Eject \(location.name)")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropHighlighted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        // Photo Mechanic semantics: a single click on the name opens the
        // folder; only the disclosure chevron expands/collapses. A paired
        // double-tap gesture would also delay every single click by the
        // double-click timeout, making the sidebar feel sluggish.
        .onTapGesture {
            openFolder(url)
        }
        // An AppKit drag session, started from this gesture, instead of `.onDrag`: in-app folder
        // moves still drop a file URL on `FolderDropDelegate`, but drops on other apps are
        // refused while the folder holds face-blurred photos (`FolderRowDragSource`).
        .background(FolderDragAnchor(source: dragSource))
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in dragSource.beginDrag(folderURL: url, browser: viewModel) }
        )
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(
            targetURL: url,
            section: section,
            viewModel: viewModel,
            isHighlighted: $isDropHighlighted
        ))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Open") {
            openFolder(url)
        }
        Button("Reveal in Finder") {
            revealInFinder(url)
        }
        Button("New Subfolder...") {
            viewModel.promptNewSubfolder(url)
        }
        Button("Refresh") {
            viewModel.refreshSubfolders(for: url)
        }
        Divider()
        switch section {
        case .favoriteRoot:
            Button("Back Up Edited Files...") {
                commandRouter.send(.backupEditedFilesForFolder(url))
            }
            Divider()
            Button("Remove from Favorites", role: .destructive) {
                if let fav = viewModel.favoriteFolders.first(where: { $0.url == url }) {
                    viewModel.removeFavorite(fav)
                }
            }

        case .locationRoot:
            Button("Back Up Edited Files...") {
                commandRouter.send(.backupEditedFilesForFolder(url))
            }
            addToFavoritesButton
            if let location, location.isEjectable, let ejectLocation {
                Divider()
                Button("Eject \(location.name)") {
                    ejectLocation(location)
                }
            }

        case .favoriteChild, .locationChild:
            if section == .locationChild {
                addToFavoritesButton
                Divider()
            }
            Button("Rename...") {
                viewModel.promptRenameSubfolder(url)
            }
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmTrashSubfolder(url)
            }
        }
    }

    private var addToFavoritesButton: some View {
        Button {
            Task {
                await viewModel.addFolderToFavorites(url)
            }
        } label: {
            Label("Add to Favorites", systemImage: "star")
        }
        .disabled(viewModel.favoriteFolders.contains { $0.url.standardizedFileURL.path == path })
    }
}

// MARK: - Folder Drop Delegate

struct FolderDropDelegate: DropDelegate {
    let targetURL: URL
    let section: SidebarFolderSection
    let viewModel: BrowserViewModel
    @Binding var isHighlighted: Bool

    func dropEntered(info: DropInfo) {
        isHighlighted = true
    }

    func dropExited(info: DropInfo) {
        isHighlighted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        isHighlighted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        let target = targetURL
        let dropSection = section
        let viewModel = viewModel
        // Read now: the source grid clears its drag state when the session ends, which happens
        // before the item providers below finish loading.
        let dragSourcePane = viewModel.paneDraggingImages?()

        Task { @MainActor in
            // Grid drags also carry each photo's `.xmp`; moving the photo brings it along.
            let sourceURLs = PhotoDragPasteboardURLs.removingCompanionSidecars(
                from: await Self.loadFileURLs(from: providers)
            )
            guard !sourceURLs.isEmpty else { return }

            guard let snapshot = try? await viewModel.fileSystemService.dropSourceSnapshot(for: sourceURLs)
            else { return }

            var foldersToMove: [URL] = []
            for sourceURL in snapshot.directories {
                let sourceIsFavoriteRoot = viewModel.favoriteFolders.contains { $0.url == sourceURL }
                let targetIsFavoriteRoot = dropSection == .favoriteRoot
                if sourceIsFavoriteRoot && targetIsFavoriteRoot {
                    viewModel.reorderFavorite(from: sourceURL, relativeTo: target)
                } else {
                    foldersToMove.append(sourceURL)
                }
            }
            if !foldersToMove.isEmpty {
                viewModel.moveFolders(foldersToMove, into: target)
            }

            if !snapshot.regularFiles.isEmpty {
                // The sidebar is bound to the primary pane; photos dragged from another pane's
                // grid must leave that pane's list (and wait behind its own file operations).
                // The pane the drag came from wins over a hidden tab on the same folder.
                let owner = viewModel.paneOwningImages?(snapshot.regularFiles, dragSourcePane) ?? viewModel
                owner.moveImages(snapshot.regularFiles, into: target)
            }
        }
        return true
    }

    nonisolated private static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    nonisolated private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
