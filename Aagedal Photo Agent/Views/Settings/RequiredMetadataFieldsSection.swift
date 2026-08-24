import SwiftUI

/// One customization surface for field order, visibility, and requirement severity. Requirement
/// state deliberately remains backed by `MetadataRequirements`, independent of whether the editor
/// field is visible.
struct RequiredMetadataFieldsSection: View {
    @Bindable var settingsViewModel: SettingsViewModel
    @State private var levels: MetadataRequirements.Levels = MetadataRequirements.load()
    @State private var minimumLengths = MetadataRequirements.loadMinimumLengths()

    var body: some View {
        Section("Metadata Fields") {
            Text("Arrange fields once for the Metadata panel and Caption navigator. Visibility affects only the editors; Warn and Require continue to validate hidden fields. Drag rows or use the move buttons with keyboard or VoiceOver.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(
                Array(settingsViewModel.orderedIPTCMetadataFields.enumerated()),
                id: \.element
            ) { index, field in
                fieldRow(field, at: index)
                    .draggable(field.rawValue)
                    .dropDestination(for: String.self) { rawValues, _ in
                        guard let rawValue = rawValues.first,
                              let source = MetadataFieldID(rawValue: rawValue) else { return false }
                        settingsViewModel.moveIPTCMetadataField(source, before: field)
                        return true
                    }
            }

            LabeledContent("Headline minimum length") { minimumLengthField(for: .title) }
            LabeledContent("Description minimum length") { minimumLengthField(for: .description) }
            Text("Minimum length is checked only when that field is set to Warn or Require. Set it to 0 to disable the length check.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset Layout to Defaults") {
                    settingsViewModel.resetIPTCMetadataFieldOrder()
                    settingsViewModel.resetIPTCMetadataFieldVisibility()
                }

                Spacer()

                Button("Show All") {
                    settingsViewModel.hiddenIPTCMetadataFields.removeAll()
                }
                .disabled(settingsViewModel.hiddenIPTCMetadataFields.isEmpty)
            }
        }
    }

    private func fieldRow(_ field: MetadataFieldID, at index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            if MetadataFieldID.alwaysVisibleEditorFields.contains(field) {
                Label(field.displayName, systemImage: "lock.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("This core field is always visible")
            } else {
                Toggle(
                    field.displayName,
                    isOn: Binding(
                        get: { settingsViewModel.isIPTCMetadataFieldVisible(field) },
                        set: { settingsViewModel.setIPTCMetadataField(field, visible: $0) }
                    )
                )
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Validation for \(field.displayName)", selection: binding(for: field)) {
                Text("Optional").tag(MetadataRequirementLevel.optional)
                Text("Warn").tag(MetadataRequirementLevel.warnOnEmpty)
                Text("Require").tag(MetadataRequirementLevel.require)
            }
            .labelsHidden()
            .frame(width: 105)
            .accessibilityLabel("Validation for \(field.displayName)")

            Button {
                settingsViewModel.moveIPTCMetadataField(field, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move \(field.displayName) up")
            .accessibilityLabel("Move \(field.displayName) up")

            Button {
                settingsViewModel.moveIPTCMetadataField(field, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == settingsViewModel.orderedIPTCMetadataFields.count - 1)
            .help("Move \(field.displayName) down")
            .accessibilityLabel("Move \(field.displayName) down")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metadata.fieldCustomization.\(field.rawValue)")
    }

    private func binding(for field: MetadataFieldID) -> Binding<MetadataRequirementLevel> {
        Binding(
            get: { levels[field] ?? .optional },
            set: { newValue in
                if newValue == .optional { levels[field] = nil } else { levels[field] = newValue }
                MetadataRequirements.save(levels)
            }
        )
    }
    private func minimumLengthField(for field: MetadataFieldID) -> some View {
        HStack(spacing: 8) {
            Text("Characters")
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.secondary)

            TextField("Minimum length", value: Binding(
                get: { minimumLengths[field] ?? 0 },
                set: { value in
                    minimumLengths[field] = max(0, value)
                    MetadataRequirements.saveMinimumLengths(minimumLengths)
                }
            ), format: .number)
            .labelsHidden()
            .frame(width: 70)
            .multilineTextAlignment(.trailing)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
