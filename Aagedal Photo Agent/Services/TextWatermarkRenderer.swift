import Foundation
import CoreGraphics
import CoreText
import ImageIO

nonisolated enum TextWatermarkFontFamily: String, CaseIterable, Identifiable, Sendable {
    case system, serif, monospaced
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .monospaced: return "Monospaced"
        }
    }
}

nonisolated struct TextWatermarkColor: Hashable, Sendable {
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
    var alpha: Double = 1
    static let white = TextWatermarkColor()
}

nonisolated struct TextWatermarkConfiguration: Hashable, Sendable {
    var text: String
    var fontFamily: TextWatermarkFontFamily = .system
    var fontSize: Double = 96
    var bold: Bool = false
    var italic: Bool = false
    var color: TextWatermarkColor = .white
}

nonisolated enum TextWatermarkError: Error, LocalizedError, Equatable {
    case emptyText, textTooLong, invalidFontSize, invalidColor, canvasTooLarge, renderingFailed
    var errorDescription: String? {
        switch self {
        case .emptyText: return "Enter some visible text for the overlay."
        case .textTooLong: return "Text overlays support up to 2,048 characters."
        case .invalidFontSize: return "Choose a font size between 8 and 512 pixels."
        case .invalidColor: return "Choose a visible text color."
        case .canvasTooLarge: return "This overlay exceeds 4,096 pixels. Use shorter text, more lines, or a smaller font."
        case .renderingFailed: return "The text overlay could not be rendered."
        }
    }
}

/// CoreText, bitmap allocation, PNG encoding and temporary-file I/O stay on a retained
/// serial executor. The resulting PNG uses the same immutable library and export path as imports.
actor TextWatermarkRenderer {
    static let shared = TextWatermarkRenderer()
    nonisolated let renderQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        renderQueue.asUnownedSerialExecutor()
    }

    init(renderQueue: DispatchSerialQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.watermark.text", qos: .userInitiated
    )) {
        self.renderQueue = renderQueue
    }

    func renderPNG(configuration: TextWatermarkConfiguration) throws -> Data {
        try Task.checkCancellation()
        guard !configuration.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextWatermarkError.emptyText
        }
        guard configuration.text.utf16.count <= 2_048 else { throw TextWatermarkError.textTooLong }
        guard configuration.fontSize.isFinite, (8...512).contains(configuration.fontSize) else {
            throw TextWatermarkError.invalidFontSize
        }
        let rgba = configuration.color
        guard [rgba.red, rgba.green, rgba.blue, rgba.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              rgba.alpha > 0 else { throw TextWatermarkError.invalidColor }
        let size = CGFloat(configuration.fontSize)
        let baseFont: CTFont
        switch configuration.fontFamily {
        case .system:
            guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else {
                throw TextWatermarkError.renderingFailed
            }
            baseFont = font
        case .serif: baseFont = CTFontCreateWithName("Georgia" as CFString, size, nil)
        case .monospaced: baseFont = CTFontCreateWithName("Menlo" as CFString, size, nil)
        }
        var traits: CTFontSymbolicTraits = []
        if configuration.bold { traits.insert(.boldTrait) }
        if configuration.italic { traits.insert(.italicTrait) }
        let font = traits.isEmpty ? baseFont : CTFontCreateCopyWithSymbolicTraits(
            baseFont, size, nil, traits, traits
        ) ?? baseFont
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let color = CGColor(colorSpace: colorSpace, components: [rgba.red, rgba.green, rgba.blue, rgba.alpha].map { CGFloat($0) }) else {
            throw TextWatermarkError.invalidColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let normalized = configuration.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes) as CFAttributedString)
        }
        let lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + max(CTFontGetLeading(font), size * 0.15))
        var bounds = CGRect.null
        for (index, line) in lines.enumerated() {
            let baseline = -CGFloat(index) * lineHeight
            var lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if !lineBounds.isNull { lineBounds.origin.y += baseline; bounds = bounds.union(lineBounds) }
            // Include spaces and empty lines as well as glyph overhangs.
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            // Fallback fonts (including color emoji without outline bounds) can extend
            // beyond the selected font's metrics. Empty lines still retain normal spacing.
            ascent = max(ascent, CTFontGetAscent(font))
            descent = max(descent, CTFontGetDescent(font))
            bounds = bounds.union(CGRect(x: 0, y: baseline - descent,
                                         width: max(1, advance), height: ascent + descent))
        }
        let padding = max(2, ceil(size * 0.08))
        let width = ceil(bounds.width + padding * 2)
        let height = ceil(bounds.height + padding * 2)
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 4_096, height <= 4_096 else {
            throw TextWatermarkError.canvasTooLarge
        }
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw TextWatermarkError.renderingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: padding - bounds.minX,
                                           y: padding - bounds.minY - CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw TextWatermarkError.renderingFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw TextWatermarkError.renderingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TextWatermarkError.renderingFailed }
        try Task.checkCancellation()
        return output as Data
    }

    func createTemporaryPNG(configuration: TextWatermarkConfiguration) throws -> URL {
        let data = try renderPNG(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-text-watermark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("overlay.png")
        do {
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func removeTemporaryPNG(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
