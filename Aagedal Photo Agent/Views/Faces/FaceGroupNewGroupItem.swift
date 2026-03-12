import AppKit

final class FaceGroupNewGroupItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("FaceGroupNewGroupItem")

    private let dashedBorder = CAShapeLayer()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Drop here to\ncreate group")
    private var isHighlighted = false

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        // Dashed border
        dashedBorder.fillColor = nil
        dashedBorder.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [6, 3]
        container.layer?.addSublayer(dashedBorder)

        // Icon
        iconView.image = NSImage(systemSymbolName: "plus.rectangle.on.folder", accessibilityDescription: "New group")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        // Label
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -14),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
        ])

        self.view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let path = NSBezierPath(roundedRect: view.bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        dashedBorder.path = path.cgPath
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setHighlighted(false)
    }

    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted else { return }
        isHighlighted = highlighted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if highlighted {
            dashedBorder.strokeColor = NSColor.controlAccentColor.cgColor
            dashedBorder.lineWidth = 2
        } else {
            dashedBorder.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3).cgColor
            dashedBorder.lineWidth = 1
        }
        CATransaction.commit()
    }
}

// MARK: - NSBezierPath → CGPath

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            @unknown default: break
            }
        }
        return path
    }
}
