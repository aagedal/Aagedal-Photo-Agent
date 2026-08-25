import SwiftUI
import UniformTypeIdentifiers

/// The watermark list + editor split, embedded in Settings (Library & Metadata ▸
/// Watermarks). Mirrors `TeamsLibraryContent`'s two-pane layout, adapted for a library
/// whose items each carry a PNG asset (imported via `.fileImporter`) rather than
/// hand-entered fields.
struct WatermarksLibraryContent: View {
    @State private var store = WatermarkStore.shared
    @State private var selection: UUID?
    @State private var showDeleteAlert = false
    @State private var isImportingPNG = false
    @State private var importErrorMessage: String?
    @State private var deletionErrorMessage: String?
    @State private var searchText = ""

    private var filteredAssets: [WatermarkAsset] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.allAssets()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            assetList
                .frame(width: 240)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var assetList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search watermarks", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            List(selection: $selection) {
                ForEach(filteredAssets) { asset in
                    HStack(spacing: 8) {
                        WatermarkThumbnail(assetID: asset.id, store: store)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(asset.name)
                            Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(asset.id)
                }
            }

            Divider()

            // Add and delete sit together as a native source-list +/- control.
            HStack(spacing: 2) {
                Button(action: { isImportingPNG = true }) {
                    Image(systemName: "plus")
                }
                .help("Import a PNG watermark")

                Button { showDeleteAlert = true } label: {
                    Image(systemName: "trash")
                }
                .help("Delete the selected watermark")
                .disabled(selection == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .fileImporter(
            isPresented: $isImportingPNG,
            allowedContentTypes: [.png],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert("Delete this watermark?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let id = selection {
                    do {
                        try store.delete(id: id)
                        selection = nil
                    } catch {
                        deletionErrorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the watermark image from the library on all your devices. Develop layers already using it will show a missing-asset placeholder.")
        }
        .alert(
            "Deletion Not Completed",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK") { deletionErrorMessage = nil }
        } message: {
            Text(deletionErrorMessage ?? "")
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            let defaultName = url.deletingPathExtension().lastPathComponent
            do {
                let asset = try store.importPNG(from: url, name: defaultName)
                selection = asset.id
            } catch {
                importErrorMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let asset = store.asset(byID: id) {
            WatermarkAssetEditorView(asset: asset, store: store)
                .id(id)
        } else {
            ContentUnavailableView(
                "No Watermark Selected",
                systemImage: "seal",
                description: Text("Import a PNG, or select one from the list.")
            )
        }
    }
}

/// Editor for one watermark asset — name (rename) and a large preview over a
/// checkerboard so transparency is visible. No re-crop/re-import in place; deleting and
/// re-importing covers that rare case, keeping this editor simple.
private struct WatermarkAssetEditorView: View {
    let asset: WatermarkAsset
    let store: WatermarkStore
    @State private var name: String
    @State private var sizeDimension: WatermarkDimension
    @State private var sizeUnit: WatermarkSizeUnit
    @State private var sizeValue: Double
    @State private var marginUnit: WatermarkMarginUnit
    @State private var marginValue: Double

    init(asset: WatermarkAsset, store: WatermarkStore) {
        self.asset = asset
        self.store = store
        _name = State(initialValue: asset.name)
        _sizeDimension = State(initialValue: asset.defaultSizeDimension)
        _sizeUnit = State(initialValue: asset.defaultSizeUnit)
        _sizeValue = State(initialValue: asset.defaultSizeValue)
        _marginUnit = State(initialValue: asset.defaultMarginUnit)
        _marginValue = State(initialValue: asset.defaultMarginValue)
    }

    var body: some View {
        Form {
            Section("Preview") {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            }
            Section("Details") {
                TextField("Name", text: $name)
                    .onSubmit { try? store.rename(asset.id, to: name) }
                    .onChange(of: name) { _, newValue in
                        // Renames are cheap (small JSON write) — no debounce needed.
                        try? store.rename(asset.id, to: newValue)
                    }
                Text("\(asset.pixelWidth) × \(asset.pixelHeight) px")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Dimension", selection: $sizeDimension) {
                    Text("Width").tag(WatermarkDimension.width)
                    Text("Height").tag(WatermarkDimension.height)
                }
                HStack {
                    Picker("Unit", selection: $sizeUnit) {
                        Text("Percent").tag(WatermarkSizeUnit.percent)
                        Text("Pixels").tag(WatermarkSizeUnit.pixel)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(
                        "Size", value: $sizeValue,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    Text(sizeUnit == .percent ? "%" : "px").foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Margin unit", selection: $marginUnit) {
                        Text("Percent").tag(WatermarkMarginUnit.percent)
                        Text("Pixels").tag(WatermarkMarginUnit.pixel)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(
                        "Margin", value: $marginValue,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    Text(marginUnit == .percent ? "%" : "px").foregroundStyle(.secondary)
                }
            } header: {
                Text("Default Placement")
            } footer: {
                Text("Applied when this watermark is added as a new layer in the edit view. Doesn't change layers you've already added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: sizeDimension) { _, _ in saveDefaults() }
        .onChange(of: sizeUnit) { _, _ in saveDefaults() }
        .onChange(of: sizeValue) { _, _ in saveDefaults() }
        .onChange(of: marginUnit) { _, _ in saveDefaults() }
        .onChange(of: marginValue) { _, _ in saveDefaults() }
    }

    private func saveDefaults() {
        try? store.updateDefaults(
            asset.id,
            sizeDimension: sizeDimension,
            sizeUnit: sizeUnit,
            sizeValue: sizeValue,
            marginUnit: marginUnit,
            marginValue: marginValue
        )
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            CheckerboardBackground()
            if let data = store.imageData(forAssetID: asset.id), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3)))
    }
}

/// Small fixed-size thumbnail for the list row, over a checkerboard so transparency reads
/// clearly even at a small size.
private struct WatermarkThumbnail: View {
    let assetID: UUID
    let store: WatermarkStore

    var body: some View {
        ZStack {
            CheckerboardBackground(tileSize: 4)
            if let data = store.imageData(forAssetID: assetID), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A tiled light/dark checker pattern, the standard way to show alpha transparency in an
/// image preview.
struct CheckerboardBackground: View {
    var tileSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / tileSize))
            let rows = Int(ceil(size.height / tileSize))
            for row in 0..<rows {
                for column in 0..<columns {
                    let isLight = (row + column).isMultiple(of: 2)
                    let rect = CGRect(
                        x: CGFloat(column) * tileSize,
                        y: CGFloat(row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(isLight ? Color(white: 0.92) : Color(white: 0.8))
                    )
                }
            }
        }
    }
}
