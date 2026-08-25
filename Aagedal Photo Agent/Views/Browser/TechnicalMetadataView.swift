import SwiftUI

struct TechnicalMetadataView: View {
    let metadata: TechnicalMetadata?
    let fileSize: Int64
    /// Current EXIF orientation of the selected image, used to display oriented
    /// (rather than stored) resolution. Defaults to 1 (no swap).
    var orientation: Int = 1
    var croppedResolution: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let m = metadata {
                if let camera = m.camera {
                    row("Camera", camera)
                }
                if let sn = m.serialNumber {
                    row("Serial No.", sn)
                }
                if let sw = m.software {
                    row("Firmware", sw)
                }
                if let lens = m.lens {
                    row("Lens", lens)
                }
                if let lid = m.lensID {
                    row("Lens ID", lid)
                }
                if let date = m.captureDate {
                    row("Captured", date)
                }
                if let modified = m.modifiedDate {
                    row("Modified", modified)
                }
                if let fl = m.focalLength {
                    row("Focal Length", fl)
                }
                if let ap = m.aperture {
                    row("Aperture", ap)
                }
                if let ss = m.shutterSpeed {
                    row("Shutter Speed", ss)
                }
                if let iso = m.iso {
                    row("ISO", iso)
                }
                if let wb = m.whiteBalance {
                    row("White Balance", wb)
                }
                if let sc = m.shutterCount {
                    row("Shutter Count", sc.formatted())
                }
                if let ct = m.cameraTemperature {
                    row("Camera Temp.", "\(ct) °C")
                }
                if let res = m.resolution(orientation: orientation) {
                    row("Resolution", res)
                }
                if let cropped = croppedResolution {
                    row("Cropped", cropped)
                }
                if let bd = m.bitDepth {
                    row("Bit Depth", "\(bd)-bit")
                }
                if let cs = m.colorSpace {
                    row("Color Space", cs)
                }
            }
            row("File Size", formattedFileSize)
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        CopyableMetadataRow(label: label, value: value)
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

/// A label/value row that copies its value to the clipboard when clicked.
private struct CopyableMetadataRow: View {
    let label: String
    let value: String

    @State private var isHovering = false
    @State private var showsCopied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copyValue) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                if showsCopied {
                    Label("Copied", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.primary.opacity(isHovering ? 0.07 : 0))
                .padding(.horizontal, -4)
                .padding(.vertical, -1)
        )
        .onHover { isHovering = $0 }
        .help("Copy value")
        .accessibilityLabel("\(label), \(value)")
        .accessibilityValue(showsCopied ? "Copied" : value)
        .accessibilityHint("Copy this value to the clipboard")
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showsCopied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}
