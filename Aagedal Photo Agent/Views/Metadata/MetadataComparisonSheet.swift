import SwiftUI

/// Side-by-side embedded-vs-sidecar comparison that lets the user pick, per field, which
/// version to keep. Replaces the old all-or-nothing "Multiple Metadata Sources" alert.
/// Applying stages the merged result into the editor (the caller saves normally).
struct MetadataComparisonSheet: View {
    let comparison: [MetadataFieldComparison]
    let isStale: Bool
    let onApply: ([IPTCMetadata.FieldKey: MetadataSource]) -> Void
    let onUseAll: (MetadataSource) -> Void
    let onCancel: () -> Void

    @State private var choices: [IPTCMetadata.FieldKey: MetadataSource]

    init(comparison: [MetadataFieldComparison],
         isStale: Bool,
         onApply: @escaping ([IPTCMetadata.FieldKey: MetadataSource]) -> Void,
         onUseAll: @escaping (MetadataSource) -> Void,
         onCancel: @escaping () -> Void) {
        self.comparison = comparison
        self.isStale = isStale
        self.onApply = onApply
        self.onUseAll = onUseAll
        self.onCancel = onCancel
        // Default each field to the policy master: the embedded file when the sidecar looks
        // stale, otherwise the sidecar.
        let defaultSource: MetadataSource = isStale ? .embedded : .sidecar
        _choices = State(initialValue: Dictionary(
            uniqueKeysWithValues: comparison.map { ($0.field, defaultSource) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(comparison) { row in
                        fieldRow(row)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolve Metadata Differences")
                .font(.headline)
            Text("This image's embedded metadata and its .xmp sidecar disagree. Choose which version to keep for each field.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isStale {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("The image file was modified more recently than the sidecar — it may have been edited in another app, so the sidecar could be out of date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.08))
                        .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 0.5)
                )
            }

            HStack(spacing: 8) {
                Button("Use all from Embedded") { onUseAll(.embedded) }
                Button("Use all from XMP Sidecar") { onUseAll(.sidecar) }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(16)
    }

    private func fieldRow(_ row: MetadataFieldComparison) -> some View {
        let selection = choices[row.field] ?? .sidecar
        return VStack(alignment: .leading, spacing: 6) {
            Text(row.label)
                .font(.subheadline.weight(.medium))
            HStack(alignment: .top, spacing: 10) {
                valueCard(title: "Embedded", value: row.embeddedValue,
                          selected: selection == .embedded) {
                    choices[row.field] = .embedded
                }
                valueCard(title: "XMP Sidecar", value: row.sidecarValue,
                          selected: selection == .sidecar) {
                    choices[row.field] = .sidecar
                }
            }
        }
    }

    private func valueCard(title: String, value: String, selected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .font(.caption)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(value.isEmpty ? "— empty —" : value)
                    .font(.callout)
                    .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                    .italic(value.isEmpty)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                                  lineWidth: selected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { onApply(choices) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}
