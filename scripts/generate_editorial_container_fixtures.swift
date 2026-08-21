#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates the small, synthetic container fixtures used by
/// `EditorialContainerFixtureTests`. The source pixels are an original deterministic gradient;
/// no third-party photographs or metadata are included.
///
/// Run from the repository root:
///
///     swift -module-cache-path /private/tmp/aagedal-swift-module-cache \
///       scripts/generate_editorial_container_fixtures.swift

private let fixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Aagedal Photo Agent Tests/Fixtures/EditorialMetadata", isDirectory: true)
private let width = 16
private let height = 12

enum GenerationError: Error, CustomStringConvertible {
    case context
    case image
    case destination(String)
    case finalize(String)
    case ffmpegMissing(String)
    case ffmpegFailed(Int32, String)

    var description: String {
        switch self {
        case .context: "Could not create the deterministic bitmap context"
        case .image: "Could not create the deterministic CGImage"
        case .destination(let type): "ImageIO cannot create a \(type) destination"
        case .finalize(let type): "ImageIO could not finalize the \(type) fixture"
        case .ffmpegMissing(let path): "The bundled FFmpeg executable is missing at \(path)"
        case .ffmpegFailed(let status, let message):
            "Bundled FFmpeg exited with status \(status): \(message)"
        }
    }
}

func makeImage() throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            pixels[offset] = UInt8((x * 17 + y * 3) & 0xff)
            pixels[offset + 1] = UInt8((x * 5 + y * 19) & 0xff)
            pixels[offset + 2] = UInt8((x * 11 + y * 7) & 0xff)
            pixels[offset + 3] = 255
        }
    }

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw GenerationError.context
    }
    guard let image = context.makeImage() else { throw GenerationError.image }
    return image
}

func writeImage(_ image: CGImage, type: UTType, filename: String, properties: [CFString: Any]) throws {
    let url = fixtureDirectory.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        1,
        nil
    ) else {
        throw GenerationError.destination(type.identifier)
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw GenerationError.finalize(type.identifier)
    }
}

func writeJPEGXL(from input: URL, to output: URL) throws {
    let ffmpeg = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Aagedal Photo Agent/Resources/ffmpeg")
    guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
        throw GenerationError.ffmpegMissing(ffmpeg.path)
    }

    let process = Process()
    let stderr = Pipe()
    process.executableURL = ffmpeg
    process.arguments = [
        "-hide_banner", "-loglevel", "error", "-y",
        "-i", input.path,
        "-frames:v", "1",
        "-c:v", "libjxl",
        "-distance", "0",
        "-effort", "7",
        output.path,
    ]
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        throw GenerationError.ffmpegFailed(process.terminationStatus, message)
    }
}

func removeImageIOTemporaries(for output: URL) {
    let prefix = ".\(output.lastPathComponent)-"
    let directory = output.deletingLastPathComponent()
    guard let siblings = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ) else { return }
    for sibling in siblings where sibling.lastPathComponent.hasPrefix(prefix) {
        try? FileManager.default.removeItem(at: sibling)
    }
}

try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
let image = try makeImage()

try writeImage(
    image,
    type: .tiff,
    filename: "synthetic-gradient.tiff",
    properties: [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFCompression: 5,
            kCGImagePropertyTIFFSoftware: "Aagedal Photo Agent fixture generator",
        ],
    ]
)
try writeImage(image, type: .png, filename: "synthetic-gradient.png", properties: [:])
try writeJPEGXL(
    from: fixtureDirectory.appendingPathComponent("synthetic-gradient.png"),
    to: fixtureDirectory.appendingPathComponent("synthetic-gradient.jxl")
)
let heicURL = fixtureDirectory.appendingPathComponent("synthetic-gradient.heic")
removeImageIOTemporaries(for: heicURL)
do {
    defer { removeImageIOTemporaries(for: heicURL) }
    try writeImage(
        image,
        type: .heic,
        filename: heicURL.lastPathComponent,
        properties: [kCGImageDestinationLossyCompressionQuality: 1.0]
    )
} catch {
    // Sandboxed builders commonly advertise public.heic but cannot reach the hardware-backed
    // encoder. Leave no empty/corrupt fixture behind. The test corpus records this as an explicit
    // unavailable external artifact instead of treating the advertised UTI as round-trip proof.
    try? FileManager.default.removeItem(at: heicURL)
    FileHandle.standardError.write(Data("HEIC not generated: \(error)\n".utf8))
}

let rawSidecar = #"""
<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Aagedal Photo Agent synthetic fixture">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
      xmlns:iptcExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
      xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
      xmlns:fixture="https://aagedal.example/ns/fixture/1.0/"
      photoshop:Headline="Synthetic RAW sidecar headline"
      iptcExt:DigitalSourceType="http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
      crs:Exposure2012="+0.35"
      fixture:provenance="original-generated-cc0">
      <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Synthetic RAW sidecar caption — no camera original is distributed.</rdf:li></rdf:Alt></dc:description>
      <dc:subject><rdf:Bag><rdf:li>synthetic</rdf:li><rdf:li>sidecar</rdf:li></rdf:Bag></dc:subject>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""#
try Data(rawSidecar.utf8).write(
    to: fixtureDirectory.appendingPathComponent("synthetic-raw-sidecar.xmp"),
    options: .atomic
)

print("Generated TIFF, PNG, JPEG XL, RAW-sidecar, and HEIC when available in \(fixtureDirectory.path)")
