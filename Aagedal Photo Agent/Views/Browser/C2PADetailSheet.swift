import SwiftUI

struct C2PADetailSheet: View {
    let metadata: C2PAMetadata
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Content Credentials", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if metadata.manifests.isEmpty {
                Text("No C2PA manifests found.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(metadata.manifests.enumerated()), id: \.offset) { index, manifest in
                            manifestSection(manifest, index: index)
                            if index < metadata.manifests.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 400, idealWidth: 480, minHeight: 250, idealHeight: 400)
    }

    @ViewBuilder
    private func manifestSection(_ manifest: C2PAManifest, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: manifest number + whether it's the active one
            HStack {
                let isActive = index == metadata.manifests.count - 1
                Text("Manifest \(index + 1)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if isActive {
                    Text("Active")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Generator
            if let name = manifest.generatorName {
                let display = if let version = manifest.generatorVersion {
                    "\(name) \(version)"
                } else {
                    name
                }
                row("Generator", display)
            } else if let generator = manifest.claimGenerator {
                row("Generator", generator)
            }

            // Author
            if let author = manifest.author {
                row("Author", author)
            }

            // Title
            if let title = manifest.title {
                row("Title", title)
            }

            // Actions
            if !manifest.actions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Actions")
                        .foregroundStyle(.secondary)
                    ForEach(manifest.actions, id: \.self) { action in
                        Text("  \(action)")
                    }
                }
                .font(.caption)
            }

            // Algorithm
            if let alg = manifest.algorithm {
                row("Hash Algorithm", alg.uppercased())
            }

            // Ingredient reference
            if let ingredient = manifest.ingredientTitle {
                row("Ingredient", ingredient)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
