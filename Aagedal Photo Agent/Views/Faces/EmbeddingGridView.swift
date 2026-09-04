import SwiftUI
import AppKit

/// Displays a grid of per-sample face thumbnails for a known person,
/// allowing selection, deletion, and setting a representative face.
struct EmbeddingGridView: View {
    let person: KnownPerson
    let onDeleteEmbedding: (UUID) -> Void
    let onSetRepresentative: (UUID) -> Void

    @State private var selectedEmbeddingID: UUID?
    @State private var showDeleteConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Face Samples")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(person.embeddings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(person.embeddings) { embedding in
                    embeddingCell(embedding)
                }
            }

            if let selectedID = selectedEmbeddingID,
               let embedding = person.embeddings.first(where: { $0.id == selectedID }) {
                selectedEmbeddingDetail(embedding)
            }
        }
    }

    // MARK: - Cell

    @ViewBuilder
    private func embeddingCell(_ embedding: PersonEmbedding) -> some View {
        let isSelected = selectedEmbeddingID == embedding.id
        let isRepresentative = person.representativeThumbnailID == embedding.id

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedEmbeddingID = selectedEmbeddingID == embedding.id ? nil : embedding.id
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                KnownPersonEmbeddingThumbnailView(embeddingID: embedding.id)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    )

                if isRepresentative {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(.blue))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selected Detail

    @ViewBuilder
    private func selectedEmbeddingDetail(_ embedding: PersonEmbedding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            if let source = embedding.sourceDescription {
                detailRow("Source", value: source)
            }

            detailRow("Added", value: embedding.addedAt.formatted(date: .abbreviated, time: .shortened))

            if let mode = embedding.recognitionMode {
                detailRow("Scan mode", value: mode == .visionFeaturePrint ? "Vision" : "Face + Clothing")
            }
            detailRow("Stored data", value: "Face only")

            HStack(spacing: 8) {
                let isRepresentative = person.representativeThumbnailID == embedding.id

                Button {
                    onSetRepresentative(embedding.id)
                } label: {
                    Label("Set as Key Face", systemImage: "star")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(isRepresentative)

                Spacer()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(person.embeddings.count <= 1)
                .help(person.embeddings.count <= 1 ? "Cannot delete the last sample" : "Delete this face sample")
            }
            .padding(.top, 2)
        }
        .alert("Delete Face Sample?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDeleteEmbedding(embedding.id)
                selectedEmbeddingID = nil
            }
        } message: {
            if let source = embedding.sourceDescription {
                Text("This will remove the face sample from \(source). This cannot be undone.")
            } else {
                Text("This will remove this face sample. This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct KnownPersonEmbeddingThumbnailView: View {
    let embeddingID: UUID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(.controlBackgroundColor)
                    Image(systemName: "person.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: embeddingID) {
            image = await KnownPeopleService.shared.loadEmbeddingThumbnail(for: embeddingID)
        }
    }
}
