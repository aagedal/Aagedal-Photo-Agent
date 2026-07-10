import SwiftUI

struct C2PADetailSheet: View {
    let metadata: C2PAMetadata
    let imageURL: URL
    let initialValidation: C2PAValidationResult?
    let onValidationChanged: (C2PAValidationResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var validation: C2PAValidationResult?
    @State private var validationTask: Task<Void, Never>?

    init(
        metadata: C2PAMetadata,
        imageURL: URL,
        initialValidation: C2PAValidationResult? = nil,
        onValidationChanged: @escaping (C2PAValidationResult) -> Void = { _ in }
    ) {
        self.metadata = metadata
        self.imageURL = imageURL
        self.initialValidation = initialValidation
        self.onValidationChanged = onValidationChanged
        _validation = State(initialValue: initialValidation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Content Credentials", systemImage: "c.circle")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Button("Re-render and Sign") {
                    NotificationCenter.default.post(name: .renderAndSignSelected, object: nil)
                    dismiss()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    validationSection
                    Divider()
                    if metadata.manifests.isEmpty {
                        Text("No C2PA manifests found.")
                            .foregroundStyle(.secondary)
                    } else {
                        Divider()
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
        .frame(minWidth: 620, idealWidth: 700, minHeight: 400)
        .frame(idealHeight: NSScreen.main.map { $0.visibleFrame.height * 0.9 } ?? 700)
        .task { validate() }
        .onDisappear { validationTask?.cancel() }
    }

    @ViewBuilder
    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let validation {
                    let presentation = validationPresentation(validation)
                    Label(presentation.title, systemImage: presentation.icon)
                        .font(.headline)
                        .foregroundStyle(presentation.color)
                        .accessibilityLabel(presentation.accessibilityLabel)
                } else {
                    Label("Validating…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { validate(forceRefresh: true) }
                    .disabled(validation == nil)
            }
            if let validation {
                Text(validation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if validation.trustSource == .legacy {
                    Text("Trusted only by the frozen legacy C2PA list; this signer is not recognized by the current official list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if validation.status == .untrusted {
                    Text("The image signature is intact, but its signer is not trusted by the active C2PA trust configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let signer = validation.signer { row("Signer", signer) }
                if let issuer = validation.issuer { row("Issuer", issuer) }
                if !validation.rawValidationCodes.isEmpty {
                    DisclosureGroup("Validation details") {
                        ForEach(validation.rawValidationCodes, id: \.self) { code in
                            Text(code).font(.caption.monospaced())
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func validationPresentation(_ result: C2PAValidationResult) -> (title: String, icon: String, color: Color, accessibilityLabel: String) {
        switch result.status {
        case .trusted:
            switch result.trustSource {
            case .official:
                ("Trusted — official list", "checkmark.circle.fill", .green, "Trusted by the official C2PA list")
            case .legacy:
                ("Trusted — legacy list", "checkmark.circle.fill", .yellow, "Trusted only by the legacy C2PA compatibility list")
            case nil:
                ("Trusted", "checkmark.circle.fill", .green, "Trusted Content Credentials")
            }
        case .untrusted:
            ("Valid signature — untrusted signer", "exclamationmark.triangle.fill", .yellow, "Valid signature, untrusted signer")
        case .invalid:
            ("Invalid", "xmark.octagon.fill", .red, "Invalid Content Credentials")
        case .trustNotConfigured:
            ("Signer trust not checked", "exclamationmark.triangle.fill", .orange, "Signer trust was not checked")
        case .unsupported, .notPresent, .validationFailed:
            ("Could not validate", "questionmark.circle.fill", .gray, "Content Credentials could not be validated")
        }
    }

    private func validate(forceRefresh: Bool = false) {
        validationTask?.cancel()
        validation = forceRefresh ? nil : validation
        validationTask = Task {
            let result: C2PAValidationResult
            do {
                result = try await C2PASigningService.validate(imageURL: imageURL, forceRefresh: forceRefresh)
            } catch is CancellationError {
                return
            } catch C2PASigningError.c2patoolMissing {
                result = .unavailable
            } catch C2PAValidationError.malformedOutput {
                result = C2PAValidationResult(status: .unsupported, message: "c2patool returned unsupported validation output.")
            } catch {
                result = C2PAValidationResult(status: .validationFailed, message: "Could not validate: \(error.localizedDescription)")
            }
            guard !Task.isCancelled else { return }
            validation = result
            onValidationChanged(result)
        }
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
