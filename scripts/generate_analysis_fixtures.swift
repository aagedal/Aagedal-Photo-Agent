#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates the small CC0 corpus used for Pixel Analysis alignment, decode, residual, and
/// malformed-input validation. The pixels and metadata are original deterministic recipes; no
/// third-party photographs, camera files, signatures, or personal data are included.
///
/// Run from the repository root:
///
///     swift -module-cache-path /private/tmp/aagedal-analysis-fixture-module-cache \
///       scripts/generate_analysis_fixtures.swift

private let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Aagedal Photo Agent Tests/Fixtures/AnalysisCorpus", isDirectory: true)
private let width = 48
private let height = 32

enum FixtureGenerationError: Error, CustomStringConvertible {
    case context
    case image
    case source(String)
    case destination(String)
    case finalize(String)

    var description: String {
        switch self {
        case .context: "Could not create a bitmap context"
        case .image: "Could not create a fixture image"
        case .source(let name): "Could not decode the generated source \(name)"
        case .destination(let name): "Could not create the destination for \(name)"
        case .finalize(let name): "Could not finalize \(name)"
        }
    }
}

typealias PixelRecipe = (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)

func makeImage(width: Int = width, height: Int = height, recipe: PixelRecipe) throws -> CGImage {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let (red, green, blue, alpha) = recipe(x, y)
            // The context expects premultiplied-last RGBA.
            pixels[offset] = UInt8((UInt16(red) * UInt16(alpha)) / 255)
            pixels[offset + 1] = UInt8((UInt16(green) * UInt16(alpha)) / 255)
            pixels[offset + 2] = UInt8((UInt16(blue) * UInt16(alpha)) / 255)
            pixels[offset + 3] = alpha
        }
    }

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw FixtureGenerationError.context }
    guard let image = context.makeImage() else { throw FixtureGenerationError.image }
    return image
}

func write(
    _ images: [CGImage],
    type: UTType,
    filename: String,
    properties: [[CFString: Any]] = []
) throws {
    let url = outputDirectory.appendingPathComponent(filename)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        images.count,
        nil
    ) else { throw FixtureGenerationError.destination(filename) }

    for (index, image) in images.enumerated() {
        let itemProperties = index < properties.count ? properties[index] : [:]
        CGImageDestinationAddImage(destination, image, itemProperties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw FixtureGenerationError.finalize(filename)
    }
}

func decode(_ filename: String) throws -> CGImage {
    let url = outputDirectory.appendingPathComponent(filename)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw FixtureGenerationError.source(filename) }
    return image
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let coordinateGrid = try makeImage(width: 16, height: 12) { x, y in
    let alpha = UInt8((x * 17 + y * 29) & 0xff)
    return (UInt8(x * 16), UInt8(y * 21), UInt8((x * 11 + y * 7) & 0xff), alpha)
}
try write([coordinateGrid], type: .png, filename: "known-pixels-alpha.png")

let photographicGradient = try makeImage { x, y in
    let radial = max(0, 255 - ((x - 24) * (x - 24) + (y - 16) * (y - 16)) / 3)
    let texture = ((x * 37 + y * 19 + (x * y * 3)) & 31) - 16
    return (
        UInt8(clamping: 34 + x * 3 + texture),
        UInt8(clamping: 52 + y * 4 + radial / 5 + texture),
        UInt8(clamping: 98 + (x + y) * 2 + texture),
        255
    )
}
try write([photographicGradient], type: .png, filename: "photographic-gradient.png")
try write(
    [photographicGradient],
    type: .jpeg,
    filename: "jpeg-single-q82.jpg",
    properties: [[kCGImageDestinationLossyCompressionQuality: 0.82]]
)
try write(
    [try decode("jpeg-single-q82.jpg")],
    type: .jpeg,
    filename: "jpeg-double-q82-q60.jpg",
    properties: [[kCGImageDestinationLossyCompressionQuality: 0.60]]
)

let scanHalftone = try makeImage { x, y in
    let paper = 224 + ((x * 5 + y * 3) & 15)
    let dot = ((x % 6) < 2 && (y % 6) < 2) ? -130 : 0
    let scratch = (x == 17 || y == 23) ? -45 : 0
    let value = UInt8(clamping: paper + dot + scratch)
    return (value, UInt8(clamping: Int(value) - 4), UInt8(clamping: Int(value) - 12), 255)
}
try write([scanHalftone], type: .png, filename: "simulated-scan-halftone.png")

let benignComposite = try makeImage { x, y in
    let inPatch = (12..<36).contains(x) && (8..<24).contains(y)
    if inPatch {
        let edge = min(x - 12, 35 - x, y - 8, 23 - y)
        let blend = min(255, max(0, edge * 64))
        let background = (48 + x * 2, 80 + y * 3, 122 + (x + y))
        let foreground = (188, 86 + y * 2, 54 + x)
        return (
            UInt8((foreground.0 * blend + background.0 * (255 - blend)) / 255),
            UInt8((foreground.1 * blend + background.1 * (255 - blend)) / 255),
            UInt8((foreground.2 * blend + background.2 * (255 - blend)) / 255),
            255
        )
    }
    return (UInt8(48 + x * 2), UInt8(80 + y * 3), UInt8(122 + x + y), 255)
}
try write([benignComposite], type: .png, filename: "benign-composite.png")

let orientationMarker = try makeImage(width: 12, height: 8) { x, y in
    if x < 4 && y < 3 { return (240, 30, 20, 255) }
    if x >= 8 && y >= 5 { return (20, 70, 240, 255) }
    return (UInt8(40 + x * 10), UInt8(50 + y * 18), 90, 255)
}
for orientation in 1...8 {
    try write(
        [orientationMarker],
        type: .tiff,
        filename: "orientation-\(orientation).tiff",
        properties: [[kCGImagePropertyOrientation: orientation]]
    )
}

let secondFrame = try makeImage(width: 12, height: 8) { x, y in
    (UInt8(220 - x * 10), UInt8(40 + y * 20), 52, 255)
}
try write(
    [orientationMarker, secondFrame],
    type: .gif,
    filename: "animated-two-frame.gif",
    properties: [
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]],
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]],
    ]
)
try write(
    [orientationMarker, secondFrame],
    type: .tiff,
    filename: "multi-frame.tiff"
)

try Data([0xff, 0xd8, 0xff, 0xe1, 0x00, 0x40, 0x01]).write(
    to: outputDirectory.appendingPathComponent("malformed-truncated.jpg"),
    options: .atomic
)

print("Generated CC0 analysis fixtures in \(outputDirectory.path)")
