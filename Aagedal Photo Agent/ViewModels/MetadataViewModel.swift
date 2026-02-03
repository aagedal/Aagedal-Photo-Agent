import Foundation

@Observable
final class MetadataViewModel {
    var metadata: IPTCMetadata?
    var editingMetadata = IPTCMetadata()
    var isLoading = false
    var isSaving = false
    var isProcessingFolder = false
    var folderProcessProgress = ""
    var selectedCount = 0
    var selectedURLs: [URL] = []
    var hasChanges = false
    var saveError: String?

    var originalImageMetadata: IPTCMetadata?
    var sidecarHistory: [MetadataHistoryEntry] = []
    var currentFolderURL: URL?
    var showingEmbeddedValues = false

    // Batch metadata state - stores common values across selected images
    var batchCommonMetadata: IPTCMetadata?
    var batchDifferingFields: Set<String> = []
    var isLoadingBatchMetadata = false

    // Geocoding state
    var isReverseGeocoding = false
    var geocodingError: String?
    var geocodingProgress = ""

    private let exifToolService: ExifToolService
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()
    private let geocodingService = GeocodingService()
    private var previousEditingMetadata: IPTCMetadata?
    @ObservationIgnored private var metadataLoadTask: Task<Void, Never>?

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
    }

    var isBatchEdit: Bool { selectedCount > 1 }

    var selectedHavePendingSidecars: Bool {
        guard let folderURL = currentFolderURL else { return false }
        for url in selectedURLs {
            if let sidecar = sidecarService.loadSidecar(for: url, in: folderURL),
               sidecar.pendingChanges {
                return true
            }
        }
        return false
    }

    func loadMetadata(for images: [ImageFile], folderURL: URL? = nil) {
        metadataLoadTask?.cancel()
        metadataLoadTask = nil

        selectedCount = images.count
        selectedURLs = images.map(\.url)
        hasChanges = false
        saveError = nil
        sidecarHistory = []
        originalImageMetadata = nil
        showingEmbeddedValues = false
        batchCommonMetadata = nil
        batchDifferingFields = []

        if let folderURL {
            currentFolderURL = folderURL
        }

        guard !images.isEmpty else {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            isLoading = false
            isLoadingBatchMetadata = false
            return
        }

        if images.count == 1 {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            isLoading = true

            let imageURL = images[0].url
            metadataLoadTask = Task {
                do {
                    var imageMeta = try await exifToolService.readFullMetadata(url: imageURL)
                    guard !Task.isCancelled else { return }
                    if MetadataWriteMode.current(forC2PA: images[0].hasC2PA) == .writeToXMPSidecar,
                       let xmpMeta = xmpSidecarService.loadSidecar(for: imageURL) {
                        imageMeta = imageMeta.merged(preferring: xmpMeta)
                    }
                    guard !Task.isCancelled else { return }
                    guard self.selectedURLs.count == 1,
                          self.selectedURLs.first == imageURL else { return }
                    self.metadata = imageMeta
                    self.originalImageMetadata = imageMeta

                    if let folder = self.currentFolderURL,
                       let sidecar = sidecarService.loadSidecar(for: imageURL, in: folder) {
                        self.sidecarHistory = sidecar.history
                        if sidecar.pendingChanges {
                            self.editingMetadata = sidecar.metadata
                            self.hasChanges = true
                        } else {
                            self.editingMetadata = imageMeta
                        }
                    } else {
                        self.editingMetadata = imageMeta
                    }
                    self.previousEditingMetadata = self.editingMetadata
                } catch {
                    self.metadata = nil
                    self.editingMetadata = IPTCMetadata()
                    self.previousEditingMetadata = nil
                }
                guard !Task.isCancelled else { return }
                self.isLoading = false
            }
        } else {
            // Batch mode: load metadata for all selected images and find common values
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            isLoadingBatchMetadata = true

            let selectionSnapshot = Set(images.map(\.url))
            metadataLoadTask = Task {
                await loadBatchMetadata(for: images, selectionSnapshot: selectionSnapshot)
                guard !Task.isCancelled else { return }
                self.isLoadingBatchMetadata = false
            }
        }
    }

    /// Load metadata for all selected images and compute common values
    private func loadBatchMetadata(for images: [ImageFile], selectionSnapshot: Set<URL>) async {
        var allMetadata: [IPTCMetadata] = []

        for image in images {
            if Task.isCancelled { return }
            do {
                var meta = try await exifToolService.readFullMetadata(url: image.url)
                if Task.isCancelled { return }
                if MetadataWriteMode.current(forC2PA: image.hasC2PA) == .writeToXMPSidecar,
                   let xmpMeta = xmpSidecarService.loadSidecar(for: image.url) {
                    meta = meta.merged(preferring: xmpMeta)
                }
                allMetadata.append(meta)
            } catch {
                // Continue with other images
            }
        }

        guard !allMetadata.isEmpty else { return }
        guard !Task.isCancelled else { return }
        guard Set(selectedURLs) == selectionSnapshot else { return }

        // Compute common values and differing fields
        var common = IPTCMetadata()
        var differing = Set<String>()

        // Title
        let titles = allMetadata.compactMap(\.title)
        if titles.count == allMetadata.count, let first = titles.first, titles.allSatisfy({ $0 == first }) {
            common.title = first
        } else if !titles.isEmpty {
            differing.insert("title")
        }

        // Description
        let descriptions = allMetadata.compactMap(\.description)
        if descriptions.count == allMetadata.count, let first = descriptions.first, descriptions.allSatisfy({ $0 == first }) {
            common.description = first
        } else if !descriptions.isEmpty {
            differing.insert("description")
        }

        // Keywords
        let keywordSets = allMetadata.map { Set($0.keywords) }
        if let first = keywordSets.first, keywordSets.allSatisfy({ $0 == first }) {
            common.keywords = allMetadata.first?.keywords ?? []
        } else {
            differing.insert("keywords")
        }

        // Person Shown
        let personSets = allMetadata.map { Set($0.personShown) }
        if let first = personSets.first, personSets.allSatisfy({ $0 == first }) {
            common.personShown = allMetadata.first?.personShown ?? []
        } else {
            differing.insert("personShown")
        }

        // Copyright
        let copyrights = allMetadata.compactMap(\.copyright)
        if copyrights.count == allMetadata.count, let first = copyrights.first, copyrights.allSatisfy({ $0 == first }) {
            common.copyright = first
        } else if !copyrights.isEmpty {
            differing.insert("copyright")
        }

        // Creator
        let creators = allMetadata.compactMap(\.creator)
        if creators.count == allMetadata.count, let first = creators.first, creators.allSatisfy({ $0 == first }) {
            common.creator = first
        } else if !creators.isEmpty {
            differing.insert("creator")
        }

        // Credit
        let credits = allMetadata.compactMap(\.credit)
        if credits.count == allMetadata.count, let first = credits.first, credits.allSatisfy({ $0 == first }) {
            common.credit = first
        } else if !credits.isEmpty {
            differing.insert("credit")
        }

        // City
        let cities = allMetadata.compactMap(\.city)
        if cities.count == allMetadata.count, let first = cities.first, cities.allSatisfy({ $0 == first }) {
            common.city = first
        } else if !cities.isEmpty {
            differing.insert("city")
        }

        // Country
        let countries = allMetadata.compactMap(\.country)
        if countries.count == allMetadata.count, let first = countries.first, countries.allSatisfy({ $0 == first }) {
            common.country = first
        } else if !countries.isEmpty {
            differing.insert("country")
        }

        // Event
        let events = allMetadata.compactMap(\.event)
        if events.count == allMetadata.count, let first = events.first, events.allSatisfy({ $0 == first }) {
            common.event = first
        } else if !events.isEmpty {
            differing.insert("event")
        }

        // Digital Source Type
        let sourceTypes = allMetadata.compactMap(\.digitalSourceType)
        if sourceTypes.count == allMetadata.count, let first = sourceTypes.first, sourceTypes.allSatisfy({ $0 == first }) {
            common.digitalSourceType = first
        } else if !sourceTypes.isEmpty {
            differing.insert("digitalSourceType")
        }

        // GPS - check if all have the same coordinates
        let latitudes = allMetadata.compactMap(\.latitude)
        let longitudes = allMetadata.compactMap(\.longitude)
        if latitudes.count == allMetadata.count,
           longitudes.count == allMetadata.count,
           let firstLat = latitudes.first,
           let firstLon = longitudes.first,
           latitudes.allSatisfy({ abs($0 - firstLat) < 0.000001 }),
           longitudes.allSatisfy({ abs($0 - firstLon) < 0.000001 }) {
            common.latitude = firstLat
            common.longitude = firstLon
        } else if !latitudes.isEmpty || !longitudes.isEmpty {
            differing.insert("gps")
        }

        self.batchCommonMetadata = common
        self.batchDifferingFields = differing
        // Pre-populate editing metadata with common values
        self.editingMetadata = common
        self.previousEditingMetadata = common
    }

    /// Returns the placeholder text for a batch field that has differing values
    func batchPlaceholder(for field: String) -> String {
        if batchDifferingFields.contains(field) {
            return "Multiple values"
        }
        return "Leave empty to skip"
    }

    /// Returns true if a field has differing values across the batch selection
    func fieldHasMultipleValues(_ field: String) -> Bool {
        batchDifferingFields.contains(field)
    }

    func markChanged() {
        hasChanges = true
    }

    func commitEdits(
        mode: MetadataWriteMode,
        hasC2PA: Bool,
        allowC2PAOverwrite: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        switch mode {
        case .historyOnly:
            saveToSidecar()
            onComplete?()
        case .writeToXMPSidecar:
            saveToSidecar()
            writeXMPSidecar()
            onComplete?()
        case .writeToFile:
            if hasC2PA && !allowC2PAOverwrite {
                saveToSidecar()
                saveError = "C2PA-protected image. Changes were saved to history only."
                onComplete?()
                return
            }
            writeMetadataAndPreserveHistory(onComplete: onComplete)
        }
    }

    func writeMetadata() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let selectionSnapshot = Set(urls)
        let edited = editingMetadata
        let original = metadata
        let isBatch = isBatchEdit
        isSaving = true
        saveError = nil

        Task {
            do {
                var fields: [String: String] = [:]

                if isBatch {
                    // Batch: only write non-empty fields
                    if let v = edited.title, !v.isEmpty { fields["XMP:Title"] = v }
                    if let v = edited.description, !v.isEmpty { fields["XMP:Description"] = v }
                    if !edited.keywords.isEmpty { fields["XMP:Subject"] = edited.keywords.joined(separator: ", ") }
                    if !edited.personShown.isEmpty { fields["XMP-iptcExt:PersonInImage"] = edited.personShown.joined(separator: ", ") }
                    if let v = edited.digitalSourceType { fields["XMP-iptcExt:DigitalSourceType"] = v.rawValue }
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields["EXIF:GPSLatitude"] = String(abs(lat))
                        fields["EXIF:GPSLatitudeRef"] = lat >= 0 ? "N" : "S"
                        fields["EXIF:GPSLongitude"] = String(abs(lon))
                        fields["EXIF:GPSLongitudeRef"] = lon >= 0 ? "E" : "W"
                    }
                    if let v = edited.creator, !v.isEmpty { fields["XMP:Creator"] = v }
                    if let v = edited.credit, !v.isEmpty { fields["XMP-photoshop:Credit"] = v }
                    if let v = edited.copyright, !v.isEmpty { fields["XMP:Rights"] = v }
                    if let v = edited.dateCreated, !v.isEmpty { fields["XMP:DateCreated"] = v }
                    if let v = edited.city, !v.isEmpty { fields["XMP-photoshop:City"] = v }
                    if let v = edited.country, !v.isEmpty { fields["XMP-photoshop:Country"] = v }
                    if let v = edited.event, !v.isEmpty { fields["XMP-iptcExt:Event"] = v }
                } else {
                    // Single: write all changed fields
                    if edited.title != original?.title { fields["XMP:Title"] = edited.title ?? "" }
                    if edited.description != original?.description { fields["XMP:Description"] = edited.description ?? "" }
                    if edited.keywords != original?.keywords {
                        // Clear then set keywords
                        fields["XMP:Subject"] = edited.keywords.joined(separator: ", ")
                    }
                    if edited.personShown != original?.personShown {
                        fields["XMP-iptcExt:PersonInImage"] = edited.personShown.joined(separator: ", ")
                    }
                    if edited.digitalSourceType != original?.digitalSourceType {
                        fields["XMP-iptcExt:DigitalSourceType"] = edited.digitalSourceType?.rawValue ?? ""
                    }
                    if edited.latitude != original?.latitude || edited.longitude != original?.longitude {
                        if let lat = edited.latitude, let lon = edited.longitude {
                            fields["EXIF:GPSLatitude"] = String(abs(lat))
                            fields["EXIF:GPSLatitudeRef"] = lat >= 0 ? "N" : "S"
                            fields["EXIF:GPSLongitude"] = String(abs(lon))
                            fields["EXIF:GPSLongitudeRef"] = lon >= 0 ? "E" : "W"
                        } else {
                            fields["EXIF:GPSLatitude"] = ""
                            fields["EXIF:GPSLatitudeRef"] = ""
                            fields["EXIF:GPSLongitude"] = ""
                            fields["EXIF:GPSLongitudeRef"] = ""
                        }
                    }
                    if edited.creator != original?.creator { fields["XMP:Creator"] = edited.creator ?? "" }
                    if edited.credit != original?.credit { fields["XMP-photoshop:Credit"] = edited.credit ?? "" }
                    if edited.copyright != original?.copyright { fields["XMP:Rights"] = edited.copyright ?? "" }
                    if edited.dateCreated != original?.dateCreated { fields["XMP:DateCreated"] = edited.dateCreated ?? "" }
                    if edited.city != original?.city { fields["XMP-photoshop:City"] = edited.city ?? "" }
                    if edited.country != original?.country { fields["XMP-photoshop:Country"] = edited.country ?? "" }
                    if edited.event != original?.event { fields["XMP-iptcExt:Event"] = edited.event ?? "" }
                }

                if !fields.isEmpty {
                    try await exifToolService.writeFields(fields, to: urls)
                }
                if Set(self.selectedURLs) == selectionSnapshot {
                    self.metadata = edited
                    self.hasChanges = false
                }
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
        }
    }

    private func writeXMPSidecar() {
        guard !selectedURLs.isEmpty else { return }

        if selectedCount == 1, let imageURL = selectedURLs.first {
            do {
                try xmpSidecarService.saveSidecar(metadata: editingMetadata, for: imageURL)
            } catch {
                saveError = "Failed to write XMP sidecar: \(error.localizedDescription)"
            }
            return
        }

        let batchMeta = editingMetadata
        for imageURL in selectedURLs {
            var existing = xmpSidecarService.loadSidecar(for: imageURL) ?? IPTCMetadata()
            applyBatchEdits(batchMeta, to: &existing)
            try? xmpSidecarService.saveSidecar(metadata: existing, for: imageURL)
        }
    }

    private func writeMetadataAndPreserveHistory(onComplete: (() -> Void)? = nil) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            onComplete?()
            return
        }

        let edited = editingMetadata
        let original = originalImageMetadata
        let previous = previousEditingMetadata
        let existingHistory = sidecarHistory

        isSaving = true
        saveError = nil

        Task {
            do {
                var fields: [String: String] = [:]
                if edited.title != original?.title { fields["XMP:Title"] = edited.title ?? "" }
                if edited.description != original?.description { fields["XMP:Description"] = edited.description ?? "" }
                if edited.keywords != original?.keywords {
                    fields["XMP:Subject"] = edited.keywords.joined(separator: ", ")
                }
                if edited.personShown != original?.personShown {
                    fields["XMP-iptcExt:PersonInImage"] = edited.personShown.joined(separator: ", ")
                }
                if edited.digitalSourceType != original?.digitalSourceType {
                    fields["XMP-iptcExt:DigitalSourceType"] = edited.digitalSourceType?.rawValue ?? ""
                }
                if edited.latitude != original?.latitude || edited.longitude != original?.longitude {
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields["EXIF:GPSLatitude"] = String(abs(lat))
                        fields["EXIF:GPSLatitudeRef"] = lat >= 0 ? "N" : "S"
                        fields["EXIF:GPSLongitude"] = String(abs(lon))
                        fields["EXIF:GPSLongitudeRef"] = lon >= 0 ? "E" : "W"
                    } else {
                        fields["EXIF:GPSLatitude"] = ""
                        fields["EXIF:GPSLatitudeRef"] = ""
                        fields["EXIF:GPSLongitude"] = ""
                        fields["EXIF:GPSLongitudeRef"] = ""
                    }
                }
                if edited.creator != original?.creator { fields["XMP:Creator"] = edited.creator ?? "" }
                if edited.credit != original?.credit { fields["XMP-photoshop:Credit"] = edited.credit ?? "" }
                if edited.copyright != original?.copyright { fields["XMP:Rights"] = edited.copyright ?? "" }
                if edited.dateCreated != original?.dateCreated { fields["XMP:DateCreated"] = edited.dateCreated ?? "" }
                if edited.city != original?.city { fields["XMP-photoshop:City"] = edited.city ?? "" }
                if edited.country != original?.country { fields["XMP-photoshop:Country"] = edited.country ?? "" }
                if edited.event != original?.event { fields["XMP-iptcExt:Event"] = edited.event ?? "" }

                if !fields.isEmpty {
                    try await exifToolService.writeFields(fields, to: [imageURL])
                }

                let now = Date()
                let history = buildHistory(
                    previous: previous ?? IPTCMetadata(),
                    edited: edited,
                    timestamp: now,
                    existing: existingHistory
                )
                let sidecar = MetadataSidecar(
                    sourceFile: imageURL.lastPathComponent,
                    lastModified: now,
                    pendingChanges: false,
                    metadata: edited,
                    imageMetadataSnapshot: edited,
                    history: history
                )
                try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)

                let isStillSelected = self.selectedCount == 1 && self.selectedURLs.first == imageURL
                if isStillSelected {
                    self.sidecarHistory = history
                    self.previousEditingMetadata = edited
                    self.metadata = edited
                    self.originalImageMetadata = edited
                    self.hasChanges = false
                }
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
            onComplete?()
        }
    }

    func applyTemplateFields(_ template: [String: String], append: Bool = false) {
        for (key, value) in template {
            switch key {
            case "title":
                editingMetadata.title = append ? appendString(editingMetadata.title, value) : value
            case "description":
                editingMetadata.description = append ? appendString(editingMetadata.description, value) : value
            case "keywords":
                let newKeywords = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if append {
                    let existing = Set(editingMetadata.keywords)
                    editingMetadata.keywords += newKeywords.filter { !existing.contains($0) }
                } else {
                    editingMetadata.keywords = newKeywords
                }
            case "personShown":
                let newPersons = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if append {
                    let existing = Set(editingMetadata.personShown)
                    editingMetadata.personShown += newPersons.filter { !existing.contains($0) }
                } else {
                    editingMetadata.personShown = newPersons
                }
            case "digitalSourceType":
                editingMetadata.digitalSourceType = DigitalSourceType(rawValue: value)
            case "creator":
                editingMetadata.creator = append ? appendString(editingMetadata.creator, value) : value
            case "credit":
                editingMetadata.credit = append ? appendString(editingMetadata.credit, value) : value
            case "copyright":
                editingMetadata.copyright = append ? appendString(editingMetadata.copyright, value) : value
            case "dateCreated":
                editingMetadata.dateCreated = append ? appendString(editingMetadata.dateCreated, value) : value
            case "city":
                editingMetadata.city = append ? appendString(editingMetadata.city, value) : value
            case "country":
                editingMetadata.country = append ? appendString(editingMetadata.country, value) : value
            case "event":
                editingMetadata.event = append ? appendString(editingMetadata.event, value) : value
            default: break
            }
        }
        hasChanges = true
    }

    private func appendString(_ existing: String?, _ new: String) -> String {
        guard let existing, !existing.isEmpty else { return new }
        guard !new.isEmpty else { return existing }
        return existing + " " + new
    }

    /// Checks whether any text field in editingMetadata contains variable placeholders.
    var hasVariables: Bool {
        let variablePattern = /\{(date|date:[^}]+|filename|persons|keywords|field:[^}]+)\}/
        let fields: [String?] = [
            editingMetadata.title,
            editingMetadata.description,
            editingMetadata.creator,
            editingMetadata.credit,
            editingMetadata.copyright,
            editingMetadata.dateCreated,
            editingMetadata.city,
            editingMetadata.country,
            editingMetadata.event,
        ]
        return fields.contains { field in
            guard let field else { return false }
            return field.contains(variablePattern)
        }
    }

    /// Resolves all variable placeholders in editingMetadata text fields in-place.
    func processVariables(filename: String = "") {
        let interpolator = PresetVariableInterpolator()
        // Use a snapshot of current editing state for field references
        let snapshot = editingMetadata

        editingMetadata.title = resolveIfPresent(editingMetadata.title, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.description = resolveIfPresent(editingMetadata.description, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.creator = resolveIfPresent(editingMetadata.creator, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.credit = resolveIfPresent(editingMetadata.credit, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.copyright = resolveIfPresent(editingMetadata.copyright, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.dateCreated = resolveIfPresent(editingMetadata.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.city = resolveIfPresent(editingMetadata.city, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.country = resolveIfPresent(editingMetadata.country, interpolator: interpolator, filename: filename, ref: snapshot)
        editingMetadata.event = resolveIfPresent(editingMetadata.event, interpolator: interpolator, filename: filename, ref: snapshot)

        hasChanges = true
    }

    private func resolveIfPresent(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref)
        return resolved.isEmpty ? nil : resolved
    }

    /// Process variables for specific images: reads each image's metadata,
    /// resolves any variable placeholders, and writes back.
    func processVariablesForImages(_ imageURLs: [URL]) {
        guard !imageURLs.isEmpty else { return }
        isProcessingFolder = true
        folderProcessProgress = "0/\(imageURLs.count)"
        saveError = nil

        Task {
            let interpolator = PresetVariableInterpolator()
            var processed = 0

            for url in imageURLs {
                let filename = url.deletingPathExtension().lastPathComponent
                do {
                    let meta = try await exifToolService.readFullMetadata(url: url)
                    let snapshot = meta

                    var changed = false
                    var resolved = meta

                    resolved.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                    resolved.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)

                    if changed {
                        var fields: [String: String] = [:]
                        if resolved.title != meta.title { fields["XMP:Title"] = resolved.title ?? "" }
                        if resolved.description != meta.description { fields["XMP:Description"] = resolved.description ?? "" }
                        if resolved.creator != meta.creator { fields["XMP:Creator"] = resolved.creator ?? "" }
                        if resolved.credit != meta.credit { fields["XMP-photoshop:Credit"] = resolved.credit ?? "" }
                        if resolved.copyright != meta.copyright { fields["XMP:Rights"] = resolved.copyright ?? "" }
                        if resolved.dateCreated != meta.dateCreated { fields["XMP:DateCreated"] = resolved.dateCreated ?? "" }
                        if resolved.city != meta.city { fields["XMP-photoshop:City"] = resolved.city ?? "" }
                        if resolved.country != meta.country { fields["XMP-photoshop:Country"] = resolved.country ?? "" }
                        if resolved.event != meta.event { fields["XMP-iptcExt:Event"] = resolved.event ?? "" }

                        if !fields.isEmpty {
                            try await exifToolService.writeFields(fields, to: [url])
                        }
                    }
                } catch {
                    // Continue with next image
                }

                processed += 1
                self.folderProcessProgress = "\(processed)/\(imageURLs.count)"
            }

            self.isProcessingFolder = false
            self.folderProcessProgress = ""
        }
    }

    /// Process variables for all images in a folder: reads each image's metadata,
    /// resolves any variable placeholders, and writes back.
    func processVariablesInFolder(images: [ImageFile]) {
        guard !images.isEmpty else { return }
        isProcessingFolder = true
        folderProcessProgress = "0/\(images.count)"
        saveError = nil

        Task {
            let interpolator = PresetVariableInterpolator()
            var processed = 0

            for image in images {
                do {
                    let meta = try await exifToolService.readFullMetadata(url: image.url)
                    let snapshot = meta

                    var changed = false
                    var resolved = meta

                    resolved.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)
                    resolved.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: image.filename, ref: snapshot, changed: &changed)

                    if changed {
                        var fields: [String: String] = [:]
                        if resolved.title != meta.title { fields["XMP:Title"] = resolved.title ?? "" }
                        if resolved.description != meta.description { fields["XMP:Description"] = resolved.description ?? "" }
                        if resolved.creator != meta.creator { fields["XMP:Creator"] = resolved.creator ?? "" }
                        if resolved.credit != meta.credit { fields["XMP-photoshop:Credit"] = resolved.credit ?? "" }
                        if resolved.copyright != meta.copyright { fields["XMP:Rights"] = resolved.copyright ?? "" }
                        if resolved.dateCreated != meta.dateCreated { fields["XMP:DateCreated"] = resolved.dateCreated ?? "" }
                        if resolved.city != meta.city { fields["XMP-photoshop:City"] = resolved.city ?? "" }
                        if resolved.country != meta.country { fields["XMP-photoshop:Country"] = resolved.country ?? "" }
                        if resolved.event != meta.event { fields["XMP-iptcExt:Event"] = resolved.event ?? "" }

                        if !fields.isEmpty {
                            try await exifToolService.writeFields(fields, to: [image.url])
                        }
                    }
                } catch {
                    // Continue with next image
                }

                processed += 1
                self.folderProcessProgress = "\(processed)/\(images.count)"
            }

            self.isProcessingFolder = false
            self.folderProcessProgress = ""
        }
    }

    private func resolveIfChanged(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, changed: inout Bool) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref)
        if resolved != value { changed = true }
        return resolved.isEmpty ? nil : resolved
    }

    // MARK: - Reverse Geocoding

    /// Reverse geocodes the current image's GPS coordinates to fill City and Country fields.
    func reverseGeocodeCurrentLocation() {
        guard let lat = editingMetadata.latitude,
              let lon = editingMetadata.longitude else {
            geocodingError = "No GPS coordinates available"
            return
        }

        isReverseGeocoding = true
        geocodingError = nil

        Task { @MainActor in
            do {
                let result = try await geocodingService.reverseGeocode(latitude: lat, longitude: lon)
                if let city = result.city { editingMetadata.city = city }
                if let country = result.country { editingMetadata.country = country }
                hasChanges = true
            } catch {
                geocodingError = error.localizedDescription
            }
            isReverseGeocoding = false
        }
    }

    /// Reverse geocodes GPS coordinates for all selected images and writes City/Country directly to each file.
    func reverseGeocodeSelectedImages() {
        guard !selectedURLs.isEmpty else { return }

        isReverseGeocoding = true
        geocodingError = nil
        geocodingProgress = "0/\(selectedURLs.count)"

        Task { @MainActor in
            var processed = 0
            var skipped = 0

            for url in selectedURLs {
                do {
                    let meta = try await exifToolService.readFullMetadata(url: url)
                    guard let lat = meta.latitude, let lon = meta.longitude else {
                        skipped += 1
                        processed += 1
                        geocodingProgress = "\(processed)/\(selectedURLs.count)"
                        continue
                    }

                    let result = try await geocodingService.reverseGeocode(latitude: lat, longitude: lon)

                    var fields: [String: String] = [:]
                    if let city = result.city { fields["XMP-photoshop:City"] = city }
                    if let country = result.country { fields["XMP-photoshop:Country"] = country }

                    if !fields.isEmpty {
                        try await exifToolService.writeFields(fields, to: [url])
                    }

                    // Rate limit: ~0.5s delay between requests
                    try await Task.sleep(for: .milliseconds(500))

                } catch {
                    // Continue with next image
                }

                processed += 1
                geocodingProgress = "\(processed)/\(selectedURLs.count)"
            }

            if skipped > 0 {
                geocodingError = "\(skipped) image(s) had no GPS data"
            }

            isReverseGeocoding = false
            geocodingProgress = ""
        }
    }

    // MARK: - Sidecar Management

    func saveToSidecar() {
        guard let folderURL = currentFolderURL else { return }

        if selectedCount == 1, let imageURL = selectedURLs.first {
            // Single image mode - save with full history tracking
            saveSingleImageSidecar(imageURL: imageURL, folderURL: folderURL, pendingChanges: true, snapshot: originalImageMetadata)
        } else if selectedCount > 1 {
            // Batch mode - merge edits into each image's sidecar
            saveBatchSidecars(folderURL: folderURL)
        }
    }

    private func saveSingleImageSidecar(
        imageURL: URL,
        folderURL: URL,
        pendingChanges: Bool,
        snapshot: IPTCMetadata?
    ) {
        let now = Date()
        let prev = previousEditingMetadata ?? IPTCMetadata()
        let newHistory = buildHistory(
            previous: prev,
            edited: editingMetadata,
            timestamp: now,
            existing: sidecarHistory
        )

        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: now,
            pendingChanges: pendingChanges,
            metadata: editingMetadata,
            imageMetadataSnapshot: snapshot,
            history: newHistory
        )

        do {
            try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
            sidecarHistory = newHistory
            previousEditingMetadata = editingMetadata
            hasChanges = pendingChanges
        } catch {
            saveError = "Failed to save sidecar: \(error.localizedDescription)"
        }
    }

    private func buildHistory(
        previous: IPTCMetadata,
        edited: IPTCMetadata,
        timestamp: Date,
        existing: [MetadataHistoryEntry]
    ) -> [MetadataHistoryEntry] {
        var history = existing

        func recordChange(_ fieldName: String, old: String?, new: String?) {
            if old != new {
                history.append(MetadataHistoryEntry(
                    timestamp: timestamp,
                    fieldName: fieldName,
                    oldValue: old,
                    newValue: new
                ))
            }
        }

        func recordArrayChange(_ fieldName: String, old: [String], new: [String]) {
            let oldVal = old.isEmpty ? nil : old.joined(separator: ", ")
            let newVal = new.isEmpty ? nil : new.joined(separator: ", ")
            if oldVal != newVal {
                history.append(MetadataHistoryEntry(
                    timestamp: timestamp,
                    fieldName: fieldName,
                    oldValue: oldVal,
                    newValue: newVal
                ))
            }
        }

        recordChange("Title", old: previous.title, new: edited.title)
        recordChange("Description", old: previous.description, new: edited.description)
        recordArrayChange("Keywords", old: previous.keywords, new: edited.keywords)
        recordArrayChange("Person Shown", old: previous.personShown, new: edited.personShown)
        recordChange("Copyright", old: previous.copyright, new: edited.copyright)
        recordChange("Creator", old: previous.creator, new: edited.creator)
        recordChange("Credit", old: previous.credit, new: edited.credit)
        recordChange("Date Created", old: previous.dateCreated, new: edited.dateCreated)
        recordChange("City", old: previous.city, new: edited.city)
        recordChange("Country", old: previous.country, new: edited.country)
        recordChange("Event", old: previous.event, new: edited.event)
        recordChange(
            "Digital Source Type",
            old: previous.digitalSourceType?.rawValue,
            new: edited.digitalSourceType?.rawValue
        )

        return history
    }

    private func saveBatchSidecars(folderURL: URL) {
        let now = Date()
        let batchMeta = editingMetadata

        for imageURL in selectedURLs {
            // Load existing sidecar or create base metadata
            var existingMeta: IPTCMetadata
            var existingHistory: [MetadataHistoryEntry] = []
            var snapshot: IPTCMetadata? = nil

            if let existing = sidecarService.loadSidecar(for: imageURL, in: folderURL) {
                existingMeta = existing.metadata
                existingHistory = existing.history
                snapshot = existing.imageMetadataSnapshot
            } else {
                existingMeta = IPTCMetadata()
            }

            applyBatchEdits(batchMeta, to: &existingMeta)

            let sidecar = MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                lastModified: now,
                pendingChanges: true,
                metadata: existingMeta,
                imageMetadataSnapshot: snapshot,
                history: existingHistory
            )

            try? sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
        }

        hasChanges = true
    }

    private func applyBatchEdits(_ batchMeta: IPTCMetadata, to metadata: inout IPTCMetadata) {
        if let title = batchMeta.title, !title.isEmpty {
            metadata.title = title
        }
        if let desc = batchMeta.description, !desc.isEmpty {
            metadata.description = desc
        }
        if !batchMeta.keywords.isEmpty {
            let existing = Set(metadata.keywords)
            metadata.keywords += batchMeta.keywords.filter { !existing.contains($0) }
        }
        if !batchMeta.personShown.isEmpty {
            let existing = Set(metadata.personShown)
            metadata.personShown += batchMeta.personShown.filter { !existing.contains($0) }
        }
        if let copyright = batchMeta.copyright, !copyright.isEmpty {
            metadata.copyright = copyright
        }
        if let creator = batchMeta.creator, !creator.isEmpty {
            metadata.creator = creator
        }
        if let credit = batchMeta.credit, !credit.isEmpty {
            metadata.credit = credit
        }
        if let city = batchMeta.city, !city.isEmpty {
            metadata.city = city
        }
        if let country = batchMeta.country, !country.isEmpty {
            metadata.country = country
        }
        if let event = batchMeta.event, !event.isEmpty {
            metadata.event = event
        }
        if batchMeta.digitalSourceType != nil {
            metadata.digitalSourceType = batchMeta.digitalSourceType
        }
    }

    func writeMetadataAndClearSidecar() {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            return
        }

        isSaving = true
        saveError = nil

        Task {
            do {
                var fields: [String: String] = [:]
                let edited = editingMetadata
                let original = originalImageMetadata

                if edited.title != original?.title { fields["XMP:Title"] = edited.title ?? "" }
                if edited.description != original?.description { fields["XMP:Description"] = edited.description ?? "" }
                if edited.keywords != original?.keywords {
                    fields["XMP:Subject"] = edited.keywords.joined(separator: ", ")
                }
                if edited.personShown != original?.personShown {
                    fields["XMP-iptcExt:PersonInImage"] = edited.personShown.joined(separator: ", ")
                }
                if edited.digitalSourceType != original?.digitalSourceType {
                    fields["XMP-iptcExt:DigitalSourceType"] = edited.digitalSourceType?.rawValue ?? ""
                }
                if edited.latitude != original?.latitude || edited.longitude != original?.longitude {
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields["EXIF:GPSLatitude"] = String(abs(lat))
                        fields["EXIF:GPSLatitudeRef"] = lat >= 0 ? "N" : "S"
                        fields["EXIF:GPSLongitude"] = String(abs(lon))
                        fields["EXIF:GPSLongitudeRef"] = lon >= 0 ? "E" : "W"
                    } else {
                        fields["EXIF:GPSLatitude"] = ""
                        fields["EXIF:GPSLatitudeRef"] = ""
                        fields["EXIF:GPSLongitude"] = ""
                        fields["EXIF:GPSLongitudeRef"] = ""
                    }
                }
                if edited.creator != original?.creator { fields["XMP:Creator"] = edited.creator ?? "" }
                if edited.credit != original?.credit { fields["XMP-photoshop:Credit"] = edited.credit ?? "" }
                if edited.copyright != original?.copyright { fields["XMP:Rights"] = edited.copyright ?? "" }
                if edited.dateCreated != original?.dateCreated { fields["XMP:DateCreated"] = edited.dateCreated ?? "" }
                if edited.city != original?.city { fields["XMP-photoshop:City"] = edited.city ?? "" }
                if edited.country != original?.country { fields["XMP-photoshop:Country"] = edited.country ?? "" }
                if edited.event != original?.event { fields["XMP-iptcExt:Event"] = edited.event ?? "" }

                if !fields.isEmpty {
                    try await exifToolService.writeFields(fields, to: [imageURL])
                }

                try? sidecarService.deleteSidecar(for: imageURL, in: folderURL)
                self.metadata = edited
                self.originalImageMetadata = edited
                self.sidecarHistory = []
                self.hasChanges = false
                self.previousEditingMetadata = edited
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
        }
    }

    func writeAllPendingChanges(in folderURL: URL?, images: [ImageFile], skipC2PA: Bool = true) {
        guard let folderURL else { return }

        isProcessingFolder = true
        folderProcessProgress = "0/?"
        saveError = nil

        Task {
            let sidecars = sidecarService.loadAllSidecars(in: folderURL)
            let pendingSidecars = sidecars.filter { $0.value.pendingChanges }

            var processed = 0
            let total = pendingSidecars.count
            self.folderProcessProgress = "0/\(total)"

            for (imageURL, sidecar) in pendingSidecars {
                if skipC2PA {
                    if let image = images.first(where: { $0.url == imageURL }), image.hasC2PA {
                        processed += 1
                        self.folderProcessProgress = "\(processed)/\(total)"
                        continue
                    }
                }

                let edited = sidecar.metadata
                let original = sidecar.imageMetadataSnapshot

                var fields: [String: String] = [:]
                if edited.title != original?.title { fields["XMP:Title"] = edited.title ?? "" }
                if edited.description != original?.description { fields["XMP:Description"] = edited.description ?? "" }
                if edited.keywords != original?.keywords {
                    fields["XMP:Subject"] = edited.keywords.joined(separator: ", ")
                }
                if edited.personShown != original?.personShown {
                    fields["XMP-iptcExt:PersonInImage"] = edited.personShown.joined(separator: ", ")
                }
                if edited.digitalSourceType != original?.digitalSourceType {
                    fields["XMP-iptcExt:DigitalSourceType"] = edited.digitalSourceType?.rawValue ?? ""
                }
                if edited.latitude != original?.latitude || edited.longitude != original?.longitude {
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields["EXIF:GPSLatitude"] = String(abs(lat))
                        fields["EXIF:GPSLatitudeRef"] = lat >= 0 ? "N" : "S"
                        fields["EXIF:GPSLongitude"] = String(abs(lon))
                        fields["EXIF:GPSLongitudeRef"] = lon >= 0 ? "E" : "W"
                    } else {
                        fields["EXIF:GPSLatitude"] = ""
                        fields["EXIF:GPSLatitudeRef"] = ""
                        fields["EXIF:GPSLongitude"] = ""
                        fields["EXIF:GPSLongitudeRef"] = ""
                    }
                }
                if edited.creator != original?.creator { fields["XMP:Creator"] = edited.creator ?? "" }
                if edited.credit != original?.credit { fields["XMP-photoshop:Credit"] = edited.credit ?? "" }
                if edited.copyright != original?.copyright { fields["XMP:Rights"] = edited.copyright ?? "" }
                if edited.dateCreated != original?.dateCreated { fields["XMP:DateCreated"] = edited.dateCreated ?? "" }
                if edited.city != original?.city { fields["XMP-photoshop:City"] = edited.city ?? "" }
                if edited.country != original?.country { fields["XMP-photoshop:Country"] = edited.country ?? "" }
                if edited.event != original?.event { fields["XMP-iptcExt:Event"] = edited.event ?? "" }

                do {
                    if !fields.isEmpty {
                        try await exifToolService.writeFields(fields, to: [imageURL])
                    }
                    try? sidecarService.deleteSidecar(for: imageURL, in: folderURL)
                } catch {
                    // Continue with next image
                }

                processed += 1
                self.folderProcessProgress = "\(processed)/\(total)"
            }

            self.isProcessingFolder = false
            self.folderProcessProgress = ""
        }
    }

    // MARK: - Diff Helpers

    func fieldDiffers(_ keyPath: KeyPath<IPTCMetadata, String?>) -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata[keyPath: keyPath] != original[keyPath: keyPath]
    }

    func keywordsDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.keywords != original.keywords
    }

    func personShownDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.personShown != original.personShown
    }

    func digitalSourceTypeDiffers() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.digitalSourceType != original.digitalSourceType
    }

    func gpsDiffers() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.latitude != original.latitude || editingMetadata.longitude != original.longitude
    }

    var pendingFieldNames: [String] {
        guard let original = originalImageMetadata else { return [] }
        var names: [String] = []
        if editingMetadata.title != original.title { names.append("Title") }
        if editingMetadata.description != original.description { names.append("Description") }
        if editingMetadata.keywords != original.keywords { names.append("Keywords") }
        if editingMetadata.personShown != original.personShown { names.append("Person Shown") }
        if editingMetadata.copyright != original.copyright { names.append("Copyright") }
        if editingMetadata.creator != original.creator { names.append("Creator") }
        if editingMetadata.credit != original.credit { names.append("Credit") }
        if editingMetadata.city != original.city { names.append("City") }
        if editingMetadata.country != original.country { names.append("Country") }
        if editingMetadata.event != original.event { names.append("Event") }
        if editingMetadata.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        return names
    }

    func discardPendingChanges() {
        guard let folderURL = currentFolderURL else { return }

        // Single image: restore from original and delete sidecar
        if selectedURLs.count == 1, let original = originalImageMetadata {
            editingMetadata = original
            hasChanges = false
            sidecarHistory = []
            previousEditingMetadata = original
            try? sidecarService.deleteSidecar(for: selectedURLs[0], in: folderURL)
        } else {
            // Multiple images: delete sidecars for all selected
            for imageURL in selectedURLs {
                try? sidecarService.deleteSidecar(for: imageURL, in: folderURL)
            }
            // Reset state since we're in batch mode
            hasChanges = false
            editingMetadata = IPTCMetadata()
        }
    }

    func discardAllPendingInFolder() {
        guard let folderURL = currentFolderURL else { return }

        try? sidecarService.deleteAllSidecars(in: folderURL)

        // Reset current editing state
        if let original = originalImageMetadata {
            editingMetadata = original
            previousEditingMetadata = original
        } else {
            editingMetadata = IPTCMetadata()
        }
        hasChanges = false
        sidecarHistory = []
    }

    func clearHistory() {
        guard let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else { return }

        sidecarHistory = []

        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: Date(),
            pendingChanges: hasChanges,
            metadata: editingMetadata,
            imageMetadataSnapshot: originalImageMetadata,
            history: []
        )
        try? sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
    }

    func restoreToHistoryPoint(at index: Int) {
        guard let original = originalImageMetadata else { return }

        // Start from original and replay history up to (and including) the given index
        var restored = original
        let historyToApply = Array(sidecarHistory.prefix(index + 1))

        for entry in historyToApply {
            applyHistoryEntry(entry, to: &restored)
        }

        editingMetadata = restored
        previousEditingMetadata = restored

        // Trim history to only include entries up to this point
        sidecarHistory = historyToApply
        hasChanges = editingMetadata != original

        // Save the updated sidecar
        if let imageURL = selectedURLs.first,
           let folderURL = currentFolderURL {
            let sidecar = MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                lastModified: Date(),
                pendingChanges: hasChanges,
                metadata: editingMetadata,
                imageMetadataSnapshot: originalImageMetadata,
                history: sidecarHistory
            )
            try? sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
        }
    }

    private func applyHistoryEntry(_ entry: MetadataHistoryEntry, to metadata: inout IPTCMetadata) {
        switch entry.fieldName {
        case "Title":
            metadata.title = entry.newValue
        case "Description":
            metadata.description = entry.newValue
        case "Keywords":
            metadata.keywords = entry.newValue?.components(separatedBy: ", ") ?? []
        case "Person Shown":
            metadata.personShown = entry.newValue?.components(separatedBy: ", ") ?? []
        case "Copyright":
            metadata.copyright = entry.newValue
        case "Creator":
            metadata.creator = entry.newValue
        case "Credit":
            metadata.credit = entry.newValue
        case "City":
            metadata.city = entry.newValue
        case "Country":
            metadata.country = entry.newValue
        case "Event":
            metadata.event = entry.newValue
        case "Digital Source Type":
            metadata.digitalSourceType = entry.newValue.flatMap { DigitalSourceType(rawValue: $0) }
        default:
            break
        }
    }

    func clear() {
        metadata = nil
        editingMetadata = IPTCMetadata()
        selectedCount = 0
        selectedURLs = []
        hasChanges = false
        sidecarHistory = []
        originalImageMetadata = nil
        previousEditingMetadata = nil
    }
}
