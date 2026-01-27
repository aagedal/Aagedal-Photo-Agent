import SwiftUI

struct FaceGroupDetailView: View {
    let group: FaceGroup
    @Bindable var viewModel: FaceRecognitionViewModel
    @State private var editingName: String = ""
    @State private var isApplying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Face Group")
                .font(.headline)

            // Face grid
            let faces = viewModel.faces(in: group)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                ForEach(faces) { face in
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
            }
            .frame(maxHeight: 200)

            Divider()

            // Name field
            HStack {
                TextField("Person name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        applyName()
                    }
            }

            Text("\(faces.count) face\(faces.count == 1 ? "" : "s") in \(Set(faces.map(\.imageURL)).count) image\(Set(faces.map(\.imageURL)).count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Actions
            HStack {
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
        .frame(width: 320, height: 360)
        .onAppear {
            editingName = group.name ?? ""
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
