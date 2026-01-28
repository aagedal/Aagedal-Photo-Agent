import SwiftUI

struct MetadataHistoryView: View {
    let history: [MetadataHistoryEntry]
    var onRestoreToPoint: ((Int) -> Void)?
    var onClearHistory: (() -> Void)?

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

            if history.isEmpty {
                Text("No changes recorded")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                List(Array(history.enumerated().reversed()), id: \.element.id) { index, entry in
                    Button {
                        onRestoreToPoint?(index)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.fieldName)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(entry.oldValue ?? "(empty)")
                                    .strikethrough()
                                    .foregroundStyle(.red)
                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                Text(entry.newValue ?? "(empty)")
                                    .foregroundStyle(.green)
                            }
                            .font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)

                Text("Click an entry to restore to that point")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(width: 320, height: 400)
    }
}
