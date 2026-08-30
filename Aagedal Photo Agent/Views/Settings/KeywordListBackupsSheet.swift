import SwiftUI

/// Browse and restore the local timestamped backups kept by
/// `KeywordListsBackupService`. Left column lists the keyword lists that have
/// stored snapshots; the right column shows that list's version history with a
/// per-version Restore action and a read-only preview.
struct KeywordListBackupsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Preselect a specific list (used by the launch recovery prompt).
    var initialKey: KeywordListKey?

    /// Lists that currently read empty while backups exist (from the launch
    /// recovery prompt). They get an "Empty" badge so the user can see exactly
    /// which lists need restoring.
    var recoverableKeys: [KeywordListKey] = []

    @State private var groups: [(key: KeywordListKey, versions: [KeywordListsBackupService.Version])] = []
    @State private var selectedKey: KeywordListKey?
    @State private var previewedVersion: KeywordListsBackupService.Version?
    @State private var previewText: String?
    @State private var previewError: String?
    @State private var previewIsLoading = false
    @State private var previewRequestID: UUID?
    @State private var previewTask: Task<Void, Never>?
    @State private var pendingRestore: KeywordListsBackupService.Version?
    @State private var feedback: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 740, minHeight: 440, idealHeight: 540)
        .onAppear { reload() }
        .onChange(of: selectedKey) { _, _ in cancelPreview() }
        .onDisappear { cancelPreview() }
        .alert(
            "Restore this version?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Restore") { performRestore() }
        } message: {
            if let version = pendingRestore {
                Text("Replace the current “\(version.key.displayName)” with the version from \(Self.dateFormatter.string(from: version.date))?\n\nYour current content is backed up first, so this can be undone.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Restore from Backup").font(.headline)
            Text("Local automatic backups of your keyword lists. Older versions are kept for 30 days (and at least the 5 most recent).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if groups.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("No backups yet").font(.headline)
                Text("Backups are captured automatically as you edit your lists. Once you've saved a list, its versions will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: 220)
                Divider()
                versionColumn
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var listColumn: some View {
        List(selection: $selectedKey) {
            ForEach(groups, id: \.key) { group in
                HStack {
                    Text(group.key.displayName)
                    Spacer()
                    if recoverableKeys.contains(group.key) {
                        Text("Empty")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Text("\(group.versions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(group.key)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var versionColumn: some View {
        if let key = selectedKey, let versions = versions(for: key) {
            VStack(spacing: 0) {
                if recoverableKeys.contains(key) {
                    Label("This list is currently empty. Restoring a version below brings its content back.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                }
                List {
                    Section {
                        ForEach(versions) { version in
                            versionRow(version)
                        }
                    } header: {
                        Text(key.displayName)
                    }
                }
                .listStyle(.inset)

                if let previewedVersion, previewedVersion.key == key {
                    Divider()
                    preview
                        .frame(height: 150)
                }
            }
        } else {
            Text("Select a list to see its saved versions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func versionRow(_ version: KeywordListsBackupService.Version) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateFormatter.string(from: version.date))
                Text("\(Self.relativeFormatter.localizedString(for: version.date, relativeTo: Date())) · \(version.entryCount) \(version.entryCount == 1 ? "entry" : "entries") · \(byteString(version.byteCount))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview") { loadPreview(version) }
                .buttonStyle(.borderless)
            Button("Restore") { pendingRestore = version }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { loadPreview(version) }
    }

    private var preview: some View {
        ScrollView {
            if previewIsLoading {
                ProgressView("Loading preview…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let previewError {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(previewError)
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(previewText ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Logic

    private func versions(for key: KeywordListKey) -> [KeywordListsBackupService.Version]? {
        groups.first { $0.key == key }?.versions
    }

    private func reload() {
        cancelPreview()
        groups = KeywordListsBackupService.shared.allVersionsByKey()
        // Keep/establish a sensible selection.
        if let initialKey, groups.contains(where: { $0.key == initialKey }) {
            selectedKey = initialKey
        } else if selectedKey == nil || !groups.contains(where: { $0.key == selectedKey }) {
            selectedKey = groups.first?.key
        }
    }

    private func loadPreview(_ version: KeywordListsBackupService.Version) {
        cancelPreview()

        let requestID = UUID()
        previewedVersion = version
        previewRequestID = requestID
        previewIsLoading = true

        previewTask = Task {
            do {
                let result = try await KeywordListBackupPreviewService.shared.loadPreview(
                    from: version.url,
                    requestID: requestID
                )
                guard previewRequestID == requestID,
                      previewedVersion?.id == version.id else { return }

                previewTask = nil
                previewRequestID = nil
                previewIsLoading = false
                switch result {
                case .loaded(let snapshot):
                    previewText = snapshot.text
                case .cancelledBeforeRead, .cancelledAfterRead:
                    previewedVersion = nil
                }
            } catch is CancellationError {
                guard previewRequestID == requestID,
                      previewedVersion?.id == version.id else { return }
                cancelPreview()
            } catch {
                guard previewRequestID == requestID,
                      previewedVersion?.id == version.id else { return }
                previewTask = nil
                previewRequestID = nil
                previewIsLoading = false
                previewError = error.localizedDescription
            }
        }
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRequestID = nil
        previewedVersion = nil
        previewText = nil
        previewError = nil
        previewIsLoading = false
    }

    private func performRestore() {
        guard let version = pendingRestore else { return }
        pendingRestore = nil
        if KeywordListsBackupService.shared.restore(version) {
            feedback = "Restored “\(version.key.displayName)” from \(Self.dateFormatter.string(from: version.date))"
            reload()
        } else {
            feedback = "Restore failed."
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
