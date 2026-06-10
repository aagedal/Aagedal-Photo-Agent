import SwiftUI

enum MetadataDestination: Equatable, Sendable {
    case embedded
    case sidecar
    case embeddedAndSidecar
    case askedAtSave
    case mixed

    var color: Color {
        switch self {
        case .embedded: return .blue
        case .sidecar: return .orange
        case .embeddedAndSidecar: return .blue
        case .askedAtSave, .mixed: return .secondary
        }
    }

    var glyph: String {
        switch self {
        case .embedded: return "doc"
        case .sidecar: return "doc.badge.ellipsis"
        case .embeddedAndSidecar: return "doc.on.doc"
        case .askedAtSave: return "questionmark.circle"
        case .mixed: return "rectangle.on.rectangle"
        }
    }

    var shortLabel: String {
        switch self {
        case .embedded: return "Embedded file"
        case .sidecar: return "XMP sidecar"
        case .embeddedAndSidecar: return "File + XMP sidecar"
        case .askedAtSave: return "Asked at save"
        case .mixed: return "Mixed"
        }
    }

    /// Whether a write to `self` also updates the given read surface — i.e. after
    /// saving, re-reading from `reading` reflects the edit. Drives the panel's
    /// "sources differ" warning: only warn when the next write leaves the surface
    /// being read untouched.
    func covers(_ reading: MetadataDestination) -> Bool {
        switch self {
        case .embeddedAndSidecar:
            return reading == .embedded || reading == .sidecar || reading == .embeddedAndSidecar
        case .embedded, .sidecar:
            return reading == self
        case .askedAtSave, .mixed:
            return false
        }
    }
}

extension MetadataReferenceSource {
    var asDestination: MetadataDestination {
        switch self {
        case .embedded: return .embedded
        case .xmp: return .sidecar
        }
    }
}

struct MetadataSourceChip: View {
    enum Role {
        case reading
        case writing

        var prefix: String {
            switch self {
            case .reading: return "Reading"
            case .writing: return "Next write"
            }
        }
    }

    let role: Role
    let destination: MetadataDestination

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: destination.glyph)
                .imageScale(.small)
            Text("\(role.prefix): \(destination.shortLabel)")
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(destination.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(destination.color.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(destination.color.opacity(0.35), lineWidth: 1)
        )
        .help(helpText)
    }

    private var helpText: String {
        switch (role, destination) {
        case (.reading, .embedded):
            return "Metadata shown is read from the image file itself."
        case (.reading, .sidecar):
            return "Metadata shown is read from the .xmp sidecar next to the image."
        case (.reading, .mixed):
            return "The current selection contains images with different read sources."
        case (.reading, .askedAtSave):
            return "Reading source is decided at save time."
        case (.reading, .embeddedAndSidecar):
            return "Metadata is kept in both the image file and the .xmp sidecar."
        case (.writing, .embedded):
            return "Edits will be written into the image file."
        case (.writing, .sidecar):
            return "Edits will be written to the .xmp sidecar — the image file is not modified."
        case (.writing, .embeddedAndSidecar):
            return "Edits will be written into the image file and a matching .xmp sidecar."
        case (.writing, .mixed):
            return "The current selection mixes RAW and non-RAW images with different write destinations."
        case (.writing, .askedAtSave):
            return "You'll be asked at save time whether to write to the file or to a sidecar."
        }
    }
}
