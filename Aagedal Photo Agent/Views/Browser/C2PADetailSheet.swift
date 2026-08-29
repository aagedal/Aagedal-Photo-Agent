import SwiftUI

private enum C2PAMetadataLoadState {
    case loading
    case absent
    case loaded(C2PAMetadata)
    case failed(C2PAInspectionFailure)
}

private enum C2PAValidationLoadState {
    case loading
    case result(C2PAValidationResult)
    case failed(C2PAInspectionFailure)
}

struct C2PADetailSheet: View {
    @Environment(AppCommandRouter.self) private var commandRouter
    let imageURL: URL
    let readService: SwiftExifReadService
    let onValidationChanged: (C2PAValidationResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var metadataState = C2PAMetadataLoadState.loading
    @State private var validationState: C2PAValidationLoadState
    @State private var inspectionRevision = 0

    init(
        imageURL: URL,
        readService: SwiftExifReadService,
        initialValidation: C2PAValidationResult? = nil,
        onValidationChanged: @escaping (C2PAValidationResult) -> Void = { _ in }
    ) {
        self.imageURL = imageURL
        self.readService = readService
        self.onValidationChanged = onValidationChanged
        _validationState = State(
            initialValue: initialValidation.map { .result($0) } ?? .loading
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Content Credentials", systemImage: "c.circle")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Button("Re-render and Sign") {
                    announceCancellationIfNeeded()
                    commandRouter.send(.renderAndSignSelected)
                    dismiss()
                }
                Button("Done") {
                    announceCancellationIfNeeded()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch metadataState {
                    case .loading:
                        loadingSection
                    case .absent:
                        inspectionStateSection(
                            title: "No Content Credentials",
                            message: "No Content Credentials were found in this image.",
                            icon: "c.circle",
                            color: .secondary
                        )
                    case .failed(let failure):
                        failureSection(failure)
                    case .loaded(let metadata):
                        validationSection
                        Divider()
                        // Thumbnails section
                        if let thumbnails = metadata.thumbnails,
                           thumbnails.claimThumbnail != nil || thumbnails.ingredientThumbnail != nil {
                            thumbnailSection(thumbnails)
                            Divider()
                        }

                        ForEach(Array(metadata.manifests.enumerated()), id: \.offset) { index, manifest in
                            manifestSection(
                                manifest,
                                index: index,
                                manifestCount: metadata.manifests.count
                            )
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
        .task(id: inspectionRevision) {
            await inspect(forceRefresh: inspectionRevision > 0)
        }
    }

    private var loadingSection: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading Content Credentials…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading Content Credentials")
    }

    @ViewBuilder
    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch validationState {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating Content Credentials…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Validating Content Credentials")
                case .result(let validation):
                    let presentation = validationPresentation(validation)
                    Label(presentation.title, systemImage: presentation.icon)
                        .font(.headline)
                        .foregroundStyle(presentation.color)
                        .accessibilityLabel(presentation.accessibilityLabel)
                case .failed(let failure):
                    Label(failure.title, systemImage: failureIcon(failure))
                        .font(.headline)
                        .foregroundStyle(failureColor(failure))
                }
                Spacer()
                if case .loading = validationState {
                    EmptyView()
                } else {
                    Button("Retry") { retry() }
                }
            }
            switch validationState {
            case .loading:
                EmptyView()
            case .failed(let failure):
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .result(let validation):
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

    private func inspectionStateSection(
        title: String,
        message: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { retry() }
        }
    }

    private func failureSection(_ failure: C2PAInspectionFailure) -> some View {
        inspectionStateSection(
            title: failure.title,
            message: failure.message,
            icon: failureIcon(failure),
            color: failureColor(failure)
        )
    }

    private func failureIcon(_ failure: C2PAInspectionFailure) -> String {
        switch failure {
        case .malformed: "exclamationmark.triangle.fill"
        case .unavailableTool: "wrench.and.screwdriver.fill"
        case .accessDenied: "lock.fill"
        case .validationFailed: "questionmark.circle.fill"
        }
    }

    private func failureColor(_ failure: C2PAInspectionFailure) -> Color {
        switch failure {
        case .malformed, .accessDenied: .orange
        case .unavailableTool, .validationFailed: .secondary
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
        case .unsupported:
            ("Unsupported", "questionmark.circle.fill", .gray, "Content Credentials validation is unsupported")
        case .notPresent:
            ("No Content Credentials", "c.circle", .gray, "No Content Credentials were found")
        case .validationFailed:
            ("Validation Failed", "questionmark.circle.fill", .gray, "Content Credentials validation failed")
        }
    }

    private func retry() {
        metadataState = .loading
        validationState = .loading
        inspectionRevision &+= 1
    }

    private func inspect(forceRefresh: Bool) async {
        do {
            var metadata = try await readService.readC2PAMetadata(url: imageURL)
            try Task.checkCancellation()
            guard !metadata.manifests.isEmpty else {
                metadataState = .absent
                AccessibilityAnnouncementCenter.post(
                    forceRefresh
                        ? .recovery(.contentCredentialsNotFound)
                        : .success(.contentCredentialsNotFound)
                )
                return
            }
            // Thumbnails are supplementary. A failed thumbnail decode must not
            // hide otherwise-readable credentials.
            metadata.thumbnails = try? await readService.readC2PAThumbnails(url: imageURL)
            try Task.checkCancellation()
            metadataState = .loaded(metadata)
        } catch is CancellationError {
            return
        } catch {
            metadataState = .failed(.metadataRead(error: error))
            AccessibilityAnnouncementCenter.post(.failure(.contentCredentialsInspection))
            return
        }

        validationState = .loading
        do {
            let result = try await C2PASigningService.validate(
                imageURL: imageURL,
                forceRefresh: forceRefresh
            )
            try Task.checkCancellation()
            validationState = .result(result)
            onValidationChanged(result)
            if result.status == .validationFailed {
                AccessibilityAnnouncementCenter.post(.failure(.contentCredentialsValidation))
            } else {
                AccessibilityAnnouncementCenter.post(
                    forceRefresh
                        ? .recovery(.contentCredentialsInspection)
                        : .success(.contentCredentialsLoaded)
                )
            }
        } catch is CancellationError {
            return
        } catch {
            let failure = C2PAInspectionFailure.validation(error: error)
            validationState = .failed(failure)
            onValidationChanged(validationResult(for: failure))
            AccessibilityAnnouncementCenter.post(.failure(.contentCredentialsValidation))
        }
    }

    private func announceCancellationIfNeeded() {
        let metadataIsLoading: Bool
        if case .loading = metadataState {
            metadataIsLoading = true
        } else {
            metadataIsLoading = false
        }

        let validationIsLoading: Bool
        if case .loaded = metadataState, case .loading = validationState {
            validationIsLoading = true
        } else {
            validationIsLoading = false
        }

        if metadataIsLoading || validationIsLoading {
            AccessibilityAnnouncementCenter.post(.cancellation(.contentCredentialsInspection))
        }
    }

    private func validationResult(for failure: C2PAInspectionFailure) -> C2PAValidationResult {
        switch failure {
        case .unavailableTool:
            .unavailable
        case .malformed:
            C2PAValidationResult(status: .unsupported, message: failure.message)
        case .accessDenied, .validationFailed:
            C2PAValidationResult(status: .validationFailed, message: failure.message)
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
    private func manifestSection(
        _ manifest: C2PAManifest,
        index: Int,
        manifestCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: manifest number + whether it's the active one
            HStack {
                let isActive = index == manifestCount - 1
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
