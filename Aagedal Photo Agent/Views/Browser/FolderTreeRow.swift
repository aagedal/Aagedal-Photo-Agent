import SwiftUI
import UniformTypeIdentifiers

enum SidebarFolderSection {
    case favoriteRoot
    case favoriteChild
    case openRoot
    case openChild
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
    /// Opens a folder into the active pane (and registers it in the shared sidebar).
    /// Bool = whether to add it to the Open Folders section.
    let openFolder: (URL, Bool) -> Void
    let revealInFinder: (URL) -> Void

    @State private var isDropHighlighted = false
    @State private var isHovered = false

    private var isCurrent: Bool {
        url == currentFolderURL
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
        case .openRoot, .openChild: .openChild
        }
    }

    var body: some View {
        rowContent
            .padding(.leading, 8 + CGFloat(depth) * 16)
            .padding(.trailing, 8)
            .contextMenu { contextMenuItems }

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
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        // Hit target much larger than the glyph, so expanding
                        // doesn't get mistaken for a click that opens the folder.
                        // Height matches the text line so it doesn't tax row height.
                        .frame(width: 20, height: 16, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: 20)
            }

            Image(systemName: isCurrent || isRootOfSection ? "folder.fill" : "folder")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            Spacer()

            if isRootOfSection && section == .openRoot && isHovered {
                Button {
                    viewModel.closeOpenFolder(url)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close Folder")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.15) :
                      isDropHighlighted ? Color.accentColor.opacity(0.1) : Color.clear)
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
            // Favorites open in place — they already have a sidebar home, so
            // they must not get duplicated into the Open Folders section.
            openFolder(url, section == .openRoot)
        }
        .onDrag {
            NSItemProvider(object: url as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(
            targetURL: url,
            section: section,
            viewModel: viewModel,
            isHighlighted: $isDropHighlighted
        ))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        switch section {
        case .favoriteRoot:
            Button("Open") {
                openFolder(url, false)
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
            Button("Back Up Edited Files...") {
                commandRouter.send(.backupEditedFilesForFolder(url))
            }
            Divider()
            Button("Remove from Favorites", role: .destructive) {
                if let fav = viewModel.favoriteFolders.first(where: { $0.url == url }) {
                    viewModel.removeFavorite(fav)
                }
            }

        case .favoriteChild:
            Button("Open") {
                openFolder(url, false)
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
            Button("Rename...") {
                viewModel.promptRenameSubfolder(url)
            }
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmTrashSubfolder(url)
            }

        case .openRoot:
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
            Button("Back Up Edited Files...") {
                commandRouter.send(.backupEditedFilesForFolder(url))
            }
            Divider()
            Button {
                Task {
                    await viewModel.addFolderToFavorites(url)
                }
            } label: {
                Label("Add to Favorites", systemImage: "star")
            }
            .disabled(viewModel.favoriteFolders.contains { $0.url == url })
            Divider()
            Button("Close", role: .destructive) {
                viewModel.closeOpenFolder(url)
            }

        case .openChild:
            Button("Open as Folder") {
                openFolder(url, true)
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
            Button("Rename...") {
                viewModel.promptRenameSubfolder(url)
            }
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmTrashSubfolder(url)
            }
        }
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

        Task { @MainActor in
            let sourceURLs = await Self.loadFileURLs(from: providers)
            guard !sourceURLs.isEmpty else { return }

            guard let snapshot = try? await viewModel.fileSystemService.dropSourceSnapshot(for: sourceURLs)
            else { return }

            for sourceURL in snapshot.directories {
                let sourceIsFavoriteRoot = viewModel.favoriteFolders.contains { $0.url == sourceURL }
                let targetIsFavoriteRoot = dropSection == .favoriteRoot
                if sourceIsFavoriteRoot && targetIsFavoriteRoot {
                    viewModel.reorderFavorite(from: sourceURL, relativeTo: target)
                } else {
                    viewModel.moveFolder(sourceURL, into: target)
                }
            }

            if !snapshot.regularFiles.isEmpty {
                viewModel.moveImages(snapshot.regularFiles, into: target)
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
