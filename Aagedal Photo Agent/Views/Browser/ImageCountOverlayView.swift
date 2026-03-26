import SwiftUI

struct ImageCountOverlayView: View {
    let totalImageCount: Int
    let visibleImageCount: Int
    let isFiltering: Bool
    let selectedCount: Int
    let faceCount: Int
    let faceGroupCount: Int

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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
