import SwiftUI
import AppKit

// MARK: - Person Edit Sidebar

struct PersonEditSidebar: View {
    @Binding var person: KnownPerson
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var editedName: String = ""
    @State private var editedRole: String = ""
    @State private var editedNotes: String = ""
    @State private var hasChanges = false
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
                        infoRow("Embeddings", value: "\(person.embeddings.count)")
                        infoRow("Created", value: person.createdAt.formatted(date: .abbreviated, time: .shortened))
                        infoRow("Updated", value: person.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    // Source files
                    if !person.embeddings.isEmpty {
                        Divider()
                            .padding(.vertical, 8)

                        sectionHeader("Source Files")

                        VStack(alignment: .leading, spacing: 4) {
                            let sources = person.embeddings.compactMap { $0.sourceDescription }
                            let uniqueSources = Array(Set(sources)).sorted()
                            ForEach(uniqueSources, id: \.self) { source in
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
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
                .disabled(!hasChanges)
            }
            .padding()
        }
        .background(.background)
        .onAppear {
            resetFields()
            loadThumbnail()
        }
        .onChange(of: person.id) {
            resetFields()
            loadThumbnail()
        }
        .onChange(of: editedName) { checkForChanges() }
        .onChange(of: editedRole) { checkForChanges() }
        .onChange(of: editedNotes) { checkForChanges() }
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

    private func loadThumbnail() {
        thumbnail = KnownPeopleService.shared.loadThumbnail(for: person.id)
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
        person.name = editedName
        person.role = editedRole.isEmpty ? nil : editedRole
        person.notes = editedNotes.isEmpty ? nil : editedNotes
        onSave()
        hasChanges = false
    }
}
