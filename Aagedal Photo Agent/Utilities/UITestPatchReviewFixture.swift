import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Opt-in native smoke fixture. Authorization and plans never enter production preferences or
/// helper storage. Each launch owns a unique photo; the caller owns disposable-folder cleanup.
enum UITestPatchReviewFixture {
    // SwiftUI can construct discarded reference-model initializers while retaining @State.
    // Keep one fixture/manifest pair for the lifetime of this explicitly opted-in test process.
    private static let currentService = Result { try makeService(configuration: .current) }

    static func currentServiceForModel() throws -> AutomationPatchReviewService? {
        try currentService.get()
    }

    private nonisolated final class ConfigurationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
        func write(_ value: Data?) {
            lock.lock()
            defer { lock.unlock() }
            data = value
        }
    }

    private struct Manifest: Encodable {
        let planID: String
        let photoPath: String
        let beforeTitle: String
        let afterTitle: String
        let beforeCity: String
    }

    enum Failure: Error, Equatable { case invalidFolder, imageCreation, invalidPlan }

    static func makeService(configuration: UITestLaunchConfiguration = .current) throws -> AutomationPatchReviewService? {
        guard configuration.isEnabled, configuration.patchReviewRequested else { return nil }
        guard let requestedFolder = configuration.patchReviewFolderURL else { throw Failure.invalidFolder }
        let folder = requestedFolder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Failure.invalidFolder }
        let root = folder.appendingPathComponent("patch-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let photo = root.appendingPathComponent("review.jpg")
            // ASCII before values make carrier decoding independent of legacy IPTC encodings;
            // proposed Unicode exercises exact text presentation from the production planner.
            let beforeTitle = "Original title"
            let afterTitle = "Blåbær – 東京 📷"
            let beforeCity = "Bergen"
            guard let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = context.makeImage() else { throw Failure.imageCreation }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else {
                throw Failure.imageCreation
            }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCHeadline: beforeTitle,
                kCGImagePropertyIPTCCity: beforeCity,
            ]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.imageCreation }
            try (bytes as Data).write(to: photo, options: .withoutOverwriting)
            let box = ConfigurationBox()
            let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
            try authority.addRoot(root)
            try authority.setEnabled(true)
            let facade = MCPAutomationFacade(authorizationStore: authority)
            let plans = MCPIPTCPatchPlanStore()
            guard let metadata = try MCPMetadataSnapshotReader.inspectPhoto(path: photo.path, facade: facade).objectValue else {
                throw Failure.invalidPlan
            }
            var arguments: [String: MCPJSONValue] = ["path": .string(photo.path), "operations": .array([
                .object(["field": .string("title"), "operation": .string("set"), "value": .string(afterTitle)]),
                .object(["field": .string("city"), "operation": .string("clear")]),
            ])]
            for key in ["sourceRevision", "xmpSidecarRevision", "appSidecarRevision"] { arguments[key] = metadata[key] }
            let prepared = try MCPIPTCPatchPreparation.prepare(arguments: arguments, facade: facade, plans: plans)
            guard let id = prepared.objectValue?["planID"]?.stringValue else { throw Failure.invalidPlan }
            let manifest = Manifest(planID: id, photoPath: photo.path, beforeTitle: beforeTitle,
                afterTitle: afterTitle, beforeCity: beforeCity)
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("patch-review-fixture.json"), options: .atomic)
            guard let canonical = realpath(folder.path, nil) else { throw Failure.invalidFolder }
            defer { free(canonical) }
            let operationFolder = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
                .appendingPathComponent("patch-operations")
            return AutomationPatchReviewService(plans: plans, facade: facade,
                operationRegistry: AutomationOperationRegistry(storageDirectory: operationFolder))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
