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

    private let exifToolService: ExifToolService
    private let sidecarService = MetadataSidecarService()
    private var previousEditingMetadata: IPTCMetadata?

    init(exifToolService: ExifToolService) {
        self.exifToolService = exifToolService
    }

    var isBatchEdit: Bool { selectedCount > 1 }

    func loadMetadata(for images: [ImageFile], folderURL: URL? = nil) {
        selectedCount = images.count
        selectedURLs = images.map(\.url)
        hasChanges = false
        saveError = nil
        sidecarHistory = []
        originalImageMetadata = nil

        if let folderURL {
            currentFolderURL = folderURL
        }

        guard !images.isEmpty else {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            return
        }

        if images.count == 1 {
            let imageURL = images[0].url
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            isLoading = true

            Task {
                do {
                    let imageMeta = try await exifToolService.readFullMetadata(url: imageURL)
                    self.metadata = imageMeta
                    self.originalImageMetadata = imageMeta

                    if let folder = self.currentFolderURL,
                       let sidecar = sidecarService.loadSidecar(for: imageURL, in: folder),
                       sidecar.pendingChanges {
                        self.editingMetadata = sidecar.metadata
                        self.sidecarHistory = sidecar.history
                        self.hasChanges = true
                    } else {
                        self.editingMetadata = imageMeta
                    }
                    self.previousEditingMetadata = self.editingMetadata
                } catch {
                    self.metadata = nil
                    self.editingMetadata = IPTCMetadata()
                    self.previousEditingMetadata = nil
                }
                self.isLoading = false
            }
        } else {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
        }
    }

    func markChanged() {
        hasChanges = true
    }

    func writeMetadata() {
        guard !selectedURLs.isEmpty else { return }
        isSaving = true
        saveError = nil

        Task {
            do {
                var fields: [String: String] = [:]
                let edited = editingMetadata
                let original = metadata

                if isBatchEdit {
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
                    try await exifToolService.writeFields(fields, to: selectedURLs)
                }
                self.metadata = edited
                self.hasChanges = false
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
        }
    }

    func applyPresetFields(_ preset: [String: String]) {
        for (key, value) in preset {
            switch key {
            case "title": editingMetadata.title = value
            case "description": editingMetadata.description = value
            case "keywords": editingMetadata.keywords = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "personShown": editingMetadata.personShown = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "digitalSourceType": editingMetadata.digitalSourceType = DigitalSourceType(rawValue: value)
            case "creator": editingMetadata.creator = value
            case "credit": editingMetadata.credit = value
            case "copyright": editingMetadata.copyright = value
            case "dateCreated": editingMetadata.dateCreated = value
            case "city": editingMetadata.city = value
            case "country": editingMetadata.country = value
            case "event": editingMetadata.event = value
            default: break
            }
        }
        hasChanges = true
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

    // MARK: - Sidecar Management

    func saveToSidecar() {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            return
        }

        var newHistory = sidecarHistory
        let prev = previousEditingMetadata ?? IPTCMetadata()
        let now = Date()

        func recordChange(_ fieldName: String, old: String?, new: String?) {
            if old != new {
                newHistory.append(MetadataHistoryEntry(
                    timestamp: now,
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
                newHistory.append(MetadataHistoryEntry(
                    timestamp: now,
                    fieldName: fieldName,
                    oldValue: oldVal,
                    newValue: newVal
                ))
            }
        }

        recordChange("Title", old: prev.title, new: editingMetadata.title)
        recordChange("Description", old: prev.description, new: editingMetadata.description)
        recordArrayChange("Keywords", old: prev.keywords, new: editingMetadata.keywords)
        recordArrayChange("Person Shown", old: prev.personShown, new: editingMetadata.personShown)
        recordChange("Copyright", old: prev.copyright, new: editingMetadata.copyright)
        recordChange("Creator", old: prev.creator, new: editingMetadata.creator)
        recordChange("Credit", old: prev.credit, new: editingMetadata.credit)
        recordChange("Date Created", old: prev.dateCreated, new: editingMetadata.dateCreated)
        recordChange("City", old: prev.city, new: editingMetadata.city)
        recordChange("Country", old: prev.country, new: editingMetadata.country)
        recordChange("Event", old: prev.event, new: editingMetadata.event)
        recordChange("Digital Source Type", old: prev.digitalSourceType?.rawValue, new: editingMetadata.digitalSourceType?.rawValue)

        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: now,
            pendingChanges: true,
            metadata: editingMetadata,
            imageMetadataSnapshot: originalImageMetadata,
            history: newHistory
        )

        do {
            try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
            sidecarHistory = newHistory
            previousEditingMetadata = editingMetadata
            hasChanges = true
        } catch {
            saveError = "Failed to save sidecar: \(error.localizedDescription)"
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
