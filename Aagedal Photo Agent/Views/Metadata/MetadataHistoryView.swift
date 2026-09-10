import SwiftUI

struct MetadataHistoryView: View {
    let history: [MetadataHistoryEntry]
    var onRestoreToPoint: ((Int) -> Void)?
    var onRestoreOriginal: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var canRestoreOriginal: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Editing History")
                    .font(.headline)
                Spacer()
                if !history.isEmpty, let onClearHistory {
                    Button {
                        onClearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Clear history")
                }
            }

            if let onRestoreOriginal {
                Button {
                    onRestoreOriginal()
                } label: {
                    HStack {
                        Text("Original State")
                            .fontWeight(.medium)
                        Spacer()
                        Text("Before edits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRestoreOriginal)
                .help(canRestoreOriginal ? "Restore the saved original metadata as a pending draft"
                    : "This older draft has no original metadata snapshot")
                .padding(.bottom, 4)
            }

            if history.isEmpty {
                Text("No changes recorded")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(history.enumerated().reversed()), id: \.offset) { index, entry in
                            let canRestoreThroughEntry = history.suffix(from: index + 1).allSatisfy(\.isRestorable)
                            Button {
                                onRestoreToPoint?(index)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(entry.displayName)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Text(entry.timestamp, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack {
                                        Text(entry.displayOldValue ?? "(empty)")
                                            .strikethrough()
                                            .foregroundStyle(.red)
                                        Image(systemName: "arrow.right")
                                            .font(.caption)
                                        Text(entry.displayNewValue ?? "(empty)")
                                            .foregroundStyle(.green)
                                    }
                                    .font(.caption)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Restore \(entry.displayName) history point")
                            .accessibilityValue("\(entry.displayOldValue ?? "empty") to \(entry.displayNewValue ?? "empty")")
                            .accessibilityIdentifier("metadata.history.restore.\(index)")
                            .disabled(!canRestoreThroughEntry)
                            .help(canRestoreThroughEntry
                                ? "Restore to this point"
                                : "Later changes include summarized or hidden metadata and cannot be reversed safely")
                        }
                    }
                }
            }
            Text("Restore a history point or Original State. Restored metadata remains pending until you choose Write to Image.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 320, height: 400)
    }
}
