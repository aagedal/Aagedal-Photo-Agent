import SwiftUI

struct VoiceMemoVariablePreviewView: View {
    let preview: VoiceMemoVariableBatchPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var isConfirmFocused: Bool
    @AccessibilityFocusState private var isHeadingAccessibilityFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Voice-Memo Transcript Changes")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("voiceMemoTranscript.preview")
                .accessibilityFocused($isHeadingAccessibilityFocused)

            Text(summaryText)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Transcript change summary")
                .accessibilityValue(summaryText)
                .accessibilityIdentifier("voiceMemoTranscript.summary")

            Label(
                "Supported transcript destinations are Description, Extended Description, Headline, and Instructions.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.imageURL.lastPathComponent)
                                    .font(.headline)
                                Spacer()
                                Text(row.writeDestination)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(row.fields) { field in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(field.field.displayName)
                                            .font(.subheadline.weight(.semibold))
                                        if field.isTranscriptDestination {
                                            Text("Transcript destination")
                                                .font(.caption2.weight(.medium))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.blue.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    valueLine("Before", value: field.before)
                                    valueLine("After", value: field.after)
                                }
                                .padding(.top, 2)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier(
                                    "voiceMemoTranscript.field.\(row.imageURL.lastPathComponent).\(field.field.rawValue)"
                                )
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(
                            "\(row.imageURL.lastPathComponent), \(row.writeDestination), \(row.fields.count) changed \(row.fields.count == 1 ? "field" : "fields")"
                        )
                        .accessibilityIdentifier(
                            "voiceMemoTranscript.photo.\(row.imageURL.lastPathComponent)"
                        )
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 520)

            Text("Every approved transcript and associated WAV will be checked again before the batch starts. If any photo fails that check, no photo in this transcript batch is written.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voiceMemoTranscript.cancel")
                Button("Confirm and Write", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.affectedImageCount == 0)
                    .focused($isConfirmFocused)
                    .accessibilityIdentifier("voiceMemoTranscript.confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .onAppear {
            isConfirmFocused = preview.affectedImageCount > 0
            isHeadingAccessibilityFocused = true
            AccessibilityAnnouncementCenter.post(.information(.voiceMemoTranscriptPreview))
        }
    }

    private func valueLine(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "Empty" : value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var summaryText: String {
        "\(preview.action.rawValue) will change \(preview.affectedFieldCount) "
            + "\(preview.affectedFieldCount == 1 ? "field" : "fields") across "
            + "\(preview.affectedImageCount) \(preview.affectedImageCount == 1 ? "photo" : "photos"). "
            + "Nothing is written until you confirm."
    }
}
