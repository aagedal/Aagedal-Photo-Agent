import SwiftUI

struct RawMetadataView: View {
    let filename: String
    let readService: SwiftExifReadService
    let imageURL: URL
    /// Folder for the app's JSON sidecar (history + pending edits). Nil hides nothing —
    /// the tab just reports that no sidecar was found.
    var folderURL: URL? = nil
    /// Open on the XMP Sidecar tab when the panel is reading the sidecar record, so the
    /// view shows the same surface the editor does (sidecar-only files like RAW/C2PA
    /// keep their edits out of the embedded file entirely).
    var prefersSidecarTab: Bool = false

    private enum MetadataTab: String, CaseIterable {
        case embedded = "Embedded"
        case xmpSidecar = "XMP Sidecar"
        case appSidecar = "App Sidecar"
    }

    @State private var selectedTab: MetadataTab = .embedded
    @State private var jsonText = ""
    @State private var xmpText = ""
    @State private var appSidecarText = ""
    @State private var hasXMPSidecar = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var displayedText = ""
    @FocusState private var isSearchFocused: Bool

    private var sidecarURL: URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(activeTint)
                .frame(height: 2)
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
            await loadXMPSidecar()
            loadAppSidecar()
            if prefersSidecarTab, hasXMPSidecar {
                selectedTab = .xmpSidecar
            }
            refreshDisplayedText()
            isSearchFocused = true
        }
        .onChange(of: searchText) { _, _ in refreshDisplayedText() }
        .onChange(of: jsonText) { _, _ in refreshDisplayedText() }
        .onChange(of: xmpText) { _, _ in refreshDisplayedText() }
        .onChange(of: appSidecarText) { _, _ in refreshDisplayedText() }
        .onChange(of: selectedTab) { _, _ in refreshDisplayedText() }
    }

    private func sourceText(for tab: MetadataTab) -> String {
        switch tab {
        case .embedded: return jsonText
        case .xmpSidecar: return xmpText
        case .appSidecar: return appSidecarText
        }
    }

    private func placeholder(for tab: MetadataTab) -> String {
        switch tab {
        case .embedded:
            return "No embedded metadata could be read from this image."
        case .xmpSidecar:
            return "No .xmp sidecar exists for this image yet."
        case .appSidecar:
            return "No app sidecar (history / pending edits) exists for this image yet."
        }
    }

    private func refreshDisplayedText() {
        let source = sourceText(for: selectedTab)
        displayedText = source.isEmpty ? placeholder(for: selectedTab) : filteredText(source)
    }

    private var header: some View {
        HStack {
            Image(systemName: activeGlyph)
                .foregroundStyle(activeTint)
            Text("Raw Metadata \u{2014} \(filename)")
                .font(.headline)
            Spacer()
            sourcePicker
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sourceText(for: selectedTab), forType: .string)
            } label: {
                Label(
                    selectedTab == .xmpSidecar ? "Copy XML" : "Copy JSON",
                    systemImage: "doc.on.doc"
                )
            }
            .disabled(sourceText(for: selectedTab).isEmpty)
        }
        .padding()
    }

    @ViewBuilder
    private var sourcePicker: some View {
        Picker("Source", selection: $selectedTab) {
            ForEach(MetadataTab.allCases, id: \.self) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 300)
        .controlSize(.small)
        .help("Switch between embedded metadata, the .xmp sidecar, and the app's JSON sidecar (history / pending edits).")
    }

    private var activeTint: Color {
        switch selectedTab {
        case .embedded: return .blue
        case .xmpSidecar: return .orange
        case .appSidecar: return .purple
        }
    }

    private var activeGlyph: String {
        switch selectedTab {
        case .embedded: return "doc"
        case .xmpSidecar: return "doc.badge.ellipsis"
        case .appSidecar: return "doc.badge.clock"
        }
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

    private func loadXMPSidecar() async {
        let url = sidecarURL
        let result: (exists: Bool, text: String) = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return (false, "")
            }
            do {
                let data = try Data(contentsOf: url)
                // Contain the parsed NSXML temporaries (see XMPSidecarService.saveSidecar).
                let text: String = autoreleasepool {
                    if let xmlDoc = try? XMLDocument(data: data, options: [.nodePrettyPrint]) {
                        return xmlDoc.xmlString(options: [.nodePrettyPrint])
                    }
                    return String(data: data, encoding: .utf8) ?? "Unable to read XMP sidecar"
                }
                return (true, text)
            } catch {
                return (true, "Error reading XMP sidecar: \(error.localizedDescription)")
            }
        }.value
        hasXMPSidecar = result.exists
        xmpText = result.text
    }

    private func loadAppSidecar() {
        guard let folderURL,
              let sidecar = MetadataSidecarService().loadSidecar(for: imageURL, in: folderURL) else {
            appSidecarText = ""
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sidecar), let text = String(data: data, encoding: .utf8) {
            appSidecarText = text
        } else {
            appSidecarText = "Unable to encode app sidecar."
        }
    }
}
