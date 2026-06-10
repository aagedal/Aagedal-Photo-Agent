import SwiftUI

struct FaceGroupDetailView: View {
    let group: FaceGroup
    @Bindable var viewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    @State private var editingName: String = ""
    @State private var isApplying = false
    @State private var mergeTargetID: UUID?
    @State private var selectedFaceIDs: Set<UUID> = []
    @State private var moveTargetID: UUID?
    @State private var showDeleteGroupAlert = false
    @State private var showMergePopover = false
    @State private var isAddingToKnownPeople = false
    @State private var knownPeopleMessage: String?
    @FocusState private var nameFieldFocused: Bool
    var isExpanded: Bool = false
    var onSelectImages: ((Set<URL>) -> Void)?
    var onScrollToGroup: ((UUID) -> Void)?
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var otherGroups: [FaceGroup] {
        viewModel.sortedGroups.filter { $0.id != group.id }
    }

    private var trimmedName: String {
        editingName.trimmingCharacters(in: .whitespaces)
    }

    /// Type-ahead matches from the structured Person Shown vocabulary. Empty
    /// until the user has typed and a structured list is loaded (managed in Settings).
    private var nameSuggestions: [String] {
        _ = StructuredKeywordService.personShown.version  // observe for reactivity
        let query = trimmedName
        guard !query.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for path in StructuredKeywordService.personShown.search(query, limit: 12) {
            let name = path.node.name
            guard !name.isEmpty, name.caseInsensitiveCompare(query) != .orderedSame else { continue }
            if seen.insert(name.lowercased()).inserted { out.append(name) }
            if out.count >= 5 { break }
        }
        return out
    }

    /// 4 columns of 60pt thumbnails fit the popover's fixed 340pt width
    /// (308pt content after padding).
    private static let gridColumnCount = 4
    private static let thumbnailSize: CGFloat = 60
    private static let gridSpacing: CGFloat = 8
    private static let gridMaxHeight: CGFloat = 160

    /// Rigid grid height so the thumbnails can never be compressed away when
    /// conditional sections (multi-select bar, name suggestions) appear — the
    /// popover must grow vertically instead.
    private func gridHeight(faceCount: Int) -> CGFloat {
        let rows = max(1, (faceCount + Self.gridColumnCount - 1) / Self.gridColumnCount)
        let height = CGFloat(rows) * Self.thumbnailSize + CGFloat(rows - 1) * Self.gridSpacing
        return min(height, Self.gridMaxHeight)
    }

    var body: some View {
        let faces = viewModel.faces(in: group)
        let imageCount = Set(faces.map(\.imageURL)).count

        VStack(alignment: .leading, spacing: 10) {
            // Header: title + close
            HStack {
                Text("Face Group")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }

            // Face grid with multi-select and context menu
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
                        count: Self.gridColumnCount
                    ),
                    spacing: Self.gridSpacing
                ) {
                    ForEach(faces) { face in
                        faceThumbnail(face: face, canUngroup: faces.count > 1)
                    }
                }
            }
            .frame(height: gridHeight(faceCount: faces.count))

            // Multi-select action bar
            if !selectedFaceIDs.isEmpty {
                multiSelectBar(faceCount: faces.count)
            }

            Divider()

            // Name field with structured-name type-ahead
            TextField("Person name", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onChange(of: editingName) { _, newValue in
                    // Names are single-line — strip any newlines.
                    let filtered = newValue.replacingOccurrences(of: "\n", with: "")
                        .replacingOccurrences(of: "\r", with: "")
                    if filtered != newValue { editingName = filtered }
                }
                .onSubmit { applyName() }

            if nameFieldFocused && !nameSuggestions.isEmpty {
                nameSuggestionsList
            }

            // Count + Apply
            HStack {
                Text("\(faces.count) face\(faces.count == 1 ? "" : "s") · \(imageCount) image\(imageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { applyName() } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmedName.isEmpty || isApplying)
                .help("Apply name")
            }

            if let message = knownPeopleMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Divider()

            // Icon action row
            HStack(spacing: 10) {
                if isExpanded {
                    iconAction("arrow.down.to.line", help: "Scroll to group") {
                        onScrollToGroup?(group.id)
                    }
                } else {
                    iconAction("photo.on.rectangle", help: "Select images") {
                        onSelectImages?(viewModel.imageURLs(for: group))
                        dismiss()
                    }
                }

                iconAction(
                    "person.crop.circle.badge.plus",
                    help: "Add to Known People",
                    disabled: trimmedName.isEmpty || isAddingToKnownPeople
                ) {
                    addToKnownPeople()
                }

                // Set as Key Art — when exactly one face selected and not already representative
                if selectedFaceIDs.count == 1,
                   let faceID = selectedFaceIDs.first,
                   faceID != group.representativeFaceID {
                    iconAction("star", help: "Set selected face as key art") {
                        viewModel.setRepresentativeFace(faceID, forGroup: group.id)
                    }
                }

                if !otherGroups.isEmpty {
                    Button { showMergePopover.toggle() } label: {
                        Image(systemName: "arrow.triangle.merge")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Merge into another group")
                    .popover(isPresented: $showMergePopover, arrowEdge: .bottom) {
                        mergePopover
                    }
                }

                Spacer()

                Button(role: .destructive) { showDeleteGroupAlert = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete group & photos")
            }
        }
        .padding()
        .frame(width: 340)
        // Force the popover to track the content's required height when
        // conditional sections appear, rather than compressing the layout.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            editingName = group.name ?? ""
        }
        .alert(
            "Delete Group & Photos",
            isPresented: $showDeleteGroupAlert
        ) {
            Button("Delete Faces Only") {
                viewModel.deleteFaces(Set(group.faceIDs))
                dismiss()
            }
            Button("Move Photos to Trash", role: .destructive) {
                let trashed = viewModel.deleteGroup(group.id, includePhotos: true)
                onPhotosDeleted?(trashed)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let photoCount = viewModel.imageURLs(for: group).count
            Text("This will delete \(group.faceIDs.count) face(s) across \(photoCount) photo(s). Moving photos to Trash cannot be undone from this app.")
        }
    }

    // MARK: - Subviews

    private var nameSuggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(nameSuggestions, id: \.self) { name in
                Button {
                    editingName = name
                    nameFieldFocused = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        Text(name)
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func multiSelectBar(faceCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            HStack {
                Text("\(selectedFaceIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                iconAction("rectangle.badge.minus", help: "Remove from group", disabled: faceCount <= 1) {
                    for faceID in selectedFaceIDs { viewModel.ungroupFace(faceID) }
                    selectedFaceIDs.removeAll()
                }

                iconAction("trash", help: "Delete selected faces", role: .destructive) {
                    viewModel.deleteFaces(selectedFaceIDs)
                    selectedFaceIDs.removeAll()
                }
            }

            if !otherGroups.isEmpty {
                HStack {
                    Picker("", selection: $moveTargetID) {
                        Text("Move to…").tag(nil as UUID?)
                        ForEach(otherGroups) { other in
                            Text(other.name ?? "Unnamed (\(other.faceIDs.count))").tag(other.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    iconAction("arrow.turn.up.right", help: "Move to selected group", disabled: moveTargetID == nil) {
                        guard let targetID = moveTargetID else { return }
                        viewModel.moveFaces(selectedFaceIDs, toGroup: targetID)
                        selectedFaceIDs.removeAll()
                    }
                }
            }
        }
    }

    private var mergePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merge into")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $mergeTargetID) {
                Text("Select group…").tag(nil as UUID?)
                ForEach(otherGroups) { other in
                    Text(other.name ?? "Unnamed (\(other.faceIDs.count))").tag(other.id as UUID?)
                }
            }
            .labelsHidden()
            HStack {
                Spacer()
                Button("Merge") {
                    guard let targetID = mergeTargetID else { return }
                    viewModel.mergeGroups(sourceID: group.id, into: targetID)
                    showMergePopover = false
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(mergeTargetID == nil)
            }
        }
        .padding()
        .frame(width: 260)
    }

    /// A small bordered icon button used across the action rows.
    private func iconAction(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder
    private func faceThumbnail(face: DetectedFace, canUngroup: Bool) -> some View {
        let isSelected = selectedFaceIDs.contains(face.id)

        let thumbnail: some View = Group {
            if let image = viewModel.thumbnailImage(for: face.id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 60, height: 60)
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

        if canUngroup {
            thumbnail
                .contextMenu {
                    Button("Remove from Group") {
                        viewModel.ungroupFace(face.id)
                        selectedFaceIDs.remove(face.id)
                    }
                    Divider()
                    Button("Delete Face", role: .destructive) {
                        selectedFaceIDs.remove(face.id)
                        viewModel.deleteFaces([face.id])
                    }
                }
        } else {
            thumbnail
        }
    }

    private func applyName() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }

        isApplying = true
        viewModel.nameGroup(group.id, name: trimmed)
        viewModel.applyNameToMetadata(groupID: group.id)
        isApplying = false
        dismiss()
    }

    private func addToKnownPeople() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }

        isAddingToKnownPeople = true
        knownPeopleMessage = nil

        // First apply the name to the group
        viewModel.nameGroup(group.id, name: trimmed)

        do {
            let result = try viewModel.addGroupToKnownPeople(groupID: group.id, name: trimmed)

            isAddingToKnownPeople = false
            if result.addedToExisting {
                knownPeopleMessage = "Added \(result.embeddingCount) sample(s) to \(result.name)"
            } else {
                knownPeopleMessage = "Added \(result.name) with \(result.embeddingCount) sample(s)"
            }

            // Clear message after delay
            Task {
                try? await Task.sleep(for: .seconds(2))
                knownPeopleMessage = nil
            }
        } catch {
            isAddingToKnownPeople = false
            knownPeopleMessage = "Failed: \(error.localizedDescription)"
        }
    }
}
