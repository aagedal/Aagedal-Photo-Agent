import Foundation
import os

nonisolated(unsafe) private let ffmpegLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FFmpeg")

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

    /// Run ffmpeg synchronously with the given arguments. Throws on failure.
    static func run(arguments: [String]) throws {
        guard let path = ffmpegPath else {
            throw FFmpegError.ffmpegMissing
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        ffmpegLogger.info("Running: ffmpeg \(arguments.joined(separator: " "), privacy: .public)")

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            ffmpegLogger.error("ffmpeg failed (\(process.terminationStatus)): \(message, privacy: .public)")
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
    static func encodeAVIF(input: String, output: String, quality: Double, isHDR: Bool) throws {
        // Map quality 0.0-1.0 to CRF 63-0 (lower CRF = better quality)
        let crf = Int((1.0 - quality) * 63.0)

        var args = ["-hide_banner", "-y", "-i", input]

        if isHDR {
            args += ["-pix_fmt", "yuv420p10le"]
            args += ["-color_primaries", "bt2020"]
            args += ["-color_trc", "arib-std-b67"]  // HLG
            args += ["-colorspace", "bt2020nc"]
        } else {
            args += ["-pix_fmt", "yuv420p"]
        }

        args += ["-c:v", "libaom-av1", "-crf", "\(crf)", "-b:v", "0"]
        args += ["-cpu-used", "6"]  // faster encoding (0=slowest, 8=fastest)
        args += ["-still-picture", "1"]
        args += [output]

        try run(arguments: args)

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
    static func encodeJXL(input: String, output: String, quality: Double, isHDR: Bool) throws {
        // Map quality 0.0-1.0 to distance 15-0 (lower distance = better quality)
        let distance = (1.0 - quality) * 15.0

        var args = ["-hide_banner", "-y", "-i", input]

        if isHDR {
            args += ["-pix_fmt", "rgb48le"]
            args += ["-color_primaries", "bt2020"]
            args += ["-color_trc", "arib-std-b67"]  // HLG
            args += ["-colorspace", "bt2020nc"]
        }

        args += ["-c:v", "libjxl", "-distance", String(format: "%.1f", distance)]
        args += ["-effort", "7"]
        args += [output]

        try run(arguments: args)

        guard FileManager.default.fileExists(atPath: output) else {
            throw FFmpegError.outputMissing
        }
    }
}
