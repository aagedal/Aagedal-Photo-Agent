import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: BrowserViewModel
    var faceCount: Int = 0
    var faceGroupCount: Int = 0
    /// Fired when the user clicks into this grid (split-view pane focus).
    var onFocus: (() -> Void)? = nil
    /// Whether this pane contributes the filter/sort/search toolbar items. In split view
    /// both panes are in the hierarchy, so only the active one provides them — otherwise
    /// the groups duplicate and overflow into the toolbar's "»" menu.
    var providesToolbar: Bool = true

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading images...")
            } else if viewModel.images.isEmpty {
                ContentUnavailableView {
                    if viewModel.iCloudDownloadNotice != nil {
                        Label("Downloading from iCloud", systemImage: "icloud.and.arrow.down")
                    } else {
                        Label("No Images", systemImage: "photo.on.rectangle.angled")
                    }
                } description: {
                    if let notice = viewModel.iCloudDownloadNotice {
                        Text(notice)
                    } else if viewModel.currentFolderURL == nil {
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
            } else if viewModel.visibleImages.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No images match the current search or filters.")
                } actions: {
                    if viewModel.isFilteringActive {
                        Button("Clear Filters") {
                            viewModel.clearFilters()
                        }
                    }
                }
            } else {
                ZStack {
                    CollectionViewGridRepresentable(viewModel: viewModel, onFocus: onFocus)

                    // Bottom-left overlays
                    VStack(alignment: .leading, spacing: 6) {
                        // Sort feedback (temporary)
                        if let sortFeedback = viewModel.sortFeedback {
                            Text(sortFeedback)
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.75), in: Capsule())
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if let notice = viewModel.iCloudDownloadNotice {
                            Label(notice, systemImage: "icloud.and.arrow.down")
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // Permanent image count overlay
                        ImageCountOverlayView(
                            totalImageCount: viewModel.images.count,
                            visibleImageCount: viewModel.visibleImages.count,
                            isFiltering: viewModel.isFilteringActive,
                            selectedCount: viewModel.selectedImageIDs.count,
                            faceCount: faceCount,
                            faceGroupCount: faceGroupCount
                        )
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.sortFeedback)
                    .animation(.easeInOut(duration: 0.25), value: viewModel.iCloudDownloadNotice)

                    // Thumbnail size slider (bottom-right)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "square.grid.3x3")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Slider(value: $viewModel.thumbnailScale, in: 0.5...2.0, step: 0.1)
                                    .frame(width: 120)
                                Image(systemName: "square.grid.2x2")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                        }
                    }
                }
            }
        }
        .toolbar {
            if providesToolbar {
                ToolbarItemGroup(placement: .automatic) {
                    ColorLabelFilterBar(selectedLabels: $viewModel.selectedColorLabels)
                        .disabled(viewModel.images.isEmpty)
                        .padding(8)
                }


                ToolbarItemGroup(placement: .automatic) {
                    StarRatingFilterBar(minimumRating: $viewModel.minimumStarRating)
                        .disabled(viewModel.images.isEmpty)
                        .padding(8)

                    filterMenu
                }

                ToolbarItemGroup(placement: .automatic) {

                    Button {
                        viewModel.sortReversed.toggle()
                    } label: {
                        Image(systemName: viewModel.sortReversed ? "arrow.up" : "arrow.down")
                    }
                    .help(viewModel.sortReversed ? "Sort ascending" : "Sort descending")
                    .disabled(viewModel.sortOrder == .manual)

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

                ToolbarItemGroup(placement: .automatic) {
                    searchField
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Person Shown", selection: $viewModel.personShownFilter) {
                ForEach(BrowserViewModel.PersonShownFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Picker("Edited", selection: $viewModel.editedFilter) {
                ForEach(BrowserViewModel.EditedFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Picker("Required Metadata", selection: $viewModel.requiredMetadataFilter) {
                ForEach(BrowserViewModel.RequiredMetadataFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Menu("Missing Field") {
                ForEach(IPTCMetadata.FieldKey.userSelectable, id: \.self) { field in
                    Toggle(field.displayName, isOn: Binding(
                        get: { viewModel.missingFieldFilters.contains(field) },
                        set: { isOn in
                            if isOn { viewModel.missingFieldFilters.insert(field) }
                            else { viewModel.missingFieldFilters.remove(field) }
                        }
                    ))
                }
            }

            Divider()

            Button("Clear Filters") {
                viewModel.clearFilters()
            }
            .disabled(!viewModel.isFilteringActive)
        } label: {
            Label(
                "Filters",
                systemImage: viewModel.isFilteringActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter images")
        .disabled(viewModel.images.isEmpty)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .disabled(viewModel.images.isEmpty)
    }

}
