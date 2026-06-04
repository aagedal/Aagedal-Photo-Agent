import SwiftUI

struct TechnicalMetadataView: View {
    let metadata: TechnicalMetadata?
    let fileSize: Int64
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
                if let res = m.resolution {
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

