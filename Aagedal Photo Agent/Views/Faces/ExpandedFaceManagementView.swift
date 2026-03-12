import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Selection State (Observable for fine-grained updates)

@Observable
final class FaceSelectionState {
    var selectedFaceIDs: Set<UUID> = []
    var draggedFaceIDs: Set<UUID> = []
    var draggedGroupID: UUID?
    var focusedFaceID: UUID?
    var selectionAnchorID: UUID?  // For shift-selection

    func isSelected(_ faceID: UUID) -> Bool {
        selectedFaceIDs.contains(faceID)
    }

    func isDragged(_ faceID: UUID) -> Bool {
        draggedFaceIDs.contains(faceID)
    }

    func isFocused(_ faceID: UUID) -> Bool {
        focusedFaceID == faceID
    }

    func toggleSelection(_ faceID: UUID, commandKey: Bool) {
        if commandKey {
            if selectedFaceIDs.contains(faceID) {
                selectedFaceIDs.remove(faceID)
            } else {
                selectedFaceIDs.insert(faceID)
            }
        } else {
            selectedFaceIDs.removeAll()
            selectedFaceIDs.insert(faceID)
        }
        focusedFaceID = faceID
        selectionAnchorID = faceID
    }

    func selectFace(_ faceID: UUID) {
        selectedFaceIDs.removeAll()
        selectedFaceIDs.insert(faceID)
        focusedFaceID = faceID
        selectionAnchorID = faceID
    }

    func extendSelection(to faceID: UUID, allFaces: [UUID]) {
        guard let anchorID = selectionAnchorID,
              let anchorIndex = allFaces.firstIndex(of: anchorID),
              let targetIndex = allFaces.firstIndex(of: faceID) else {
            selectFace(faceID)
            return
        }

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedFaceIDs = Set(allFaces[range])
        focusedFaceID = faceID
    }
}

// MARK: - Main View

struct ExpandedFaceManagementView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    @Bindable var selectionState: FaceSelectionState
    var onClose: () -> Void
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    @State private var groupToDelete: FaceGroup?
    @State private var showDeleteGroupAlert = false
    @State private var showingNameListFilePicker = false
    @State private var showSuggestionsPanel = true

    private let suggestionsPanelWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            // Main face management area
            VStack(spacing: 0) {
                toolbar
                Divider()
                FaceGroupCollectionRepresentable(
                    viewModel: viewModel,
                    selectionState: selectionState,
                    settingsViewModel: settingsViewModel,
                    callbacks: FaceGroupCardCallbacks(
                        onDeleteGroup: { group in
                            groupToDelete = group
                            showDeleteGroupAlert = true
                        },
                        onChooseListFile: { showingNameListFilePicker = true },
                        onToggleExpand: nil, // Handled internally by controller
                        onOpenFullScreen: onOpenFullScreen,
                        onPhotosDeleted: onPhotosDeleted
                    )
                )
            }

            // Suggestions panel on the right
            if showSuggestionsPanel {
                Divider()
                FaceSuggestionsPanel(
                    viewModel: viewModel,
                    onClose: { showSuggestionsPanel = false }
                )
                .frame(width: suggestionsPanelWidth)
            }
        }
        .onChange(of: selectionState.focusedFaceID) { _, newValue in
            updateThumbnailReplacementSelection(for: newValue)
        }
        .alert(
            "Delete Group & Photos",
            isPresented: $showDeleteGroupAlert,
            presenting: groupToDelete
        ) { group in
            Button("Delete Faces Only") {
                let faceIDs = Set(group.faceIDs)
                viewModel.deleteFaces(faceIDs)
                groupToDelete = nil
            }
            Button("Move Photos to Trash", role: .destructive) {
                let trashed = viewModel.deleteGroup(group.id, includePhotos: true)
                onPhotosDeleted?(trashed)
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                groupToDelete = nil
            }
        } message: { group in
            let photoCount = Set(group.faceIDs.compactMap { faceID in
                viewModel.face(byID: faceID)?.imageURL
            }).count
            Text("This will delete \(group.faceIDs.count) face(s) across \(photoCount) photo(s). Moving photos to Trash cannot be undone from this app.")
        }
        .fileImporter(
            isPresented: $showingNameListFilePicker,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settingsViewModel.setPersonShownListURL(url)
            }
        }
    }

    private func updateThumbnailReplacementSelection(for faceID: UUID?) {
        guard let faceID,
              let groupID = viewModel.face(byID: faceID)?.groupID else {
            viewModel.selectGroupForThumbnailReplacement(nil)
            return
        }
        viewModel.selectGroupForThumbnailReplacement(groupID, faceID: faceID)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack {
            Button {
                viewModel.createNewGroup(withFaces: selectionState.selectedFaceIDs)
                selectionState.selectedFaceIDs.removeAll()
            } label: {
                Label("New Group", systemImage: "plus")
            }
            .disabled(selectionState.selectedFaceIDs.isEmpty)

            Divider()
                .frame(height: 16)

            Menu {
                ForEach(FaceGroupSortMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.sortMode = mode
                    } label: {
                        HStack {
                            Text(mode.rawValue)
                            if viewModel.sortMode == mode {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider()
                .frame(height: 16)

            if let faceData = viewModel.faceData {
                Text("\(faceData.faces.count) faces in \(faceData.groups.count) groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SelectionInfoView(selectionState: selectionState, viewModel: viewModel)

            // Toggle suggestions panel
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSuggestionsPanel.toggle()
                }
            } label: {
                Label(
                    showSuggestionsPanel ? "Hide Suggestions" : "Show Suggestions",
                    systemImage: showSuggestionsPanel ? "sidebar.trailing" : "sidebar.trailing"
                )
            }
            .help(showSuggestionsPanel ? "Hide suggestions panel" : "Show suggestions panel")

            Button {
                onClose()
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Selection Info View (isolated to prevent toolbar re-renders)

struct SelectionInfoView: View {
    @Bindable var selectionState: FaceSelectionState
    let viewModel: FaceRecognitionViewModel

    var body: some View {
        if !selectionState.selectedFaceIDs.isEmpty {
            Button(role: .destructive) {
                viewModel.deleteFaces(selectionState.selectedFaceIDs)
                selectionState.selectedFaceIDs.removeAll()
            } label: {
                Label("Delete \(selectionState.selectedFaceIDs.count)", systemImage: "trash")
            }

            Text("\(selectionState.selectedFaceIDs.count) face\(selectionState.selectedFaceIDs.count == 1 ? "" : "s") selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - Face Suggestions Panel

struct FaceSuggestionsPanel: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    var onClose: () -> Void

    @AppStorage("knownPeopleMode") private var knownPeopleMode: String = "off"
    @State private var isRefining = false
    @State private var isCheckingKnown = false
    @State private var lastRefinementCount = 0
    @State private var lastKnownCount = 0

    /// The single selected group for thumbnail replacement (if any)
    private var replaceThumbnailCandidate: (groupID: UUID, personID: UUID)? {
        guard let groupID = viewModel.selectedThumbnailReplacementGroupID,
              let match = viewModel.knownPersonMatchByGroup[groupID],
              viewModel.groupNameMatchesKnownPerson(groupID),
              KnownPeopleService.shared.person(byID: match.personID) != nil else {
            return nil
        }
        return (groupID: groupID, personID: match.personID)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Suggestions")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // Action buttons
                    VStack(spacing: 12) {
                        // Refine button
                        if viewModel.canRefine {
                            Button {
                                isRefining = true
                                lastRefinementCount = viewModel.refineWithNamedGroups()
                                isRefining = false
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Refine with Named Groups")
                                            .font(.subheadline)
                                        Text("Match unnamed groups against named ones")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if lastRefinementCount > 0 {
                                        Text("+\(lastRefinementCount)")
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.blue, in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(isRefining)
                        }

                        // Known People button
                        if knownPeopleMode != "off" {
                            Button {
                                checkKnownPeople()
                            } label: {
                                HStack {
                                    Image(systemName: "person.text.rectangle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Check Known People")
                                            .font(.subheadline)
                                        Text("Match against global database")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isCheckingKnown {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else if lastKnownCount > 0 {
                                        Text("+\(lastKnownCount)")
                                            .font(.caption)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.green, in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(isCheckingKnown)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)

                    // Replace Thumbnail card (single selection)
                    if let candidate = replaceThumbnailCandidate {
                        Divider()
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Update Known People")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            ReplaceThumbnailCard(
                                groupID: candidate.groupID,
                                personID: candidate.personID,
                                viewModel: viewModel
                            )
                            .padding(.horizontal)
                        }
                    }

                    Divider()
                        .padding(.horizontal)

                    // Merge suggestions list
                    if viewModel.mergeSuggestions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Name some groups and click Refine to find matches")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Merge Suggestions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)

                            LazyVStack(spacing: 8) {
                                ForEach(viewModel.mergeSuggestions) { suggestion in
                                    SuggestionRow(suggestion: suggestion, viewModel: viewModel)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom)
                        }
                    }
                }
            }
        }
        .background(.background)
    }

    private func checkKnownPeople() {
        guard let faceData = viewModel.faceData else { return }

        isCheckingKnown = true
        lastKnownCount = 0

        var matchCount = 0
        var lastMatchedGroupID: UUID?
        let unnamedGroups = faceData.groups.filter { $0.name == nil }

        for group in unnamedGroups {
            guard let face = faceData.faces.first(where: { $0.id == group.representativeFaceID }) else {
                continue
            }

            if let bestMatch = KnownPeopleService.shared.bestAutoMatch(
                featurePrintData: face.featurePrintData
            ) {
                viewModel.nameGroup(group.id, name: bestMatch.person.name)
                // Track the match for "Replace Thumbnail" feature
                viewModel.knownPersonMatchByGroup[group.id] = (personID: bestMatch.person.id, confidence: bestMatch.confidence)
                lastMatchedGroupID = group.id
                matchCount += 1
            }
        }

        // Select the last matched group for thumbnail replacement suggestion
        viewModel.selectGroupForThumbnailReplacement(lastMatchedGroupID)

        isCheckingKnown = false
        lastKnownCount = matchCount
    }
}

// MARK: - Replace Thumbnail Card

struct ReplaceThumbnailCard: View {
    let groupID: UUID
    let personID: UUID
    @Bindable var viewModel: FaceRecognitionViewModel

    @State private var currentThumbnail: NSImage?
    @State private var newThumbnail: NSImage?
    @State private var isReplacing = false

    private var group: FaceGroup? {
        viewModel.group(byID: groupID)
    }

    private var person: KnownPerson? {
        KnownPeopleService.shared.person(byID: personID)
    }

    var body: some View {
        if group != nil, let person {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Replace thumbnail for \(person.name)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        viewModel.clearThumbnailReplacementSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }

                HStack(spacing: 12) {
                    // Current thumbnail in database
                    VStack {
                        thumbnailView(currentThumbnail)
                        Text("Current")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    // New thumbnail from this scan
                    VStack {
                        thumbnailView(newThumbnail)
                        Text("New")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        replaceThumbnail()
                    } label: {
                        if isReplacing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Replace")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReplacing)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onAppear {
                loadThumbnails()
            }
            .onChange(of: viewModel.selectedThumbnailReplacementFaceID) { _, _ in
                loadThumbnails()
            }
            .onChange(of: groupID) { _, _ in
                loadThumbnails()
            }
            .onChange(of: personID) { _, _ in
                loadThumbnails()
            }
        }
    }

    @ViewBuilder
    private func thumbnailView(_ image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        )
    }

    private func loadThumbnails() {
        // Load current thumbnail from Known People database
        currentThumbnail = KnownPeopleService.shared.loadThumbnail(for: personID)

        // Load new thumbnail from current scan
        if let faceID = viewModel.selectedThumbnailReplacementFaceID ?? group?.representativeFaceID {
            newThumbnail = viewModel.thumbnailImage(for: faceID)
        } else {
            newThumbnail = nil
        }
    }

    private func replaceThumbnail() {
        guard let group else { return }

        let faceID = viewModel.selectedThumbnailReplacementFaceID ?? group.representativeFaceID
        guard let thumbImage = viewModel.thumbnailImage(for: faceID),
              let tiffData = thumbImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return
        }

        isReplacing = true

        do {
            try KnownPeopleService.shared.replaceThumbnail(for: personID, newThumbnailData: jpegData)
            // Clear selection after successful replacement
            viewModel.clearThumbnailReplacementSelection()
        } catch {
            // Handle error silently
        }

        isReplacing = false
    }
}

// MARK: - Suggestion Row

struct SuggestionRow: View {
    let suggestion: MergeSuggestion
    @Bindable var viewModel: FaceRecognitionViewModel

    private var group1: FaceGroup? {
        viewModel.group(byID: suggestion.group1ID)
    }

    private var group2: FaceGroup? {
        viewModel.group(byID: suggestion.group2ID)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Group 1
            groupPreview(group1)

            // Similarity indicator
            VStack(spacing: 2) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\(Int(suggestion.similarity * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36)

            // Group 2
            groupPreview(group2)

            Spacer()

            // Actions
            VStack(spacing: 4) {
                Button {
                    viewModel.applyMergeSuggestion(suggestion)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Merge groups")

                Button {
                    viewModel.dismissMergeSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss suggestion")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func groupPreview(_ group: FaceGroup?) -> some View {
        VStack(spacing: 4) {
            if let group,
               let image = viewModel.thumbnailImage(for: group.representativeFaceID) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)
            }

            Text(group?.name ?? "Unnamed")
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(maxWidth: 60)
        }
    }
}
