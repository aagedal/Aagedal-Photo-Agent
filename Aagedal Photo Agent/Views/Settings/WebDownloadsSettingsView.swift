import SwiftUI

struct WebDownloadsSettingsView: View {
    @State private var installed = [String: String]()
    @State private var available = [String: String]()
    @State private var status = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Web Download Tools") {
                ForEach(["gallery-dl", "yt-dlp"], id: \.self) { name in
                    LabeledContent(name) {
                        Text(installed[name] ?? "Unavailable")
                        if let latest = available[name] { Text("Latest: \(latest)").foregroundStyle(.secondary) }
                    }
                }
                Text("Both tools use Photo Agent’s private Python runtime. Updates are installed separately from the app; no system Python or Homebrew is required.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check for Updates") { perform {
                        available = try await WebDownloadRuntimeService.shared.availableVersions()
                        status = available == installed ? "Downloader packages are up to date." : "New package versions are available."
                    } }
                    Button("Update Packages") { perform {
                        installed = try await WebDownloadRuntimeService.shared.update(to: available)
                        status = "Downloader packages updated."
                    } }.disabled(available.isEmpty || available == installed)
                }.disabled(task != nil)
                Button("Restore Bundled Versions") { perform {
                    try await WebDownloadRuntimeService.shared.restoreBundled()
                    installed = try await WebDownloadRuntimeService.shared.installedVersions()
                    status = "Bundled versions restored."
                } }.disabled(task != nil)
                if task != nil { HStack { ProgressView().controlSize(.small); Button("Cancel") { task?.cancel() } } }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
        .task {
            do { installed = try await WebDownloadRuntimeService.shared.installedVersions() }
            catch { status = error.localizedDescription }
        }
        .onDisappear { task?.cancel() }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        task = Task { @MainActor in
            defer { task = nil }
            do { try await operation() }
            catch is CancellationError { status = "Cancelled. The active packages were kept." }
            catch { status = error.localizedDescription }
        }
    }
}
