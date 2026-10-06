import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StructuredKeywordLibrarySettings: View {
    @State private var library = StructuredKeywordLibrary.shared
    @State private var editing: StructuredKeywordLibraryDocument.List?
    @State private var editingLegacy = false
    @State private var newName = ""
    @State private var feedback: String?
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?

    private var unavailable: Bool { library.isLoading || library.isSaving || library.hasReadFailure || importing }

    var body: some View {
        Section("Structured Keyword Lists") {
            Picker("Active lists", selection: Binding(get: { library.document.mode }, set: { mode in
                commit { $0.setMode(mode) }
            })) {
                Text("One list at a time").tag(StructuredKeywordLibraryDocument.SelectionMode.single)
                Text("Multiple lists").tag(StructuredKeywordLibraryDocument.SelectionMode.multiple)
            }
            .disabled(unavailable)
            Text("Enable the lists available in the keyword picker, autocomplete, and structured keyword validation. List names are navigation headings and are never added to photos.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                activeToggle(StructuredKeywordLibraryDocument.iptcID, name: "IPTC Media Topics")
                Spacer()
                Text("Release · \(library.iptcRelease)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Automatically update IPTC Media Topics", isOn: $library.automaticallyUpdateIPTC)
                Spacer()
                Button("Check for Updates") {
                    Task { await library.checkForIPTCUpdates() }
                }
                .disabled(library.isLoading || library.isUpdatingIPTC)
            }
            Text("Checks weekly when the app runs. Updates include every available language and remain available offline.")
                .font(.caption).foregroundStyle(.secondary)
            if library.isUpdatingIPTC { ProgressView("Checking IPTC…").controlSize(.small) }
            if let message = library.iptcUpdateMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Picker("IPTC language", selection: Binding(get: { library.document.languageOverride ?? "system" }, set: { language in
                commit { $0.languageOverride = language == "system" ? nil : language }
            })) {
                Text("Follow System (\(IPTCMediaTopicsLanguage.resolve(override: nil).displayName))").tag("system")
                ForEach(IPTCMediaTopicsLanguage.allCases, id: \.rawValue) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .disabled(unavailable)
            Text("Missing translations use English. Changing the list language does not change keywords already saved to photos.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                activeToggle(StructuredKeywordLibraryDocument.legacyID, name: "My Keywords")
                Spacer()
                Button("Edit…") { editingLegacy = true }.disabled(unavailable)
            }
            ForEach(library.document.lists) { list in
                HStack {
                    activeToggle(list.id, name: list.name)
                    Spacer()
                    Button("Edit…") { editing = list }
                    Button(role: .destructive) {
                        commit { document in
                            document.lists.removeAll { $0.id == list.id }
                            document.activeIDs.removeAll { $0 == list.id }
                        }
                    } label: { Image(systemName: "trash") }
                    .help("Remove \(list.name)")
                }
                .disabled(unavailable)
            }
            HStack {
                TextField("New list name", text: $newName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: .infinity)
                    .layoutPriority(1)
                    .accessibilityLabel("New list name")
                Button("Create List") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let list = StructuredKeywordLibraryDocument.List(id: UUID().uuidString, name: name, text: "")
                    Task {
                        do {
                            if try await library.update({ $0.lists.append(list); $0.setActive(list.id, active: true) }) {
                                newName = ""
                                editing = list
                            }
                        } catch { feedback = error.localizedDescription }
                    }
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Import List…", action: importList)
            }
            .disabled(unavailable)
            Text("Import a PhotoMechanic-style .txt tree. Each import adds a separate list; use Edit to change or export a list.")
                .font(.caption).foregroundStyle(.secondary)
            Link("IPTC Media Topics © IPTC · CC BY 4.0", destination: URL(string: "https://iptc.org/standards/media-topics/")!)
                .font(.caption)
            Text("Adapted to a keyword tree; retired concepts omitted. Topic labels and their ancestors are applied as keywords.")
                .font(.caption).foregroundStyle(.secondary)
            if library.isLoading || importing { ProgressView().controlSize(.small) }
            if let message = feedback ?? library.error {
                Text(message).foregroundStyle(.red).font(.caption)
                if library.hasReadFailure {
                    Button("Retry") { Task { await library.reload() } }
                }
            }
        }
        .onDisappear {
            importTask?.cancel()
            importTask = nil
        }
        .sheet(isPresented: $editingLegacy) {
            StructuredKeywordEditor(service: .legacy, title: "My Keywords")
        }
        .sheet(item: $editing) { list in
            VStack(spacing: 0) {
                LibraryListNameEditor(list: list, library: library)
                StructuredKeywordEditor(
                    initialTree: StructuredKeywordParser.parseString(list.text),
                    saveHandler: { tree in
                        guard library.document.lists.contains(where: { $0.id == list.id }) else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        return try await library.update { document in
                            if let index = document.lists.firstIndex(where: { $0.id == list.id }) {
                                document.lists[index].text = StructuredKeywordSerializer.serialize(tree)
                            }
                        }
                    },
                    title: list.name,
                    exportFilename: "\(list.name).txt"
                )
            }
        }
    }

    private func activeToggle(_ id: String, name: String) -> some View {
        Toggle(name, isOn: Binding(get: { library.document.activeIDs.contains(id) }, set: { active in
            commit { $0.setActive(id, active: active) }
        }))
        .disabled(unavailable)
    }

    private func commit(_ change: @escaping (inout StructuredKeywordLibraryDocument) -> Void) {
        Task {
            do { if try await library.update(change) { feedback = nil } }
            catch { feedback = error.localizedDescription }
        }
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Add a structured keyword list"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        importTask = Task {
            defer { importing = false; importTask = nil }
            do {
                let result = try await TextFileImportService.shared.loadText(from: url, requestID: UUID())
                guard !Task.isCancelled, case .loaded(let snapshot) = result else { return }
                guard !StructuredKeywordParser.parseString(snapshot.text).isEmpty else { throw StructuredKeywordParserError.empty }
                let list = StructuredKeywordLibraryDocument.List(
                    id: UUID().uuidString, name: url.deletingPathExtension().lastPathComponent, text: snapshot.text)
                if try await library.update({ $0.lists.append(list); $0.setActive(list.id, active: true) }) { feedback = nil }
            } catch { feedback = error.localizedDescription }
        }
    }
}

private struct LibraryListNameEditor: View {
    let list: StructuredKeywordLibraryDocument.List
    let library: StructuredKeywordLibrary
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        HStack {
            TextField("List name", text: $name)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: .infinity)
                .layoutPriority(1)
                .accessibilityLabel("List name")
            Button("Rename") {
                Task {
                    do {
                        _ = try await library.update { document in
                            if let index = document.lists.firstIndex(where: { $0.id == list.id }) {
                                document.lists[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isSaving)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding()
        .onAppear { name = list.name }
    }
}
