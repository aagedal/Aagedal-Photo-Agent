import SwiftUI

/// A compact button + popover surfacing recent import/upload history.
/// Layer 1 lists each operation (count + time); expanding a row reveals
/// Layer 2: the per-file list with destinations and a verification column.
struct ActivityHistoryButton: View {
    var history: ActivityHistoryStore
    @State private var isShowingHistory = false

    var body: some View {
        Button {
            isShowingHistory = true
        } label: {
            Label("Activity", systemImage: "clock.arrow.circlepath")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
            ActivityHistoryView(history: history)
        }
    }
}

struct ActivityHistoryView: View {
    var history: ActivityHistoryStore

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case imports = "Imports"
        case uploads = "Uploads"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .all
    @State private var expanded: Set<UUID> = []

    private var filteredEntries: [ActivityEntry] {
        switch filter {
        case .all: return history.entries
        case .imports: return history.entries.filter { $0.kind == .importJob }
        case .uploads: return history.entries.filter { $0.kind == .upload }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity History")
                    .font(.headline)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Divider()

            if filteredEntries.isEmpty {
                Text("No recent activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredEntries) { entry in
                            ActivityEntryRow(
                                entry: entry,
                                isExpanded: expanded.contains(entry.id),
                                toggle: { toggle(entry.id) }
                            )
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(width: 480)
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

private struct ActivityEntryRow: View {
    let entry: ActivityEntry
    let isExpanded: Bool
    let toggle: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Layer 1: summary row (click to reveal Layer 2)
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Image(systemName: entry.kind == .importJob ? "square.and.arrow.down" : "square.and.arrow.up")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            if let title = entry.title, !title.isEmpty {
                                Text(title)
                                Text("·")
                            }
                            Text(Self.dateFormatter.string(from: entry.date))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: entry.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(entry.isClean ? Color.green : Color.orange)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Layer 2: per-file detail
            if isExpanded {
                ActivityFileTable(files: entry.files, kind: entry.kind)
                    .padding(.leading, 28)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ActivityFileTable: View {
    let files: [ActivityFileRecord]
    let kind: ActivityKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("File").frame(maxWidth: .infinity, alignment: .leading)
                Text(kind == .importJob ? "Folder" : "Destination").frame(maxWidth: .infinity, alignment: .leading)
                Text("Verified").frame(width: 56, alignment: .center)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(files) { file in
                HStack {
                    Text(file.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(file.succeeded ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(displayDestination(file.destination))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    verificationCell(file.verification)
                        .frame(width: 56, alignment: .center)
                }
                .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func verificationCell(_ v: ActivityVerification) -> some View {
        switch v {
        case .verified:
            Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark").foregroundStyle(.red)
        case .notApplicable:
            Text("–").foregroundStyle(.secondary)
        }
    }

    /// Shows the folder name (or last two path components) rather than the full path.
    private func displayDestination(_ path: String) -> String {
        guard !path.isEmpty else { return "—" }
        let comps = path.split(separator: "/")
        if comps.count >= 2 {
            return comps.suffix(2).joined(separator: "/")
        }
        return comps.last.map(String.init) ?? path
    }
}
