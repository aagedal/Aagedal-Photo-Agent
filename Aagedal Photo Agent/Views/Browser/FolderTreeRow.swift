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

    private var isCurrent: Bool {
        url == viewModel.currentFolderURL
    }

    private var isExpanded: Bool {
        viewModel.isExpanded(url, in: tree)
    }

    private var hasOrMayHaveChildren: Bool {
        if let cached = viewModel.subfoldersByOpenFolder[url] {
            return !cached.isEmpty
        }
        return true // Optimistic — show chevron until loaded
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
            .listRowInsets(EdgeInsets(
                top: depth == 0 ? 2 : 1,
                leading: 8 + CGFloat(depth) * 16,
                bottom: depth == 0 ? 2 : 1,
                trailing: 8
            ))
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
                    .listRowInsets(EdgeInsets(
                        top: 1,
                        leading: 8 + CGFloat(depth + 1) * 16,
                        bottom: 1,
                        trailing: 8
                    ))
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
                        .frame(width: 12, alignment: .center)
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: 12)
            }

            Image(systemName: isCurrent || isRootOfSection ? "folder.fill" : "folder")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            Spacer()

            if isRootOfSection && section == .openRoot {
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
        .padding(.vertical, depth == 0 ? 4 : 3)
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
        .applyIf(isFavoriteSection) { view in
            view
                .onTapGesture(count: 2) {
                    viewModel.loadFolder(url: url, addToOpenFolders: isRootOfSection)
                }
                .onTapGesture(count: 1) {
                    viewModel.toggleFolderExpansion(url, in: tree)
                }
        }
        .applyIf(!isFavoriteSection) { view in
            view
                .onTapGesture {
                    viewModel.loadFolder(url: url, addToOpenFolders: isRootOfSection)
                }
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
                viewModel.loadFolder(url: url)
            }
            Button("Reveal in Finder") {
                revealInFinder(url)
            }
            Button("New Subfolder...") {
                viewModel.promptNewSubfolder(url)
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

extension View {
    @ViewBuilder
    fileprivate func applyIf(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
