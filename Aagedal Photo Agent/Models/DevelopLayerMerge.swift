import Foundation

/// Per-image layer limits imposed by the Metal edit pipeline's fixed-size GPU buffers. Enabled
/// local layers past the limit are skipped by preview *and* export, so creation is gated here.
nonisolated enum DevelopLayerLimits {
    /// Max enabled local adjustment layers (ellipse/brush/AI masks, extra Global and LUT/CST
    /// layers). The Metal shaders (EditAdjustments.metal, ScopeShaders.metal) mirror this as 8.
    static let maxEnabledMasks = 8

    /// Max enabled watermark layers (the pipeline composites only the first N).
    static let maxEnabledWatermarks = 4

    static let limitReachedMessage =
        "Layer limit reached: up to \(maxEnabledMasks) enabled mask/adjustment layers. Disable or delete one to add another."

    static func enabledMaskCount(in settings: CameraRawSettings?) -> Int {
        settings?.localAdjustments?.reduce(0) { $0 + ($1.enabled ? 1 : 0) } ?? 0
    }

    static func canAddMask(to settings: CameraRawSettings?) -> Bool {
        enabledMaskCount(in: settings) < maxEnabledMasks
    }

    static func exceedsMaskLimit(_ settings: CameraRawSettings?) -> Bool {
        enabledMaskCount(in: settings) > maxEnabledMasks
    }
}

/// The outcome of appending copied layers (masks, watermark layers) onto a target's own layers.
/// `skipped*` count copied layers left out because the target would otherwise exceed the
/// renderer's enabled-layer limits; duplicates of layers the target already has are not skipped
/// layers (they are already there).
nonisolated struct DevelopLayerAppendResult: Sendable, Equatable {
    var settings: CameraRawSettings
    var skippedMasks = 0
    var skippedWatermarks = 0

    var skippedLayerCount: Int { skippedMasks + skippedWatermarks }

    /// User-facing note for skipped layers, nil when nothing was skipped.
    var skippedLayersMessage: String? {
        guard skippedLayerCount > 0 else { return nil }
        var parts: [String] = []
        if skippedMasks > 0 {
            parts.append("\(skippedMasks) mask\(skippedMasks == 1 ? "" : "s")")
        }
        if skippedWatermarks > 0 {
            parts.append("\(skippedWatermarks) watermark\(skippedWatermarks == 1 ? "" : "s")")
        }
        return "Skipped " + parts.joined(separator: " and ")
            + ": layer limit reached (\(DevelopLayerLimits.maxEnabledMasks) masks, "
            + "\(DevelopLayerLimits.maxEnabledWatermarks) watermarks). The photo's own layers were kept."
    }
}

/// How appended layers get their identities.
nonisolated enum DevelopLayerAppendIdentity: Sendable, Equatable {
    /// Every appended layer gets a new UUID (an independent copy).
    case fresh
    /// Keep the copied UUID unless the target already uses it.
    case keepUnlessTaken
}

extension CameraRawSettings {
    /// The shared paste/template merge: scalar settings from `source`, the target's crop when
    /// the crop isn't applied, collections `source` doesn't carry kept from the target, and
    /// layers appended (never replaced). See `pasted(_:onto:includeCrop:)` and
    /// `DevelopTemplate.applicationResult(preserving:)`.
    nonisolated static func pastedResult(
        _ source: CameraRawSettings,
        onto existing: CameraRawSettings?,
        includeCrop: Bool,
        maskIdentity: DevelopLayerAppendIdentity,
        watermarkIdentity: DevelopLayerAppendIdentity
    ) -> DevelopLayerAppendResult {
        var result = source
        result.hasSettings = true
        if !includeCrop || source.crop?.isEmpty != false {
            result.crop = existing?.crop
        }
        if source.toneCurve == nil { result.toneCurve = existing?.toneCurve }
        if source.hslAdjustments?.isEmpty != false { result.hslAdjustments = existing?.hslAdjustments }
        if source.anonymizer?.isEmpty != false { result.anonymizer = existing?.anonymizer }
        // Layers start from the target's own chain; the source's are appended below.
        result.localAdjustments = existing?.localAdjustments
        result.watermarkLayers = existing?.watermarkLayers
        result.layerOrder = existing?.layerOrder
        result.unparsedMaskCorrections = existing?.unparsedMaskCorrections
        // Per-image decode facts, never part of a paste (see their declarations).
        result.asShotNeutralTemperature = existing?.asShotNeutralTemperature
        result.asShotNeutralTint = existing?.asShotNeutralTint
        result.sourceHasHDRHeadroom = existing?.sourceHasHDRHeadroom
        return result.appendingLayers(from: source, maskIdentity: maskIdentity,
                                      watermarkIdentity: watermarkIdentity)
    }

    /// Appends `source`'s masks and watermark layers to this record's own (Adobe convention: a
    /// preset or paste adds layers, it never removes the photo's own — an Anonymizer face mask or
    /// a watermark on the target always survives). Copied layers that already exist on the
    /// target (same content, ignoring identity and name) are skipped, so pasting twice doesn't
    /// duplicate them. Enabled layers are appended only up to the renderer's limits; enabled
    /// Anonymizer masks take priority for the remaining mask slots. Preserved (unmodelled) ACR
    /// mask corrections the target doesn't already carry are appended too.
    ///
    /// The layer order keeps the target's chain (incl. the Global node's position, persisted as
    /// `aaphoto:GlobalLayerIndex`) and appends the new layers in the source's relative order. A
    /// target without layers of its own takes the source's order.
    nonisolated func appendingLayers(
        from source: CameraRawSettings,
        maskIdentity: DevelopLayerAppendIdentity,
        watermarkIdentity: DevelopLayerAppendIdentity
    ) -> DevelopLayerAppendResult {
        var result = self
        let targetMasks = localAdjustments ?? []
        let targetWatermarks = watermarkLayers ?? []
        let targetHadLayers = !targetMasks.isEmpty || !targetWatermarks.isEmpty

        if let sourcePreserved = source.unparsedMaskCorrections, !sourcePreserved.isEmpty {
            var preserved = unparsedMaskCorrections ?? []
            for correction in sourcePreserved where !preserved.contains(correction) {
                preserved.append(correction)
            }
            result.unparsedMaskCorrections = preserved
        }

        // Masks: drop duplicates of the target's (and of each other), then fill free slots.
        var maskPrints = Set(targetMasks.compactMap { Self.layerFingerprint($0, clearing: \.id, \.name) })
        var candidates: [MaskAdjustment] = []
        for mask in source.localAdjustments ?? [] {
            if let print = Self.layerFingerprint(mask, clearing: \.id, \.name) {
                guard maskPrints.insert(print).inserted else { continue }
            }
            candidates.append(mask)
        }
        var freeMaskSlots = max(0, DevelopLayerLimits.maxEnabledMasks - DevelopLayerLimits.enabledMaskCount(in: self))
        var acceptedMasks = Set(candidates.indices.filter { !candidates[$0].enabled })
        let enabledByPriority = candidates.indices.filter { candidates[$0].enabled }.sorted { lhs, rhs in
            let lhsRedacts = candidates[lhs].anonymizer?.isEmpty == false
            let rhsRedacts = candidates[rhs].anonymizer?.isEmpty == false
            return lhsRedacts != rhsRedacts ? lhsRedacts : lhs < rhs
        }
        for index in enabledByPriority where freeMaskSlots > 0 {
            acceptedMasks.insert(index)
            freeMaskSlots -= 1
        }
        let skippedMasks = candidates.count - acceptedMasks.count

        var usedMaskIDs = Set(targetMasks.map(\.id))
        var maskIDMap: [UUID: UUID] = [:]
        var appendedMasks: [MaskAdjustment] = []
        for (index, mask) in candidates.enumerated() where acceptedMasks.contains(index) {
            var copy = mask
            if maskIdentity == .fresh || usedMaskIDs.contains(copy.id) { copy.id = UUID() }
            usedMaskIDs.insert(copy.id)
            maskIDMap[mask.id] = copy.id
            appendedMasks.append(copy)
        }

        // Watermark layers: same rules, their own limit.
        var watermarkPrints = Set(targetWatermarks.compactMap { Self.layerFingerprint($0, clearing: \.id, \.name) })
        var freeWatermarkSlots = max(0, DevelopLayerLimits.maxEnabledWatermarks
            - targetWatermarks.reduce(0) { $0 + ($1.enabled ? 1 : 0) })
        var usedWatermarkIDs = Set(targetWatermarks.map(\.id))
        var watermarkIDMap: [UUID: UUID] = [:]
        var appendedWatermarks: [WatermarkLayer] = []
        var skippedWatermarks = 0
        for layer in source.watermarkLayers ?? [] {
            if let print = Self.layerFingerprint(layer, clearing: \.id, \.name) {
                guard watermarkPrints.insert(print).inserted else { continue }
            }
            if layer.enabled {
                guard freeWatermarkSlots > 0 else {
                    skippedWatermarks += 1
                    continue
                }
                freeWatermarkSlots -= 1
            }
            var copy = layer
            if watermarkIdentity == .fresh || usedWatermarkIDs.contains(copy.id) { copy.id = UUID() }
            usedWatermarkIDs.insert(copy.id)
            watermarkIDMap[layer.id] = copy.id
            appendedWatermarks.append(copy)
        }

        guard !appendedMasks.isEmpty || !appendedWatermarks.isEmpty else {
            return DevelopLayerAppendResult(settings: result, skippedMasks: skippedMasks,
                                            skippedWatermarks: skippedWatermarks)
        }
        let masks = targetMasks + appendedMasks
        result.localAdjustments = masks.isEmpty ? nil : masks
        let watermarks = targetWatermarks + appendedWatermarks
        result.watermarkLayers = watermarks.isEmpty ? nil : watermarks

        func remapped(_ ref: LayerRef) -> LayerRef? {
            switch ref {
            case .global: return .global
            case .mask(let id): return maskIDMap[id].map(LayerRef.mask)
            case .watermark(let id): return watermarkIDMap[id].map(LayerRef.watermark)
            }
        }
        if !targetHadLayers {
            // Nothing of the target's to keep in place: follow the source's chain, including
            // where its Global node sits.
            result.layerOrder = source.layerOrder == nil
                ? layerOrder
                : source.resolvedLayerOrder().compactMap(remapped)
        } else if layerOrder == nil && source.layerOrder == nil {
            // The canonical order already appends masks and watermarks in array order.
            result.layerOrder = nil
        } else {
            let appendedRefs = source.resolvedLayerOrder().compactMap(remapped).filter { $0 != .global }
            result.layerOrder = resolvedLayerOrder() + appendedRefs
        }
        return DevelopLayerAppendResult(settings: result, skippedMasks: skippedMasks,
                                        skippedWatermarks: skippedWatermarks)
    }

    /// Content identity of a layer for duplicate detection: its JSON encoding with the identity
    /// and name cleared, numbers rounded to 1e-4 and zero/false values dropped — a layer written
    /// to XMP and read back can return explicit zeros or slightly less precision.
    nonisolated static func layerFingerprint<Layer: Encodable>(
        _ layer: Layer,
        clearing idPath: WritableKeyPath<Layer, UUID>,
        _ namePath: WritableKeyPath<Layer, String>
    ) -> String? {
        var normalized = layer
        normalized[keyPath: idPath] = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        normalized[keyPath: namePath] = ""
        guard let data = try? JSONEncoder().encode(normalized),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = canonicalFingerprintValue(object),
              JSONSerialization.isValidJSONObject(canonical),
              let encoded = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    nonisolated private static func canonicalFingerprintValue(_ value: Any) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                if let canonical = canonicalFingerprintValue(child) { result[key] = canonical }
            }
            return result
        case let array as [Any]:
            return array.map { canonicalFingerprintValue($0) ?? NSNull() }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? true : nil
            }
            let rounded = (number.doubleValue * 10_000).rounded() / 10_000
            return rounded == 0 ? nil : NSNumber(value: rounded)
        default:
            return value
        }
    }
}
