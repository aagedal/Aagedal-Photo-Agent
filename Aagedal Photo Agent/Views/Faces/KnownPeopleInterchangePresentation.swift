import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared Known People interchange controls and presentation. Each screen supplies a stable
/// presenter ID so confirmations and results from one screen never appear on another one.
@MainActor
struct KnownPeopleInterchangeMenu: View {
    let presenterID: UUID
    let legacyImport: () -> Void
    let legacyExport: () -> Void

    @Environment(KnownPeopleInterchangeController.self) private var controller

    var body: some View {
        Menu {
            Button("Import People Library…") {
                guard let url = KnownPeopleInterchangePanels.chooseImportSource() else { return }
                controller.beginImport(at: url, presenterID: presenterID)
            }
            .disabled(!isAvailable)
            .accessibilityIdentifier("known-people-import-library")

            Menu("Export People Library…") {
                Button("Directory Package…") {
                    beginExport(format: .directory)
                }
                .accessibilityIdentifier("known-people-export-directory")

                Button("ZIP Archive…") {
                    beginExport(format: .zip)
                }
                .accessibilityIdentifier("known-people-export-zip")
            }
            .disabled(!isAvailable)

            if let availabilityMessage {
                Divider()
                Text(availabilityMessage)
            }

            Divider()

            Menu("Legacy ZIP") {
                Button("Import Legacy ZIP (Additive)…", action: legacyImport)
                    .accessibilityIdentifier("known-people-import-legacy-zip")
                Button("Export Legacy ZIP…", action: legacyExport)
                    .accessibilityIdentifier("known-people-export-legacy-zip")
                Divider()
                Text("Legacy ZIP import only adds unseen UUIDs. It does not restore renames or removals.")
            }
        } label: {
            Label("People Library", systemImage: "arrow.up.arrow.down.square")
        }
        .disabled(controller.isBusy)
        .help("Import, replace, or export the Known People library")
        .accessibilityIdentifier("known-people-interchange-menu")
    }

    private var isAvailable: Bool {
        if case .available = controller.availability { return true }
        return false
    }

    private var availabilityMessage: String? {
        switch controller.availability {
        case .available:
            return nil
        case .unavailable(.iCloudEnabled):
            return "Turn off Known People iCloud sync to import or export a People Library."
        case .unavailable(.routing):
            return "Wait for Known People storage routing to finish."
        }
    }

    private func beginExport(format: KnownPeopleInterchangeFormat) {
        guard let destination = KnownPeopleInterchangePanels.chooseExportDestination(format: format) else { return }
        let overwrite = FileManager.default.fileExists(atPath: destination.path)
        controller.beginExport(
            to: destination,
            format: format,
            overwrite: overwrite,
            presenterID: presenterID
        )
    }
}

@MainActor
enum KnownPeopleInterchangePanels {
    static func chooseImportSource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import People Library"
        panel.message = "Choose a .aagedalpeople directory package or .aagedalpeople.zip archive. The current local library will only change after you review the replacement."
        panel.prompt = "Review Import"
        panel.allowedContentTypes = [.aagedalPeopleLibrary, .zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExportDestination(format: KnownPeopleInterchangeFormat) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export People Library"
        panel.message = format == .directory
            ? "Export the complete Known People library as a directory package."
            : "Export the complete Known People library as a ZIP archive."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        switch format {
        case .directory:
            panel.allowedContentTypes = [.aagedalPeopleLibrary]
            panel.nameFieldStringValue = "Known People.aagedalpeople"
        case .zip:
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "Known People.aagedalpeople.zip"
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseLegacyImportSource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Legacy Known People ZIP"
        panel.message = "Legacy ZIP import only adds unseen UUIDs. It does not restore renames or removals."
        panel.prompt = "Import Additively"
        panel.allowedContentTypes = [.zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.resolvesAliases = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseLegacyExportDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Legacy Known People ZIP"
        panel.message = "Export a legacy additive-transfer ZIP."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "KnownPeople-Legacy.zip"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum KnownPeopleInterchangePromptCopy {
    struct Content: Equatable {
        let title: String
        let message: String
        let confirmLabel: String
    }

    static func content(for prompt: KnownPeopleInterchangeImportPrompt) -> Content {
        let title: String
        let relationship: String
        switch prompt.relationship {
        case .sameLibrary:
            title = prompt.replacesWithEmptyLibrary ? "Replace This Library with an Empty Library?" : "Replace This People Library?"
            relationship = "The package belongs to the same library as the local data."
        case .differentLibrary:
            title = prompt.replacesWithEmptyLibrary ? "Replace with a Different Empty Library?" : "Replace with a Different People Library?"
            relationship = "The package belongs to a different library."
        case .untracked:
            title = prompt.replacesWithEmptyLibrary ? "Replace Untracked Data with an Empty Library?" : "Replace Untracked Local Data?"
            relationship = "The current local data has no library identity, so it cannot be matched to this package."
        }

        let currentID = prompt.currentLibraryID?.uuidString ?? "Untracked"
        let currentCounts = countDescription(
            people: prompt.currentPeopleCount,
            embeddings: prompt.currentEmbeddingCount
        )
        var paragraphs = [
            relationship,
            "Current: \(currentCounts)\nLibrary ID: \(currentID)",
            "Incoming: \(countDescription(people: prompt.peopleCount, embeddings: prompt.embeddingCount))\nLibrary ID: \(prompt.libraryID.uuidString)",
            "This replaces the complete local Known People library, including names, removals, face samples, and reference thumbnails."
        ]
        if prompt.replacesWithEmptyLibrary {
            paragraphs.append("The incoming library is empty. Continuing removes every person and face sample from the current library.")
        }
        if prompt.missingEditorMetadata {
            paragraphs.append("This package does not include editor metadata. Core people and face data can be restored, but roles, notes, representative-photo choices, added and updated dates, source descriptions, and recognition metadata will be unavailable or use defaults.")
        }
        return Content(title: title, message: paragraphs.joined(separator: "\n\n"), confirmLabel: "Replace Library")
    }

    private static func countDescription(people: Int?, embeddings: Int?) -> String {
        let peopleText = people.map { "\($0) \($0 == 1 ? "person" : "people")" } ?? "unknown people"
        let samplesText = embeddings.map { "\($0) face \($0 == 1 ? "sample" : "samples")" } ?? "unknown face samples"
        return "\(peopleText), \(samplesText)"
    }
}

@MainActor
private struct KnownPeopleInterchangePresentationModifier: ViewModifier {
    let presenterID: UUID
    @Environment(KnownPeopleInterchangeController.self) private var controller

    private var pendingImport: KnownPeopleInterchangeController.PendingImport? {
        guard let pending = controller.pendingImport, pending.presenterID == presenterID else { return nil }
        return pending
    }

    private var promptIsPresented: Binding<Bool> {
        Binding(
            get: { pendingImport != nil },
            set: { isPresented in
                guard !isPresented, let pending = pendingImport else { return }
                controller.cancelPendingImport(promptID: pending.id, presenterID: presenterID)
            }
        )
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { controller.notice(for: presenterID) != nil },
            set: { isPresented in
                guard !isPresented, let notice = controller.notice(for: presenterID) else { return }
                controller.dismissNotice(id: notice.id, presenterID: presenterID)
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                pendingImport.map { KnownPeopleInterchangePromptCopy.content(for: $0.prompt).title } ?? "Replace People Library?",
                isPresented: promptIsPresented,
                presenting: pendingImport
            ) { pending in
                let copy = KnownPeopleInterchangePromptCopy.content(for: pending.prompt)
                Button(copy.confirmLabel, role: .destructive) {
                    controller.confirmImport(promptID: pending.id, presenterID: presenterID)
                }
                .accessibilityIdentifier("known-people-confirm-replacement")
                Button("Cancel", role: .cancel) {
                    controller.cancelPendingImport(promptID: pending.id, presenterID: presenterID)
                }
                .accessibilityIdentifier("known-people-cancel-replacement")
            } message: { pending in
                Text(KnownPeopleInterchangePromptCopy.content(for: pending.prompt).message)
            }
            .sheet(isPresented: noticeIsPresented) {
                if let notice = controller.notice(for: presenterID) {
                    KnownPeopleInterchangeNoticeView(notice: notice) {
                        controller.dismissNotice(id: notice.id, presenterID: presenterID)
                    }
                }
            }
            .onDisappear {
                if let pending = controller.pendingImport, pending.presenterID == presenterID {
                    controller.cancelPendingImport(promptID: pending.id, presenterID: presenterID)
                }
                if controller.activeRequest?.presenterID == presenterID {
                    controller.cancelActiveRequest()
                }
            }
    }
}

@MainActor
private struct KnownPeopleInterchangeNoticeView: View {
    let notice: KnownPeopleInterchangeNotice
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice.title)
                        .font(.headline)
                    if let detail = notice.detail, !detail.isEmpty {
                        Text(detail)
                            .textSelection(.enabled)
                    }
                }
            }

            if notice.identityAssignment?.committed == true {
                Label(
                    "A permanent identity was assigned to the local People Library during this operation.",
                    systemImage: "person.text.rectangle"
                )
                .font(.callout)
            }

            if !notice.recoveryURLs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery locations")
                        .font(.headline)
                    Text("Keep these locations until you have verified the library. You can reveal each one in Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(notice.recoveryURLs.enumerated()), id: \.offset) { index, url in
                        HStack {
                            Text(url.path(percentEncoded: false))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer(minLength: 12)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .accessibilityIdentifier("known-people-reveal-recovery-\(index)")
                        }
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("known-people-dismiss-notice")
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 720)
        .accessibilityIdentifier("known-people-interchange-notice")
    }

    private var iconName: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .cancelled: "xmark.circle"
        case .guidance: "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch notice.kind {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .cancelled, .guidance: .secondary
        }
    }
}

extension View {
    @MainActor
    func knownPeopleInterchangePresentation(presenterID: UUID) -> some View {
        modifier(KnownPeopleInterchangePresentationModifier(presenterID: presenterID))
    }
}
