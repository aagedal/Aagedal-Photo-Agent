import SwiftUI

struct BrowserView: View {
    @Bindable var viewModel: BrowserViewModel
    var faceCount: Int = 0
    var faceGroupCount: Int = 0

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
                    CollectionViewGridRepresentable(viewModel: viewModel)

                    // Thumbnail generation progress (bottom-left)
                    if viewModel.thumbnailService.isPreGenerating {
                        VStack {
                            Spacer()
                            HStack {
                                ThumbnailGenerationProgressView(
                                    completed: viewModel.thumbnailService.preGenerateCompleted,
                                    total: viewModel.thumbnailService.preGenerateTotal,
                                    onCancel: { viewModel.thumbnailService.cancelBackgroundGeneration() }
                                )
                                .padding(8)
                                Spacer()
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.25), value: viewModel.thumbnailService.isPreGenerating)
                    }

                    // Sort feedback overlay (bottom-left)
                    if let sortFeedback = viewModel.sortFeedback {
                        VStack {
                            Spacer()
                            HStack {
                                Text(sortFeedback)
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.black.opacity(0.7), in: Capsule())
                                    .padding(8)
                                Spacer()
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.easeInOut(duration: 0.2), value: viewModel.sortFeedback)
                    }

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
                Button {
                    viewModel.sortReversed.toggle()
                } label: {
                    Image(systemName: viewModel.sortReversed ? "arrow.up" : "arrow.down")
                }
                .help(viewModel.sortReversed ? "Sort ascending" : "Sort descending")
                .disabled(viewModel.sortOrder == .manual)
            }

            ToolbarItem(placement: .automatic) {
                filterMenu
            }

            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    if viewModel.isFilteringActive {
                        Text("\(viewModel.visibleImages.count) of \(viewModel.images.count) images")
                    } else {
                        Text("\(viewModel.images.count) images")
                    }
                    if viewModel.selectedImageIDs.count > 0 {
                        Text("\(viewModel.selectedImageIDs.count) selected")
                    }
                    if faceCount > 0 {
                        if faceGroupCount > 0 {
                            Text("\(faceCount) faces in \(faceGroupCount) groups")
                        } else {
                            Text("\(faceCount) faces")
                        }
                    }
                }
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }

            ToolbarItem(placement: .automatic) {
                searchField
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Minimum Stars", selection: $viewModel.minimumStarRating) {
                ForEach(StarRating.allCases, id: \.self) { rating in
                    Text(ratingFilterLabel(rating)).tag(rating)
                }
            }

            Menu("Label Colors") {
                Button("Any Label") {
                    viewModel.selectedColorLabels.removeAll()
                }

                Divider()

                ForEach(ColorLabel.allCases, id: \.self) { label in
                    Toggle(isOn: Binding(
                        get: { viewModel.selectedColorLabels.contains(label) },
                        set: { isOn in
                            if isOn {
                                viewModel.selectedColorLabels.insert(label)
                            } else {
                                viewModel.selectedColorLabels.remove(label)
                            }
                        }
                    )) {
                        Text(label.displayName)
                    }
                }
            }

            Picker("Person Shown", selection: $viewModel.personShownFilter) {
                ForEach(BrowserViewModel.PersonShownFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
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

    private func ratingFilterLabel(_ rating: StarRating) -> String {
        if rating == .none { return "Any Rating" }
        return "\(rating.displayString) & up"
    }
}
