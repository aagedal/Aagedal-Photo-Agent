import SwiftUI
import UniformTypeIdentifiers

struct ExpandedFaceManagementView: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    var onClose: () -> Void

    @State private var selectedFaceIDs: Set<UUID> = []
    @State private var draggedFaceIDs: Set<UUID> = []
    @State private var highlightedGroupID: UUID?
    @State private var highlightNewGroup = false
    @State private var editingGroupID: UUID?
    @State private var editingName: String = ""

    var body: some View {
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
    }

    // MARK: - Group Card

    @ViewBuilder
    private func groupCard(group: FaceGroup) -> some View {
        let faces = viewModel.faces(in: group)

        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                if editingGroupID == group.id {
                    TextField("Name", text: $editingName, onCommit: {
                        viewModel.nameGroup(group.id, name: editingName)
                        editingGroupID = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                } else {
                    Text(group.name ?? "Unnamed")
                        .font(.headline)
                        .foregroundStyle(group.name != nil ? .primary : .secondary)
                        .onTapGesture(count: 2) {
                            editingName = group.name ?? ""
                            editingGroupID = group.id
                        }
                }

                Text("\(faces.count)")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary, in: Capsule())

                Spacer()

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
                    Button("Ungroup All", role: .destructive) {
                        viewModel.ungroupMultiple([group.id])
                    }
                    .disabled(faces.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            // Face thumbnails grid
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 6) {
                ForEach(faces) { face in
                    expandedFaceThumbnail(face: face)
                }
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
        .onDrop(of: [.text], delegate: FaceGroupDropDelegate(
            targetGroupID: group.id,
            viewModel: viewModel,
            selectedFaceIDs: $selectedFaceIDs,
            draggedFaceIDs: $draggedFaceIDs,
            highlightedGroupID: $highlightedGroupID
        ))
    }

    // MARK: - Face Thumbnail

    @ViewBuilder
    private func expandedFaceThumbnail(face: DetectedFace) -> some View {
        let isSelected = selectedFaceIDs.contains(face.id)
        let isDragged = draggedFaceIDs.contains(face.id)

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
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if selectedFaceIDs.contains(face.id) {
                    selectedFaceIDs.remove(face.id)
                } else {
                    selectedFaceIDs.insert(face.id)
                }
            } else {
                selectedFaceIDs.removeAll()
                selectedFaceIDs.insert(face.id)
            }
        }
        .onDrag {
            // If this face is selected, drag all selected; otherwise just this one
            let ids: Set<UUID>
            if selectedFaceIDs.contains(face.id) {
                ids = selectedFaceIDs
            } else {
                ids = [face.id]
            }
            draggedFaceIDs = ids
            let idString = ids.map(\.uuidString).joined(separator: ",")
            return NSItemProvider(object: idString as NSString)
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
    @Binding var highlightedGroupID: UUID?

    func dropEntered(info: DropInfo) {
        highlightedGroupID = targetGroupID
    }

    func dropExited(info: DropInfo) {
        if highlightedGroupID == targetGroupID {
            highlightedGroupID = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        highlightedGroupID = nil

        guard let item = info.itemProviders(for: [.text]).first else { return false }

        // Capture values needed in the async closure
        let targetID = targetGroupID
        let vm = viewModel

        item.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String else { return }
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

            Task { @MainActor in
                vm.moveFaces(facesToMove, toGroup: targetID)
                selectedFaceIDs.removeAll()
                draggedFaceIDs.removeAll()
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
