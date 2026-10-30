import SwiftUI

struct ImageCountOverlayView: View {
    let totalImageCount: Int
    let visibleImageCount: Int
    let isFiltering: Bool
    let selectedCount: Int
    let faceCount: Int
    let faceGroupCount: Int

    @State private var showsBadgeLegend = false

    var body: some View {
        HStack(spacing: 8) {
            if isFiltering {
                Text("\(visibleImageCount) of \(totalImageCount) images")
            } else {
                Text("\(totalImageCount) images")
            }
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
            }
            if faceCount > 0 {
                if faceGroupCount > 0 {
                    Text("\(faceCount) faces in \(faceGroupCount) groups")
                } else {
                    Text("\(faceCount) faces")
                }
            }
            Button {
                showsBadgeLegend.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("What the thumbnail icons mean")
            .accessibilityLabel("Thumbnail icon legend")
            .popover(isPresented: $showsBadgeLegend, arrowEdge: .top) {
                ThumbnailBadgeLegendView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
