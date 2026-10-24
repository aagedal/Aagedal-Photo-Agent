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

extension MaskAdjustment {
    /// An Anonymizer redaction mask (face blur / black-out). Paste and templates never remove one.
    nonisolated var isRedaction: Bool { anonymizer?.isEmpty == false }
}

extension CameraRawSettings {
    /// True when rendering these settings redacts pixels: an enabled Anonymizer mask (face blur /
    /// Black Out) or a global Anonymizer. Privacy decisions (which settings copy an export uses,
    /// whether a C2PA manifest may embed the unredacted parent) key off this.
    nonisolated var hasActiveRedaction: Bool {
        if anonymizer?.isEmpty == false { return true }
        return localAdjustments?.contains { $0.enabled && $0.isRedaction } == true
    }
}

extension AnonymizerSettings {
    /// The global Anonymizer a paste/template leaves when the target already redacts: it may be
    /// turned on or strengthened from the source, never turned off or weakened (privacy rule).
    nonisolated static func atLeastAsStrong(
        target: AnonymizerSettings?,
        incoming: AnonymizerSettings?
    ) -> AnonymizerSettings? {
        guard let target, !target.isEmpty else { return incoming }
        guard let incoming, !incoming.isEmpty else { return target }
        let amount = max(target.amount ?? 0, incoming.amount ?? 0)
        let blackOut = target.blackOut == true || incoming.blackOut == true
        return AnonymizerSettings(amount: amount > 0 ? amount : nil, blackOut: blackOut ? true : nil)
    }
}

extension CameraRawSettings {
    /// The Develop record a paste (Lightroom-like) leaves on one target: scalar sliders from the
    /// source; tone curve / HSL kept from the target when the source has none; the crop only
    /// when pasted. Layers follow `pastingLayers(from:maskIdentity:watermarkIdentity:)`: the
    /// source's masks replace the target's ordinary masks and its watermarks replace the
    /// target's, but the target's Anonymizer masks are always kept. The global Anonymizer is
    /// never turned off or weakened.
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
        result.anonymizer = AnonymizerSettings.atLeastAsStrong(target: existing?.anonymizer, incoming: source.anonymizer)
        result.copyLayersAndDecodeFacts(from: existing)
        return result.pastingLayers(from: source, maskIdentity: maskIdentity,
                                    watermarkIdentity: watermarkIdentity)
    }

    /// The Develop record a template (preset) leaves on one target: every non-layer group the
    /// template carries overrides the target, neutral values included (a template stores the
    /// complete look, so switching template A → B leaves none of A's curve or HSL behind). The
    /// crop follows `includeCrop` (the target's is kept when the template has none). Masks and
    /// watermark layers are add-only (`appendingLayers`), and the global Anonymizer is never
    /// turned off or weakened.
    nonisolated static func templateResult(
        _ template: CameraRawSettings,
        onto existing: CameraRawSettings?,
        includeCrop: Bool
    ) -> DevelopLayerAppendResult {
        var result = template
        result.hasSettings = template.hasSettings ?? existing?.hasSettings
        if !includeCrop || template.crop?.isEmpty != false {
            result.crop = existing?.crop
        }
        result.anonymizer = AnonymizerSettings.atLeastAsStrong(target: existing?.anonymizer, incoming: template.anonymizer)
        result.copyLayersAndDecodeFacts(from: existing)
        return result.appendingLayers(from: template, maskIdentity: .fresh, watermarkIdentity: .fresh)
    }

    /// Layers start from the target's own chain; per-image decode facts are never copied.
    nonisolated private mutating func copyLayersAndDecodeFacts(from existing: CameraRawSettings?) {
        localAdjustments = existing?.localAdjustments
        watermarkLayers = existing?.watermarkLayers
        layerOrder = existing?.layerOrder
        unparsedMaskCorrections = existing?.unparsedMaskCorrections
        asShotNeutralTemperature = existing?.asShotNeutralTemperature
        asShotNeutralTint = existing?.asShotNeutralTint
        sourceHasHDRHeadroom = existing?.sourceHasHDRHeadroom
    }

    /// Paste layer merge onto this (target) record:
    /// - Source ordinary masks (incl. extra Global and LUT/CST layers) — or preserved ACR
    ///   corrections — replace the target's ordinary masks and preserved corrections; without
    ///   them the target keeps its own.
    /// - The target's Anonymizer masks are always kept; the source's are appended unless the
    ///   target already has the same one (content match ignoring identity/name).
    /// - Source watermark layers replace the target's; without any the target keeps its own.
    /// - Order: the source's chain for what it brings; kept target Anonymizer masks stay on
    ///   their side of Global (before-Global ones just before it, the rest after the source's
    ///   adjustment layers, ahead of watermarks); kept target watermarks go last.
    /// - Limits: kept target Anonymizer masks always stay (even beyond the limit); free enabled
    ///   slots go to source Anonymizer masks first, then source ordinary masks.
    nonisolated func pastingLayers(
        from source: CameraRawSettings,
        maskIdentity: DevelopLayerAppendIdentity,
        watermarkIdentity: DevelopLayerAppendIdentity
    ) -> DevelopLayerAppendResult {
        let targetMasks = localAdjustments ?? []
        let sourceMasks = source.localAdjustments ?? []
        let sourceOrdinary = sourceMasks.filter { !$0.isRedaction }
        let replacesOrdinary = !sourceOrdinary.isEmpty || source.unparsedMaskCorrections?.isEmpty == false
        let sourceWatermarks = source.watermarkLayers ?? []
        let replacesWatermarks = !sourceWatermarks.isEmpty

        guard replacesOrdinary || replacesWatermarks else {
            // Only Anonymizer masks (or nothing) to bring: purely additive.
            var redactionsOnly = CameraRawSettings()
            redactionsOnly.localAdjustments = sourceMasks
            redactionsOnly.layerOrder = source.layerOrder
            return appendingLayers(from: redactionsOnly, maskIdentity: maskIdentity,
                                   watermarkIdentity: watermarkIdentity)
        }

        var result = self
        let keptMasks = replacesOrdinary ? targetMasks.filter(\.isRedaction) : targetMasks
        let keptWatermarks = replacesWatermarks ? [] : (watermarkLayers ?? [])
        result.unparsedMaskCorrections = replacesOrdinary ? source.unparsedMaskCorrections : unparsedMaskCorrections

        // Incoming masks in source order; Anonymizer duplicates of kept target masks dropped.
        var redactionPrints = Set(keptMasks.filter(\.isRedaction)
            .compactMap { Self.layerFingerprint($0, clearing: \.id, \.name) })
        var incoming: [MaskAdjustment] = []
        for mask in sourceMasks {
            if mask.isRedaction, let print = Self.layerFingerprint(mask, clearing: \.id, \.name) {
                guard redactionPrints.insert(print).inserted else { continue }
            } else if !mask.isRedaction && !replacesOrdinary {
                continue
            }
            incoming.append(mask)
        }
        var freeMaskSlots = max(0, DevelopLayerLimits.maxEnabledMasks - keptMasks.filter(\.enabled).count)
        var acceptedMasks = Set(incoming.indices.filter { !incoming[$0].enabled })
        let enabledByPriority = incoming.indices.filter { incoming[$0].enabled }.sorted { lhs, rhs in
            let lhsRedacts = incoming[lhs].isRedaction
            let rhsRedacts = incoming[rhs].isRedaction
            return lhsRedacts != rhsRedacts ? lhsRedacts : lhs < rhs
        }
        for index in enabledByPriority where freeMaskSlots > 0 {
            acceptedMasks.insert(index)
            freeMaskSlots -= 1
        }
        let skippedMasks = incoming.count - acceptedMasks.count

        var usedMaskIDs = Set(keptMasks.map(\.id))
        var maskIDMap: [UUID: UUID] = [:]
        var appendedMasks: [MaskAdjustment] = []
        for (index, mask) in incoming.enumerated() where acceptedMasks.contains(index) {
            var copy = mask
            if maskIdentity == .fresh || usedMaskIDs.contains(copy.id) { copy.id = UUID() }
            usedMaskIDs.insert(copy.id)
            maskIDMap[mask.id] = copy.id
            appendedMasks.append(copy)
        }

        var freeWatermarkSlots = max(0, DevelopLayerLimits.maxEnabledWatermarks
            - keptWatermarks.filter(\.enabled).count)
        var usedWatermarkIDs = Set(keptWatermarks.map(\.id))
        var watermarkIDMap: [UUID: UUID] = [:]
        var appendedWatermarks: [WatermarkLayer] = []
        var skippedWatermarks = 0
        for layer in replacesWatermarks ? sourceWatermarks : [] {
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

        let masks = keptMasks + appendedMasks
        result.localAdjustments = masks.isEmpty ? nil : masks
        let watermarks = keptWatermarks + appendedWatermarks
        result.watermarkLayers = watermarks.isEmpty ? nil : watermarks

        // Order: the source's chain for what it brought, kept target layers placed around it.
        let targetOrder = resolvedLayerOrder()
        let targetGlobalIndex = targetOrder.firstIndex(of: .global) ?? 0
        let keptMaskIDs = Set(keptMasks.map(\.id))
        var keptBeforeGlobal: [LayerRef] = []
        var keptAfterGlobal: [LayerRef] = []
        for (index, ref) in targetOrder.enumerated() {
            guard case .mask(let id) = ref, keptMaskIDs.contains(id) else { continue }
            if index < targetGlobalIndex { keptBeforeGlobal.append(ref) } else { keptAfterGlobal.append(ref) }
        }
        let keptWatermarkIDs = Set(keptWatermarks.map(\.id))
        let keptWatermarkRefs = targetOrder.filter {
            if case .watermark(let id) = $0 { return keptWatermarkIDs.contains(id) }
            return false
        }
        var order: [LayerRef] = []
        for ref in source.resolvedLayerOrder() {
            switch ref {
            case .global:
                order += keptBeforeGlobal
                order.append(.global)
            case .mask(let id):
                if let mapped = maskIDMap[id] { order.append(.mask(mapped)) }
            case .watermark(let id):
                if let mapped = watermarkIDMap[id] { order.append(.watermark(mapped)) }
            }
        }
        let globalPosition = order.firstIndex(of: .global) ?? 0
        let firstWatermarkAfterGlobal = order.indices.first { index in
            guard index > globalPosition, case .watermark = order[index] else { return false }
            return true
        }
        order.insert(contentsOf: keptAfterGlobal, at: firstWatermarkAfterGlobal ?? order.count)
        order += keptWatermarkRefs

        let canonical: [LayerRef] = [.global] + masks.map { .mask($0.id) } + watermarks.map { .watermark($0.id) }
        result.layerOrder = order == canonical ? nil : order
        return DevelopLayerAppendResult(settings: result, skippedMasks: skippedMasks,
                                        skippedWatermarks: skippedWatermarks)
    }

    /// Appends `source`'s masks and watermark layers to this record's own (template/preset
    /// semantics, and a paste that only brings Anonymizer masks: layers are added, the photo's
    /// own are never removed). Copied layers that already exist on the target (same content,
    /// ignoring identity and name) are skipped, so applying twice doesn't duplicate them. Enabled layers are appended only up to the renderer's limits; enabled
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
        normalized[keyPath: idPath] = Self.zeroIdentity
        normalized[keyPath: namePath] = ""
        return canonicalJSONFingerprint(normalized)
    }

    nonisolated static let zeroIdentity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Canonical JSON of any Codable value: sorted keys, numbers rounded to `1 / scale`, and
    /// zero/false values dropped (so nil ≡ 0 ≡ false), for tolerant content comparison.
    nonisolated static func canonicalJSONFingerprint<Value: Encodable>(
        _ value: Value,
        scale: Double = 10_000
    ) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let canonical = canonicalFingerprintValue(object, scale: scale),
              let encoded = try? JSONSerialization.data(
                withJSONObject: canonical, options: [.sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    nonisolated private static func canonicalFingerprintValue(_ value: Any, scale: Double) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                if let canonical = canonicalFingerprintValue(child, scale: scale) { result[key] = canonical }
            }
            return result
        case let array as [Any]:
            return array.map { canonicalFingerprintValue($0, scale: scale) ?? NSNull() }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? true : nil
            }
            let rounded = (number.doubleValue * scale).rounded() / scale
            return rounded == 0 ? nil : NSNumber(value: rounded)
        default:
            return value
        }
    }
}

/// Combines Anonymizer redactions across the copies of one photo's develop settings (sidecar,
/// embedded, the Browser's live copy) so that merging copies only ever adds redactions:
/// every enabled Anonymizer mask of every copy (deduplicated by identity, then by region), and
/// the strongest global Anonymizer. Over-redacting is recoverable; publishing a face is not.
///
/// Also the fail-closed check every output render runs (`covers`): a redaction saved in any
/// copy that the render settings don't carry refuses the render.
nonisolated enum RedactionUnion {
    /// Enabled Anonymizer masks (face blur / Black Out) in `settings`.
    static func redactionMasks(in settings: CameraRawSettings?) -> [MaskAdjustment] {
        settings?.localAdjustments?.filter { $0.enabled && $0.isRedaction } ?? []
    }

    /// The region a mask covers (geometry, inversion, full-frame), ignoring identity, name,
    /// strength and adjustments. Two copies of the same face blur share it even when their
    /// identities differ (e.g. one copy re-created by another tool).
    static func regionFingerprint(_ mask: MaskAdjustment) -> String? {
        struct Region: Encodable {
            let geometry: EllipseMaskGeometry?
            let brush: BrushMaskGeometry?
            let aiMask: AIMaskGeometry?
            let inverted: Bool
            let fullFrame: Bool
        }
        let usesEllipse = mask.brush == nil && mask.aiMask == nil && !mask.isFullFrame
        return CameraRawSettings.canonicalJSONFingerprint(Region(
            geometry: usesEllipse ? mask.geometry : nil,
            brush: mask.brush,
            aiMask: mask.aiMask,
            inverted: mask.inverted,
            fullFrame: mask.isFullFrame
        ), scale: 1_000)
    }

    /// `base` (the preferred copy, which keeps all its own settings) plus every enabled
    /// redaction from `others`: a mask `base` already has (same identity, or an enabled
    /// redaction over the same region) is re-enabled/strengthened in place, any other is
    /// appended; the global Anonymizer becomes the strongest of all copies. Redactions are kept
    /// within the renderer's mask limit (ordinary masks are disabled to make room).
    static func merged(_ base: CameraRawSettings, adding others: [CameraRawSettings?]) -> CameraRawSettings {
        var result = base
        let others = others.compactMap { $0 }

        var anonymizer = base.anonymizer
        for other in others {
            anonymizer = AnonymizerSettings.atLeastAsStrong(target: anonymizer, incoming: other.anonymizer)
        }
        if let anonymizer, !anonymizer.isEmpty, anonymizer != base.anonymizer {
            result.anonymizer = anonymizer
        }

        var masks = base.localAdjustments ?? []
        var appendedIDs: [UUID] = []
        for other in others {
            for mask in redactionMasks(in: other) {
                if let index = masks.firstIndex(where: { $0.id == mask.id }) {
                    masks[index] = strengthened(masks[index], covering: mask)
                    continue
                }
                let region = regionFingerprint(mask)
                if let region, let index = masks.firstIndex(where: {
                    $0.enabled && $0.isRedaction && regionFingerprint($0) == region
                }) {
                    masks[index] = strengthened(masks[index], covering: mask)
                    continue
                }
                masks.append(mask)   // its identity isn't taken (checked above)
                appendedIDs.append(mask.id)
            }
        }
        if masks != (base.localAdjustments ?? []) {
            result.localAdjustments = masks
            if !appendedIDs.isEmpty, var order = base.layerOrder, !order.isEmpty {
                // An explicit chain: place the added redactions ahead of the watermarks.
                let insertAt = order.firstIndex {
                    if case .watermark = $0 { return true }
                    return false
                } ?? order.count
                order.insert(contentsOf: appendedIDs.map(LayerRef.mask), at: insertAt)
                result.layerOrder = order
            }
        }
        keepRedactionsRenderable(&result)
        return result
    }

    /// True when `render` carries every redaction saved in `saved`: each enabled Anonymizer
    /// mask (matched by identity or region, enabled and redacting) and, when any copy has a
    /// global Anonymizer, a global Anonymizer of its own; and the renderer's mask limit doesn't
    /// skip any of its redaction masks.
    static func covers(render: CameraRawSettings?, saved: [CameraRawSettings?]) -> Bool {
        let renderMasks = redactionMasks(in: render)
        let renderIDs = Set(renderMasks.map(\.id))
        let renderRegions = Set(renderMasks.compactMap(regionFingerprint))
        for copy in saved.compactMap({ $0 }) {
            if copy.anonymizer?.isEmpty == false, render?.anonymizer?.isEmpty != false {
                return false
            }
            for mask in redactionMasks(in: copy) {
                if renderIDs.contains(mask.id) { continue }
                if let region = regionFingerprint(mask), renderRegions.contains(region) { continue }
                return false
            }
        }
        if let render, redactionsExceedRenderLimit(render) { return false }
        return true
    }

    /// True when the renderer (which takes the first `maxEnabledMasks` enabled masks in array
    /// order) would skip an enabled redaction mask.
    static func redactionsExceedRenderLimit(_ settings: CameraRawSettings) -> Bool {
        let enabled = settings.localAdjustments?.filter(\.enabled) ?? []
        guard enabled.count > DevelopLayerLimits.maxEnabledMasks else { return false }
        return enabled.dropFirst(DevelopLayerLimits.maxEnabledMasks).contains(where: \.isRedaction)
    }

    /// Disables ordinary masks (the last one ahead of a skipped redaction first) until no
    /// enabled redaction falls past the renderer's mask limit, or nothing more can be freed.
    static func keepRedactionsRenderable(_ settings: inout CameraRawSettings) {
        guard var masks = settings.localAdjustments else { return }
        while true {
            let enabledIndices = masks.indices.filter { masks[$0].enabled }
            guard enabledIndices.count > DevelopLayerLimits.maxEnabledMasks,
                  let skipped = enabledIndices.dropFirst(DevelopLayerLimits.maxEnabledMasks)
                    .first(where: { masks[$0].isRedaction }),
                  let victim = enabledIndices.last(where: { $0 < skipped && !masks[$0].isRedaction })
            else { break }
            masks[victim].enabled = false
        }
        if masks != settings.localAdjustments { settings.localAdjustments = masks }
    }

    private static func strengthened(_ existing: MaskAdjustment, covering incoming: MaskAdjustment) -> MaskAdjustment {
        var mask = existing
        if !mask.enabled { mask.enabled = true }
        let anonymizer = AnonymizerSettings.atLeastAsStrong(target: mask.anonymizer, incoming: incoming.anonymizer)
        if anonymizer != mask.anonymizer { mask.anonymizer = anonymizer }
        if incoming.amount > mask.amount { mask.amount = incoming.amount }
        return mask
    }
}
