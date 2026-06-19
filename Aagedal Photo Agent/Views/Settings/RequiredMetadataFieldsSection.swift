import SwiftUI

/// Settings section for choosing which IPTC fields an image must carry to count as "complete".
/// Drives the browser's Filters ▸ Required Metadata check. Persists straight to UserDefaults via
/// `MetadataRequirements` — the same store the filter reads — so it stays consistent regardless of
/// which `SettingsViewModel` instance is live (the app keeps two; see settings-viewmodel notes).
struct RequiredMetadataFieldsSection: View {
    @State private var required: Set<IPTCMetadata.FieldKey> = MetadataRequirements.load()

    var body: some View {
        Section("Required Metadata") {
            Text("Fields an image must have to count as complete. The browser's Filters ▸ Required Metadata uses this to find images missing any of them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(IPTCMetadata.FieldKey.userSelectable, id: \.self) { field in
                Toggle(field.displayName, isOn: Binding(
                    get: { required.contains(field) },
                    set: { isOn in
                        if isOn { required.insert(field) } else { required.remove(field) }
                        MetadataRequirements.save(required)
                    }
                ))
            }
        }
    }
}
