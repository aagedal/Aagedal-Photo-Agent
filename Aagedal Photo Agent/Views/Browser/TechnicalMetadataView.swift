import SwiftUI

struct TechnicalMetadataView: View {
    let metadata: TechnicalMetadata?
    let fileSize: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Technical")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if let m = metadata {
                if let camera = m.camera {
                    row("Camera", camera)
                }
                if let lens = m.lens {
                    row("Lens", lens)
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
                if let res = m.resolution {
                    row("Resolution", res)
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
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
    }

    private var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct UpdatePillButton: View {
    @AppStorage("updateLatestVersion") private var latestVersion: String = ""

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var isNewerVersionAvailable: Bool {
        guard !latestVersion.isEmpty else { return false }
        return UpdateChecker.isNewerVersion(latestVersion, than: currentVersion)
    }

    var body: some View {
        if isNewerVersionAvailable {
            Button {
                UpdateChecker.shared.openReleasesPage()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text("version \(latestVersion)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.blue.opacity(0.45), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Update available")
        }
    }
}
