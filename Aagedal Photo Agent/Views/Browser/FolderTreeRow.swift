import SwiftUI
import UniformTypeIdentifiers

enum SidebarFolderSection {
    case favoriteRoot
    case favoriteChild
    case openRoot
    case openChild
}

struct FolderTreeRow: View {
    let url: URL
    let depth: Int
    let section: SidebarFolderSection
    let isRootOfSection: Bool
    @Bindable var viewModel: BrowserViewModel
    let revealInFinder: (URL) -> Void

    @State private var isDropHighlighted = false
    @State private var isHovered = false

    private var isCurrent: Bool {
        url == viewModel.currentFolderURL
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

    private var tree: SidebarTree {
        isFavoriteSection ? .favorites : .open
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
                ForEach(children, id: \.self) { childURL in
                    FolderTreeRow(
                        url: childURL,
                        depth: depth + 1,
                        section: childSection,
                        isRootOfSection: false,
                        viewModel: viewModel,
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
            viewModel.loadFolder(url: url, addToOpenFolders: section == .openRoot)
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
                viewModel.loadFolder(url: url, addToOpenFolders: false)
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
                NotificationCenter.default.post(name: .backupEditedFilesForFolder, object: url)
            }
            Divider()
            Button("Remove from Favorites", role: .destructive) {
                if let fav = viewModel.favoriteFolders.first(where: { $0.url == url }) {
                    viewModel.removeFavorite(fav)
                }
            }

        case .favoriteChild:
            Button("Open") {
                viewModel.loadFolder(url: url, addToOpenFolders: false)
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
                NotificationCenter.default.post(name: .backupEditedFilesForFolder, object: url)
            }
            Divider()
            Button {
                viewModel.addFolderToFavorites(url)
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
                viewModel.openSubfolderAsRoot(url)
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

            var photoURLs: [URL] = []
            let fileManager = FileManager.default

            for sourceURL in sourceURLs {
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
                if exists && isDirectory.boolValue {
                    let sourceIsFavoriteRoot = viewModel.favoriteFolders.contains { $0.url == sourceURL }
                    let targetIsFavoriteRoot = dropSection == .favoriteRoot
                    if sourceIsFavoriteRoot && targetIsFavoriteRoot {
                        viewModel.reorderFavorite(from: sourceURL, relativeTo: target)
                    } else {
                        viewModel.moveFolder(sourceURL, into: target)
                    }
                } else if exists {
                    photoURLs.append(sourceURL)
                }
            }

            if !photoURLs.isEmpty {
                viewModel.moveImages(photoURLs, into: target)
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
