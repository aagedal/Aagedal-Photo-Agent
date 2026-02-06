import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

// MARK: - Expanded Known People View

struct ExpandedKnownPeopleView: View {
    var onClose: () -> Void

    @State private var people: [KnownPerson] = []
    @State private var selectedPersonIDs: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var showDeleteConfirmation = false
    @State private var personToDelete: KnownPerson?
    @State private var showMergeConfirmation = false
    @State private var sortMode: KnownPeopleSortMode = .name
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importExportMessage: String?

    private var filteredPeople: [KnownPerson] {
        let base: [KnownPerson]
        if searchText.isEmpty {
            base = people
        } else {
            base = people.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.role?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                ($0.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return sortPeople(base)
    }

    private var selectedPerson: KnownPerson? {
        guard selectedPersonIDs.count == 1,
              let id = selectedPersonIDs.first else { return nil }
        return people.first { $0.id == id }
    }

    private var selectedPersonBinding: Binding<KnownPerson>? {
        guard selectedPersonIDs.count == 1,
              let id = selectedPersonIDs.first,
              let index = people.firstIndex(where: { $0.id == id }) else { return nil }
        return $people[index]
    }

    private var canMerge: Bool {
        selectedPersonIDs.count >= 2
    }

    private var stats: (peopleCount: Int, embeddingCount: Int) {
        KnownPeopleService.shared.getStatistics()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            mainContent
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
        } message: { person in
            Text("Are you sure you want to delete \"\(person.name)\"? This will remove all \(person.embeddings.count) face sample(s). This cannot be undone.")
        }
        .alert("Merge People?", isPresented: $showMergeConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Merge") {
                mergeSelectedPeople()
            }
        } message: {
            let targetName = people.first { selectedPersonIDs.contains($0.id) }?.name ?? ""
            Text("Merge \(selectedPersonIDs.count) people into one? The first person (\(targetName)) will be kept and receive all embeddings from the others. The other \(selectedPersonIDs.count - 1) people will be deleted.")
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Label("Close", systemImage: "xmark")
            }

            Divider()
                .frame(height: 16)

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search people...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            Divider()
                .frame(height: 16)

            // Stats
            Text("\(stats.peopleCount) people, \(stats.embeddingCount) samples")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let importExportMessage {
                Text(importExportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                importKnownPeople()
            } label: {
                if isImporting {
                    Label("Importing...", systemImage: "arrow.down.doc")
                } else {
                    Label("Import", systemImage: "arrow.down.doc")
                }
            }
            .disabled(isImporting || isExporting)

            Button {
                exportKnownPeople()
            } label: {
                if isExporting {
                    Label("Exporting...", systemImage: "arrow.up.doc")
                } else {
                    Label("Export", systemImage: "arrow.up.doc")
                }
            }
            .disabled(isImporting || isExporting)

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

            // Selection info
            if !selectedPersonIDs.isEmpty {
                Text("\(selectedPersonIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Merge button
            Button {
                showMergeConfirmation = true
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
            }
            .disabled(!canMerge)
            .help("Merge selected people into one")

            // Delete button
            Button(role: .destructive) {
                if let person = selectedPerson {
                    personToDelete = person
                    showDeleteConfirmation = true
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedPersonIDs.count != 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        HStack(spacing: 0) {
            // Person list (left)
            personListView
                .frame(width: 280)

            Divider()

            // Contact card area (center)
            contactCardView
                .frame(maxWidth: .infinity)

            // Edit sidebar (right)
            if let binding = selectedPersonBinding {
                Divider()
                PersonEditSidebar(
                    person: binding,
                    onSave: { savePerson(binding.wrappedValue) },
                    onDelete: {
                        personToDelete = binding.wrappedValue
                        showDeleteConfirmation = true
                    }
                )
                .frame(width: 320)
            }
        }
    }

    // MARK: - Person List

    @ViewBuilder
    private var personListView: some View {
        VStack(spacing: 0) {
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
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredPeople) { person in
                            PersonListRow(
                                person: person,
                                isSelected: selectedPersonIDs.contains(person.id)
                            )
                            .onTapGesture {
                                handlePersonTap(person)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(.background.secondary)
    }

    // MARK: - Contact Card

    @ViewBuilder
    private var contactCardView: some View {
        if let person = selectedPerson {
            PersonContactCard(person: person)
        } else if selectedPersonIDs.count > 1 {
            // Multiple selection
            VStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("\(selectedPersonIDs.count) People Selected")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Click Merge to combine them into one person")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Select a Person", systemImage: "person.crop.rectangle")
            } description: {
                Text("Choose a person from the list to view and edit their details.")
            }
        }
    }

    // MARK: - Actions

    private func handlePersonTap(_ person: KnownPerson) {
        if NSEvent.modifierFlags.contains(.command) {
            // Cmd+click: toggle selection
            if selectedPersonIDs.contains(person.id) {
                selectedPersonIDs.remove(person.id)
            } else {
                selectedPersonIDs.insert(person.id)
            }
        } else {
            // Regular click: single selection
            selectedPersonIDs = [person.id]
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

    private func importKnownPeople() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "Select a Known People database (.zip)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        importExportMessage = nil

        Task {
            do {
                let count = try await KnownPeopleService.shared.importFromZip(sourceURL: url)
                isImporting = false
                importExportMessage = "Imported \(count) people"
                loadPeople()

                try? await Task.sleep(for: .seconds(3))
                importExportMessage = nil
            } catch {
                isImporting = false
                importExportMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportKnownPeople() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "KnownPeople.zip"
        panel.message = "Export Known People database"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        importExportMessage = nil

        Task {
            do {
                try await KnownPeopleService.shared.exportToZip(destinationURL: url)
                isExporting = false
                importExportMessage = "Export complete"
                loadPeople()

                try? await Task.sleep(for: .seconds(3))
                importExportMessage = nil
            } catch {
                isExporting = false
                importExportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func savePerson(_ person: KnownPerson) {
        try? KnownPeopleService.shared.updatePerson(person)
    }

    private func deletePerson(_ person: KnownPerson) {
        do {
            try KnownPeopleService.shared.removePerson(id: person.id)
            people.removeAll { $0.id == person.id }
            selectedPersonIDs.remove(person.id)
        } catch {
            // Handle error silently for now
        }
    }

    private func mergeSelectedPeople() {
        guard selectedPersonIDs.count >= 2 else { return }

        // Sort selected people by name to get consistent merge order
        let sortedSelected = people
            .filter { selectedPersonIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard let targetPerson = sortedSelected.first else { return }
        let sourcePeople = Array(sortedSelected.dropFirst())

        do {
            for source in sourcePeople {
                try KnownPeopleService.shared.mergePeople(sourceID: source.id, intoTargetID: targetPerson.id)
            }
            loadPeople()
            selectedPersonIDs = [targetPerson.id]
        } catch {
            // Handle error silently for now
        }
    }
}

// MARK: - Person List Row

struct PersonListRow: View {
    let person: KnownPerson
    let isSelected: Bool
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

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        thumbnail = KnownPeopleService.shared.loadThumbnail(for: person.id)
    }
}

// MARK: - Person Contact Card

struct PersonContactCard: View {
    let person: KnownPerson
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 24) {
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
                        .padding(30)
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.quaternary)
            )
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)

            // Name and role
            VStack(spacing: 4) {
                Text(person.name)
                    .font(.title)
                    .fontWeight(.semibold)

                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            // Notes
            if let notes = person.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Stats
            HStack(spacing: 24) {
                VStack {
                    Text("\(person.embeddings.count)")
                        .font(.title2.monospacedDigit())
                        .fontWeight(.medium)
                    Text("Embeddings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 40)

                VStack {
                    Text(sourceFilesCount)
                        .font(.title2.monospacedDigit())
                        .fontWeight(.medium)
                    Text("Source Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: person.id) {
            loadThumbnail()
        }
    }

    private var sourceFilesCount: String {
        let uniqueSources = Set(person.embeddings.compactMap { $0.sourceDescription })
        return "\(uniqueSources.count)"
    }

    private func loadThumbnail() {
        thumbnail = KnownPeopleService.shared.loadThumbnail(for: person.id)
    }
}
