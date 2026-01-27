import SwiftUI

struct FaceBarView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?
    let imageURLs: [URL]
    var isExpanded: Bool = false
    var onSelectImages: ((Set<URL>) -> Void)?
    var onToggleExpanded: (() -> Void)?

    @State private var selectedGroup: FaceGroup?
    @State private var multiSelectedGroupIDs: Set<UUID> = []

    private var isMultiSelecting: Bool {
        multiSelectedGroupIDs.count >= 2
    }

    private var canUnmergeSelection: Bool {
        guard let data = viewModel.faceData else { return false }
        return multiSelectedGroupIDs.contains { id in
            data.groups.first(where: { $0.id == id })?.faceIDs.count ?? 0 > 1
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Scan button
            scanButton

            Divider()
                .frame(height: 58)

            // Face group thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.sortedGroups) { group in
                        FaceGroupThumbnail(
                            group: group,
                            image: viewModel.thumbnailCache[group.representativeFaceID],
                            isMultiSelected: multiSelectedGroupIDs.contains(group.id)
                        )
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                toggleMultiSelect(group.id)
                            } else {
                                multiSelectedGroupIDs.removeAll()
                                selectedGroup = group
                            }
                        }
                        .popover(isPresented: Binding<Bool>(
                            get: { selectedGroup?.id == group.id },
                            set: { newValue in if !newValue { selectedGroup = nil } }
                        )) {
                            FaceGroupDetailView(group: group, viewModel: viewModel, onSelectImages: onSelectImages)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            // Multi-select action bar
            if isMultiSelecting {
                Divider()
                    .frame(height: 58)

                VStack(spacing: 4) {
                    Button {
                        viewModel.mergeMultipleGroups(multiSelectedGroupIDs)
                        multiSelectedGroupIDs.removeAll()
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 14))
                            Text("Merge")
                                .font(.system(size: 9))
                        }
                        .frame(width: 52, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.ungroupMultiple(multiSelectedGroupIDs)
                        multiSelectedGroupIDs.removeAll()
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 14))
                            Text("Unmerge")
                                .font(.system(size: 9))
                        }
                        .frame(width: 52, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUnmergeSelection)
                }

                Text("\(multiSelectedGroupIDs.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Expand/collapse button
            if viewModel.scanComplete {
                Button {
                    onToggleExpanded?()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            .font(.system(size: 16))
                        Text(isExpanded ? "Collapse" : "Expand")
                            .font(.system(size: 9))
                    }
                    .frame(width: 52, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse face manager" : "Expand face manager")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 76)
        .background(.bar)
    }

    private func toggleMultiSelect(_ id: UUID) {
        if multiSelectedGroupIDs.contains(id) {
            multiSelectedGroupIDs.remove(id)
        } else {
            multiSelectedGroupIDs.insert(id)
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        Group {
            if viewModel.isScanning {
                VStack(spacing: 2) {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.scanProgress)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)
            } else {
                Button {
                    guard let folderURL else { return }
                    viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: viewModel.scanComplete ? "checkmark.circle.fill" : "camera.viewfinder")
                            .font(.system(size: 20))
                            .foregroundStyle(viewModel.scanComplete ? .green : .primary)
                        Text("Scan")
                            .font(.system(size: 10))
                    }
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rescan Folder") {
                        guard let folderURL else { return }
                        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL)
                    }
                    Button("Delete Face Data", role: .destructive) {
                        guard let folderURL else { return }
                        viewModel.deleteFaceData(for: folderURL)
                    }
                }
            }
        }
    }
}
