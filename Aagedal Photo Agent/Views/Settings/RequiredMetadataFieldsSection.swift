import SwiftUI

/// Settings section for choosing how strictly each IPTC field is enforced: Optional, Warn if empty,
/// or Require. One global config drives both the browser's Filters ▸ Required Metadata check and the
/// FTP upload checks. Persists straight to UserDefaults via `MetadataRequirements` — the same store
/// those checks read — so it stays consistent regardless of which `SettingsViewModel` instance is
/// live (the app keeps two; see settings-viewmodel notes).
struct RequiredMetadataFieldsSection: View {
    @State private var levels: MetadataRequirements.Levels = MetadataRequirements.load()

    var body: some View {
        Section("Required Metadata") {
            Text("How strictly each field is enforced. Require marks images incomplete and blocks FTP upload when empty; Warn flags them without blocking. Used by the browser's Filters ▸ Required Metadata and the upload checks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(IPTCMetadata.FieldKey.userSelectable, id: \.self) { field in
                Picker(field.displayName, selection: binding(for: field)) {
                    Text("Optional").tag(MetadataRequirementLevel.optional)
                    Text("Warn if empty").tag(MetadataRequirementLevel.warnOnEmpty)
                    Text("Require").tag(MetadataRequirementLevel.require)
                }
            }
        }
    }

    private func binding(for field: IPTCMetadata.FieldKey) -> Binding<MetadataRequirementLevel> {
        Binding(
            get: { levels[field] ?? .optional },
            set: { newValue in
                if newValue == .optional { levels[field] = nil } else { levels[field] = newValue }
                MetadataRequirements.save(levels)
            }
        )
    }
}
