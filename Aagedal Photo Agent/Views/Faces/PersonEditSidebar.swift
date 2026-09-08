import SwiftUI
import AppKit
import os.log

nonisolated private let knownPeopleSidebarLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent",
    category: "PersonEditSidebar"
)

// MARK: - Person Edit Sidebar

struct PersonEditSidebar: View {
    @Binding var person: KnownPerson
    let onSave: (KnownPerson) async throws -> Void
    let onDelete: () -> Void

    @State private var editedName: String = ""
    @State private var editedRole: String = ""
    @State private var editedNotes: String = ""
    @State private var hasChanges = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Identity section
                    sectionHeader("Identity")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.roundedBorder)

                        Text("Role")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Role (optional)", text: $editedRole)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // Notes section
                    sectionHeader("Notes")

                    TextEditor(text: $editedNotes)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.background.secondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )

                    Divider()
                        .padding(.vertical, 8)

                    // Information section
                    sectionHeader("Information")

                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Created", value: person.createdAt.formatted(date: .abbreviated, time: .shortened))
                        infoRow("Updated", value: person.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    // Face samples
                    if !person.embeddings.isEmpty {
                        Divider()
                            .padding(.vertical, 8)

                        EmbeddingGridView(
                            person: person,
                            onDeleteEmbedding: { embeddingID in
                                deleteEmbedding(embeddingID)
                            },
                            onSetRepresentative: { embeddingID in
                                setRepresentative(embeddingID)
                            }
                        )
                    }
                }
                .padding()
            }

            Divider()

            // Action buttons
            HStack {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    applyChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || isSaving)
            }
            .padding()
        }
        .background(.background)
        .onAppear {
            resetFields()
        }
        .onChange(of: person.id) {
            resetFields()
        }
        .task(id: person.id) { await loadThumbnail() }
        .onChange(of: editedName) { checkForChanges() }
        .onChange(of: editedRole) { checkForChanges() }
        .onChange(of: editedNotes) { checkForChanges() }
        .alert("Save Not Completed", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK") { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    private func loadThumbnail() async {
        let personID = person.id
        let loaded = await KnownPeopleService.shared.loadThumbnail(for: personID)
        guard person.id == personID, !Task.isCancelled else { return }
        thumbnail = loaded
    }

    private func resetFields() {
        editedName = person.name
        editedRole = person.role ?? ""
        editedNotes = person.notes ?? ""
        hasChanges = false
    }

    private func checkForChanges() {
        let nameChanged = editedName != person.name
        let roleChanged = editedRole != (person.role ?? "")
        let notesChanged = editedNotes != (person.notes ?? "")
        hasChanges = nameChanged || roleChanged || notesChanged
    }

    private func applyChanges() {
        guard !isSaving else { return }
        var edited = person
        edited.name = editedName
        edited.role = editedRole.isEmpty ? nil : editedRole
        edited.notes = editedNotes.isEmpty ? nil : editedNotes
        isSaving = true
        saveErrorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onSave(edited)
                guard person.id == edited.id else { return }
                // Compare with the submitted fields; publication may reach the binding later.
                hasChanges = editedName != edited.name || editedRole != (edited.role ?? "") ||
                    editedNotes != (edited.notes ?? "")
            } catch is CancellationError {
                // Storage replacement invalidates this editor's completion.
            } catch {
                guard person.id == edited.id else { return }
                saveErrorMessage = error.localizedDescription
                checkForChanges()
            }
        }
    }

    private func deleteEmbedding(_ embeddingID: UUID) {
        let personID = person.id
        Task {
            do {
                try await KnownPeopleService.shared.removeEmbedding(
                    embeddingID,
                    fromPersonID: personID
                )
                guard person.id == personID, !Task.isCancelled else { return }
                if let updated = KnownPeopleService.shared.person(byID: personID) {
                    person = updated
                }
            } catch {
                knownPeopleSidebarLog.error("Failed to delete embedding: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func setRepresentative(_ embeddingID: UUID) {
        let personID = person.id
        Task {
            do {
                let embeddingThumbnail = await KnownPeopleService.shared.loadEmbeddingThumbnail(
                    for: embeddingID
                )
                guard person.id == personID, !Task.isCancelled else { return }
                if let embeddingThumbnail,
                   let tiffData = embeddingThumbnail.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let jpegData = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.85]
                   ) {
                    try await KnownPeopleService.shared.replaceThumbnail(
                        for: personID,
                        newThumbnailData: jpegData
                    )
                }
                guard person.id == personID, !Task.isCancelled,
                      let updated = KnownPeopleService.shared.person(byID: personID),
                      updated.embeddings.contains(where: { $0.id == embeddingID }) else { return }
                try await KnownPeopleService.shared.updateRepresentativeInBackground(embeddingID, for: personID)
                guard person.id == personID, !Task.isCancelled else { return }
                if let current = KnownPeopleService.shared.person(byID: personID) { person = current }
                await loadThumbnail()
            } catch {
                knownPeopleSidebarLog.error("Failed to set representative: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
