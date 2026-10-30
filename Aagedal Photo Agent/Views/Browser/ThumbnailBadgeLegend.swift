import AppKit
import SwiftUI

/// The status badges drawn on thumbnail cells. Shared by the cell renderer
/// (`ThumbnailItemView`) and the legend popover so the two can't drift apart.
enum ThumbnailBadgeKind: CaseIterable {
    case contentCredentials
    case developEdits
    case pendingMetadata
    case cropped
    case hdr
    case voiceMemoUntranscribed
    case voiceMemoTranscribed

    var systemName: String {
        switch self {
        case .contentCredentials: "checkmark.seal.fill"
        case .developEdits: "slider.horizontal.3"
        case .pendingMetadata: "pencil"
        case .cropped: "crop"
        case .hdr: "sun.max.fill"
        case .voiceMemoUntranscribed, .voiceMemoTranscribed: "waveform"
        }
    }

    var color: NSColor {
        switch self {
        case .contentCredentials: .systemBlue
        case .developEdits: .systemOrange
        case .pendingMetadata: .systemYellow
        case .cropped: .systemGreen
        case .hdr: .systemPurple
        case .voiceMemoUntranscribed: .systemOrange
        case .voiceMemoTranscribed: .systemGreen
        }
    }

    var title: String {
        switch self {
        case .contentCredentials: "Content Credentials"
        case .developEdits: "Develop edits"
        case .pendingMetadata: "Metadata not written yet"
        case .cropped: "Cropped"
        case .hdr: "HDR"
        case .voiceMemoUntranscribed: "Voice memo"
        case .voiceMemoTranscribed: "Voice memo, transcribed"
        }
    }

    var detail: String {
        switch self {
        case .contentCredentials:
            "The file carries C2PA Content Credentials. Details are in the metadata panel."
        case .developEdits:
            "Has Develop adjustments such as exposure, colour or masks."
        case .pendingMetadata:
            "Saved in the app but not yet written to the file or its XMP sidecar. Hover to see which fields; choose Metadata › Write All Pending Metadata to write them."
        case .cropped:
            "Has a crop or straighten applied in Develop."
        case .hdr:
            "HDR editing is turned on in Develop."
        case .voiceMemoUntranscribed:
            "A voice memo recorded with the photo (bottom-left of the thumbnail), not transcribed yet."
        case .voiceMemoTranscribed:
            "A voice memo with its transcript available."
        }
    }
}

/// Small "what do the thumbnail icons mean" legend, shown from the info button next to
/// the image count.
struct ThumbnailBadgeLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Thumbnail Icons")
                .font(.headline)
            ForEach(ThumbnailBadgeKind.allCases, id: \.self) { kind in
                row(title: kind.title, detail: kind.detail) {
                    ThumbnailBadgeIcon(kind: kind)
                }
            }
            Divider()
            row(title: "Stars", detail: "Rating, shown under the filename.") {
                Text("★★★")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(nsColor: .systemYellow))
            }
            row(title: "Colour bar", detail: "Colour label, shown next to the rating.") {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 20, height: 7)
            }
            row(title: "Cloud placeholder", detail: "The file is still downloading from iCloud.") {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row<Icon: View>(title: String, detail: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(alignment: .top, spacing: 10) {
            icon()
                .frame(width: 24, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// SwiftUI rendering of a thumbnail badge: coloured circle with a white symbol, matching
/// `ThumbnailItemView.badgeImage`.
private struct ThumbnailBadgeIcon: View {
    let kind: ThumbnailBadgeKind

    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: kind.color))
            Image(systemName: kind.systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
    }
}
