import SwiftUI
import AppKit

private enum KnownPeopleSortMode: String, CaseIterable, Identifiable {
    case name
    case dateAdded
    case dateUpdated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .dateUpdated: return "Date Updated"
        }
    }
}

struct KnownPeopleListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var people: [KnownPerson] = []
    @State private var selectedPersonID: UUID?
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var personToDelete: KnownPerson?
    @State private var deletingPersonIDs: Set<UUID> = []
    @State private var sortMode: KnownPeopleSortMode = .name
    @State private var deletionErrorMessage: String?

    private var filteredPeople: [KnownPerson] {
        let filtered: [KnownPerson]
        if searchText.isEmpty {
            filtered = people
        } else {
            filtered = people.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.role?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return sortPeople(filtered)
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
               let selectedPerson = people.first(where: { $0.id == selectedID }) {
                KnownPersonDetailView(
                    person: knownPersonBinding(for: selectedPerson, in: $people),
                    onSave: { try await savePerson($0) },
                    onDelete: {
                        personToDelete = selectedPerson
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
                Menu {
                    ForEach(KnownPeopleSortMode.allCases) { mode in
                        Button {
                            sortMode = mode
                        } label: {
                            if mode == sortMode {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort known people")
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
        .onReceive(NotificationCenter.default.publisher(for: .knownPeopleDatabaseDidChange)) { _ in
            loadPeople()
        }
        .alert("Delete Person?", isPresented: $showDeleteConfirmation, presenting: personToDelete) { person in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deletePerson(person)
            }
            .disabled(deletingPersonIDs.contains(person.id))
        } message: { person in
            Text("Are you sure you want to delete \"\(person.name)\"? This will remove all \(person.embeddings.count) face sample(s). This cannot be undone.")
        }
        .alert(
            "Deletion Not Completed",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK") { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "")
        }
    }

    private func loadPeople() {
        people = KnownPeopleService.shared.getAllPeople()
    }

    private func sortPeople(_ people: [KnownPerson]) -> [KnownPerson] {
        switch sortMode {
        case .name:
            return people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateAdded:
            return people.sorted { $0.createdAt > $1.createdAt }
        case .dateUpdated:
            return people.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func savePerson(_ person: KnownPerson) async throws {
        try await KnownPeopleService.shared.updatePersonDetailsInBackground(person)
    }

    private func deletePerson(_ person: KnownPerson) {
        guard deletingPersonIDs.insert(person.id).inserted else { return }
        Task {
            defer { deletingPersonIDs.remove(person.id) }
            do {
                try await KnownPeopleService.shared.removePersonInBackground(id: person.id)
                people.removeAll { $0.id == person.id }
                if selectedPersonID == person.id {
                    selectedPersonID = nil
                }
            } catch is CancellationError {
                // Durable changes are published by the service; storage changes cancel this view's request.
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
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
        .task(id: person.updatedAt) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let personID = person.id
        let loaded = await KnownPeopleService.shared.loadThumbnail(for: personID)
        guard person.id == personID, !Task.isCancelled else { return }
        thumbnail = loaded
    }
}

// MARK: - Known Person Detail View

struct KnownPersonDetailView: View {
    @Binding var person: KnownPerson
    let onSave: (KnownPerson) async throws -> Void
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var editedName: String = ""
    @State private var editedRole: String = ""
    @State private var editedNotes: String = ""
    @State private var hasChanges = false
    @State private var saveRequestID: UUID?
    private var isSaving: Bool { saveRequestID != nil }
    @State private var saveErrorMessage: String?

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
                .disabled(!hasChanges || isSaving)
            }
            .padding()
            .background(.bar)
        }
        .onAppear {
            resetFields()
        }
        .onChange(of: person.id) {
            resetFields()
        }
        .onDisappear {
            // The admitted write may finish, but its old editor must not publish into a new one.
            saveRequestID = nil
            saveErrorMessage = nil
        }
        .task(id: person.updatedAt) { await loadThumbnail() }
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

    private func loadThumbnail() async {
        let personID = person.id
        let loaded = await KnownPeopleService.shared.loadThumbnail(for: personID)
        guard person.id == personID, !Task.isCancelled else { return }
        thumbnail = loaded
    }

    private func resetFields() {
        saveRequestID = nil
        saveErrorMessage = nil
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
        let requestID = UUID()
        saveRequestID = requestID
        saveErrorMessage = nil
        Task {
            defer {
                if saveRequestID == requestID { saveRequestID = nil }
            }
            do {
                try await onSave(edited)
                guard saveRequestID == requestID, person.id == edited.id else { return }
                // Compare with the submitted fields; publication may reach the binding later.
                hasChanges = editedName != edited.name || editedRole != (edited.role ?? "") ||
                    editedNotes != (edited.notes ?? "")
            } catch is CancellationError {
                // Storage replacement invalidates this editor's completion.
            } catch {
                guard saveRequestID == requestID, person.id == edited.id else { return }
                saveErrorMessage = error.localizedDescription
                checkForChanges()
            }
        }
    }
}

/// Async editors can outlive removal or reordering of their original array element.
/// Retain a display fallback for that disappearing view and ignore writes to missing identities.
@MainActor
func knownPersonBinding(for person: KnownPerson, in people: Binding<[KnownPerson]>) -> Binding<KnownPerson> {
    Binding(
        get: { people.wrappedValue.first(where: { $0.id == person.id }) ?? person },
        set: { updated in
            guard updated.id == person.id,
                  let index = people.wrappedValue.firstIndex(where: { $0.id == person.id }) else { return }
            people.wrappedValue[index] = updated
        }
    )
}
