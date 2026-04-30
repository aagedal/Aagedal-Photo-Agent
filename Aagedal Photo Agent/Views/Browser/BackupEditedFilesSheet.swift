import SwiftUI
import AppKit
import os

private nonisolated let editedBackupLog = Logger(subsystem: "com.aagedal.photo-agent", category: "BackupEditedFilesSheet")

/// Sheet for the "Back Up Edited Files…" command. Discovers Edited_*/Signed_*
/// renders plus `.photo_metadata/` and `.face_data/` under the working folder
/// and copies them to a chosen destination via `ImportCopyService`.
struct BackupEditedFilesSheet: View {
    let sourceFolder: URL
    var onDismiss: () -> Void

    @State private var discovery: EditedFolderBackupService.DiscoveryResult?
    @State private var destinationURL: URL?
    @State private var verificationMode: CopyVerificationMode = .on
    @State private var phase: Phase = .form
    @State private var copiedFiles: Int = 0
    @State private var totalFiles: Int = 0
    @State private var verifiedFiles: Int = 0
    @State private var mismatchedFiles: Int = 0
    @State private var failedFiles: Int = 0
    @State private var currentFile: String = ""
    @State private var failures: [ImportFailureRecord] = []
    @State private var summaryLine: String = ""
    @State private var runningTask: Task<Void, Never>?

    enum Phase: Equatable {
        case form
        case running
        case complete
        case cancelled
    }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .form:
                formContent
            case .running:
                progressContent
            case .complete, .cancelled:
                completionContent
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear {
            scanForBackupContent()
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Back Up Edited Files")
                    .font(.title2.bold())

                GroupBox("Source") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            Text(sourceFolder.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let discovery {
                            if discovery.folders.isEmpty {
                                Text("No edited renders or sidecar metadata found in this folder.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                ForEach(discovery.folders) { folder in
                                    HStack(spacing: 4) {
                                        Image(systemName: icon(for: folder.kind))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(folder.relativePath)
                                            .font(.caption.monospaced())
                                        Spacer()
                                        Text("\(folder.fileCount) files · \(formatBytes(folder.totalBytes))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Scanning…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Destination") {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.secondary)
                        if let destinationURL {
                            Text(destinationURL.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No destination chosen")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(destinationURL == nil ? "Choose…" : "Change…") {
                            chooseDestination()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Verification") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Verify each file after copy", selection: $verificationMode) {
                            ForEach(CopyVerificationMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(verificationMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        Divider()
        HStack {
            Spacer()
            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Back Up") {
                startBackup()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(destinationURL == nil || (discovery?.folders.isEmpty ?? true))
        }
        .padding()
    }

    // MARK: - Running

    @ViewBuilder
    private var progressContent: some View {
        CopyProgressView(
            title: "Copying edited files…",
            primaryCopied: copiedFiles,
            totalFiles: totalFiles,
            backupCopied: nil,
            backupTotal: nil,
            backupFailed: 0,
            verifiedCount: verifiedFiles,
            mismatchedCount: mismatchedFiles,
            currentFile: currentFile,
            isApplyingMetadata: false,
            onCancel: {
                runningTask?.cancel()
            }
        )
    }

    // MARK: - Complete

    @ViewBuilder
    private var completionContent: some View {
        VStack(spacing: 12) {
            VerificationSummaryView(
                title: "Backup Complete",
                succeededLabel: "copied",
                copiedFiles: copiedFiles,
                totalFiles: totalFiles,
                renamedFiles: 0,
                skippedFiles: 0,
                failedFiles: failedFiles,
                verifiedFiles: verifiedFiles,
                mismatchedFiles: mismatchedFiles,
                backupCopiedFiles: 0,
                backupFailedFiles: 0,
                backupEnabled: false,
                failureRecords: failures,
                summaryLine: summaryLine,
                cancelled: phase == .cancelled
            )

            HStack(spacing: 12) {
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom)
        }
    }

    // MARK: - Actions

    private func scanForBackupContent() {
        let source = sourceFolder
        Task.detached(priority: .userInitiated) {
            let result = EditedFolderBackupService.discover(in: source)
            await MainActor.run {
                self.discovery = result
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a destination for the backed-up edited files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL = url
    }

    private func startBackup() {
        guard let destinationURL, let discovery else { return }
        let source = sourceFolder
        let mode = verificationMode

        // Mirror under <destination>/<source folder name>/.
        let destinationRoot = destinationURL.appendingPathComponent(source.lastPathComponent)
        let jobs = EditedFolderBackupService.buildJobs(
            from: discovery,
            sourceRoot: source,
            destinationRoot: destinationRoot
        )

        copiedFiles = 0
        totalFiles = jobs.count
        verifiedFiles = 0
        mismatchedFiles = 0
        failedFiles = 0
        currentFile = ""
        failures = []
        summaryLine = ""
        phase = .running

        let copyService = ImportCopyService()

        runningTask = Task.detached(priority: .userInitiated) {
            do {
                let fm = FileManager.default
                // Pre-create destination directories.
                var dirs: Set<URL> = []
                for job in jobs {
                    dirs.insert(job.desiredPrimaryDest.deletingLastPathComponent())
                }
                for dir in dirs {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }

                _ = try await copyService.run(
                    jobs: jobs,
                    conflictPolicy: .overwrite,
                    verificationMode: mode,
                    verifyBackup: false,
                    progress: { result in
                        await MainActor.run {
                            self.applyProgress(result)
                        }
                    }
                )
                await MainActor.run {
                    self.summaryLine = self.buildSummaryLine()
                    self.phase = .complete
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.summaryLine = self.buildSummaryLine()
                    self.phase = .cancelled
                }
            } catch {
                editedBackupLog.error("Edited folder backup failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.summaryLine = error.localizedDescription
                    self.phase = .complete
                }
            }
        }
    }

    @MainActor
    private func applyProgress(_ result: ImportCopyService.CopyResult) {
        currentFile = result.source.lastPathComponent
        switch result.primary {
        case .copied:
            copiedFiles += 1
        case .skipped:
            break
        case .failed(let detail):
            failedFiles += 1
            failures.append(ImportFailureRecord(source: result.source, kind: .copyFailed, detail: detail))
        }
        switch result.primaryVerification {
        case .verified:
            verifiedFiles += 1
        case .mismatch(let expected, let got):
            mismatchedFiles += 1
            failures.append(ImportFailureRecord(
                source: result.source,
                kind: .verificationMismatch,
                detail: "expected \(expected.shortHex), got \(got.shortHex)"
            ))
        case .skipped, .failed:
            break
        }
    }

    private func buildSummaryLine() -> String {
        var parts: [String] = []
        parts.append("Copied \(copiedFiles)")
        if failedFiles > 0 { parts.append("failed \(failedFiles)") }
        if mismatchedFiles > 0 { parts.append("verification failures \(mismatchedFiles)") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Helpers

    private func icon(for kind: EditedFolderBackupService.DiscoveredFolder.Kind) -> String {
        switch kind {
        case .editedRender: return "wand.and.stars"
        case .signedRender: return "checkmark.seal"
        case .metadataSidecars: return "doc.text"
        case .faceData: return "person.crop.square"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
