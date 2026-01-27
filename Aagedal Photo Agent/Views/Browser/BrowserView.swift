import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: BrowserViewModel
    @Bindable var faceViewModel: FaceRecognitionViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.images.isEmpty {
                FaceBarView(
                    viewModel: faceViewModel,
                    folderURL: viewModel.currentFolderURL,
                    imageURLs: viewModel.images.map(\.url)
                )
                Divider()
            }

            Group {
                if viewModel.isLoading {
                    ProgressView("Loading images...")
                } else if viewModel.images.isEmpty {
                    ContentUnavailableView {
                        Label("No Images", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        if viewModel.currentFolderURL == nil {
                            Text("Open a folder to browse images")
                        } else {
                            Text("No supported images found in this folder")
                        }
                    } actions: {
                        Button("Open Folder") {
                            viewModel.openFolder()
                        }
                    }
                } else if let error = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else {
                    ThumbnailGridView(viewModel: viewModel)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Sort", selection: Binding(
                    get: { viewModel.sortOrder },
                    set: { newValue in
                        if newValue == .manual && viewModel.sortOrder != .manual {
                            viewModel.initializeManualOrder(from: viewModel.sortedImages)
                        }
                        viewModel.sortOrder = newValue
                    }
                )) {
                    ForEach(BrowserViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }

            ToolbarItem(placement: .automatic) {
                Text("\(viewModel.images.count) images")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }
}
