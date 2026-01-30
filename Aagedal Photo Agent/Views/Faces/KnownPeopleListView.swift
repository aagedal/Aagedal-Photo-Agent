import SwiftUI
import AppKit

struct KnownPeopleListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var people: [KnownPerson] = []
    @State private var selectedPersonID: UUID?
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var personToDelete: KnownPerson?

    private var filteredPeople: [KnownPerson] {
        if searchText.isEmpty {
            return people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return people.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.role?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search people...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.background.secondary)

                Divider()

                // People list
                if filteredPeople.isEmpty {
                    ContentUnavailableView {
                        Label(
                            searchText.isEmpty ? "No Known People" : "No Results",
                            systemImage: searchText.isEmpty ? "person.crop.rectangle.stack" : "magnifyingglass"
                        )
                    } description: {
                        Text(searchText.isEmpty
                             ? "Add people from face groups to build your database."
                             : "No people match \"\(searchText)\"")
                    }
                } else {
                    List(filteredPeople, selection: $selectedPersonID) { person in
                        KnownPersonRow(person: person)
                            .tag(person.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 350)
        } detail: {
            if let selectedID = selectedPersonID,
               let personIndex = people.firstIndex(where: { $0.id == selectedID }) {
                KnownPersonDetailView(
                    person: $people[personIndex],
                    onSave: { savePerson(people[personIndex]) },
                    onDelete: {
                        personToDelete = people[personIndex]
                        showDeleteConfirmation = true
                    }
                )
            } else {
                ContentUnavailableView {
                    Label("Select a Person", systemImage: "person.crop.rectangle")
                } description: {
                    Text("Choose a person from the list to view and edit their details.")
                }
            }
        }
        .frame(width: 700, height: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Text("\(people.count) people")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            loadPeople()
        }
        .alert("Delete Person?", isPresented: $showDeleteConfirmation, presenting: personToDelete) { person in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deletePerson(person)
            }
        } message: { person in
            Text("Are you sure you want to delete \"\(person.name)\"? This will remove all \(person.embeddings.count) face sample(s). This cannot be undone.")
        }
    }

    private func loadPeople() {
        people = KnownPeopleService.shared.getAllPeople()
    }

    private func savePerson(_ person: KnownPerson) {
        try? KnownPeopleService.shared.updatePerson(person)
    }

    private func deletePerson(_ person: KnownPerson) {
        do {
            try KnownPeopleService.shared.removePerson(id: person.id)
            people.removeAll { $0.id == person.id }
            if selectedPersonID == person.id {
                selectedPersonID = nil
            }
        } catch {
            // Handle error silently for now
        }
    }
}

// MARK: - Known Person Row

struct KnownPersonRow: View {
    let person: KnownPerson
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            Group {
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            )

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.body)
                    .lineLimit(1)

                if let subtitle = person.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("\(person.embeddings.count) sample\(person.embeddings.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        thumbnail = KnownPeopleService.shared.loadThumbnail(for: person.id)
    }
}

// MARK: - Known Person Detail View

struct KnownPersonDetailView: View {
    @Binding var person: KnownPerson
    let onSave: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var editedName: String = ""
    @State private var editedRole: String = ""
    @State private var editedNotes: String = ""
    @State private var hasChanges = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Large thumbnail
                Group {
                    if let image = thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                // Edit form
                Form {
                    Section("Identity") {
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.roundedBorder)

                        TextField("Role (optional)", text: $editedRole)
                            .textFieldStyle(.roundedBorder)
                    }

                    Section("Notes") {
                        TextEditor(text: $editedNotes)
                            .frame(minHeight: 60)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.background.secondary)
                            )

                        Text("Use notes to distinguish between people with the same name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Information") {
                        LabeledContent("Face Samples") {
                            Text("\(person.embeddings.count)")
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Created") {
                            Text(person.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("Updated") {
                            Text(person.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent("ID") {
                            Text(person.id.uuidString.prefix(8) + "...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospaced()
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)

                Spacer()
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Person", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save Changes") {
                    applyChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
            }
            .padding()
            .background(.bar)
        }
        .onAppear {
            loadThumbnail()
            resetFields()
        }
        .onChange(of: person.id) {
            loadThumbnail()
            resetFields()
        }
        .onChange(of: editedName) { checkForChanges() }
        .onChange(of: editedRole) { checkForChanges() }
        .onChange(of: editedNotes) { checkForChanges() }
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
