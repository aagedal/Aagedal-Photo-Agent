import SwiftUI

struct C2PAMetadataView: View {
    let metadata: TechnicalMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Content Credentials", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.bottom, 2)

            if let generator = metadata.c2paClaimGenerator {
                row("Generator", generator)
            }
            if let action = metadata.c2paAction {
                row("Action", action)
            }
            if let alg = metadata.c2paHashAlgorithm {
                row("Hash", alg)
            }
        }
        .font(.caption)
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
