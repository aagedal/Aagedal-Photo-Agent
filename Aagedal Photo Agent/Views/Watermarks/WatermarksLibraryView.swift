import SwiftUI
import Synchronization
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
    @State private var isCreatingText = false
    @State private var importErrorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var importRequestID: UUID?
    @State private var deletionErrorMessage: String?
    /// Name and default placement save on edit, with no Save button: a failed write must say so.
    @State private var saveErrorMessage: String?
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
                        .accessibilityLabel("Clear search")
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
                .accessibilityLabel("Import PNG watermark")

                Button("Create Text…") { isCreatingText = true }
                    .help("Create a reusable text watermark")
                    .accessibilityIdentifier("textWatermark.openCreator")

                Button { showDeleteAlert = true } label: {
                    Image(systemName: "trash")
                }
                .help("Delete the selected watermark")
                .accessibilityLabel("Delete the selected watermark")
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
        .sheet(isPresented: $isCreatingText) {
            TextWatermarkCreatorView(store: store) { asset in
                searchText = ""
                selection = asset.id
            }
        }
        .alert("Delete this watermark?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let id = selection {
                    Task { @MainActor in
                        do {
                            try await store.delete(id: id)
                            selection = nil
                        } catch {
                            deletionErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the watermark image from the library on all your devices. Develop layers already using it are marked \u{201C}Missing watermark\u{201D} and render without it, and exports of those photos report a warning.")
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
            "Watermark Not Saved",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button("OK") { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
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
        .onDisappear {
            cancelImport()
        }
        .task {
            await store.loadIfNeeded()
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        cancelImport()
        let requestID = UUID()
        importRequestID = requestID
        importTask = Task {
            var latestSelection: UUID?
            var failures: [String] = []
            for url in urls {
                guard !Task.isCancelled else { break }
                let defaultName = url.deletingPathExtension().lastPathComponent
                do {
                    let result = try await store.importPNG(
                        from: url,
                        name: defaultName,
                        requestID: requestID
                    )
                    if case .committed(let commit) = result {
                        latestSelection = commit.asset.id
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            guard importRequestID == requestID else { return }
            importTask = nil
            importRequestID = nil
            if let latestSelection {
                selection = latestSelection
            }
            if !failures.isEmpty {
                // Report every failed file, not just the last one.
                let heading = failures.count == 1
                    ? "Could not import 1 file:"
                    : "Could not import \(failures.count) files:"
                importErrorMessage = ([heading] + failures).joined(separator: "\n")
            }
        }
    }

    private func cancelImport() {
        importRequestID = nil
        importTask?.cancel()
        importTask = nil
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let asset = store.asset(byID: id) {
            WatermarkAssetEditorView(asset: asset, store: store) { change, error in
                guard !(error is CancellationError) else { return }
                saveErrorMessage = "The watermark's \(change) couldn't be saved. \(UserFacingErrorCause.sentence(for: error))"
            }
                .id(id)
        } else {
            ContentUnavailableView(
                "No Watermark Selected",
                systemImage: "seal",
                description: Text("Import a PNG, create a text watermark, or select one from the list.")
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
    @FocusState private var isNameFocused: Bool
    /// Reports a failed save: what was being saved ("new name", "default placement") and why.
    private let onSaveFailure: (String, Error) -> Void

    init(asset: WatermarkAsset, store: WatermarkStore, onSaveFailure: @escaping (String, Error) -> Void) {
        self.asset = asset
        self.store = store
        self.onSaveFailure = onSaveFailure
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
                    .focused($isNameFocused)
                    .onSubmit(commitName)
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused { commitName() }
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
                    Picker("Unit", selection: sizeUnitBinding) {
                        Text("Percent").tag(WatermarkSizeUnit.percent)
                        Text("Pixels").tag(WatermarkSizeUnit.pixel)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(
                        "Size", value: sizeValueBinding,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    Text(sizeUnit == .percent ? "%" : "px").foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Margin unit", selection: marginUnitBinding) {
                        Text("Percent").tag(WatermarkMarginUnit.percent)
                        Text("Pixels").tag(WatermarkMarginUnit.pixel)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(
                        "Margin", value: marginValueBinding,
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
        .onDisappear(perform: commitName)
    }

    /// Commits the name on Return or focus loss — not per keystroke, which wrote meta.json
    /// (and an iCloud sync) for every character. Blank names revert to the saved one.
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = asset.name
            return
        }
        if trimmed != name { name = trimmed }
        guard trimmed != asset.name else { return }
        let onSaveFailure = onSaveFailure
        let savedName = asset.name
        Task {
            do {
                try await store.rename(asset.id, to: trimmed)
            } catch {
                name = savedName
                onSaveFailure("new name", error)
            }
        }
    }

    /// Geometry view of the default-placement fields, so unit switches reuse the edit view's
    /// conversion (against a nominal frame — there's no target image here).
    private var defaultGeometry: WatermarkGeometry {
        WatermarkGeometry(
            sizeDimension: sizeDimension, sizeUnit: sizeUnit, sizeValue: sizeValue,
            marginUnit: marginUnit, marginValue: marginValue
        )
    }

    private var sizeUnitBinding: Binding<WatermarkSizeUnit> {
        Binding(
            get: { sizeUnit },
            set: { newUnit in
                let reference = WatermarkGeometry.nominalReferenceImageSize
                let converted = defaultGeometry.convertingSizeUnit(
                    to: newUnit, imageWidth: reference.width, imageHeight: reference.height
                )
                sizeValue = converted.sizeValue
                sizeUnit = converted.sizeUnit
            }
        )
    }

    private var marginUnitBinding: Binding<WatermarkMarginUnit> {
        Binding(
            get: { marginUnit },
            set: { newUnit in
                let reference = WatermarkGeometry.nominalReferenceImageSize
                let converted = defaultGeometry.convertingMarginUnit(
                    to: newUnit, imageWidth: reference.width, imageHeight: reference.height
                )
                marginValue = converted.marginValue
                marginUnit = converted.marginUnit
            }
        )
    }

    /// Typed values are clamped into the edit-view slider's range, so zero/negative sizes
    /// (an invisible watermark) and negative margins can't be saved.
    private var sizeValueBinding: Binding<Double> {
        Binding(
            get: { sizeValue },
            set: { newValue in
                let range = WatermarkGeometry.sizeRange(for: sizeUnit)
                sizeValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    private var marginValueBinding: Binding<Double> {
        Binding(
            get: { marginValue },
            set: { newValue in
                let range = WatermarkGeometry.marginRange(for: marginUnit)
                marginValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    private func saveDefaults() {
        let onSaveFailure = onSaveFailure
        Task {
            do {
                try await store.updateDefaults(
                    asset.id,
                    sizeDimension: sizeDimension,
                    sizeUnit: sizeUnit,
                    sizeValue: sizeValue,
                    marginUnit: marginUnit,
                    marginValue: marginValue
                )
            } catch {
                onSaveFailure("default placement", error)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            CheckerboardBackground()
            if let nsImage = WatermarkThumbnailCache.shared.image(forAssetID: asset.id, store: store) {
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
            if let nsImage = WatermarkThumbnailCache.shared.image(forAssetID: assetID, store: store) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Decoded watermark images for the library list and preview, so `body` doesn't re-decode
/// each PNG on every re-render. Dropped wholesale whenever the library revision changes
/// (import, delete, sync), which is rare.
@MainActor
private final class WatermarkThumbnailCache {
    static let shared = WatermarkThumbnailCache()
    private var revision = -1
    private var images: [UUID: NSImage] = [:]

    func image(forAssetID id: UUID, store: WatermarkStore) -> NSImage? {
        // Read through the store even on a hit so the caller's body keeps its observation
        // dependency and re-renders when this asset's bytes change.
        guard let data = store.imageData(forAssetID: id) else { return nil }
        let current = WatermarkStore.libraryRevision.load(ordering: .relaxed)
        if current != revision {
            images = [:]
            revision = current
        }
        if let cached = images[id] { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images[id] = image
        return image
    }
}

/// A tiled light/dark checker pattern, the standard way to show alpha transparency in an
/// image preview.
struct CheckerboardBackground: View {
    var tileSize: CGFloat = 8
    var lightColor: Color = Color(white: 0.92)
    var darkColor: Color = Color(white: 0.8)

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
                        with: .color(isLight ? lightColor : darkColor)
                    )
                }
            }
        }
    }
}
