import SwiftUI

struct IPTCCheckResult: Identifiable {
    let id = UUID()
    let fileName: String
    let url: URL
    let missingFields: [IPTCMetadata.FieldKey]
}

struct IPTCCheckResultsView: View {
    let results: [IPTCCheckResult]
    let totalFileCount: Int
    var onCancel: () -> Void
    var onProceed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("Missing Metadata Fields")
                    .font(.headline)
            }

            Text("\(results.count) of \(totalFileCount) file\(totalFileCount == 1 ? "" : "s") \(results.count == 1 ? "has" : "have") missing required fields")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.fileName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(result.missingFields.map(\.displayName).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if result.id != results.last?.id {
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Upload Anyway") {
                    onProceed()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding()
        .frame(minWidth: 400)
    }
}
