import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: BrowserViewModel

    var body: some View {
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
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Sort", selection: $viewModel.sortOrder) {
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
