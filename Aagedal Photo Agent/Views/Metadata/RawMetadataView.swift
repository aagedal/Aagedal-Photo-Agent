import SwiftUI

struct RawMetadataView: View {
    let filename: String
    let readService: SwiftExifReadService
    let imageURL: URL

    private enum MetadataTab: String, CaseIterable {
        case embedded = "Embedded"
        case xmpSidecar = "XMP Sidecar"
    }

    @State private var selectedTab: MetadataTab = .embedded
    @State private var jsonText = ""
    @State private var xmpText = ""
    @State private var hasXMPSidecar = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var sidecarURL: URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer()
                ProgressView("Reading metadata\u{2026}")
                Spacer()
            } else if let error = errorMessage {
                Spacer()
                Text(error)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                searchBar
                ScrollView(.vertical) {
                    Text(filteredText(selectedTab == .embedded ? jsonText : xmpText))
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
            loadXMPSidecar()
            isSearchFocused = true
        }
    }

    private var header: some View {
        HStack {
            Text("Raw Metadata \u{2014} \(filename)")
                .font(.headline)
            Spacer()
            if hasXMPSidecar {
                Picker("Source", selection: $selectedTab) {
                    ForEach(MetadataTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
                .controlSize(.small)
            }
            Button {
                NSPasteboard.general.clearContents()
                let textToCopy = selectedTab == .embedded ? jsonText : xmpText
                NSPasteboard.general.setString(textToCopy, forType: .string)
            } label: {
                Label(
                    selectedTab == .embedded ? "Copy JSON" : "Copy XML",
                    systemImage: "doc.on.doc"
                )
            }
            .disabled(selectedTab == .embedded ? jsonText.isEmpty : xmpText.isEmpty)
        }
        .padding()
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter\u{2026}", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
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

    private func filteredText(_ source: String) -> String {
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        let lines = source.components(separatedBy: "\n")
        var result: [String] = []
        var bracketDepth = 0
        for line in lines {
            if bracketDepth > 0 {
                result.append(line)
                bracketDepth += line.filter({ $0 == "[" }).count
                bracketDepth -= line.filter({ $0 == "]" }).count
            } else if line.lowercased().contains(query) {
                result.append(line)
                bracketDepth += line.filter({ $0 == "[" }).count
                bracketDepth -= line.filter({ $0 == "]" }).count
            }
        }
        return result.isEmpty ? "No matches for \"\(searchText)\"" : result.joined(separator: "\n")
    }

    private func loadRawMetadata() async {
        do {
            jsonText = try await readService.readRawJSON(url: imageURL)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadXMPSidecar() {
        let url = sidecarURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            hasXMPSidecar = false
            return
        }
        hasXMPSidecar = true
        do {
            let data = try Data(contentsOf: url)
            if let xmlDoc = try? XMLDocument(data: data, options: [.nodePrettyPrint]) {
                xmpText = xmlDoc.xmlString(options: [.nodePrettyPrint])
            } else {
                xmpText = String(data: data, encoding: .utf8) ?? "Unable to read XMP sidecar"
            }
        } catch {
            xmpText = "Error reading XMP sidecar: \(error.localizedDescription)"
        }
    }
}
