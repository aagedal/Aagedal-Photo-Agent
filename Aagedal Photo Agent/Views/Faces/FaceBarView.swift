import SwiftUI

struct FaceBarView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?
    let imageURLs: [URL]
    var isExpanded: Bool = false
    var onSelectImages: ((Set<URL>) -> Void)?
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    var onToggleExpanded: (() -> Void)?

    @State private var selectedGroup: FaceGroup?
    @State private var multiSelectedGroupIDs: Set<UUID> = []
    @State private var showMergeSuggestions = false

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
                            FaceGroupDetailView(group: group, viewModel: viewModel, onSelectImages: onSelectImages, onPhotosDeleted: onPhotosDeleted)
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

            // Merge suggestions indicator
            if !viewModel.mergeSuggestions.isEmpty {
                Divider()
                    .frame(height: 58)

                Button {
                    showMergeSuggestions = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 2) {
                            Image(systemName: "person.2.badge.gearshape")
                                .font(.system(size: 16))
                            Text("Suggestions")
                                .font(.system(size: 9))
                        }
                        .frame(width: 60, height: 48)

                        // Badge
                        Text("\(viewModel.mergeSuggestions.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .clipShape(Capsule())
                            .offset(x: 4, y: -2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMergeSuggestions) {
                    MergeSuggestionsPopover(viewModel: viewModel)
                }
                .help("Review merge suggestions for similar face groups")
            }

            Spacer()

            // Expand/collapse button
            if viewModel.scanComplete {
                Button {
                    // Dismiss any open popovers before toggling
                    selectedGroup = nil
                    showMergeSuggestions = false
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
                    // Option+click triggers full rescan
                    let forceFullScan = NSEvent.modifierFlags.contains(.option)
                    viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL, forceFullScan: forceFullScan)
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
                .help("Click to scan new images. Option+click to force full rescan.")
                .contextMenu {
                    Button("Rescan Folder (Force Full)") {
                        guard let folderURL else { return }
                        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL, forceFullScan: true)
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

// MARK: - Merge Suggestions Popover

struct MergeSuggestionsPopover: View {
    @Bindable var viewModel: FaceRecognitionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Suggestions")
                .font(.headline)

            if viewModel.mergeSuggestions.isEmpty {
                Text("No suggestions")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(viewModel.mergeSuggestions) { suggestion in
                            MergeSuggestionRow(suggestion: suggestion, viewModel: viewModel)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

struct MergeSuggestionRow: View {
    let suggestion: MergeSuggestion
    @Bindable var viewModel: FaceRecognitionViewModel

    private var group1: FaceGroup? {
        viewModel.faceData?.groups.first { $0.id == suggestion.group1ID }
    }

    private var group2: FaceGroup? {
        viewModel.faceData?.groups.first { $0.id == suggestion.group2ID }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Group 1 thumbnail
            groupThumbnail(group1)

            VStack(spacing: 2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("\(Int(suggestion.similarity * 100))%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Group 2 thumbnail
            groupThumbnail(group2)

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                Button("Merge") {
                    viewModel.applyMergeSuggestion(suggestion)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    viewModel.dismissMergeSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func groupThumbnail(_ group: FaceGroup?) -> some View {
        if let group,
           let image = viewModel.thumbnailCache[group.representativeFaceID] {
            VStack(spacing: 2) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                Text(group.name ?? "Unknown")
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .frame(maxWidth: 50)
            }
        } else {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 40)
        }
    }
}
