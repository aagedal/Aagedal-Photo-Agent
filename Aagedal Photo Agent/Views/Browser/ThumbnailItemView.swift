import AppKit
import QuartzCore

/// Data needed to configure a thumbnail cell, extracted from ImageFile to avoid passing the full model.
struct ThumbnailCellData: Equatable {
    let url: URL
    let filename: String
    let starRating: StarRating
    let colorLabel: ColorLabel
    let hasC2PA: Bool
    let hasDevelopEdits: Bool
    let hasCropEdits: Bool
    let isHDR: Bool
    let hasPendingMetadataChanges: Bool
    let pendingFieldNames: [String]

    init(from image: ImageFile) {
        self.url = image.url
        self.filename = image.filename
        self.starRating = image.starRating
        self.colorLabel = image.colorLabel
        self.hasC2PA = image.hasC2PA
        self.hasDevelopEdits = image.hasDevelopEdits
        self.hasCropEdits = image.hasCropEdits
        self.isHDR = image.cameraRawSettings?.hdrEditMode == 1
        self.hasPendingMetadataChanges = image.hasPendingMetadataChanges
        self.pendingFieldNames = image.pendingFieldNames
    }
}

/// Layer-backed NSView that renders a single thumbnail cell.
final class ThumbnailItemView: NSView {
    // MARK: - Layers

    private let imageLayer = CALayer()
    private let placeholderLayer = CALayer()

    // Badge layers (top-right)
    private let c2paBadge = CALayer()
    private let editedBadge = CALayer()
    private let cropBadge = CALayer()
    private let hdrBadge = CALayer()

    // Pending metadata dot (top-left)
    private let pendingDot = CALayer()
    private let pendingDotBorder = CALayer()

    // Text fields
    private let filenameField = NSTextField(labelWithString: "")
    private let starsField = NSTextField(labelWithString: "")
    private let labelDot = NSView()
    private let labelDotLayer = CALayer()
    private let labelNameField = NSTextField(labelWithString: "")
    private let ratingLabelRow = NSStackView()

    // MARK: - State

    private var currentData: ThumbnailCellData?
    private var currentScale: Double = 1.0

    // MARK: - Badge images (rendered once at 2x for Retina, shared)

    nonisolated(unsafe) private static var badgeImageCache: [String: CGImage] = [:]
    nonisolated(unsafe) private static var placeholderImage: CGImage?
    private static let retinaScale: CGFloat = 2.0

    /// Renders a complete badge: colored circle + white SF Symbol, at 2x resolution.
    private static func badgeImage(systemName: String, color: NSColor) -> CGImage? {
        let key = "\(systemName)_\(color.description)"
        if let cached = badgeImageCache[key] { return cached }

        let pointSize: CGFloat = 20
        let pixelSize = Int(pointSize * retinaScale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        // Scale for Retina
        ctx.scaleBy(x: retinaScale, y: retinaScale)

        // Draw colored circle
        let circleRect = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        // Draw white symbol centered
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()

            let symbolSize = tinted.size
            let symbolX = (pointSize - symbolSize.width) / 2
            let symbolY = (pointSize - symbolSize.height) / 2
            tinted.draw(in: NSRect(x: symbolX, y: symbolY, width: symbolSize.width, height: symbolSize.height))
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        badgeImageCache[key] = cgImage
        return cgImage
    }

    private static func getPlaceholderImage() -> CGImage? {
        if let cached = placeholderImage { return cached }

        let pointSize: CGFloat = 48
        let pixelSize = Int(pointSize * retinaScale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: retinaScale, y: retinaScale)

        let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.secondaryLabelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()

            let symbolSize = tinted.size
            let symbolX = (pointSize - symbolSize.width) / 2
            let symbolY = (pointSize - symbolSize.height) / 2
            tinted.draw(in: NSRect(x: symbolX, y: symbolY, width: symbolSize.width, height: symbolSize.height))
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        placeholderImage = cgImage
        return cgImage
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        // Image layer
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = ThumbnailItemView.retinaScale
        imageLayer.cornerRadius = 4
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.addSublayer(imageLayer)

        // Placeholder icon
        placeholderLayer.contentsGravity = .center
        placeholderLayer.contentsScale = ThumbnailItemView.retinaScale
        placeholderLayer.contents = ThumbnailItemView.getPlaceholderImage()
        imageLayer.addSublayer(placeholderLayer)

        // Badge layers — fully composited at 2x
        configureBadge(c2paBadge, color: .systemBlue, systemName: "checkmark.seal.fill")
        configureBadge(editedBadge, color: .systemOrange, systemName: "slider.horizontal.3")
        configureBadge(cropBadge, color: .systemGreen, systemName: "crop")
        configureBadge(hdrBadge, color: .systemPurple, systemName: "sun.max.fill")

        for badge in [c2paBadge, editedBadge, cropBadge, hdrBadge] {
            badge.isHidden = true
            layer?.addSublayer(badge)
        }

        // Pending dot
        pendingDot.backgroundColor = NSColor.systemYellow.cgColor
        pendingDot.cornerRadius = 5
        pendingDot.isHidden = true
        pendingDotBorder.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        pendingDotBorder.cornerRadius = 6
        pendingDotBorder.isHidden = true
        layer?.addSublayer(pendingDotBorder)
        layer?.addSublayer(pendingDot)

        // Filename
        filenameField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        filenameField.lineBreakMode = .byTruncatingMiddle
        filenameField.alignment = .center
        filenameField.maximumNumberOfLines = 1
        filenameField.textColor = .labelColor
        addSubview(filenameField)

        // Stars
        starsField.font = .systemFont(ofSize: 11)
        starsField.textColor = .systemYellow
        starsField.alignment = .left
        starsField.maximumNumberOfLines = 1
        starsField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Label color bar
        labelDot.wantsLayer = true
        labelDot.layer?.cornerRadius = 1.5
        labelDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            labelDot.widthAnchor.constraint(equalToConstant: 41),
            labelDot.heightAnchor.constraint(equalToConstant: 11)
        ])

        // Label name
        labelNameField.font = .systemFont(ofSize: 9)
        labelNameField.textColor = .secondaryLabelColor
        labelNameField.alignment = .right
        labelNameField.maximumNumberOfLines = 1
        labelNameField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Rating + label row
        let starContainer = NSStackView(views: [starsField])
        starContainer.orientation = .horizontal
        starContainer.spacing = 0

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let labelContainer = NSStackView(views: [labelDot, labelNameField])
        labelContainer.orientation = .horizontal
        labelContainer.spacing = 3

        ratingLabelRow.orientation = .horizontal
        ratingLabelRow.spacing = 4
        ratingLabelRow.alignment = .centerY
        ratingLabelRow.setViews([starContainer, spacer, labelContainer], in: .leading)
        addSubview(ratingLabelRow)
    }

    private func configureBadge(_ badge: CALayer, color: NSColor, systemName: String) {
        badge.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        badge.contentsGravity = .resizeAspect
        badge.contentsScale = ThumbnailItemView.retinaScale
        badge.contents = ThumbnailItemView.badgeImage(systemName: systemName, color: color)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutSublayers()
    }

    private func layoutSublayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let w = bounds.width
        let padding: CGFloat = 6
        let imageWidth = w - padding * 2
        let imageHeight = 140 * currentScale
        let imageFrame = CGRect(x: padding, y: bounds.height - padding - imageHeight, width: imageWidth, height: imageHeight)
        imageLayer.frame = imageFrame

        // Placeholder centered in image layer
        placeholderLayer.frame = imageLayer.bounds

        // Badge positions (top-right of image, in view coordinates)
        let badgeX = imageFrame.maxX - 24
        var badgeY = imageFrame.maxY - 24
        for badge in [c2paBadge, editedBadge, cropBadge, hdrBadge] where !badge.isHidden {
            badge.position = CGPoint(x: badgeX, y: badgeY)
            badgeY -= 24
        }

        // Pending dot (top-left of image)
        pendingDotBorder.frame = CGRect(x: imageFrame.minX + 2, y: imageFrame.maxY - 14, width: 12, height: 12)
        pendingDot.frame = CGRect(x: imageFrame.minX + 3, y: imageFrame.maxY - 13, width: 10, height: 10)

        // Text below image
        let textTop = imageFrame.minY - 4
        let textWidth = imageWidth
        let filenameHeight: CGFloat = 16
        filenameField.frame = CGRect(x: padding, y: textTop - filenameHeight, width: textWidth, height: filenameHeight)

        // Rating+label row
        let rowHeight: CGFloat = 14
        ratingLabelRow.frame = CGRect(x: padding, y: filenameField.frame.minY - rowHeight - 1, width: textWidth, height: rowHeight)

        CATransaction.commit()
    }

    // MARK: - Configure

    func configure(with data: ThumbnailCellData) {
        guard data != currentData else { return }
        currentData = data

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Badges
        c2paBadge.isHidden = !data.hasC2PA
        editedBadge.isHidden = !(data.hasDevelopEdits || data.hasPendingMetadataChanges)
        cropBadge.isHidden = !data.hasCropEdits
        hdrBadge.isHidden = !data.isHDR

        // Pending dot
        pendingDot.isHidden = !data.hasPendingMetadataChanges
        pendingDotBorder.isHidden = !data.hasPendingMetadataChanges
        if data.hasPendingMetadataChanges {
            let tooltip: String
            if data.pendingFieldNames.isEmpty {
                tooltip = "Pending metadata changes"
            } else {
                tooltip = "Pending: " + data.pendingFieldNames.joined(separator: ", ")
            }
            self.toolTip = tooltip
        } else {
            self.toolTip = nil
        }

        // Filename
        filenameField.stringValue = data.filename

        // Star rating
        if data.starRating != .none {
            starsField.stringValue = data.starRating.displayString
            starsField.isHidden = false
        } else {
            starsField.stringValue = ""
            starsField.isHidden = true
        }

        // Color label in row
        if let nsColor = data.colorLabel.nsColor {
            labelDot.layer?.backgroundColor = nsColor.cgColor
            labelDot.isHidden = false
//            labelNameField.stringValue = data.colorLabel.displayName
//            labelNameField.isHidden = false
        } else {
            labelDot.isHidden = true
//            labelNameField.stringValue = ""
//            labelNameField.isHidden = true
        }

        // Show/hide the row if nothing to display
        ratingLabelRow.isHidden = data.starRating == .none && data.colorLabel == .none

        CATransaction.commit()
        needsLayout = true
    }

    // MARK: - Selection

    func updateSelection(isSelected: Bool, isActive: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isSelected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = isActive ? 3 : 1
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }

        CATransaction.commit()
    }

    // MARK: - Thumbnail

    func setThumbnail(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let image {
            imageLayer.contents = image
            placeholderLayer.isHidden = true
            imageLayer.backgroundColor = nil
        } else {
            imageLayer.contents = nil
            placeholderLayer.isHidden = false
            imageLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }

        CATransaction.commit()
    }

    func setThumbnailNSImage(_ nsImage: NSImage?) {
        guard let nsImage else {
            setThumbnail(nil)
            return
        }
        let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        setThumbnail(cgImage)
    }

    // MARK: - Scale

    func updateScale(_ scale: Double) {
        currentScale = scale
        needsLayout = true
    }

    func reset() {
        currentData = nil
        setThumbnail(nil)
        updateSelection(isSelected: false, isActive: false)
        toolTip = nil
    }
}
