import Foundation
import os

nonisolated private let ffmpegLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FFmpeg")

enum FFmpegError: Error, LocalizedError {
    case ffmpegMissing
    case processFailed(String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg binary not found in app bundle"
        case .processFailed(let message):
            return "ffmpeg failed: \(message)"
        case .outputMissing:
            return "ffmpeg produced no output file"
        }
    }
}

nonisolated enum FFmpegService {

    static var ffmpegPath: String? {
        Bundle.main.path(forResource: "ffmpeg", ofType: nil)
    }

    /// Run ffmpeg asynchronously with the given arguments. Throws on failure.
    static func run(arguments: [String]) async throws {
        guard let path = ffmpegPath else {
            throw FFmpegError.ffmpegMissing
        }

        ffmpegLogger.info("Running: ffmpeg \(arguments.joined(separator: " "), privacy: .public)")

        do {
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: path),
                arguments: arguments
            )
        } catch {
            let message = error.localizedDescription
            ffmpegLogger.error("ffmpeg failed: \(message, privacy: .public)")
            throw FFmpegError.processFailed(message)
        }
    }

    // MARK: - Image Encoding

    /// Encode an image to AVIF using ffmpeg.
    /// - Parameters:
    ///   - input: Path to the input image (TIFF 16-bit recommended for HDR)
    ///   - output: Path to the output .avif file
    ///   - quality: 0.0 (worst) to 1.0 (best). Maps to CRF 63-0.
    ///   - isHDR: Whether to preserve HDR color metadata
    static func encodeAVIF(input: String, output: String, quality: Double, isHDR: Bool) async throws {
        // Map quality 0.0-1.0 to CRF 63-0 (lower CRF = better quality)
        let crf = Int((1.0 - quality) * 63.0)

        var args = ["-hide_banner", "-y", "-i", input]

        args += ["-pix_fmt", isHDR ? "yuv420p10le" : "yuv420p"]
        args += ["-c:v", "libaom-av1", "-crf", "\(crf)", "-b:v", "0"]
        args += ["-cpu-used", "6"]  // faster encoding (0=slowest, 8=fastest)
        args += ["-still-picture", "1"]
        args += [output]

        try await run(arguments: args)

        guard FileManager.default.fileExists(atPath: output) else {
            throw FFmpegError.outputMissing
        }
    }

    /// Encode an image to JPEG XL using ffmpeg.
    /// - Parameters:
    ///   - input: Path to the input image (TIFF 16-bit recommended for HDR)
    ///   - output: Path to the output .jxl file
    ///   - quality: 0.0 (worst) to 1.0 (best). Maps to distance 15-0.
    ///   - isHDR: Whether to preserve HDR color metadata
    ///   - force16Bit: Feed libjxl 16-bit RGB even for an SDR input.
    static func encodeJXL(
        input: String,
        output: String,
        quality: Double,
        isHDR: Bool,
        force16Bit: Bool = false
    ) async throws {
        let args = jxlArguments(
            input: input,
            output: output,
            quality: quality,
            isHDR: isHDR,
            force16Bit: force16Bit
        )

        try await run(arguments: args)

        guard FileManager.default.fileExists(atPath: output) else {
            throw FFmpegError.outputMissing
        }
    }

    /// Builds the libjxl invocation separately so bit-depth and quality mapping can be
    /// verified without launching the bundled executable.
    static func jxlArguments(
        input: String,
        output: String,
        quality: Double,
        isHDR: Bool,
        force16Bit: Bool = false
    ) -> [String] {
        // Map quality 0.0-1.0 to distance 15-0 (lower distance = better quality)
        let distance = (1.0 - quality) * 15.0

        var args = ["-hide_banner", "-y", "-i", input]

        if isHDR || force16Bit {
            args += ["-pix_fmt", "rgb48le"]
        }

        args += ["-c:v", "libjxl", "-distance", String(format: "%.1f", distance)]
        args += ["-effort", "7"]
        args += [output]
        return args
    }

    /// Decodes one still image to a display-sized PNG. This is the fallback used by
    /// Advanced Export when ImageIO/Core Image cannot decode formats such as AVIF or
    /// JPEG XL on the current macOS release.
    static func decodePreview(input: String, output: String, maxPixelSize: Int) async throws {
        let args = [
            "-hide_banner",
            "-y",
            "-i", input,
            "-frames:v", "1",
            "-vf", "scale=\(maxPixelSize):\(maxPixelSize):force_original_aspect_ratio=decrease",
            output
        ]
        try await run(arguments: args)
        guard FileManager.default.fileExists(atPath: output) else {
            throw FFmpegError.outputMissing
        }
    }
}
