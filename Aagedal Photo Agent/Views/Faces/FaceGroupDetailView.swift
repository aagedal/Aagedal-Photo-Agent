import SwiftUI

struct FaceGroupDetailView: View {
    let group: FaceGroup
    @Bindable var viewModel: FaceRecognitionViewModel
    @State private var editingName: String = ""
    @State private var isApplying = false
    @State private var mergeTargetID: UUID?
    var onSelectImages: ((Set<URL>) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var otherGroups: [FaceGroup] {
        viewModel.sortedGroups.filter { $0.id != group.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Face Group")
                .font(.headline)

            // Face grid with context menu for ungrouping
            let faces = viewModel.faces(in: group)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                    ForEach(faces) { face in
                        faceThumbnail(face: face, canUngroup: faces.count > 1)
                    }
                }
            }
            .frame(maxHeight: 200)

            Divider()

            // Name field
            TextField("Person name", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    applyName()
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

            // Actions
            HStack {
                Button("Select Images") {
                    let urls = viewModel.imageURLs(for: group)
                    onSelectImages?(urls)
                    dismiss()
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Apply Name") {
                    applyName()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty || isApplying)
            }
        }
        .padding()
        .frame(width: 320, height: 420)
        .onAppear {
            editingName = group.name ?? ""
        }
    }

    @ViewBuilder
    private func faceThumbnail(face: DetectedFace, canUngroup: Bool) -> some View {
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

        if canUngroup {
            thumbnail
                .contextMenu {
                    Button("Remove from Group") {
                        viewModel.ungroupFace(face.id)
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
}
