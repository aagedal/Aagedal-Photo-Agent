import SwiftUI

/// Standalone window that hosts the structured keywords picker so the user can keep
/// it open alongside the main browser. Routes adds through the shared coordinator,
/// which forwards to whichever metadata panel most recently appeared.
struct StructuredKeywordsWindowContent: View {
    private let coordinator = StructuredKeywordsCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            if !coordinator.hasActiveTarget {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Open the main window and select an image — keyword picks land in that metadata panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial)
            }
            StructuredKeywordsPicker(
                onAddKeywords: { expanded in
                    _ = coordinator.apply(expanded)
                }
            )
        }
    }
}
