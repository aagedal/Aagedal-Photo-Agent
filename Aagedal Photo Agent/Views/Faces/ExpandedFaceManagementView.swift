import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Fullscreen Image Window for Face View

private class FaceFullScreenWindow: NSWindow {
    var onDismiss: (() -> Void)?
    var onNavigate: ((Int) -> Void)?  // -1 for previous, +1 for next
    var onToggleUI: (() -> Void)?     // Toggle overlay visibility

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = Int(event.keyCode)
        switch keyCode {
        case 53, 49:  // Escape or Space → dismiss
            onDismiss?()
        case 123:  // Left arrow → previous
            onNavigate?(-1)
        case 124:  // Right arrow → next
            onNavigate?(1)
        case 4:  // 'H' key → toggle UI
            onToggleUI?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

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
    var onClose: () -> Void
    var onPhotosDeleted: ((Set<URL>) -> Void)?

    @State private var selectionState = FaceSelectionState()
    @State private var highlightedGroupID: UUID?
    @State private var highlightNewGroup = false
    @State private var editingGroupID: UUID?
    @State private var editingName: String = ""
    @FocusState private var isEditingFocused: Bool
    @State private var groupToDelete: FaceGroup?
    @State private var showDeleteGroupAlert = false
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var fullscreenFaces: [DetectedFace] = []
    @State private var fullscreenFaceIndex: Int = 0
    @State private var fullscreenWindow: FaceFullScreenWindow?
    @State private var fullscreenState: FaceFullScreenState?
    @State private var showingNameListFilePicker = false
    @State private var showSuggestionsPanel = true

    private let maxVisibleFaces = 12
    private let suggestionsPanelWidth: CGFloat = 320

    /// Generate a distinct color for a face group based on its UUID
    private func colorForGroup(_ groupID: UUID?) -> Color {
        guard let groupID else {
            return Color.gray  // Ungrouped faces
        }
        // Use first bytes of UUID for deterministic hue
        let hue = Double(groupID.uuid.0 ^ groupID.uuid.1) / 256.0
        return Color(hue: hue, saturation: 0.8, brightness: 0.9)
    }

    // Flat list of all visible face IDs for keyboard navigation
    private var allVisibleFaceIDs: [UUID] {
        var faceIDs: [UUID] = []
        for group in viewModel.sortedGroups {
            let faces = viewModel.faces(in: group)
            let isExpanded = expandedGroupIDs.contains(group.id)
            let visibleFaces = isExpanded ? faces : Array(faces.prefix(maxVisibleFaces))
            faceIDs.append(contentsOf: visibleFaces.map(\.id))
        }
        return faceIDs
    }

    // Approximate columns in the grid (based on 90px face + spacing in ~300px cards)
    private let columnsPerGroup = 3

    var body: some View {
        HStack(spacing: 0) {
            // Main face management area
            VStack(spacing: 0) {
                toolbar
                Divider()
                groupCardsScrollView
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
        .focusable()
        .onKeyPress(.space) {
            openFullscreenForSelectedFace()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            let shift = NSEvent.modifierFlags.contains(.shift)
            navigateFace(direction: .left, shift: shift)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            let shift = NSEvent.modifierFlags.contains(.shift)
            navigateFace(direction: .right, shift: shift)
            return .handled
        }
        .onKeyPress(.upArrow) {
            let shift = NSEvent.modifierFlags.contains(.shift)
            navigateFace(direction: .up, shift: shift)
            return .handled
        }
        .onKeyPress(.downArrow) {
            let shift = NSEvent.modifierFlags.contains(.shift)
            navigateFace(direction: .down, shift: shift)
            return .handled
        }
        .onKeyPress(keys: [KeyEquivalent("g")]) { press in
            if press.modifiers.contains(.command) {
                createGroupFromSelection()
                return .handled
            }
            return .ignored
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

    // MARK: - Fullscreen Image

    private func openFullscreenForSelectedFace() {
        // Only open if exactly one face is selected
        guard selectionState.selectedFaceIDs.count == 1,
              let faceID = selectionState.selectedFaceIDs.first,
              let face = viewModel.face(byID: faceID),
              let groupID = face.groupID,
              let group = viewModel.group(byID: groupID) else { return }

        // Collect all faces in this group for navigation
        let groupFaces = viewModel.faces(in: group)
        let currentIndex = groupFaces.firstIndex(where: { $0.id == faceID }) ?? 0

        openFullscreenWindow(faces: groupFaces, startIndex: currentIndex)
    }

    private func openFullscreenWindow(faces: [DetectedFace], startIndex: Int) {
        guard fullscreenWindow == nil,
              let screen = NSScreen.main,
              !faces.isEmpty else { return }

        fullscreenFaces = faces
        fullscreenFaceIndex = min(startIndex, faces.count - 1)
        fullscreenState = FaceFullScreenState()

        let window = FaceFullScreenWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .mainMenu + 1
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .ignoresCycle]
        window.hasShadow = false
        window.onDismiss = { [self] in
            closeFullscreenWindow()
        }
        window.onNavigate = { [self] direction in
            navigateFullscreen(direction: direction)
        }
        window.onToggleUI = { [self] in
            fullscreenState?.hideOverlays.toggle()
        }

        updateFullscreenContent(window: window)
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        fullscreenWindow = window
    }

    private func navigateFullscreen(direction: Int) {
        let newIndex = fullscreenFaceIndex + direction
        guard newIndex >= 0, newIndex < fullscreenFaces.count else { return }
        fullscreenFaceIndex = newIndex

        if let window = fullscreenWindow {
            updateFullscreenContent(window: window)
        }
    }

    private func updateFullscreenContent(window: NSWindow) {
        guard fullscreenFaceIndex < fullscreenFaces.count else { return }
        let currentFace = fullscreenFaces[fullscreenFaceIndex]
        let url = currentFace.imageURL
        let total = fullscreenFaces.count
        let current = fullscreenFaceIndex + 1

        // Get ALL faces in this specific image (may include faces from other groups)
        let facesInThisImage = viewModel.faceData?.faces.filter { $0.imageURL == url } ?? []

        let hostingView = NSHostingView(
            rootView: FaceFullScreenImageView(
                imageURL: url,
                facesInImage: facesInThisImage,
                selectedFaceID: currentFace.id,
                colorForGroup: colorForGroup,
                fullscreenState: fullscreenState,
                currentIndex: current,
                totalCount: total
            )
        )
        window.contentView = hostingView
    }

    private func closeFullscreenWindow() {
        // Select the last viewed face before closing
        if fullscreenFaceIndex < fullscreenFaces.count {
            let lastViewedFace = fullscreenFaces[fullscreenFaceIndex]
            selectionState.selectFace(lastViewedFace.id)
        }

        fullscreenWindow?.orderOut(nil)
        fullscreenWindow = nil
        fullscreenFaces = []
        fullscreenFaceIndex = 0
        fullscreenState = nil
    }

    // MARK: - Keyboard Navigation

    private enum NavigationDirection {
        case left, right, up, down
    }

    private func navigateFace(direction: NavigationDirection, shift: Bool) {
        let allFaces = allVisibleFaceIDs
        guard !allFaces.isEmpty else { return }

        // If no focus, start from first face or first selected
        let currentFocusID = selectionState.focusedFaceID ?? selectionState.selectedFaceIDs.first ?? allFaces[0]
        guard let currentIndex = allFaces.firstIndex(of: currentFocusID) else {
            // Focus not in visible list, select first face
            selectionState.selectFace(allFaces[0])
            return
        }

        let newIndex: Int
        switch direction {
        case .left:
            newIndex = max(0, currentIndex - 1)
        case .right:
            newIndex = min(allFaces.count - 1, currentIndex + 1)
        case .up:
            newIndex = max(0, currentIndex - columnsPerGroup)
        case .down:
            newIndex = min(allFaces.count - 1, currentIndex + columnsPerGroup)
        }

        let newFaceID = allFaces[newIndex]

        if shift {
            selectionState.extendSelection(to: newFaceID, allFaces: allFaces)
        } else {
            selectionState.selectFace(newFaceID)
        }
    }

    private func createGroupFromSelection() {
        guard !selectionState.selectedFaceIDs.isEmpty else { return }
        viewModel.createNewGroup(withFaces: selectionState.selectedFaceIDs)
        selectionState.selectedFaceIDs.removeAll()
        selectionState.focusedFaceID = nil
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

    // MARK: - Group Cards Grid

    @ViewBuilder
    private var groupCardsScrollView: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                ForEach(viewModel.sortedGroups) { group in
                    GroupCardContainer(
                        groupID: group.id,
                        viewModel: viewModel,
                        settingsViewModel: settingsViewModel,
                        selectionState: selectionState,
                        maxVisibleFaces: maxVisibleFaces,
                        expandedGroupIDs: $expandedGroupIDs,
                        highlightedGroupID: $highlightedGroupID,
                        editingGroupID: $editingGroupID,
                        editingName: $editingName,
                        isEditingFocused: $isEditingFocused,
                        onDeleteGroup: { g in
                            groupToDelete = g
                            showDeleteGroupAlert = true
                        },
                        onChooseListFile: { showingNameListFilePicker = true }
                    )
                    .id(group.id)
                }

                newGroupDropTarget
            }
            .padding()
        }
    }

    // MARK: - New Group Drop Target

    @ViewBuilder
    private var newGroupDropTarget: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.folder")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Drop here to\ncreate group")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    highlightNewGroup ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: highlightNewGroup ? 2 : 1, dash: [6, 3])
                )
        )
        .onDrop(of: [.text], delegate: NewGroupDropDelegate(
            viewModel: viewModel,
            selectionState: selectionState,
            highlightNewGroup: $highlightNewGroup
        ))
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

// MARK: - Group Card Container (looks up its own state)

struct GroupCardContainer: View {
    let groupID: UUID
    let viewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    let selectionState: FaceSelectionState
    let maxVisibleFaces: Int
    @Binding var expandedGroupIDs: Set<UUID>
    @Binding var highlightedGroupID: UUID?
    @Binding var editingGroupID: UUID?
    @Binding var editingName: String
    var isEditingFocused: FocusState<Bool>.Binding
    let onDeleteGroup: (FaceGroup) -> Void
    let onChooseListFile: () -> Void

    private var group: FaceGroup? {
        viewModel.group(byID: groupID)
    }

    var body: some View {
        if let group {
            GroupCardContent(
                group: group,
                viewModel: viewModel,
                settingsViewModel: settingsViewModel,
                selectionState: selectionState,
                maxVisibleFaces: maxVisibleFaces,
                isExpanded: expandedGroupIDs.contains(groupID),
                isHighlighted: highlightedGroupID == groupID,
                isEditing: editingGroupID == groupID,
                editingName: $editingName,
                isEditingFocused: isEditingFocused,
                onToggleExpand: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedGroupIDs.contains(groupID) {
                            expandedGroupIDs.remove(groupID)
                        } else {
                            expandedGroupIDs.insert(groupID)
                        }
                    }
                },
                onStartEditing: {
                    editingName = group.name ?? ""
                    editingGroupID = groupID
                },
                onEndEditing: {
                    editingGroupID = nil
                },
                onSaveEdit: {
                    viewModel.nameGroup(groupID, name: editingName)
                    editingGroupID = nil
                },
                onDeleteGroup: { onDeleteGroup(group) },
                onChooseListFile: onChooseListFile,
                onHighlight: { highlighted in
                    if highlighted {
                        highlightedGroupID = groupID
                    } else if highlightedGroupID == groupID {
                        highlightedGroupID = nil
                    }
                }
            )
        }
    }
}

// MARK: - Group Card Content (the actual view)

struct GroupCardContent: View {
    let group: FaceGroup
    let viewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    let selectionState: FaceSelectionState
    let maxVisibleFaces: Int
    let isExpanded: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    @Binding var editingName: String
    var isEditingFocused: FocusState<Bool>.Binding
    let onToggleExpand: () -> Void
    let onStartEditing: () -> Void
    let onEndEditing: () -> Void
    let onSaveEdit: () -> Void
    let onDeleteGroup: () -> Void
    let onChooseListFile: () -> Void
    let onHighlight: (Bool) -> Void

    var body: some View {
        let allFaces = viewModel.faces(in: group)
        let visibleFaces = isExpanded ? allFaces : Array(allFaces.prefix(maxVisibleFaces))
        let hiddenCount = allFaces.count - visibleFaces.count


        VStack(alignment: .leading, spacing: 8) {
            // Header
            GroupCardHeader(
                group: group,
                faceCount: allFaces.count,
                isEditing: isEditing,
                editingName: $editingName,
                isEditingFocused: isEditingFocused,
                settingsViewModel: settingsViewModel,
                onStartEditing: onStartEditing,
                onEndEditing: onEndEditing,
                onSaveEdit: onSaveEdit,
                onDeleteGroup: onDeleteGroup,
                onChooseListFile: onChooseListFile,
                viewModel: viewModel
            )

            // Faces grid
            FacesGridView(
                faces: visibleFaces,
                viewModel: viewModel,
                selectionState: selectionState,
                groupFaceCount: allFaces.count
            )

            // Expand button
            if hiddenCount > 0 || isExpanded {
                ExpandButton(
                    isExpanded: isExpanded,
                    hiddenCount: hiddenCount,
                    onToggle: onToggleExpand
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isHighlighted ? Color.accentColor : Color.secondary.opacity(0.2),
                    lineWidth: isHighlighted ? 2 : 1
                )
        )
        // Drop target for receiving faces (group dragging disabled for performance)
        .onDrop(of: [.text], delegate: GroupCardDropDelegate(
            targetGroupID: group.id,
            viewModel: viewModel,
            selectionState: selectionState,
            onHighlight: onHighlight
        ))
    }
}

// MARK: - Group Card Header

struct GroupCardHeader: View {
    let group: FaceGroup
    let faceCount: Int
    let isEditing: Bool
    @Binding var editingName: String
    var isEditingFocused: FocusState<Bool>.Binding
    let settingsViewModel: SettingsViewModel
    let onStartEditing: () -> Void
    let onEndEditing: () -> Void
    let onSaveEdit: () -> Void
    let onDeleteGroup: () -> Void
    let onChooseListFile: () -> Void
    let viewModel: FaceRecognitionViewModel

    var body: some View {
        HStack {
            if isEditing {
                TextField("Name", text: $editingName, onCommit: onSaveEdit)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                    .focused(isEditingFocused)
                    .onExitCommand { onEndEditing() }
                    .onChange(of: isEditingFocused.wrappedValue) { _, focused in
                        if !focused { onEndEditing() }
                    }
                    .onAppear { isEditingFocused.wrappedValue = true }

                let presetNames = settingsViewModel.loadPersonShownList()
                Menu {
                    if !presetNames.isEmpty {
                        ForEach(presetNames, id: \.self) { name in
                            Button(name) {
                                editingName = name
                            }
                        }
                        Divider()
                    }
                    Button("Choose List File...") {
                        onChooseListFile()
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(presetNames.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(group.name ?? "Unnamed")
                    .font(.headline)
                    .foregroundStyle(group.name != nil ? .primary : .secondary)
                    .onTapGesture(count: 2) { onStartEditing() }
            }

            Text("\(faceCount)")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary, in: Capsule())

            Spacer()

            GroupCardMenu(
                group: group,
                faceCount: faceCount,
                onStartEditing: onStartEditing,
                onDeleteGroup: onDeleteGroup,
                viewModel: viewModel
            )
        }
    }
}

// MARK: - Group Card Menu

struct GroupCardMenu: View {
    let group: FaceGroup
    let faceCount: Int
    let onStartEditing: () -> Void
    let onDeleteGroup: () -> Void
    let viewModel: FaceRecognitionViewModel

    @AppStorage("knownPeopleMode") private var knownPeopleMode: String = "off"
    @State private var isAddingToKnown = false
    @State private var addedToKnownMessage: String?

    var body: some View {
        Menu {
            Button("Rename") { onStartEditing() }
            if group.name != nil {
                Button("Apply Name to Metadata") {
                    viewModel.applyNameToMetadata(groupID: group.id)
                }

                // Add to Known People option
                if knownPeopleMode != "off" {
                    Button {
                        addToKnownPeople()
                    } label: {
                        if isAddingToKnown {
                            Label("Adding...", systemImage: "hourglass")
                        } else {
                            Label("Add to Known People", systemImage: "person.badge.plus")
                        }
                    }
                    .disabled(isAddingToKnown)
                }
            }
            Divider()
            Button("Ungroup All") {
                viewModel.ungroupMultiple([group.id])
            }
            .disabled(faceCount <= 1)
            Button("Delete Group Faces", role: .destructive) {
                viewModel.deleteFaces(Set(group.faceIDs))
            }
            Button("Delete Group & Photos", role: .destructive) {
                onDeleteGroup()
            }
        } label: {
            HStack(spacing: 4) {
                if let message = addedToKnownMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 24)
    }

    private func addToKnownPeople() {
        guard let name = group.name, !name.isEmpty else { return }

        isAddingToKnown = true
        addedToKnownMessage = nil

        do {
            let faces = viewModel.faces(in: group)
            let embeddings = faces.map { face in
                PersonEmbedding(
                    featurePrintData: face.featurePrintData,
                    sourceDescription: face.imageURL.lastPathComponent,
                    recognitionMode: face.embeddingMode
                )
            }

            var thumbnailData: Data?
            if let thumbImage = viewModel.thumbnailImage(for: group.representativeFaceID),
               let tiffData = thumbImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData) {
                thumbnailData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }

            let _ = try KnownPeopleService.shared.addPerson(
                name: name,
                embeddings: embeddings,
                thumbnailData: thumbnailData
            )

            isAddingToKnown = false
            addedToKnownMessage = "Added"

            // Clear message after delay
            Task {
                try? await Task.sleep(for: .seconds(2))
                addedToKnownMessage = nil
            }
        } catch {
            isAddingToKnown = false
            addedToKnownMessage = "Failed"
        }
    }
}

// MARK: - Faces Grid View

struct FacesGridView: View {
    let faces: [DetectedFace]
    let viewModel: FaceRecognitionViewModel
    @Bindable var selectionState: FaceSelectionState
    let groupFaceCount: Int

    var body: some View {
        let faceIDs = faces.map(\.id)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
            ForEach(faces) { face in
                let isSelected = selectionState.selectedFaceIDs.contains(face.id)
                let isFocused = selectionState.focusedFaceID == face.id
                let isDragged = selectionState.draggedFaceIDs.contains(face.id)
                let thumbnail = viewModel.thumbnailImage(for: face.id)

                FaceThumbnailView(
                    faceID: face.id,
                    image: thumbnail,
                    isSelected: isSelected,
                    isFocused: isFocused,
                    isDragged: isDragged,
                    groupFaceCount: groupFaceCount,
                    onTap: { commandKey, shiftKey in
                        if shiftKey {
                            selectionState.extendSelection(to: face.id, allFaces: faceIDs)
                        } else {
                            selectionState.toggleSelection(face.id, commandKey: commandKey)
                        }
                    },
                    onDragStart: {
                        let ids: Set<UUID> = isSelected ? selectionState.selectedFaceIDs : [face.id]
                        selectionState.draggedFaceIDs = ids
                        return ids
                    }
                )
                .id(face.id)
            }
        }
    }
}

// MARK: - Expand Button

struct ExpandButton: View {
    let isExpanded: Bool
    let hiddenCount: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Spacer()
                Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Face Thumbnail View

struct FaceThumbnailView: View {
    let faceID: UUID
    let image: NSImage?
    let isSelected: Bool
    let isFocused: Bool
    let isDragged: Bool
    let groupFaceCount: Int
    let onTap: (_ commandKey: Bool, _ shiftKey: Bool) -> Void
    let onDragStart: () -> Set<UUID>

    var body: some View {
        thumbnailImage
            .onTapGesture {
                let modifiers = NSEvent.modifierFlags
                onTap(modifiers.contains(.command), modifiers.contains(.shift))
            }
            .onDrag {
                let ids = onDragStart()
                return NSItemProvider(object: ids.map(\.uuidString).joined(separator: ",") as NSString)
            }
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isFocused {
            return Color.secondary
        } else {
            return Color.clear
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 90, height: 90)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : (isFocused ? 1 : 0))
        )
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(2)
            }
        }
        .opacity(isDragged ? 0.4 : 1.0)
    }
}

// MARK: - Drop Delegates

struct GroupCardDropDelegate: DropDelegate {
    let targetGroupID: UUID
    let viewModel: FaceRecognitionViewModel
    let selectionState: FaceSelectionState
    let onHighlight: (Bool) -> Void

    func dropEntered(info: DropInfo) {
        if selectionState.draggedGroupID != targetGroupID {
            onHighlight(true)
        }
    }

    func dropExited(info: DropInfo) {
        onHighlight(false)
    }

    func validateDrop(info: DropInfo) -> Bool {
        if selectionState.draggedGroupID == targetGroupID {
            return false
        }
        return info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        onHighlight(false)

        guard let item = info.itemProviders(for: [.text]).first else { return false }

        let targetID = targetGroupID
        let vm = viewModel
        let state = selectionState

        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }

            Task { @MainActor in
                if string.hasPrefix("group:") {
                    let groupIDString = String(string.dropFirst(6))
                    if let sourceGroupID = UUID(uuidString: groupIDString),
                       sourceGroupID != targetID {
                        vm.mergeGroups(sourceID: sourceGroupID, into: targetID)
                    }
                    state.draggedGroupID = nil
                } else {
                    let ids = Set(string.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
                    guard !ids.isEmpty else { return }

                    let facesToMove: Set<UUID>
                    if let data = vm.faceData {
                        facesToMove = ids.filter { faceID in
                            data.faces.first(where: { $0.id == faceID })?.groupID != targetID
                        }
                    } else {
                        facesToMove = ids
                    }

                    vm.moveFaces(facesToMove, toGroup: targetID)
                    state.selectedFaceIDs.removeAll()
                    state.draggedFaceIDs.removeAll()
                }
            }
        }

        return true
    }
}

struct NewGroupDropDelegate: DropDelegate {
    let viewModel: FaceRecognitionViewModel
    let selectionState: FaceSelectionState
    @Binding var highlightNewGroup: Bool

    func dropEntered(info: DropInfo) {
        highlightNewGroup = true
    }

    func dropExited(info: DropInfo) {
        highlightNewGroup = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        highlightNewGroup = false

        guard let item = info.itemProviders(for: [.text]).first else { return false }

        let vm = viewModel
        let state = selectionState

        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            let ids = Set(string.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            guard !ids.isEmpty else { return }

            Task { @MainActor in
                vm.createNewGroup(withFaces: ids)
                state.selectedFaceIDs.removeAll()
                state.draggedFaceIDs.removeAll()
            }
        }

        return true
    }
}

// MARK: - Face Fullscreen State (shared observable for UI toggles without view recreation)

@Observable
final class FaceFullScreenState {
    var hideOverlays: Bool = false
}

// MARK: - Face Fullscreen Image View

struct FaceFullScreenImageView: View {
    let imageURL: URL
    var facesInImage: [DetectedFace] = []
    var selectedFaceID: UUID?
    var colorForGroup: ((UUID?) -> Color)?
    var fullscreenState: FaceFullScreenState?
    var currentIndex: Int = 1
    var totalCount: Int = 1

    private var hideOverlays: Bool {
        fullscreenState?.hideOverlays ?? false
    }

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnificationGesture)
                        .gesture(dragGesture(in: geometry.size))
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if scale > 1.0 {
                                    // Reset to fit
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                } else {
                                    // Zoom to 2x
                                    scale = 2.0
                                    lastScale = 2.0
                                }
                            }
                        }

                    // Face rectangles as sibling with same transforms
                    if !hideOverlays {
                        faceRectanglesView(imageSize: image.size, containerSize: geometry.size)
                            .scaleEffect(scale)
                            .offset(offset)
                    }
                }

                if !hideOverlays {
                    // Loading indicator
                    if isLoading {
                        VStack {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .tint(.white)
                                    .padding(12)
                                Spacer()
                            }
                            Spacer()
                        }
                    }

                    // Overlay info
                    VStack {
                        Spacer()
                        HStack(spacing: 16) {
                            // Navigation info
                            if totalCount > 1 {
                                Text("\(currentIndex) / \(totalCount)")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.6), in: Capsule())
                            }

                            // Filename
                            Text(imageURL.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: Capsule())

                            // Zoom indicator
                            if scale > 1.0 {
                                Text("\(Int(scale * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.6), in: Capsule())
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    // Navigation hints
                    if totalCount > 1 {
                        HStack {
                            if currentIndex > 1 {
                                Image(systemName: "chevron.left")
                                    .font(.title)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.leading, 20)
                            }
                            Spacer()
                            if currentIndex < totalCount {
                                Image(systemName: "chevron.right")
                                    .font(.title)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.trailing, 20)
                            }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .task(id: imageURL) {
            await loadImage()
        }
    }

    // MARK: - Face Rectangles View

    /// Calculate where the image content is displayed within a container using aspect-fit
    private func calculateImageDisplayRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if imageAspect > containerAspect {
            // Image is wider - fills width, letterboxed vertically
            let displayHeight = containerSize.width / imageAspect
            let yOffset = (containerSize.height - displayHeight) / 2
            return CGRect(x: 0, y: yOffset, width: containerSize.width, height: displayHeight)
        } else {
            // Image is taller - fills height, pillarboxed horizontally
            let displayWidth = containerSize.height * imageAspect
            let xOffset = (containerSize.width - displayWidth) / 2
            return CGRect(x: xOffset, y: 0, width: displayWidth, height: containerSize.height)
        }
    }

    /// Convert Vision face rect (normalized, bottom-left origin) to display rect (pixels, top-left origin)
    private func convertFaceRect(_ faceRect: CGRect, toDisplayIn imageDisplayRect: CGRect) -> CGRect {
        // Vision: x,y is bottom-left corner of face, normalized 0-1
        // SwiftUI: x,y is top-left corner, in pixels
        let displayX = imageDisplayRect.minX + faceRect.origin.x * imageDisplayRect.width
        let displayY = imageDisplayRect.minY + (1.0 - faceRect.origin.y - faceRect.height) * imageDisplayRect.height
        let displayW = faceRect.width * imageDisplayRect.width
        let displayH = faceRect.height * imageDisplayRect.height
        return CGRect(x: displayX, y: displayY, width: displayW, height: displayH)
    }

    /// Face rectangles view - draws rectangles at face positions
    /// Zoom/pan transforms are applied via SwiftUI modifiers on this view
    @ViewBuilder
    private func faceRectanglesView(imageSize: CGSize, containerSize: CGSize) -> some View {
        let imageDisplayRect = calculateImageDisplayRect(imageSize: imageSize, in: containerSize)

        Canvas { context, _ in
            guard !facesInImage.isEmpty else { return }

            for face in facesInImage {
                let isSelected = face.id == selectedFaceID

                // Convert face coordinates to display coordinates
                let faceDisplayRect = convertFaceRect(face.faceRect, toDisplayIn: imageDisplayRect)

                // Style based on selection
                let groupColor = colorForGroup?(face.groupID) ?? .gray
                let lineWidth: CGFloat = isSelected ? 4 : 2
                let opacity: CGFloat = isSelected ? 1.0 : 0.5

                // Draw rounded rectangle
                let path = Path(roundedRect: faceDisplayRect, cornerRadius: 4)
                context.stroke(path, with: .color(groupColor.opacity(opacity)), lineWidth: lineWidth)
            }
        }
        .allowsHitTesting(false)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(max(newScale, minScale), maxScale)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= minScale {
                    withAnimation(.easeOut(duration: 0.2)) {
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
                // Clamp offset to prevent image from going too far off-screen
                let maxOffset = size.width * (scale - 1) / 2
                withAnimation(.easeOut(duration: 0.2)) {
                    offset.width = min(max(offset.width, -maxOffset), maxOffset)
                    offset.height = min(max(offset.height, -maxOffset), maxOffset)
                }
                lastOffset = offset
            }
    }

    private func loadImage() async {
        isLoading = true
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero

        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let screenMaxPx = max(NSScreen.main?.frame.width ?? 3840, NSScreen.main?.frame.height ?? 2160) * screenScale

        let url = imageURL
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadDownsampled(from: url, maxPixelSize: screenMaxPx)
        }.value

        await MainActor.run {
            image = loaded
            isLoading = false
        }
    }

    nonisolated private static func loadDownsampled(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let needsDownsample: Bool
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            let longest = max(pw, ph)
            needsDownsample = CGFloat(longest) > maxPixelSize * 1.5
        } else {
            needsDownsample = true
        }

        if needsDownsample {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return NSImage(contentsOf: url)
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
            .padding()

            Divider()

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge Suggestions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    ScrollView {
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
        .background(.background)
    }

    private func checkKnownPeople() {
        guard let faceData = viewModel.faceData else { return }

        isCheckingKnown = true
        lastKnownCount = 0

        var matchCount = 0
        let unnamedGroups = faceData.groups.filter { $0.name == nil }

        for group in unnamedGroups {
            guard let face = faceData.faces.first(where: { $0.id == group.representativeFaceID }) else {
                continue
            }

            let matches = KnownPeopleService.shared.matchFace(
                featurePrintData: face.featurePrintData,
                threshold: 0.45,
                maxResults: 1
            )

            if let bestMatch = matches.first {
                viewModel.nameGroup(group.id, name: bestMatch.person.name)
                matchCount += 1
            }
        }

        isCheckingKnown = false
        lastKnownCount = matchCount
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
               let image = viewModel.thumbnailCache[group.representativeFaceID] {
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
