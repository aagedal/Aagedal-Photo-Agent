import AppKit
import Foundation

nonisolated enum AdobeDNGCompression: Sendable {
    case lossless
    case lossy

    var commandLineOption: String {
        switch self {
        case .lossless: return "-c"
        case .lossy: return "-lossy"
        }
    }
}

nonisolated enum AdobeDNGConverterError: LocalizedError {
    case notInstalled
    case noOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Adobe DNG Converter is not installed. Download and install the free converter from Adobe, then try again."
        case .noOutput(let filename):
            return "Adobe DNG Converter completed without creating \(filename)."
        }
    }
}

nonisolated enum AdobeDNGConverterService {
    static let bundleIdentifier = "com.adobe.DNGConverter"
    static let downloadURL = URL(
        string: "https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html"
    )!

    /// Resolve through Launch Services so non-standard application locations work, with
    /// explicit Applications-folder fallbacks because Adobe's installer does not always
    /// leave the converter registered in the current Launch Services database.
    @MainActor
    static var installedExecutableURL: URL? {
        var applicationURLs: [URL] = []
        if let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            applicationURLs.append(registeredURL)
        }
        applicationURLs.append(
            URL(fileURLWithPath: "/Applications/Adobe DNG Converter.app", isDirectory: true)
        )
        applicationURLs.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Adobe DNG Converter.app", isDirectory: true)
        )

        for applicationURL in applicationURLs {
            if let executable = executableURL(in: applicationURL) {
                return executable
            }
        }
        return nil
    }

    nonisolated static func executableURL(in applicationURL: URL) -> URL? {
        let executable = applicationURL
            .appendingPathComponent("Contents/MacOS/Adobe DNG Converter")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        return executable
    }

    nonisolated static func conversionArguments(
        sourceURL: URL,
        destinationURL: URL,
        compression: AdobeDNGCompression
    ) -> [String] {
        [
            compression.commandLineOption,
            "-d", destinationURL.deletingLastPathComponent().path,
            "-o", destinationURL.lastPathComponent,
            sourceURL.path
        ]
    }

    @discardableResult
    nonisolated static func convert(
        sourceURL: URL,
        destinationFolder: URL,
        compression: AdobeDNGCompression,
        executableURL: URL
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AdobeDNGConverterError.notInstalled
        }

        let destinationURL = RAWArchiveService.uniqueDestinationURL(
            for: sourceURL,
            in: destinationFolder,
            extension: "dng"
        )
        let arguments = conversionArguments(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            compression: compression
        )
        do {
            _ = try await Process.run(
                executableURL: executableURL,
                arguments: arguments
            )
        } catch {
            // The converter may leave an incomplete destination after failure or
            // cancellation. It is newly created by this operation and safe to discard.
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw AdobeDNGConverterError.noOutput(destinationURL.lastPathComponent)
        }

        do {
            try RAWArchiveService.copySidecarIfPresent(
                from: sourceURL,
                to: destinationURL
            )
        } catch {
            // Avoid reporting a complete archive when its authoritative RAW
            // develop sidecar could not be preserved.
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return destinationURL
    }
}
