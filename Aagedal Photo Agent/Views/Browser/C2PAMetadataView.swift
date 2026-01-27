import SwiftUI

struct C2PAMetadataView: View {
    let metadata: TechnicalMetadata
    let onShowDetail: () -> Void

    var body: some View {
        Button(action: onShowDetail) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("Content Credentials", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                if let generator = metadata.c2paClaimGenerator {
                    row("Signed by", generator)
                }
                if let author = metadata.c2paAuthor {
                    row("Author", author)
                }
                if metadata.c2paEdited {
                    row("Status", "Edited")
                }
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
    }
}
