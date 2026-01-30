import SwiftUI

struct FaceBarView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?
    let imageURLs: [URL]
    let settingsViewModel: SettingsViewModel
    var isExpanded: Bool = false
    var onSelectImages: ((Set<URL>) -> Void)?
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    var onToggleExpanded: (() -> Void)?

    @State private var selectedGroup: FaceGroup?
    @State private var multiSelectedGroupIDs: Set<UUID> = []
    @State private var showMergeSuggestions = false
    @State private var showClusteringSettings = false
    @State private var isCheckingKnownPeople = false
    @State private var knownPeopleMatchCount = 0
    @State private var refinementCount = 0
    @AppStorage("knownPeopleMode") private var knownPeopleMode: String = "off"

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
            // Scan button with settings
            HStack(spacing: 4) {
                scanButton

                Button {
                    showClusteringSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clustering settings")
                .popover(isPresented: $showClusteringSettings) {
                    ClusteringSettingsPopover(settingsViewModel: settingsViewModel)
                }
            }

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
                            FaceGroupDetailView(group: group, viewModel: viewModel, settingsViewModel: settingsViewModel, onSelectImages: onSelectImages, onPhotosDeleted: onPhotosDeleted)
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

            // Refine button (when there are named and unnamed groups)
            if viewModel.canRefine {
                Divider()
                    .frame(height: 58)

                Button {
                    refinementCount = viewModel.refineWithNamedGroups()
                    // Clear the badge after a delay
                    if refinementCount > 0 {
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            await MainActor.run {
                                refinementCount = 0
                            }
                        }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 16))
                            Text("Refine")
                                .font(.system(size: 9))
                        }
                        .frame(width: 52, height: 48)

                        // Badge showing new suggestions found
                        if refinementCount > 0 {
                            Text("\(refinementCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .clipShape(Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Find matches for unnamed groups using named groups as reference")
            }

            // Check Known People button (On Demand mode)
            if knownPeopleMode == "onDemand" && viewModel.scanComplete {
                Divider()
                    .frame(height: 58)

                Button {
                    checkKnownPeople()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 2) {
                            if isCheckingKnownPeople {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "person.text.rectangle")
                                    .font(.system(size: 16))
                            }
                            Text("Known")
                                .font(.system(size: 9))
                        }
                        .frame(width: 52, height: 48)

                        // Badge showing match count
                        if knownPeopleMatchCount > 0 {
                            Text("\(knownPeopleMatchCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .clipShape(Capsule())
                                .offset(x: 4, y: -2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCheckingKnownPeople)
                .help("Match faces against Known People database")
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

    private func checkKnownPeople() {
        guard let faceData = viewModel.faceData else { return }

        isCheckingKnownPeople = true
        knownPeopleMatchCount = 0

        Task {
            var matchCount = 0

            // Get unnamed groups only
            let unnamedGroups = faceData.groups.filter { $0.name == nil }

            for group in unnamedGroups {
                // Get the representative face's embedding
                guard let face = faceData.faces.first(where: { $0.id == group.representativeFaceID }) else {
                    continue
                }

                // Match against known people
                let matches = await KnownPeopleService.shared.matchFace(
                    featurePrintData: face.featurePrintData,
                    threshold: 0.45,
                    maxResults: 1
                )

                if let bestMatch = matches.first {
                    // Auto-name the group with the matched person's name
                    await MainActor.run {
                        viewModel.nameGroup(group.id, name: bestMatch.person.name)
                    }
                    matchCount += 1
                }
            }

            await MainActor.run {
                isCheckingKnownPeople = false
                knownPeopleMatchCount = matchCount
            }

            // Clear the badge after a delay
            if matchCount > 0 {
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run {
                    knownPeopleMatchCount = 0
                }
            }
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

// MARK: - Clustering Settings Popover

struct ClusteringSettingsPopover: View {
    @Bindable var settingsViewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Face Clustering")
                .font(.headline)

            // Recognition mode picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Mode", selection: $settingsViewModel.faceRecognitionMode) {
                    ForEach(FaceRecognitionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(settingsViewModel.faceRecognitionMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Clustering threshold slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", settingsViewModel.effectiveClusteringThreshold))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if settingsViewModel.faceRecognitionMode == .visionFeaturePrint {
                    Slider(value: $settingsViewModel.visionClusteringThreshold, in: 0.3...0.8, step: 0.01)
                } else {
                    Slider(value: $settingsViewModel.faceClothingClusteringThreshold, in: 0.3...0.8, step: 0.01)
                }

                HStack {
                    Text("Strict")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("Loose")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Text("Changes apply to new scans. Option+click Scan to rescan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 260)
    }
}
