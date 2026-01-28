import SwiftUI

struct TemplateListView: View {
    @Bindable var viewModel: TemplateViewModel
    var onApply: ((MetadataTemplate) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Templates")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.startEditing()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }

            if viewModel.templates.isEmpty {
                Text("No templates saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.templates) { template in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(template.name)
                                .font(.body)
                            Text("\(template.fields.count) fields \u{2022} \(template.templateType.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Apply") {
                            onApply?(template)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Menu {
                            Button("Edit") {
                                viewModel.startEditing(template)
                            }
                            Button("Delete", role: .destructive) {
                                viewModel.deleteTemplate(template)
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
