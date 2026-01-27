import SwiftUI

struct PresetListView: View {
    @Bindable var viewModel: PresetViewModel
    var onApply: ((MetadataPreset) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Presets")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.startEditing()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }

            if viewModel.presets.isEmpty {
                Text("No presets saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.presets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name)
                                .font(.body)
                            Text("\(preset.fields.count) fields \u{2022} \(preset.presetType.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Apply") {
                            onApply?(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Menu {
                            Button("Edit") {
                                viewModel.startEditing(preset)
                            }
                            Button("Delete", role: .destructive) {
                                viewModel.deletePreset(preset)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                    }
                    .padding(.vertical, 2)
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
