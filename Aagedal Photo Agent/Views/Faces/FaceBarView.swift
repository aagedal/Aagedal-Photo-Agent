import SwiftUI
import UniformTypeIdentifiers

struct FaceBarView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let folderURL: URL?
    let images: [ImageFile]
    let settingsViewModel: SettingsViewModel
    var isExpanded: Bool = false
    var selectionState: FaceSelectionState?  // Passed from expanded view for drag detection
    var onSelectImages: ((Set<URL>) -> Void)?
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    var onToggleExpanded: (() -> Void)?
    var onOpenPeopleDatabase: (() -> Void)?

    @State private var selectedGroup: FaceGroup?
    @State private var multiSelectedGroupIDs: Set<UUID> = []
    @State private var showMergeSuggestions = false
    @State private var showClusteringSettings = false
    @State private var isCheckingKnownPeople = false
    @State private var isApplyingAllNames = false
    @State private var knownPeopleMatchCount = 0
    @State private var refinementCount = 0
    @State private var highlightedGroupID: UUID?
    @State private var isDraggingOverBar: Bool = false
    @AppStorage("knownPeopleMode") private var knownPeopleMode: String = "off"

    /// Named groups (shown first in the bar)
    private var namedGroups: [FaceGroup] {
        viewModel.sortedGroups.filter { $0.name != nil }
    }

    /// Unnamed groups (shown after the divider)
    private var unnamedGroups: [FaceGroup] {
        viewModel.sortedGroups.filter { $0.name == nil }
    }

    /// Height of the face bar
    private let barHeight: CGFloat = 100

    private var imageURLs: [URL] {
        images.map(\.url)
    }

    private var isMultiSelecting: Bool {
        multiSelectedGroupIDs.count >= 2
    }

    private var canApplyAllNames: Bool {
        viewModel.scanComplete && !namedGroups.isEmpty && !isApplyingAllNames
    }

    private var canUnmergeSelection: Bool {
        guard let data = viewModel.faceData else { return false }
        return multiSelectedGroupIDs.contains { id in
            data.groups.first(where: { $0.id == id })?.faceIDs.count ?? 0 > 1
        }
    }

    private func thumbnailFaceID(for group: FaceGroup) -> UUID {
        if group.id == viewModel.selectedThumbnailReplacementGroupID,
           let selectedFaceID = viewModel.selectedThumbnailReplacementFaceID,
           group.faceIDs.contains(selectedFaceID) {
            return selectedFaceID
        }
        return group.representativeFaceID
    }

    var body: some View {
        HStack(spacing: 8) {
            // Scan button with settings
            HStack(spacing: 4) {
                Button {
                    applyAllNamesToMetadata()
                } label: {
                    VStack(spacing: 2) {
                        if isApplyingAllNames {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 20))
                        }
                        Text("Apply Names")
                            .font(.system(size: 10))
                    }
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canApplyAllNames)
                .help("Apply all named faces to metadata")

                scanButton

                VStack(spacing: 2) {
                    // Reset/rescan button on top
                    Button {
                        guard let folderURL else { return }
                        viewModel.scanFolder(imageURLs: imageURLs, folderURL: folderURL, forceFullScan: true)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.orange)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Force full rescan")

                    // Cog button below
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
            }

            Divider()
                .frame(height: 58)

            // Face group thumbnails (show in-progress groups during scanning)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if viewModel.isScanning {
                        // During scanning: show intermediate groups (non-interactive)
                        ForEach(viewModel.scanningGroups) { group in
                            FaceGroupThumbnail(
                                group: group,
                                image: viewModel.thumbnailImage(for: group.representativeFaceID),
                                isMultiSelected: false
                            )
                            .opacity(0.7)
                        }
                    } else {
                        // Named groups first (interactive with drop targets)
                        ForEach(namedGroups) { group in
                            faceGroupThumbnailWithActions(group: group)
                        }

                        // Divider between named and unnamed groups
                        if !namedGroups.isEmpty && !unnamedGroups.isEmpty {
                            Divider()
                                .frame(height: 70)
                        }

                        // Unnamed groups after divider
                        ForEach(unnamedGroups) { group in
                            faceGroupThumbnailWithActions(group: group)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .allowsHitTesting(!viewModel.isScanning)

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
        .frame(height: barHeight)
        .background(.bar)
    }

    // MARK: - Face Group Thumbnail with Actions

    @ViewBuilder
    private func faceGroupThumbnailWithActions(group: FaceGroup) -> some View {
        FaceGroupThumbnail(
            group: group,
            image: viewModel.thumbnailImage(for: thumbnailFaceID(for: group)),
            isMultiSelected: multiSelectedGroupIDs.contains(group.id),
            isHighlighted: highlightedGroupID == group.id,
            isExpanded: true
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
        .onDrop(of: [.text], delegate: FaceBarDropDelegate(
            targetGroupID: group.id,
            viewModel: viewModel,
            selectionState: selectionState,
            highlightedGroupID: $highlightedGroupID,
            isDraggingOverBar: $isDraggingOverBar
        ))
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

        var matchCount = 0

        // Get unnamed groups only
        let unnamedGroups = faceData.groups.filter { $0.name == nil }

        for group in unnamedGroups {
            // Get the representative face's embedding
            guard let face = faceData.faces.first(where: { $0.id == group.representativeFaceID }) else {
                continue
            }

            // Match against known people
            if let bestMatch = KnownPeopleService.shared.bestAutoMatch(
                featurePrintData: face.featurePrintData
            ) {
                // Auto-name the group with the matched person's name
                viewModel.nameGroup(group.id, name: bestMatch.person.name)
                matchCount += 1
            }
        }

        isCheckingKnownPeople = false
        knownPeopleMatchCount = matchCount

        // Clear the badge after a delay
        if matchCount > 0 {
            Task {
                try? await Task.sleep(for: .seconds(5))
                knownPeopleMatchCount = 0
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

    private func applyAllNamesToMetadata() {
        guard !isApplyingAllNames else { return }
        isApplyingAllNames = true
        viewModel.applyAllNamesToMetadata(images: images, folderURL: folderURL) {
            isApplyingAllNames = false
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
           let image = viewModel.thumbnailImage(for: group.representativeFaceID) {
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

            if settingsViewModel.faceRecognitionMode == .faceAndClothing {
                Divider()
                Toggle("Second-pass can join existing groups", isOn: $settingsViewModel.faceClothingSecondPassAttachToExisting)
                Text("If off, leftovers only cluster among themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Changes apply to new scans. Option+click Scan to rescan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 260)
    }
}

// MARK: - Face Bar Drop Delegate

struct FaceBarDropDelegate: DropDelegate {
    let targetGroupID: UUID
    let viewModel: FaceRecognitionViewModel
    let selectionState: FaceSelectionState?
    @Binding var highlightedGroupID: UUID?
    @Binding var isDraggingOverBar: Bool

    func dropEntered(info: DropInfo) {
        // Don't highlight if dragging within the same group
        if selectionState?.draggedGroupID != targetGroupID {
            highlightedGroupID = targetGroupID
        }
        isDraggingOverBar = true
    }

    func dropExited(info: DropInfo) {
        if highlightedGroupID == targetGroupID {
            highlightedGroupID = nil
        }
        // Only set isDraggingOverBar to false if we're exiting the entire bar area
        // This is handled by checking if we're still over any group
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isDraggingOverBar = true
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Don't allow drop if the dragged faces are from this same group
        if selectionState?.draggedGroupID == targetGroupID {
            return false
        }
        return info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        highlightedGroupID = nil
        isDraggingOverBar = false

        guard let item = info.itemProviders(for: [.text]).first else { return false }

        let targetID = targetGroupID
        let vm = viewModel
        let state = selectionState

        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }

            Task { @MainActor in
                // Parse the comma-separated UUID string
                let ids = Set(string.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
                guard !ids.isEmpty else { return }

                // Filter out faces that are already in the target group
                let facesToMove: Set<UUID>
                if let data = vm.faceData {
                    facesToMove = ids.filter { faceID in
                        data.faces.first(where: { $0.id == faceID })?.groupID != targetID
                    }
                } else {
                    facesToMove = ids
                }

                vm.moveFaces(facesToMove, toGroup: targetID)
                state?.selectedFaceIDs.removeAll()
                state?.draggedFaceIDs.removeAll()
            }
        }

        return true
    }
}
