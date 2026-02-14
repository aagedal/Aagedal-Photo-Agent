import SwiftUI

struct ThumbnailGenerationProgressView: View {
    let completed: Int
    let total: Int
    let onCancel: () -> Void

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("Generating previews")
                    .font(.caption)
                    .foregroundStyle(.primary)

                ProgressView(value: progress)
                    .frame(width: 120)
            }

            Text("\(completed)/\(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
