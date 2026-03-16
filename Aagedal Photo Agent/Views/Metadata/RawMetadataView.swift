import SwiftUI

struct RawMetadataView: View {
    let filename: String
    let exifToolService: ExifToolService
    let imageURL: URL

    @State private var jsonText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer()
                ProgressView("Reading metadata…")
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                Text(error)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                searchBar
                ScrollView(.vertical) {
                    Text(displayedText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(
            minWidth: 700,
            idealWidth: 800,
            minHeight: 400,
            idealHeight: (NSScreen.main?.visibleFrame.height ?? 800) * 0.9
        )
        .task {
            await loadRawMetadata()
        }
    }

    private var header: some View {
        HStack {
            Text("Raw Metadata — \(filename)")
                .font(.headline)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(jsonText, forType: .string)
            } label: {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }
            .disabled(jsonText.isEmpty)
        }
        .padding()
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter…", text: $searchText)
                .textFieldStyle(.plain)
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
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var displayedText: String {
        guard !searchText.isEmpty else { return jsonText }
        let query = searchText.lowercased()
        let lines = jsonText.components(separatedBy: "\n")
        let filtered = lines.filter { $0.lowercased().contains(query) }
        return filtered.isEmpty ? "No matches for \"\(searchText)\"" : filtered.joined(separator: "\n")
    }

    private func loadRawMetadata() async {
        do {
            jsonText = try await exifToolService.readRawJSON(url: imageURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
