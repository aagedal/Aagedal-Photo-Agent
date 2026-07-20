import SwiftUI

/// A compact button + popover surfacing active work and recent background-operation history.
/// Layer 1 lists each operation (count + time); expanding a row reveals
/// Layer 2: the per-file list with destinations and a verification column.
struct ActivityHistoryButton: View {
    var history: ActivityHistoryStore
    var faceViewModel: FaceRecognitionViewModel
    @State private var isShowingHistory = false

    var body: some View {
        Button {
            isShowingHistory = true
        } label: {
            Group {
                if faceViewModel.isScanning {
                    Label("Face Scan \(faceViewModel.scanProgress)", systemImage: "viewfinder")
                } else {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
            ActivityHistoryView(history: history, faceViewModel: faceViewModel)
        }
    }
}

struct ActivityHistoryView: View {
    var history: ActivityHistoryStore
    var faceViewModel: FaceRecognitionViewModel

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case imports = "Imports"
        case uploads = "Uploads"
        case faceScans = "Face Scans"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .all
    @State private var expanded: Set<UUID> = []

    private var filteredEntries: [ActivityEntry] {
        switch filter {
        case .all: return history.entries
        case .imports: return history.entries.filter { $0.kind == .importJob }
        case .uploads: return history.entries.filter { $0.kind == .upload }
        case .faceScans: return history.entries.filter { $0.kind == .faceScan }
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

            if faceViewModel.isScanning {
                ActiveFaceScanRow(viewModel: faceViewModel)
                Divider()
            }

            if filteredEntries.isEmpty {
                Text(faceViewModel.isScanning ? "No completed activity." : "No recent activity.")
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
                .frame(maxHeight: 480)
            }
        }
        .padding(12)
        .frame(width: 560)
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
            Button(action: { if !entry.files.isEmpty { toggle() } }) {
                HStack(spacing: 8) {
                    Group {
                        if entry.files.isEmpty {
                            Color.clear
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 10)

                    Image(systemName: iconName)
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
            if isExpanded && !entry.files.isEmpty {
                ActivityFileTable(files: entry.files, kind: entry.kind)
                    .padding(.leading, 28)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.kind {
        case .importJob: "square.and.arrow.down"
        case .upload: "square.and.arrow.up"
        case .faceScan: "viewfinder"
        }
    }
}

private struct ActiveFaceScanRow: View {
    @Bindable var viewModel: FaceRecognitionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.isCancellingScan ? "Cancelling face scan…" : "Scanning faces")
                        .font(.caption.weight(.semibold))
                    if let folder = viewModel.scanningFolderURL {
                        Text(folder.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(viewModel.scanProgress)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { viewModel.cancelScan() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(viewModel.isCancellingScan)
            }
            ProgressView(
                value: Double(viewModel.scanProcessedCount),
                total: Double(max(viewModel.scanTotalCount, 1))
            )
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
