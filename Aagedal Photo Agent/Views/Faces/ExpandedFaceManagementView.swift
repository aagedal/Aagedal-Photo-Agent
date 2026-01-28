import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.aagedal.photoagent", category: "ExpandedFaceView")

struct ExpandedFaceManagementView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    var onClose: () -> Void
    var onPhotosDeleted: ((Set<URL>) -> Void)?

    @State private var selectedFaceIDs: Set<UUID> = []
    @State private var draggedFaceIDs: Set<UUID> = []
    @State private var draggedGroupID: UUID?
    @State private var highlightedGroupID: UUID?
    @State private var highlightNewGroup = false
    @State private var editingGroupID: UUID?
    @State private var editingName: String = ""
    @FocusState private var isEditingFocused: Bool
    @State private var groupToDelete: FaceGroup?
    @State private var showDeleteGroupAlert = false
    @State private var expandedGroupIDs: Set<UUID> = []

    private let maxVisibleFaces = 12

    var body: some View {
        let _ = logger.debug("body evaluated - groups: \(viewModel.sortedGroups.count), editing: \(editingGroupID?.uuidString ?? "none"), selected: \(selectedFaceIDs.count)")

        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button {
                    viewModel.createNewGroup(withFaces: selectedFaceIDs)
                    selectedFaceIDs.removeAll()
                } label: {
                    Label("New Group", systemImage: "plus")
                }
                .disabled(selectedFaceIDs.isEmpty)

                Spacer()

                if !selectedFaceIDs.isEmpty {
                    Button(role: .destructive) {
                        viewModel.deleteFaces(selectedFaceIDs)
                        selectedFaceIDs.removeAll()
                    } label: {
                        Label("Delete \(selectedFaceIDs.count)", systemImage: "trash")
                    }

                    Text("\(selectedFaceIDs.count) face\(selectedFaceIDs.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                Button {
                    onClose()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Group cards grid
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(viewModel.sortedGroups) { group in
                        groupCard(group: group)
                    }

                    // "New Group" drop target
                    newGroupDropTarget
                }
                .padding()
            }
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
                viewModel.faceData?.faces.first(where: { $0.id == faceID })?.imageURL
            }).count
            Text("This will delete \(group.faceIDs.count) face(s) across \(photoCount) photo(s). Moving photos to Trash cannot be undone from this app.")
        }
    }

    // MARK: - Group Card Header

    @ViewBuilder
    private func groupCardHeader(group: FaceGroup, faceCount: Int) -> some View {
        HStack {
            if editingGroupID == group.id {
                groupNameTextField(group: group)
            } else {
                Text(group.name ?? "Unnamed")
                    .font(.headline)
                    .foregroundStyle(group.name != nil ? .primary : .secondary)
                    .onTapGesture(count: 2) {
                        editingName = group.name ?? ""
                        editingGroupID = group.id
                    }
            }

            Text("\(faceCount)")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary, in: Capsule())

            Spacer()

            groupCardMenu(group: group, faceCount: faceCount)
        }
    }

    @ViewBuilder
    private func groupNameTextField(group: FaceGroup) -> some View {
        TextField("Name", text: $editingName, onCommit: {
            viewModel.nameGroup(group.id, name: editingName)
            editingGroupID = nil
        })
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 180)
        .focused($isEditingFocused)
        .onExitCommand {
            editingGroupID = nil
        }
        .onChange(of: isEditingFocused) { _, focused in
            if !focused {
                editingGroupID = nil
            }
        }
        .onAppear {
            isEditingFocused = true
        }
    }

    @ViewBuilder
    private func groupCardMenu(group: FaceGroup, faceCount: Int) -> some View {
        Menu {
            Button("Rename") {
                editingName = group.name ?? ""
                editingGroupID = group.id
            }
            if group.name != nil {
                Button("Apply Name to Metadata") {
                    viewModel.applyNameToMetadata(groupID: group.id)
                }
            }
            Divider()
            Button("Ungroup All") {
                viewModel.ungroupMultiple([group.id])
            }
            .disabled(faceCount <= 1)
            Button("Delete Group Faces", role: .destructive) {
                let faceIDs = Set(group.faceIDs)
                viewModel.deleteFaces(faceIDs)
            }
            Button("Delete Group & Photos", role: .destructive) {
                groupToDelete = group
                showDeleteGroupAlert = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }

    // MARK: - Group Card

    @ViewBuilder
    private func groupCard(group: FaceGroup) -> some View {
        let allFaces = viewModel.faces(in: group)
        let isExpanded = expandedGroupIDs.contains(group.id)
        let visibleFaces = isExpanded ? allFaces : Array(allFaces.prefix(maxVisibleFaces))
        let hiddenCount = allFaces.count - visibleFaces.count

        VStack(alignment: .leading, spacing: 8) {
            // Header
            groupCardHeader(group: group, faceCount: allFaces.count)

            // Face thumbnails grid - use fixed grid columns for better performance
            let columns = [GridItem(.adaptive(minimum: 90), spacing: 6)]
            FlowGrid(columns: columns, spacing: 6) {
                ForEach(visibleFaces) { face in
                    expandedFaceThumbnail(face: face, groupID: group.id, groupFaceCount: allFaces.count)
                }
            }
            .drawingGroup()

            // Show more/less button
            if hiddenCount > 0 || isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedGroupIDs.remove(group.id)
                        } else {
                            expandedGroupIDs.insert(group.id)
                        }
                    }
                } label: {
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    highlightedGroupID == group.id ? Color.accentColor : Color.secondary.opacity(0.2),
                    lineWidth: highlightedGroupID == group.id ? 2 : 1
                )
        )
        .onDrag {
            draggedGroupID = group.id
            return NSItemProvider(object: "group:\(group.id.uuidString)" as NSString)
        }
        .opacity(draggedGroupID == group.id ? 0.5 : 1.0)
        .onDrop(of: [.text], delegate: FaceGroupDropDelegate(
            targetGroupID: group.id,
            viewModel: viewModel,
            selectedFaceIDs: $selectedFaceIDs,
            draggedFaceIDs: $draggedFaceIDs,
            draggedGroupID: $draggedGroupID,
            highlightedGroupID: $highlightedGroupID
        ))
    }

    // MARK: - Face Thumbnail

    @ViewBuilder
    private func expandedFaceThumbnail(face: DetectedFace, groupID: UUID, groupFaceCount: Int) -> some View {
        let isSelected = selectedFaceIDs.contains(face.id)
        let isDragged = draggedFaceIDs.contains(face.id)
        // Determine which faces the context menu applies to
        let affectedFaceIDs: Set<UUID> = isSelected ? selectedFaceIDs : [face.id]
        let affectedCount = affectedFaceIDs.count

        faceThumbnailImage(face: face, isSelected: isSelected, isDragged: isDragged)
            .onTapGesture {
                handleFaceTap(faceID: face.id)
            }
            .contextMenu {
                faceContextMenu(
                    affectedFaceIDs: affectedFaceIDs,
                    affectedCount: affectedCount,
                    groupFaceCount: groupFaceCount
                )
            }
            .onDrag {
                let ids: Set<UUID> = isSelected ? selectedFaceIDs : [face.id]
                draggedFaceIDs = ids
                let idString = ids.map(\.uuidString).joined(separator: ",")
                return NSItemProvider(object: idString as NSString)
            }
    }

    @ViewBuilder
    private func faceThumbnailImage(face: DetectedFace, isSelected: Bool, isDragged: Bool) -> some View {
        Group {
            if let image = viewModel.thumbnailImage(for: face.id) {
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
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
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

    private func handleFaceTap(faceID: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedFaceIDs.contains(faceID) {
                selectedFaceIDs.remove(faceID)
            } else {
                selectedFaceIDs.insert(faceID)
            }
        } else {
            selectedFaceIDs.removeAll()
            selectedFaceIDs.insert(faceID)
        }
    }

    @ViewBuilder
    private func faceContextMenu(affectedFaceIDs: Set<UUID>, affectedCount: Int, groupFaceCount: Int) -> some View {
        let label = affectedCount > 1 ? "\(affectedCount) Faces" : "Face"

        Button("Move to New Group") {
            viewModel.createNewGroup(withFaces: affectedFaceIDs)
            selectedFaceIDs.removeAll()
        }

        Button("Remove from Group") {
            for faceID in affectedFaceIDs {
                viewModel.ungroupFace(faceID)
            }
            selectedFaceIDs.removeAll()
        }
        .disabled(groupFaceCount <= affectedCount)

        Divider()

        Button("Delete \(label)", role: .destructive) {
            viewModel.deleteFaces(affectedFaceIDs)
            selectedFaceIDs.subtract(affectedFaceIDs)
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
            selectedFaceIDs: $selectedFaceIDs,
            draggedFaceIDs: $draggedFaceIDs,
            highlightNewGroup: $highlightNewGroup
        ))
    }
}

// MARK: - Drop Delegates

struct FaceGroupDropDelegate: DropDelegate {
    let targetGroupID: UUID
    let viewModel: FaceRecognitionViewModel
    @Binding var selectedFaceIDs: Set<UUID>
    @Binding var draggedFaceIDs: Set<UUID>
    @Binding var draggedGroupID: UUID?
    @Binding var highlightedGroupID: UUID?

    func dropEntered(info: DropInfo) {
        // Don't highlight if dragging onto self
        if draggedGroupID != targetGroupID {
            highlightedGroupID = targetGroupID
        }
    }

    func dropExited(info: DropInfo) {
        if highlightedGroupID == targetGroupID {
            highlightedGroupID = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Don't allow dropping a group onto itself
        if draggedGroupID == targetGroupID {
            return false
        }
        return info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        highlightedGroupID = nil

        guard let item = info.itemProviders(for: [.text]).first else { return false }

        let targetID = targetGroupID
        let vm = viewModel

        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }

            Task { @MainActor in
                // Check if this is a group drag (format: "group:UUID")
                if string.hasPrefix("group:") {
                    let groupIDString = String(string.dropFirst(6))
                    if let sourceGroupID = UUID(uuidString: groupIDString),
                       sourceGroupID != targetID {
                        vm.mergeGroups(sourceID: sourceGroupID, into: targetID)
                    }
                    draggedGroupID = nil
                } else {
                    // Face drag (format: "UUID,UUID,...")
                    let ids = Set(string.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
                    guard !ids.isEmpty else { return }

                    // Filter out faces already in this group
                    let facesToMove: Set<UUID>
                    if let data = vm.faceData {
                        facesToMove = ids.filter { faceID in
                            data.faces.first(where: { $0.id == faceID })?.groupID != targetID
                        }
                    } else {
                        facesToMove = ids
                    }

                    vm.moveFaces(facesToMove, toGroup: targetID)
                    selectedFaceIDs.removeAll()
                    draggedFaceIDs.removeAll()
                }
            }
        }

        return true
    }
}

struct NewGroupDropDelegate: DropDelegate {
    let viewModel: FaceRecognitionViewModel
    @Binding var selectedFaceIDs: Set<UUID>
    @Binding var draggedFaceIDs: Set<UUID>
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

        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
            let ids = Set(string.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            guard !ids.isEmpty else { return }

            Task { @MainActor in
                vm.createNewGroup(withFaces: ids)
                selectedFaceIDs.removeAll()
                draggedFaceIDs.removeAll()
            }
        }

        return true
    }
}

// MARK: - Flow Grid (non-lazy for better scroll performance)

/// A simple non-lazy grid that renders all items immediately.
/// Better for scroll performance when inside a lazy container.
struct FlowGrid<Content: View>: View {
    let columns: [GridItem]
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        // Use a standard Grid for non-lazy rendering
        LazyVGrid(columns: columns, spacing: spacing) {
            content
        }
    }
}
