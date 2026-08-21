import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DeadlineProfileManagementView: View {
    @Bindable var model: DeadlineProfileLibraryModel
    let onClose: () -> Void

    @State private var namePrompt: NamePrompt?
    @State private var proposedName = ""
    @State private var confirmsDelete = false

    private enum NamePrompt {
        case create
        case duplicate
        case rename

        var title: String {
            switch self {
            case .create: "Create Deadline Profile"
            case .duplicate: "Duplicate Deadline Profile"
            case .rename: "Rename Deadline Profile"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deadline Profiles")
                        .font(.title2.weight(.semibold))
                    Text("Profiles contain stable references, never connection passwords or keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if model.profiles.isEmpty, model.isLoaded {
                ContentUnavailableView(
                    "No Deadline Profiles",
                    systemImage: "doc.badge.plus",
                    description: Text("Create a profile or import a versioned deadline-profile JSON file.")
                )
            } else {
                List(model.profiles, id: \.id) { profile in
                    Button {
                        Task { await model.select(profile.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: profile.id == model.selectedProfileID
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profile.id == model.selectedProfileID ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text(profile.id.uuidString.lowercased())
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    proposedName = ""
                    namePrompt = .create
                } label: {
                    Label("New", systemImage: "plus")
                }
                Button("Duplicate") {
                    proposedName = model.selectedProfile.map { "\($0.name) Copy" } ?? ""
                    namePrompt = .duplicate
                }
                .disabled(model.selectedProfile == nil)
                Button("Rename") {
                    proposedName = model.selectedProfile?.name ?? ""
                    namePrompt = .rename
                }
                .disabled(model.selectedProfile == nil)
                Button("Delete", role: .destructive) {
                    confirmsDelete = true
                }
                .disabled(model.selectedProfile == nil)

                Spacer()

                Button("Import…", action: importProfile)
                Button("Export…", action: exportProfile)
                    .disabled(model.selectedProfile == nil)
            }
            .padding(16)
            .disabled(model.isBusy)
        }
        .frame(minWidth: 620, minHeight: 420)
        .task { await model.loadIfNeeded() }
        .alert(namePrompt?.title ?? "Deadline Profile", isPresented: Binding(
            get: { namePrompt != nil },
            set: { if !$0 { namePrompt = nil } }
        )) {
            TextField("Profile Name", text: $proposedName)
            Button("Cancel", role: .cancel) { namePrompt = nil }
            Button(namePrompt == .rename ? "Rename" : "Save") {
                let prompt = namePrompt
                namePrompt = nil
                Task {
                    switch prompt {
                    case .create: await model.create(name: proposedName)
                    case .duplicate: await model.duplicateSelected(name: proposedName)
                    case .rename: await model.renameSelected(to: proposedName)
                    case nil: break
                    }
                }
            }
            .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete \(model.selectedProfile?.name ?? "this deadline profile")?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local saved profile. Referenced templates, lists, and connections are not deleted.")
        }
        .alert("Deadline Profile Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a versioned deadline-profile JSON file."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task { await model.importProfile(from: source) }
    }

    private func exportProfile() {
        guard let profile = model.selectedProfile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFilename(profile.name)).deadline.json"
        panel.message = "Export a portable, secret-free deadline profile. Existing files are not overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await model.exportSelected(to: destination) }
    }

    private func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let parts = value.components(separatedBy: forbidden)
        let result = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Deadline Profile" : result
    }
}
