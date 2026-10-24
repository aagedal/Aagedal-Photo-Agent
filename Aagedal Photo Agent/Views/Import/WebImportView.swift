import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WebImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var cookies: URL?
    /// Remembered across sessions like the other import destinations; resolved once when the
    /// sheet appears (a `@State` initial value would re-run bookmark I/O on every view init).
    @State private var destination: URL?
    @State private var inspection: WebPostInspection?
    @State private var selected = Set<String>()
    @State private var caption = ""
    @State private var status = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var completedFolder: URL?
    @State private var retainedFolder: URL?
    let onImported: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Web URL").font(.title2.bold())
            HStack {
                TextField("Instagram or X post URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .disabled(task != nil)
                    .onSubmit { if canInspect { inspect() } }
                    .onChange(of: url) { _, _ in resetInspection() }
                Button("Find Media", action: inspect).disabled(!canInspect)
            }
            HStack {
                Button(cookies == nil ? "Choose Cookies File…" : "Cookies: \(cookies!.lastPathComponent)") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK { cookies = panel.url; resetInspection() }
                }
                if cookies != nil { Button("Clear") { cookies = nil; resetInspection() } }
                Text("Optional Netscape cookies file for posts that require sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(task != nil)
            if let inspection {
                HStack {
                    Text("\(selected.count) of \(inspection.items.count) selected · Best available quality").font(.headline)
                    Spacer()
                    Button("Select All") { selected = Set(inspection.items.map(\.id)) }
                        .disabled(task != nil || selected.count == inspection.items.count)
                    Button("Select None") { selected.removeAll() }
                        .disabled(task != nil || selected.isEmpty)
                }
                List(inspection.items) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                        if value { selected.insert(item.id) } else { selected.remove(item.id) }
                    })) {
                        HStack {
                            Image(systemName: item.kind == "video" ? "film" : "photo")
                            Text("\(item.position). \(item.kind.capitalized)")
                            Spacer()
                            Text(item.resolution).foregroundStyle(.secondary)
                        }
                    }
                }.frame(minHeight: 140).disabled(task != nil)
                Text("Caption for working copies").font(.headline)
                TextEditor(text: $caption).frame(height: 100).border(.secondary.opacity(0.3)).disabled(task != nil)
                Text("Original post text and account attribution are preserved in provenance records. The account is recorded as Source; Creator remains unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Find all images and videos in a post, then download selected items together.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button("Choose Destination…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = destination
                    if panel.runModal() == .OK, let url = panel.url {
                        destination = url
                        RAWArchiveService.saveBookmark(for: url, key: UserDefaultsKeys.webImportDestinationBookmark)
                    }
                }.disabled(task != nil)
                Text(destination?.path ?? "No destination selected").font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Text("Each import creates Originals, Working and Provenance folders. Working copies follow your metadata write preset (Settings \u{2192} Metadata); videos and other formats that can't be embedded receive XMP sidecars.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let retainedFolder {
                Button("Reveal Retained Files in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([retainedFolder])
                }
            }
            if !status.isEmpty { HStack { if task != nil { ProgressView().controlSize(.small) }; Text(status) } }
            HStack {
                Button(task == nil ? "Close" : "Cancel") {
                    if let task { task.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if let folder = completedFolder {
                    Button("Open Working Folder") { onImported(folder); dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    Button(selected.isEmpty ? "Download & Import" : "Download & Import (\(selected.count))", action: importSelected)
                        .buttonStyle(.borderedProminent)
                        .disabled(task != nil || inspection == nil || selected.isEmpty || destination == nil)
                }
            }
        }
        .padding(24).frame(width: 720, height: 680)
        .interactiveDismissDisabled(task != nil)
        .onAppear {
            if destination == nil {
                destination = RAWArchiveService.resolveBookmark(
                    key: UserDefaultsKeys.webImportDestinationBookmark,
                    removeOnFailure: false
                )
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var canInspect: Bool {
        task == nil && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetInspection() {
        inspection = nil
        selected.removeAll()
        completedFolder = nil
        retainedFolder = nil
        caption = ""
        status = ""
        error = nil
    }

    private func inspect() {
        guard canInspect else { return }
        resetInspection()
        status = "Reading post…"
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let result = try await WebDownloadRuntimeService.shared.inspect(url: url, cookies: cookies)
                inspection = result
                selected = Set(result.items.map(\.id))
                caption = result.items.first?.description ?? ""
                status = "Found \(result.items.count) media items."
            } catch is CancellationError { status = "Cancelled." }
            catch { self.error = error.localizedDescription; status = "" }
        }
    }

    private func importSelected() {
        guard task == nil, !selected.isEmpty, let inspection, let destination else { return }
        error = nil
        retainedFolder = nil
        task = Task { @MainActor in
            let didAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if didAccess { destination.stopAccessingSecurityScopedResource() }
                task = nil
            }
            do {
                completedFolder = try await WebMediaImportService().importMedia(
                    inspection: inspection, selected: selected, cookies: cookies,
                    destination: destination, caption: caption,
                    onRetainedBatch: { retainedFolder = $0 }, progress: { status = $0 })
                status = "Import complete. Originals are preserved unchanged."
            } catch is CancellationError {
                status = retainedFolder == nil ? "Cancelled. No files were retained."
                    : "Cancelled. Downloaded and partial originals are retained."
            } catch {
                self.error = error.localizedDescription
                status = retainedFolder == nil ? "Import stopped. No files were retained."
                    : "Import stopped. Downloaded and partial originals are retained."
            }
        }
    }
}
