import SwiftUI

/// A sticky completion banner shown in the inspector after an import or upload
/// finishes. It stays until the user clicks the green confirm check, so the
/// confirmation can't be missed. A new operation replaces the previous banner.
struct CompletionBannerView: View {
    /// Drives the icon/tint: clean (green check) vs. had problems (orange).
    let isClean: Bool
    /// One-line summary, e.g. "Import of 42 files completed with copy verification".
    let message: String
    /// Called when the user clicks the confirm check to dismiss.
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isClean ? Color.green : Color.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(action: onConfirm) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help("Dismiss")
        }
    }
}
