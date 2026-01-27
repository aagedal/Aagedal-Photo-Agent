import SwiftUI

struct FaceBarView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?
    let imageURLs: [URL]
    var onSelectImages: ((Set<URL>) -> Void)?

    @State private var selectedGroup: FaceGroup?

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
                            image: viewModel.thumbnailCache[group.representativeFaceID]
                        )
                        .onTapGesture {
                            selectedGroup = group
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 76)
        .background(.bar)
        .popover(item: $selectedGroup) { group in
            FaceGroupDetailView(group: group, viewModel: viewModel, onSelectImages: onSelectImages)
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
                        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL, rescan: true)
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
