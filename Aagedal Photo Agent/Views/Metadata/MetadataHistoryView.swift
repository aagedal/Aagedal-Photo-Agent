import SwiftUI

struct MetadataHistoryView: View {
    let history: [MetadataHistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editing History")
                .font(.headline)

            if history.isEmpty {
                Text("No changes recorded")
                    .foregroundStyle(.secondary)
            } else {
                List(history.reversed()) { entry in
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
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .frame(width: 300, height: 400)
    }
}
