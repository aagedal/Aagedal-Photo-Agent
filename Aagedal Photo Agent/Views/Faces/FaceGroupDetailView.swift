import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingNameListFilePicker = false
    @State private var isAddingToKnownPeople = false
    @State private var knownPeopleMessage: String?
    @AppStorage("knownPeopleMode") private var knownPeopleMode: String = "off"
    var onSelectImages: ((Set<URL>) -> Void)?
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var otherGroups: [FaceGroup] {
        viewModel.sortedGroups.filter { $0.id != group.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Face Group")
                .font(.headline)

            // Face grid with multi-select and context menu
            let faces = viewModel.faces(in: group)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                    ForEach(faces) { face in
                        faceThumbnail(face: face, canUngroup: faces.count > 1)
                    }
                }
            }
            .frame(maxHeight: 200)

            // Multi-select action bar
            if !selectedFaceIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()

                    Text("\(selectedFaceIDs.count) face\(selectedFaceIDs.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Remove \(selectedFaceIDs.count) from Group") {
                            for faceID in selectedFaceIDs {
                                viewModel.ungroupFace(faceID)
                            }
                            selectedFaceIDs.removeAll()
                        }
                        .disabled(faces.count <= 1)

                        Spacer()

                        Button(role: .destructive) {
                            viewModel.deleteFaces(selectedFaceIDs)
                            selectedFaceIDs.removeAll()
                        } label: {
                            Label("Delete \(selectedFaceIDs.count)", systemImage: "trash")
                        }
                    }

                    if !otherGroups.isEmpty {
                        HStack {
                            Text("Move to:")
                                .font(.caption)
                            Picker("", selection: $moveTargetID) {
                                Text("Select group...").tag(nil as UUID?)
                                ForEach(otherGroups) { other in
                                    Text(other.name ?? "Unnamed (\(other.faceIDs.count))").tag(other.id as UUID?)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)

                            Button("Move") {
                                guard let targetID = moveTargetID else { return }
                                viewModel.moveFaces(selectedFaceIDs, toGroup: targetID)
                                selectedFaceIDs.removeAll()
                            }
                            .disabled(moveTargetID == nil)
                        }
                    }
                }
            }

            Divider()

            // Name field with preset picker
            HStack {
                TextField("Person name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: editingName) { _, newValue in
                        // Filter out newlines - names should be single line
                        let filtered = newValue.replacingOccurrences(of: "\n", with: "")
                            .replacingOccurrences(of: "\r", with: "")
                        if filtered != newValue {
                            editingName = filtered
                        }
                    }
                    .onSubmit {
                        applyName()
                    }

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
                        showingNameListFilePicker = true
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(presetNames.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(presetNames.isEmpty ? "Choose a list file to load names" : "Choose from preset names")
            }

            Text("\(faces.count) face\(faces.count == 1 ? "" : "s") in \(Set(faces.map(\.imageURL)).count) image\(Set(faces.map(\.imageURL)).count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Merge picker
            if !otherGroups.isEmpty {
                HStack {
                    Text("Merge into:")
                        .font(.caption)
                    Picker("", selection: $mergeTargetID) {
                        Text("Select group...").tag(nil as UUID?)
                        ForEach(otherGroups) { other in
                            Text(other.name ?? "Unnamed (\(other.faceIDs.count))").tag(other.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button("Merge") {
                        guard let targetID = mergeTargetID else { return }
                        viewModel.mergeGroups(sourceID: group.id, into: targetID)
                        dismiss()
                    }
                    .disabled(mergeTargetID == nil)
                }
            }

            // Known People feedback
            if let message = knownPeopleMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            // Primary actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Apply Name") {
                    applyName()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty || isApplying)
            }

            // Secondary actions
            HStack {
                Button {
                    let urls = viewModel.imageURLs(for: group)
                    onSelectImages?(urls)
                    dismiss()
                } label: {
                    Label("Select Images", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Add to Known People button (only when mode is enabled)
                if knownPeopleMode != "off" {
                    Button {
                        addToKnownPeople()
                    } label: {
                        Label("Add to Known", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        editingName.trimmingCharacters(in: .whitespaces).isEmpty ||
                        isAddingToKnownPeople
                    )
                    .help("Add to Known People database")
                }

                Spacer()

                Button(role: .destructive) {
                    showDeleteGroupAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete group & photos")
            }
        }
        .padding()
        .frame(width: 360, height: 500)
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
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isApplying = true
        viewModel.nameGroup(group.id, name: trimmed)
        viewModel.applyNameToMetadata(groupID: group.id)
        isApplying = false
        dismiss()
    }

    private func addToKnownPeople() {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isAddingToKnownPeople = true
        knownPeopleMessage = nil

        // First apply the name to the group
        viewModel.nameGroup(group.id, name: trimmed)

        do {
            // Collect embeddings from all faces in the group
            let faces = viewModel.faces(in: group)
            let embeddings = faces.map { face in
                PersonEmbedding(
                    featurePrintData: face.featurePrintData,
                    sourceDescription: face.imageURL.lastPathComponent,
                    recognitionMode: face.embeddingMode
                )
            }

            // Get thumbnail data for the representative face
            var thumbnailData: Data?
            if let thumbImage = viewModel.thumbnailImage(for: group.representativeFaceID),
               let tiffData = thumbImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData) {
                thumbnailData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }

            // Check for existing person with same name or similar face
            let representativeFace = faces.first { $0.id == group.representativeFaceID } ?? faces.first
            let duplicateCheck: KnownPeopleService.DuplicateCheckResult
            if let repFace = representativeFace {
                duplicateCheck = KnownPeopleService.shared.checkForDuplicate(
                    name: trimmed,
                    representativeFaceData: repFace.featurePrintData
                )
            } else {
                duplicateCheck = .noDuplicate
            }

            // Use smart add that handles duplicates
            let (_, addedToExisting) = try KnownPeopleService.shared.addOrMergePerson(
                name: trimmed,
                embeddings: embeddings,
                thumbnailData: thumbnailData,
                duplicateCheck: duplicateCheck
            )

            isAddingToKnownPeople = false
            if addedToExisting {
                knownPeopleMessage = "Added \(embeddings.count) sample(s) to \(trimmed)"
            } else {
                knownPeopleMessage = "Added \(trimmed) with \(embeddings.count) sample(s)"
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
