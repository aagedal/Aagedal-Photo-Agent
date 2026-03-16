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
                        // Thumbnails section
                        if let thumbnails = metadata.thumbnails,
                           thumbnails.claimThumbnail != nil || thumbnails.ingredientThumbnail != nil {
                            thumbnailSection(thumbnails)
                            Divider()
                        }

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
        .frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 600)
    }

    @ViewBuilder
    private func thumbnailSection(_ thumbnails: C2PAThumbnails) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if let claimImage = thumbnails.claimThumbnail {
                VStack(spacing: 4) {
                    Image(nsImage: claimImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Claim")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let ingredientImage = thumbnails.ingredientThumbnail {
                VStack(spacing: 4) {
                    Image(nsImage: ingredientImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Ingredient")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
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

            // Source Type
            if let sourceType = manifest.digitalSourceType {
                row("Source Type", C2PAMetadata.formatDigitalSourceType(sourceType))
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

            // Original Format
            if let format = manifest.ingredientFormat {
                row("Original Format", C2PAMetadata.formatMimeType(format))
            }

            // Document ID
            if let docID = manifest.documentID {
                row("Document ID", docID)
            }

            // Instance ID
            if let instID = manifest.instanceID {
                row("Instance ID", instID)
            }

            // Assertions
            if !manifest.assertions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assertions")
                        .foregroundStyle(.secondary)
                    ForEach(manifest.assertions, id: \.self) { assertion in
                        Text("  \(assertion)")
                    }
                }
                .font(.caption)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
