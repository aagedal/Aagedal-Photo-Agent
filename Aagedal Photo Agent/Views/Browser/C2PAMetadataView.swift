import SwiftUI

struct C2PAMetadataView: View {
    let metadata: TechnicalMetadata
    let validation: C2PAValidationResult?
    let onShowDetail: () -> Void

    var body: some View {
        Button(action: onShowDetail) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("Content Credentials present", systemImage: "c.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    if let validation {
                        validationIndicator(validation)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)

                if let generator = metadata.c2paClaimGenerator {
                    row("Signed by", generator)
                }
                if let author = metadata.c2paAuthor {
                    row("Author", author)
                }
                if metadata.c2paEdited {
                    row("Status", "Edited")
                }
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func validationIndicator(_ validation: C2PAValidationResult) -> some View {
        let presentation: (String, Color, String) = switch validation.status {
        case .trusted: ("Trusted", .green, "Validated Content Credentials: trusted")
        case .untrusted: ("Untrusted", .yellow, "Validated Content Credentials: valid signature, untrusted signer")
        case .invalid: ("Invalid", .red, "Validated Content Credentials: invalid")
        case .unsupported, .notPresent, .validationFailed: ("Could not validate", .gray, "Content Credentials could not be validated")
        }
        Text(presentation.0)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(presentation.1.opacity(0.18))
            .foregroundStyle(presentation.1)
            .clipShape(Capsule())
            .accessibilityLabel(presentation.2)
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
}
