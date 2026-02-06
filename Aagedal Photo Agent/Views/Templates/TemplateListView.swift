import SwiftUI

struct TemplateListView: View {
    @Bindable var viewModel: TemplateViewModel
    var onApply: ((MetadataTemplate) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Templates")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.startEditing()
                } label: {
                    Image(systemName: "plus")
                }
            }

            if viewModel.templates.isEmpty {
                Text("No templates saved")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
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

                            Button("Edit") {
                                viewModel.startEditing(template)
                            }

                            Button("Delete", role: .destructive) {
                                viewModel.deleteTemplate(template)
                            }
                        }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
