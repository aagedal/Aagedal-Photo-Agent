import Foundation
import Observation

/// Tells the Develop workspace whether a layer-chain mutation needs to cross the metadata or
/// named-version persistence boundary. Pointer-only selection and drag state never return
/// `.commit`.
nonisolated enum DevelopLayerPersistenceIntent: Equatable, Sendable {
    case unchanged
    case commit
}

/// Owns the Develop layer strip's image-scoped selection and transient interaction state.
///
/// Rendering and persistence stay at the workspace boundary. Durable layer-chain operations
/// mutate the value passed into the coordinator and return an explicit persistence intent, so
/// rename, reorder, and deletion share one testable policy without writing XMP themselves.
@MainActor
@Observable
final class DevelopLayerSessionCoordinator {
    private(set) var activeImageURL: URL?
    var selectedLayer: LayerRef = .global
    var draggingLayer: LayerRef?
    var dropTargetLayer: LayerRef?
    var hoveredLayer: LayerRef?
    var hoveredAddLayerKind: LayerKind?
    private(set) var isShowingRename = false
    private(set) var layerBeingRenamed: LayerRef?
    var nameDraft = ""

    /// This is a workspace-level viewing preference, so image navigation deliberately preserves
    /// it while all image-specific layer state is reset.
    var showsMaskOutlines = true

    func beginImageSession(_ imageURL: URL?) {
        activeImageURL = imageURL
        resetImageScopedState()
    }

    func endImageSession() {
        activeImageURL = nil
        resetImageScopedState()
    }

    func cancelRename() {
        isShowingRename = false
        layerBeingRenamed = nil
        nameDraft = ""
    }

    @discardableResult
    func beginRename(_ ref: LayerRef, in settings: CameraRawSettings?) -> Bool {
        guard let name = layerName(for: ref, in: settings), ref != .global else { return false }
        selectedLayer = ref
        layerBeingRenamed = ref
        nameDraft = name
        isShowingRename = true
        return true
    }

    @discardableResult
    func commitRename(
        in settings: inout CameraRawSettings
    ) -> DevelopLayerPersistenceIntent {
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ref = layerBeingRenamed, !trimmedName.isEmpty else {
            cancelRename()
            return .unchanged
        }

        let intent: DevelopLayerPersistenceIntent
        switch ref {
        case .global:
            intent = .unchanged
        case .mask(let id):
            guard let index = settings.localAdjustments?.firstIndex(where: { $0.id == id }),
                  settings.localAdjustments?[index].name != trimmedName else {
                cancelRename()
                return .unchanged
            }
            settings.localAdjustments?[index].name = trimmedName
            intent = .commit
        case .watermark(let id):
            guard let index = settings.watermarkLayers?.firstIndex(where: { $0.id == id }),
                  settings.watermarkLayers?[index].name != trimmedName else {
                cancelRename()
                return .unchanged
            }
            settings.watermarkLayers?[index].name = trimmedName
            intent = .commit
        }

        cancelRename()
        return intent
    }

    @discardableResult
    func reorder(
        _ dragged: LayerRef,
        onto target: LayerRef,
        in settings: inout CameraRawSettings
    ) -> DevelopLayerPersistenceIntent {
        guard dragged != target else { return .unchanged }
        var order = settings.resolvedLayerOrder()
        guard let from = order.firstIndex(of: dragged) else { return .unchanged }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return .unchanged }
        order.insert(dragged, at: to)
        guard order != settings.resolvedLayerOrder() else { return .unchanged }
        settings.layerOrder = order
        return .commit
    }

    @discardableResult
    func deleteSelectedLayer(
        in settings: inout CameraRawSettings
    ) -> DevelopLayerPersistenceIntent {
        switch selectedLayer {
        case .global:
            return .unchanged
        case .mask(let id):
            guard let layers = settings.localAdjustments,
                  let index = layers.firstIndex(where: { $0.id == id }) else {
                selectedLayer = .global
                return .unchanged
            }
            settings.localAdjustments?.remove(at: index)
            settings.layerOrder?.removeAll { $0 == .mask(id) }
            if settings.localAdjustments?.isEmpty == true {
                settings.localAdjustments = nil
            }
            let remaining = settings.localAdjustments ?? []
            selectedLayer = remaining.isEmpty
                ? .global
                : .mask(remaining[min(index, remaining.count - 1)].id)
            return .commit
        case .watermark(let id):
            guard let layers = settings.watermarkLayers,
                  let index = layers.firstIndex(where: { $0.id == id }) else {
                selectedLayer = .global
                return .unchanged
            }
            settings.watermarkLayers?.remove(at: index)
            settings.layerOrder?.removeAll { $0 == .watermark(id) }
            if settings.watermarkLayers?.isEmpty == true {
                settings.watermarkLayers = nil
            }
            let remaining = settings.watermarkLayers ?? []
            selectedLayer = remaining.isEmpty
                ? .global
                : .watermark(remaining[min(index, remaining.count - 1)].id)
            return .commit
        }
    }

    private func resetImageScopedState() {
        selectedLayer = .global
        draggingLayer = nil
        dropTargetLayer = nil
        hoveredLayer = nil
        hoveredAddLayerKind = nil
        cancelRename()
    }

    private func layerName(for ref: LayerRef, in settings: CameraRawSettings?) -> String? {
        switch ref {
        case .global:
            return "Global"
        case .mask(let id):
            return settings?.localAdjustments?.first(where: { $0.id == id })?.name
        case .watermark(let id):
            return settings?.watermarkLayers?.first(where: { $0.id == id })?.name
        }
    }
}
