import Foundation
import Observation

/// The immutable Camera Raw mutation requested by a successfully parsed Develop LUT import.
///
/// The coordinator deliberately does not apply this intent. The Develop view remains the owner
/// of layer lookup, undo registration, and the existing XMP or named-version persistence path.
nonisolated struct DevelopColorLUTPersistenceIntent: Equatable, Sendable {
    let layerID: UUID
    let displayName: String
    let data: Data
}

/// Testable ownership for a file importer's security-scoped URL lifetime.
nonisolated struct DevelopColorLUTSecurityScope: @unchecked Sendable {
    let start: (URL) -> Bool
    let stop: (URL) -> Void

    static let system = DevelopColorLUTSecurityScope(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Owns the image-scoped Color LUT import lifecycle for the Develop workspace.
///
/// File reading and parsing are injected test seams. Request identity supplements cooperative
/// cancellation so a superseded reader cannot publish a LUT into a replacement image or layer.
/// A successful parse emits persistence intent back to the view; it never mutates Camera Raw
/// settings or crosses the XMP/named-version write boundary itself.
@MainActor
@Observable
final class DevelopColorLUTImportCoordinator {
    typealias LoadOperation = @MainActor (URL, UUID) async throws -> ColorLUTImportResult
    typealias ParseOperation = @MainActor (Data) throws -> ParsedCubeLUT
    typealias PersistencePublisher = @MainActor (DevelopColorLUTPersistenceIntent) -> Void

    private(set) var imageURL: URL?
    private(set) var isImporterPresented = false
    private(set) var targetLayerID: UUID?
    private(set) var isImporting = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let securityScope: DevelopColorLUTSecurityScope
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    init(securityScope: DevelopColorLUTSecurityScope = .system) {
        self.securityScope = securityScope
    }

    /// Starts a new image lifetime and rejects all publication from the previous image.
    func beginImageSession(_ imageURL: URL?) {
        invalidateImport(clearTarget: true)
        self.imageURL = imageURL
        isImporterPresented = false
        errorMessage = nil
    }

    /// Ends presentation ownership and releases any active security-scoped import lifetime.
    func endImageSession() {
        beginImageSession(nil)
    }

    /// Presents the importer for one concrete layer. A workspace without an image cannot import.
    @discardableResult
    func requestImport(for layerID: UUID) -> Bool {
        guard imageURL != nil else { return false }
        invalidateImport(clearTarget: true)
        targetLayerID = layerID
        isImporterPresented = true
        errorMessage = nil
        return true
    }

    /// SwiftUI dismisses a file importer before delivering its result. Preserve the target until
    /// `acceptSelection` consumes that callback; image/session lifecycle still clears it eagerly.
    func setImporterPresented(_ presented: Bool) {
        isImporterPresented = presented
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Consumes the file-importer result and starts one cancellable read/parse request.
    func acceptSelection(
        _ selection: Result<[URL], any Error>,
        load: @escaping LoadOperation,
        parse: @escaping ParseOperation,
        publisher: @escaping PersistencePublisher
    ) {
        guard imageURL != nil, let layerID = targetLayerID else { return }

        isImporterPresented = false
        invalidateImport(clearTarget: true)

        let sourceURL: URL
        do {
            guard let selectedURL = try selection.get().first else { return }
            sourceURL = selectedURL
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let accessed = securityScope.start(sourceURL)
        let securityScope = securityScope
        let currentRequestID = requestID
        isImporting = true
        errorMessage = nil

        importTask = Task { [weak self] in
            defer {
                if accessed {
                    securityScope.stop(sourceURL)
                }
            }

            do {
                let result = try await load(sourceURL, currentRequestID)
                guard let self,
                      !Task.isCancelled,
                      requestID == currentRequestID else { return }

                switch result {
                case let .loaded(snapshot):
                    guard snapshot.requestID == currentRequestID else {
                        finishImport(requestID: currentRequestID)
                        return
                    }
                    let parsed = try parse(snapshot.data)
                    guard !Task.isCancelled, requestID == currentRequestID else { return }
                    let trimmedTitle = parsed.title?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = trimmedTitle.flatMap { $0.isEmpty ? nil : $0 }
                        ?? snapshot.sourceURL.deletingPathExtension().lastPathComponent
                    publisher(DevelopColorLUTPersistenceIntent(
                        layerID: layerID,
                        displayName: displayName,
                        data: snapshot.data
                    ))
                    finishImport(requestID: currentRequestID)
                case .cancelledBeforeRead, .cancelledAfterRead:
                    finishImport(requestID: currentRequestID)
                }
            } catch is CancellationError {
                self?.finishImport(requestID: currentRequestID)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      requestID == currentRequestID else { return }
                errorMessage = error.localizedDescription
                finishImport(requestID: currentRequestID)
            }
        }
    }

    func cancelImport() {
        invalidateImport(clearTarget: true)
        isImporterPresented = false
    }

    private func invalidateImport(clearTarget: Bool) {
        importTask?.cancel()
        importTask = nil
        requestID = UUID()
        isImporting = false
        if clearTarget {
            targetLayerID = nil
        }
    }

    private func finishImport(requestID completedRequestID: UUID) {
        guard requestID == completedRequestID else { return }
        importTask = nil
        isImporting = false
    }
}
