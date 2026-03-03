import SwiftUI

struct ImageFacesSection: View {
    @Bindable var viewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    let selectedImageURL: URL?
    let selectedCount: Int

    @State private var selectedGroup: FaceGroup?

    private var facePairs: [(face: DetectedFace, group: FaceGroup?)] {
        guard selectedCount == 1, let url = selectedImageURL else { return [] }
        return viewModel.faceGroupPairs(forImageURL: url)
    }

    var body: some View {
        if !facePairs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Faces in Image", systemImage: "person.crop.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(facePairs.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(facePairs, id: \.face.id) { pair in
                            faceThumbnailButton(face: pair.face, group: pair.group)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func faceThumbnailButton(face: DetectedFace, group: FaceGroup?) -> some View {
        let isSelected = selectedGroup?.id == group?.id && group != nil
        Button {
            if let group {
                selectedGroup = group
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if let image = viewModel.thumbnailImage(for: face.id) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .frame(width: 48, height: 48)
                            .overlay {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 16))
                            }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )

                Text(group?.name ?? "?")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .frame(width: 56)
                    .foregroundStyle(group?.name != nil ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(group == nil)
        .popover(isPresented: Binding<Bool>(
            get: { selectedGroup?.id == group?.id && group != nil && selectedGroup != nil },
            set: { newValue in if !newValue { selectedGroup = nil } }
        )) {
            if let group {
                FaceGroupDetailView(
                    group: group,
                    viewModel: viewModel,
                    settingsViewModel: settingsViewModel
                )
            }
        }
    }
}
