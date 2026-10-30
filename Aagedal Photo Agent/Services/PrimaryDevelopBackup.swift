import CryptoKit
import Foundation
import SwiftMediaMetadata

/// A Develop edit whose save failed is copied to a standalone `.xmp` file, so it survives
/// leaving Develop or quitting even though it never reached the photo's own sidecar. The file is
/// a regular sidecar (crs + app-private develop block, descriptive metadata), so Photo Agent,
/// Camera Raw and Lightroom can read it once it's placed next to the photo.
nonisolated enum PrimaryDevelopBackup {
    @TaskLocal static var rootOverride: URL?

    /// `~/Library/Application Support/Aagedal Photo Agent/Develop Backups`. Test runs never
    /// write into the user's real Application Support.
    static var root: URL {
        if let rootOverride { return rootOverride }
        if AppPaths.isTestProcess {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("PhotoAgentTests-DevelopBackups", isDirectory: true)
        }
        return AppPaths.applicationSupport.appendingPathComponent("Develop Backups", isDirectory: true)
    }

    /// One subfolder per photo folder (its name plus a short path hash, so two folders with the
    /// same name don't share backups). A paired JPEG's develop is its own, so its backup is
    /// named after the full file name instead of the stem shared with the RAW.
    static func url(for imageURL: URL, pairedWithRAW: Bool = false) -> URL {
        let folder = imageURL.deletingLastPathComponent().standardizedFileURL
        let hash = SHA256.hash(data: Data(folder.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("\(folder.lastPathComponent) \(hash)", isDirectory: true)
        let name = pairedWithRAW
            ? imageURL.lastPathComponent + ".xmp"
            : XMPSidecarService().sidecarURL(for: imageURL).lastPathComponent
        return directory.appendingPathComponent(name)
    }

    static func data(for metadata: IPTCMetadata, imageURL: URL) -> Data {
        var xmp = XMPData()
        XMPDataBuilder.applyDescriptive(metadata, into: &xmp)
        let crop = metadata.cameraRaw?.crop
        let aspect = abs(crop?.angle ?? 0) > 0.0001 ? ImagePixelAspect.aspect(at: imageURL) : nil
        XMPDataBuilder.applyCameraRaw(metadata.cameraRaw, imageAspect: aspect, into: &xmp)
        xmp.creatorTool = SwiftExifWriteEngine.creatorTool
        return Data(XMPWriter.generateXML(xmp).utf8)
    }

    @discardableResult
    static func write(_ request: PrimaryDevelopWriteRequest) throws -> URL {
        let url = url(for: request.imageURL, pairedWithRAW: request.embedsDevelopOnly)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(for: request.edited, imageURL: request.imageURL).write(to: url, options: .atomic)
        return url
    }

    static let retiredExtension = "retired"

    /// A newer Develop save of the photo landed, so a backup left from an earlier session (a
    /// quit, a crash, a Review discard) is no longer offered. It stays in Finder until the next
    /// launch (`purgeRetired`), in case the newer save wasn't what the user wanted after all.
    static func retire(at url: URL) {
        let retired = url.appendingPathExtension(retiredExtension)
        try? FileManager.default.removeItem(at: retired)
        try? FileManager.default.moveItem(at: url, to: retired)
    }

    /// Deletes backups retired in an earlier session. Run once at launch, off the main thread.
    static func purgeRetired(in root: URL = PrimaryDevelopBackup.root) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == retiredExtension {
                remove(at: file)
            }
        }
    }

    /// Called once the photo's edit has been saved for real; an emptied folder is removed too.
    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
