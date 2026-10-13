import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WebImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var cookies: URL?
    @State private var destination: URL?
    @State private var inspection: WebPostInspection?
    @State private var selected = Set<String>()
    @State private var caption = ""
    @State private var status = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var completedFolder: URL?
    let onImported: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Web URL").font(.title2.bold())
            HStack {
                TextField("Instagram or X post URL", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .disabled(task != nil)
                    .onChange(of: url) { _, _ in inspection = nil; selected = []; completedFolder = nil }
                Button("Find Media", action: inspect).disabled(task != nil || url.isEmpty)
            }
            HStack {
                Button(cookies == nil ? "Choose Cookies File…" : "Cookies: \(cookies!.lastPathComponent)") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK { cookies = panel.url; inspection = nil }
                }
                if cookies != nil { Button("Clear") { cookies = nil; inspection = nil } }
                Text("Optional Netscape cookies file for posts that require sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(task != nil)
            if let inspection {
                Text("\(inspection.items.count) media items · Highest available quality").font(.headline)
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
                    if panel.runModal() == .OK { destination = panel.url }
                }.disabled(task != nil)
                Text(destination?.path ?? "No destination selected").font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Text("Each import creates Originals, Working and Provenance folders. JPEG working copies receive embedded metadata; videos, other formats and credentialed JPEGs receive XMP sidecars.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !status.isEmpty { HStack { if task != nil { ProgressView().controlSize(.small) }; Text(status) } }
            HStack {
                Button(task == nil ? "Close" : "Cancel") {
                    if let task { task.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if let folder = completedFolder {
                    Button("Open Working Folder") { onImported(folder); dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Download & Import", action: importSelected)
                        .buttonStyle(.borderedProminent)
                        .disabled(task != nil || inspection == nil || selected.isEmpty || destination == nil)
                }
            }
        }
        .padding(24).frame(width: 720, height: 680)
        .interactiveDismissDisabled(task != nil)
        .onDisappear { task?.cancel() }
    }

    private func inspect() {
        error = nil
        status = "Reading post…"
        inspection = nil
        completedFolder = nil
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
        guard let inspection, let destination else { return }
        error = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                completedFolder = try await WebMediaImportService().importMedia(
                    inspection: inspection, selected: selected, cookies: cookies,
                    destination: destination, caption: caption, progress: { status = $0 })
                status = "Import complete. Originals are preserved unchanged."
            } catch is CancellationError { status = "Cancelled. Completed original downloads are retained in the destination." }
            catch { self.error = error.localizedDescription; status = "Import stopped. Check the destination for retained originals." }
        }
    }
}
