import AppKit
import os

// MARK: - Flipped View Helper

/// NSView subclass with flipped coordinate system (y=0 at top).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Callbacks

struct FaceGroupCardCallbacks {
    var onDeleteGroup: ((FaceGroup) -> Void)?
    var onChooseListFile: (() -> Void)?
    var onToggleExpand: ((UUID) -> Void)?
    var onOpenFullScreen: ((URL, UUID?) -> Void)?
    var onPhotosDeleted: ((Set<URL>) -> Void)?
    /// Sports lens: name this group from the team roster by entering a number + team.
    var onNameFromTeamSheet: ((UUID) -> Void)?
}

// MARK: - Face Thumbnail Subview

final class FaceThumbnailSubview: NSView {

    override var isFlipped: Bool { true }

    var faceID: UUID?

    private let imageLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let selectionBorder = CALayer()
    private let checkmarkLayer = CALayer()

    private static var checkmarkImage: CGImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = NSSize(width: 16, height: 16)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                   pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // White circle background
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
        img.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        placeholderLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        placeholderLayer.isHidden = true
        layer?.addSublayer(placeholderLayer)

        selectionBorder.borderColor = NSColor.controlAccentColor.cgColor
        selectionBorder.borderWidth = 0
        selectionBorder.cornerRadius = 4
        selectionBorder.zPosition = 10
        layer?.addSublayer(selectionBorder)

        checkmarkLayer.contents = Self.checkmarkImage
        checkmarkLayer.contentsGravity = .center
        checkmarkLayer.zPosition = 20
        checkmarkLayer.isHidden = true
        layer?.addSublayer(checkmarkLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        placeholderLayer.frame = bounds
        selectionBorder.frame = bounds
        checkmarkLayer.frame = CGRect(x: bounds.width - 18, y: 2, width: 16, height: 16)
        CATransaction.commit()
    }

    func configure(faceID: UUID, image: NSImage?) {
        self.faceID = faceID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image {
            imageLayer.contents = image.layerContents(forContentsScale: 2.0)
            imageLayer.isHidden = false
            placeholderLayer.isHidden = true
        } else {
            imageLayer.contents = nil
            imageLayer.isHidden = true
            placeholderLayer.isHidden = false
        }
        CATransaction.commit()
    }

    func updateVisuals(isSelected: Bool, isFocused: Bool, isDragged: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isSelected {
            selectionBorder.borderWidth = 2
            selectionBorder.borderColor = NSColor.controlAccentColor.cgColor
        } else if isFocused {
            selectionBorder.borderWidth = 1
            selectionBorder.borderColor = NSColor.secondaryLabelColor.cgColor
        } else {
            selectionBorder.borderWidth = 0
        }

        checkmarkLayer.isHidden = !isSelected
        layer?.opacity = isDragged ? 0.4 : 1.0

        CATransaction.commit()
    }

    override func prepareForReuse() {
        faceID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        imageLayer.isHidden = true
        placeholderLayer.isHidden = false
        selectionBorder.borderWidth = 0
        checkmarkLayer.isHidden = true
        layer?.opacity = 1.0
        CATransaction.commit()
    }
}

// MARK: - Face Group Card View

final class FaceGroupCardView: NSView {

    override var isFlipped: Bool { true }

    // MARK: - State

    private(set) var groupID: UUID?
    private var viewModel: FaceRecognitionViewModel?
    private var selectionState: FaceSelectionState?
    private var settingsViewModel: SettingsViewModel?
    private var callbacks = FaceGroupCardCallbacks()

    private var currentGroup: FaceGroup?
    private var isExpanded = false
    private var maxVisibleFaces = 12

    // MARK: - Header views

    private let nameLabel = NSTextField(labelWithString: "")
    private let nameEditor = NSComboBox()
    private let countBadge = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton()

    private var isEditingName = false
    private var editingName = ""
    /// Structured Person Shown names backing the name combo box's dropdown list.
    private var structuredNameCache: [String] = []

    // MARK: - Face grid

    private var faceSubviews: [FaceThumbnailSubview] = []
    private let faceContainer = FlippedView()
    private let faceSize: CGFloat = 90
    private let faceSpacing: CGFloat = 6

    // MARK: - Key art button

    private let keyArtButton = NSButton()

    // MARK: - Expand button

    private let expandButton = NSButton()

    // MARK: - Card styling

    private let highlightBorder = CALayer()
    private let dashedBorder = CAShapeLayer()
    private var isHighlighted = false

    // MARK: - Mouse state

    private var mouseDownPoint: NSPoint?
    private var mouseDownFaceID: UUID?
    private var mouseDownInHeader = false

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupLayers()
        setupHeader()
        setupFaceContainer()
        setupKeyArtButton()
        setupExpandButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 10
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.1
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        highlightBorder.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
        highlightBorder.borderWidth = 1
        highlightBorder.cornerRadius = 10
        highlightBorder.zPosition = 100
        layer?.addSublayer(highlightBorder)

        // Dashed border for the unmatched faces group (hidden by default)
        dashedBorder.fillColor = nil
        dashedBorder.strokeColor = NSColor.tertiaryLabelColor.cgColor
        dashedBorder.lineWidth = 1.5
        dashedBorder.lineDashPattern = [6, 4]
        dashedBorder.zPosition = 101
        dashedBorder.isHidden = true
        layer?.addSublayer(dashedBorder)
    }

    private func setupHeader() {
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        nameEditor.font = .systemFont(ofSize: 13, weight: .semibold)
        nameEditor.placeholderString = "Name"
        nameEditor.isHidden = true
        nameEditor.translatesAutoresizingMaskIntoConstraints = false
        nameEditor.target = self
        nameEditor.action = #selector(nameEditorCommit)
        nameEditor.delegate = self
        // Structured Person Shown suggestions: show a browsable dropdown without
        // inline completion mutating whatever the user is typing.
        nameEditor.completes = false
        nameEditor.usesDataSource = true
        nameEditor.dataSource = self
        nameEditor.numberOfVisibleItems = 8
        nameEditor.hasVerticalScroller = true
        addSubview(nameEditor)

        countBadge.wantsLayer = true
        countBadge.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        countBadge.layer?.cornerRadius = 8
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countBadge)

        countLabel.font = .systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .white
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countBadge.addSubview(countLabel)

        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Menu")
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.bezelStyle = .accessoryBarAction
        menuButton.isBordered = false
        menuButton.target = self
        menuButton.action = #selector(showMenu(_:))
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.heightAnchor.constraint(equalToConstant: 20),

            nameEditor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameEditor.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameEditor.widthAnchor.constraint(equalToConstant: 170),

            countBadge.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            countBadge.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countBadge.heightAnchor.constraint(equalToConstant: 16),

            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: countBadge.centerYAnchor),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            menuButton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 24),
            menuButton.heightAnchor.constraint(equalToConstant: 24),

            countBadge.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -4),
        ])
    }

    private func setupFaceContainer() {
        // Manual frame layout — no Auto Layout constraints.
        // Frame is set in layout() based on card bounds.
        // FlippedView ensures faces render top-down (y=0 at top).
        faceContainer.wantsLayer = true
        faceContainer.layer?.masksToBounds = true
        addSubview(faceContainer)
    }

    private func setupKeyArtButton() {
        keyArtButton.title = "Set as Key Art"
        keyArtButton.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Set as key art")
        keyArtButton.imagePosition = .imageLeading
        keyArtButton.bezelStyle = .rounded
        keyArtButton.font = .systemFont(ofSize: 11)
        keyArtButton.contentTintColor = .controlAccentColor
        keyArtButton.target = self
        keyArtButton.action = #selector(setAsKeyArt)
        keyArtButton.isHidden = true
        keyArtButton.toolTip = "Use selected face as the group thumbnail"
        addSubview(keyArtButton)
    }

    private func setupExpandButton() {
        expandButton.title = ""
        expandButton.bezelStyle = .accessoryBarAction
        expandButton.isBordered = false
        expandButton.font = .systemFont(ofSize: 11)
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.target = self
        expandButton.action = #selector(toggleExpand)
        expandButton.isHidden = true
        // Manual frame layout — positioned below faceContainer in layout().
        addSubview(expandButton)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let cardWidth = bounds.width
        let padding: CGFloat = 12
        let headerHeight: CGFloat = 40

        // Position faceContainer: full width minus padding, below header
        let containerWidth = cardWidth - padding * 2
        let gridHeight = computeGridHeight(containerWidth: containerWidth)
        faceContainer.frame = CGRect(x: padding, y: headerHeight, width: containerWidth, height: gridHeight)

        // Position faces within the (flipped) container
        layoutFaceSubviews(containerWidth: containerWidth)

        // Position key art button and expand button below face container
        let buttonY = headerHeight + gridHeight + 4
        if !keyArtButton.isHidden && !expandButton.isHidden {
            // Both visible: key art left, expand right
            let halfWidth = (cardWidth - padding * 2 - 8) / 2
            keyArtButton.frame = CGRect(x: padding, y: buttonY, width: halfWidth, height: 24)
            expandButton.frame = CGRect(x: padding + halfWidth + 8, y: buttonY, width: halfWidth, height: 24)
        } else if !keyArtButton.isHidden {
            let btnWidth: CGFloat = 160
            let btnX = (cardWidth - btnWidth) / 2
            keyArtButton.frame = CGRect(x: btnX, y: buttonY, width: btnWidth, height: 24)
        } else if !expandButton.isHidden {
            let btnWidth: CGFloat = 200
            let btnX = (cardWidth - btnWidth) / 2
            expandButton.frame = CGRect(x: btnX, y: buttonY, width: btnWidth, height: 24)
        }

        // Update highlight border
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightBorder.frame = bounds
        dashedBorder.frame = bounds
        dashedBorder.path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).cgPath
        CATransaction.commit()
    }

    private func computeGridHeight(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        let columns = max(1, Int((containerWidth + faceSpacing) / (faceSize + faceSpacing)))
        let visibleCount = faceSubviews.filter { !$0.isHidden }.count
        guard visibleCount > 0 else { return 0 }
        let rows = ceil(Double(visibleCount) / Double(columns))
        return CGFloat(rows) * (faceSize + faceSpacing) - faceSpacing
    }

    private func layoutFaceSubviews(containerWidth: CGFloat) {
        guard containerWidth > 0 else { return }
        let columns = max(1, Int((containerWidth + faceSpacing) / (faceSize + faceSpacing)))

        for (index, subview) in faceSubviews.enumerated() where !subview.isHidden {
            let col = index % columns
            let row = index / columns
            let x = CGFloat(col) * (faceSize + faceSpacing)
            let y = CGFloat(row) * (faceSize + faceSpacing)
            subview.frame = CGRect(x: x, y: y, width: faceSize, height: faceSize)
        }
    }

    // MARK: - Configure

    func configure(group: FaceGroup, viewModel: FaceRecognitionViewModel, selectionState: FaceSelectionState,
                   settingsViewModel: SettingsViewModel, isExpanded: Bool, callbacks: FaceGroupCardCallbacks) {
        self.groupID = group.id
        self.currentGroup = group
        self.viewModel = viewModel
        self.selectionState = selectionState
        self.settingsViewModel = settingsViewModel
        self.isExpanded = isExpanded
        self.callbacks = callbacks

        // Header
        let isUnmatched = group.id == FaceRecognitionViewModel.unmatchedGroupID
        let name = isUnmatched ? "Unmatched Faces" : (group.name ?? "Unnamed")
        // Prefix the player's jersey number in sports mode (display only — the number is
        // never folded into group.name, so it can't leak into Person Shown metadata).
        let number = isUnmatched ? nil : viewModel.groupNumber(group.id)
        nameLabel.stringValue = number.map { "#\($0)  \(name)" } ?? name
        nameLabel.textColor = isUnmatched ? .tertiaryLabelColor : (group.name != nil ? .labelColor : .secondaryLabelColor)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        // Dashed border for unmatched group, solid for normal groups
        dashedBorder.isHidden = !isUnmatched
        highlightBorder.isHidden = isUnmatched
        if isUnmatched {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }

        let allFaces = viewModel.faces(in: group)
        countLabel.stringValue = "\(allFaces.count)"

        // Faces
        let visibleFaces = isExpanded ? allFaces : Array(allFaces.prefix(maxVisibleFaces))
        reconcileFaceSubviews(faces: visibleFaces, viewModel: viewModel)

        // Expand button (hidden for the always-expanded unmatched group)
        let hiddenCount = allFaces.count - visibleFaces.count
        if isUnmatched {
            expandButton.isHidden = true
        } else if hiddenCount > 0 {
            expandButton.title = "Show \(hiddenCount) more ▾"
            expandButton.isHidden = false
        } else if isExpanded && allFaces.count > maxVisibleFaces {
            expandButton.title = "Show less ▴"
            expandButton.isHidden = false
        } else {
            expandButton.isHidden = true
        }

        // Update selection visuals
        let ss: FaceSelectionState? = selectionState
        if let state = ss {
            updateFaceVisuals(
                selectedIDs: state.selectedFaceIDs,
                focusedID: state.focusedFaceID,
                draggedIDs: state.draggedFaceIDs
            )
        }

        // End any editing if group changed
        if isEditingName {
            endEditing()
        }
    }

    private func reconcileFaceSubviews(faces: [DetectedFace], viewModel: FaceRecognitionViewModel) {
        // Reuse or create subviews
        while faceSubviews.count < faces.count {
            let sub = FaceThumbnailSubview(frame: NSRect(x: 0, y: 0, width: faceSize, height: faceSize))
            faceSubviews.append(sub)
            faceContainer.addSubview(sub)
        }

        for (i, face) in faces.enumerated() {
            let sub = faceSubviews[i]
            sub.isHidden = false
            let thumbnail = viewModel.thumbnailImage(for: face.id)
            sub.configure(faceID: face.id, image: thumbnail)
        }

        // Hide excess
        for i in faces.count..<faceSubviews.count {
            faceSubviews[i].isHidden = true
            faceSubviews[i].faceID = nil
        }

        needsLayout = true
    }

    // MARK: - Selection Visuals

    func updateFaceVisuals(selectedIDs: Set<UUID>, focusedID: UUID?, draggedIDs: Set<UUID>) {
        for sub in faceSubviews {
            guard let fid = sub.faceID else { continue }
            sub.updateVisuals(
                isSelected: selectedIDs.contains(fid),
                isFocused: fid == focusedID,
                isDragged: draggedIDs.contains(fid)
            )
        }

        // Show "Set as Key Art" when exactly one face in this group is selected
        // and it's not already the representative (not applicable to unmatched group)
        let visibleFaceIDs = Set(faceSubviews.compactMap { $0.isHidden ? nil : $0.faceID })
        let selectedInGroup = selectedIDs.intersection(visibleFaceIDs)
        let isUnmatchedGroup = groupID == FaceRecognitionViewModel.unmatchedGroupID
        let shouldShow = !isUnmatchedGroup
            && selectedInGroup.count == 1
            && selectedIDs.count == 1
            && selectedInGroup.first != currentGroup?.representativeFaceID
        if keyArtButton.isHidden != !shouldShow {
            keyArtButton.isHidden = !shouldShow
            needsLayout = true
        }
    }

    // MARK: - Highlight (drop target)

    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted else { return }
        isHighlighted = highlighted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if highlighted {
            highlightBorder.borderColor = NSColor.controlAccentColor.cgColor
            highlightBorder.borderWidth = 2
        } else {
            highlightBorder.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
            highlightBorder.borderWidth = 1
        }
        CATransaction.commit()
    }

    // MARK: - Height Computation

    static func computeHeight(faceCount: Int, cardWidth: CGFloat, isExpanded: Bool, maxVisibleFaces: Int) -> CGFloat {
        let faceSize: CGFloat = 90
        let faceSpacing: CGFloat = 6
        let padding: CGFloat = 12
        let headerHeight: CGFloat = 40
        let expandButtonHeight: CGFloat = 28
        let bottomPadding: CGFloat = 8

        let visibleCount = isExpanded ? faceCount : min(faceCount, maxVisibleFaces)
        let gridWidth = cardWidth - padding * 2
        let columns = max(1, Int((gridWidth + faceSpacing) / (faceSize + faceSpacing)))
        let rows = visibleCount > 0 ? ceil(Double(visibleCount) / Double(columns)) : 0
        let gridHeight = CGFloat(rows) * (faceSize + faceSpacing) - (rows > 0 ? faceSpacing : 0)

        // Reserve button row when expand needed or multiple faces (key art possible)
        let needsButtonRow = faceCount > maxVisibleFaces || faceCount > 1
        let buttonHeight: CGFloat = needsButtonRow ? expandButtonHeight : 0

        return headerHeight + gridHeight + buttonHeight + bottomPadding
    }

    // MARK: - Prepare for Reuse

    override func prepareForReuse() {
        groupID = nil
        currentGroup = nil
        viewModel = nil
        selectionState = nil
        isHighlighted = false
        mouseDownPoint = nil
        mouseDownFaceID = nil

        for sub in faceSubviews {
            sub.prepareForReuse()
            sub.isHidden = true
        }

        keyArtButton.isHidden = true
        expandButton.isHidden = true
        endEditing()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightBorder.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.2).cgColor
        highlightBorder.borderWidth = 1
        CATransaction.commit()
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownFaceID = nil
        mouseDownInHeader = false

        // Check if click is on a face subview
        let containerPoint = faceContainer.convert(event.locationInWindow, from: nil)
        for sub in faceSubviews where !sub.isHidden {
            if sub.frame.contains(containerPoint), let fid = sub.faceID {
                mouseDownFaceID = fid
                return
            }
        }

        // Check header area for double-click rename (flipped coordinates: y < 40 is top)
        if point.y < 40 {
            mouseDownInHeader = true
            if event.clickCount == 2 {
                startEditing()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        defer {
            mouseDownPoint = nil
            mouseDownFaceID = nil
            mouseDownInHeader = false
        }

        // If we were dragging, the collection view handles it
        guard let faceID = mouseDownFaceID, let selectionState else { return }

        let modifiers = event.modifierFlags
        if modifiers.contains(.shift) {
            // Build allFaces for this group from visible subviews
            let visibleFaceIDs = faceSubviews.compactMap { $0.isHidden ? nil : $0.faceID }
            selectionState.extendSelection(to: faceID, allFaces: visibleFaceIDs)
        } else {
            selectionState.toggleSelection(faceID, commandKey: modifiers.contains(.command))
        }

        // Select group for thumbnail replacement
        if let groupID {
            viewModel?.selectGroupForThumbnailReplacement(groupID, faceID: faceID)
        }

        // Notify collection view to refresh
        (enclosingScrollView?.documentView as? FaceGroupCollectionView)?.refreshVisibleSelections()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = abs(current.x - start.x)
        let dy = abs(current.y - start.y)
        guard dx >= 3 || dy >= 3 else { return }

        guard let selectionState, let viewModel, let collectionView = enclosingScrollView?.documentView as? FaceGroupCollectionView else { return }

        if let faceID = mouseDownFaceID {
            // Face drag
            let ids: Set<UUID> = selectionState.selectedFaceIDs.contains(faceID) ? selectionState.selectedFaceIDs : [faceID]
            selectionState.draggedFaceIDs = ids
            collectionView.beginFaceDrag(faceIDs: ids, event: event, sourceView: self, viewModel: viewModel)
        } else if mouseDownInHeader, let groupID {
            // Group drag
            selectionState.draggedGroupID = groupID
            collectionView.beginGroupDrag(groupID: groupID, event: event, sourceView: self)
        }

        mouseDownPoint = nil // Prevent further drag starts
    }

    override func rightMouseDown(with event: NSEvent) {
        let containerPoint = faceContainer.convert(event.locationInWindow, from: nil)
        var clickedFaceID: UUID?
        for sub in faceSubviews where !sub.isHidden {
            if sub.frame.contains(containerPoint), let fid = sub.faceID {
                clickedFaceID = fid
                break
            }
        }
        guard let faceID = clickedFaceID, let viewModel, let groupID else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()

        // Show in Browser
        if let face = viewModel.face(byID: faceID) {
            let showItem = NSMenuItem(title: "Show in Browser", action: nil, keyEquivalent: "")
            showItem.representedObject = face.imageURL
            showItem.target = self
            showItem.action = #selector(faceMenuShowInBrowser(_:))
            menu.addItem(showItem)
        }

        // Set as Key Art (only for real groups, not unmatched)
        let isUnmatched = groupID == FaceRecognitionViewModel.unmatchedGroupID
        if !isUnmatched, currentGroup?.representativeFaceID != faceID {
            let keyArtItem = NSMenuItem(title: "Set as Key Art", action: #selector(faceMenuSetKeyArt(_:)), keyEquivalent: "")
            keyArtItem.representedObject = faceID
            keyArtItem.target = self
            menu.addItem(keyArtItem)
        }

        // Move to New Group
        let targetCount = menuTargetFaceIDs(clicked: faceID).count
        if let group = currentGroup, group.faceIDs.count > 1 || isUnmatched {
            let title = targetCount > 1 ? "Move \(targetCount) to New Group" : "Move to New Group"
            let moveItem = NSMenuItem(title: title, action: #selector(faceMenuMoveToNewGroup(_:)), keyEquivalent: "")
            moveItem.representedObject = faceID
            moveItem.target = self
            menu.addItem(moveItem)
        }

        // Add each selected face to its own separate new group
        if targetCount > 1 {
            let separateItem = NSMenuItem(title: "Add \(targetCount) to Separate Groups", action: #selector(faceMenuSeparateGroups(_:)), keyEquivalent: "")
            separateItem.representedObject = faceID
            separateItem.target = self
            menu.addItem(separateItem)
        }

        // Ungroup (move to Unmatched Faces)
        if !isUnmatched {
            let ungroupItem = NSMenuItem(title: "Ungroup", action: #selector(faceMenuUngroup(_:)), keyEquivalent: "")
            ungroupItem.representedObject = faceID
            ungroupItem.target = self
            menu.addItem(ungroupItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Delete Face Data
        let deleteItem = NSMenuItem(title: "Delete Face Data", action: #selector(faceMenuDeleteFace(_:)), keyEquivalent: "")
        deleteItem.representedObject = faceID
        deleteItem.target = self
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func faceMenuShowInBrowser(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        callbacks.onOpenFullScreen?(url, nil)
    }

    @objc private func faceMenuSetKeyArt(_ sender: NSMenuItem) {
        guard let faceID = sender.representedObject as? UUID, let groupID else { return }
        viewModel?.setRepresentativeFace(faceID, forGroup: groupID)
    }

    @objc private func faceMenuMoveToNewGroup(_ sender: NSMenuItem) {
        guard let faceID = sender.representedObject as? UUID else { return }
        viewModel?.createNewGroup(withFaces: menuTargetFaceIDs(clicked: faceID))
    }

    @objc private func faceMenuSeparateGroups(_ sender: NSMenuItem) {
        guard let faceID = sender.representedObject as? UUID else { return }
        viewModel?.createSeparateGroups(forFaces: menuTargetFaceIDs(clicked: faceID))
    }

    /// Faces a context-menu action should apply to: the whole selection when the
    /// right-clicked face is part of it, otherwise just the clicked face.
    private func menuTargetFaceIDs(clicked faceID: UUID) -> Set<UUID> {
        if let selected = selectionState?.selectedFaceIDs, selected.contains(faceID) {
            return selected
        }
        return [faceID]
    }

    @objc private func faceMenuUngroup(_ sender: NSMenuItem) {
        guard let faceID = sender.representedObject as? UUID else { return }
        viewModel?.moveToUnmatched(menuTargetFaceIDs(clicked: faceID))
    }

    @objc private func faceMenuDeleteFace(_ sender: NSMenuItem) {
        guard let faceID = sender.representedObject as? UUID else { return }
        let ids = menuTargetFaceIDs(clicked: faceID)
        viewModel?.deleteFaces(ids)
        selectionState?.selectedFaceIDs.subtract(ids)
    }

    // MARK: - Editing

    private func startEditing() {
        guard !isEditingName, let group = currentGroup else { return }
        isEditingName = true
        editingName = group.name ?? ""
        nameEditor.stringValue = editingName
        nameLabel.isHidden = true
        countBadge.isHidden = true
        nameEditor.isHidden = false

        // Refresh structured Person Shown names for the dropdown.
        structuredNameCache = StructuredKeywordService.personShown.allSearchableNames()
        nameEditor.reloadData()

        window?.makeFirstResponder(nameEditor)
    }

    private func endEditing() {
        guard isEditingName else { return }
        isEditingName = false
        nameLabel.isHidden = false
        countBadge.isHidden = false
        nameEditor.isHidden = true
    }

    @objc private func nameEditorCommit() {
        let typedName = nameEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = StructuredKeywordService.personShown.canonicalName(forNameOrSynonym: typedName) ?? typedName
        if let groupID, !name.isEmpty {
            viewModel?.nameGroup(groupID, name: name)
        }
        endEditing()
    }

    // MARK: - Key Art

    @objc private func setAsKeyArt() {
        guard let groupID,
              let selectionState,
              selectionState.selectedFaceIDs.count == 1,
              let faceID = selectionState.selectedFaceIDs.first else { return }
        viewModel?.setRepresentativeFace(faceID, forGroup: groupID)
    }

    // MARK: - Expand

    @objc private func toggleExpand() {
        guard let groupID else { return }
        callbacks.onToggleExpand?(groupID)
    }

    // MARK: - Context Menu

    @objc private func showMenu(_ sender: NSButton) {
        let menu = buildContextMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        guard let group = currentGroup else { return menu }

        // The synthetic "Unmatched Faces" pool isn't a real group — rename/merge/delete
        // don't apply. Offer the bulk split instead.
        if group.id == FaceRecognitionViewModel.unmatchedGroupID {
            let splitAllItem = NSMenuItem(title: "Add All Faces to Separate Groups", action: #selector(menuSplitAllUnmatched), keyEquivalent: "")
            splitAllItem.target = self
            if (viewModel?.faces(in: group).count ?? 0) == 0 {
                splitAllItem.isEnabled = false
            }
            menu.addItem(splitAllItem)
            return menu
        }

        let renameItem = NSMenuItem(title: "Rename", action: #selector(menuRename), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        // Sports lens: name the group from the roster by jersey number + team — for when the
        // photographer can read the number but doesn't remember who wears it (or OCR missed it).
        if viewModel?.activeLens == .sports, viewModel?.matchRoster?.isReady == true {
            let fromSheetItem = NSMenuItem(title: "Name from Team Sheet…", action: #selector(menuNameFromTeamSheet), keyEquivalent: "")
            fromSheetItem.target = self
            menu.addItem(fromSheetItem)
        }

        // Sports lens: hand-assign the jersey number when OCR missed it and there's no
        // roster to resolve it from. Display-only; never written to Person Shown.
        if viewModel?.activeLens == .sports {
            let assignNumberItem = NSMenuItem(title: "Assign Number…", action: #selector(menuAssignNumber), keyEquivalent: "")
            assignNumberItem.target = self
            menu.addItem(assignNumberItem)
        }

        if group.name != nil {
            let applyItem = NSMenuItem(title: "Apply Name to Metadata", action: #selector(menuApplyName), keyEquivalent: "")
            applyItem.target = self
            menu.addItem(applyItem)

            let addKnownItem = NSMenuItem(title: "Add to Known People", action: #selector(menuAddToKnownPeople), keyEquivalent: "")
            addKnownItem.target = self
            menu.addItem(addKnownItem)
        }

        menu.addItem(NSMenuItem.separator())

        let ungroupItem = NSMenuItem(title: "Ungroup All", action: #selector(menuUngroup), keyEquivalent: "")
        ungroupItem.target = self
        if viewModel?.faces(in: group).count ?? 0 <= 1 {
            ungroupItem.isEnabled = false
        }
        menu.addItem(ungroupItem)

        let deleteFacesItem = NSMenuItem(title: "Delete Group Faces", action: #selector(menuDeleteFaces), keyEquivalent: "")
        deleteFacesItem.target = self
        menu.addItem(deleteFacesItem)

        let deleteGroupItem = NSMenuItem(title: "Delete Group & Photos", action: #selector(menuDeleteGroup), keyEquivalent: "")
        deleteGroupItem.target = self
        menu.addItem(deleteGroupItem)

        return menu
    }

    @objc private func menuRename() {
        startEditing()
    }

    @objc private func menuNameFromTeamSheet() {
        guard let groupID else { return }
        callbacks.onNameFromTeamSheet?(groupID)
    }

    @objc private func menuAssignNumber() {
        guard let groupID, let viewModel else { return }
        let alert = NSAlert()
        alert.messageText = "Assign Jersey Number"
        alert.informativeText = "Enter a number (0–99), or leave blank to clear. This labels the group only — it isn't written to Person Shown."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Number"
        // Pre-fill with the current manual number, falling back to the resolved one so an
        // OCR'd/roster number can be corrected in place.
        if let current = currentGroup?.manualNumber ?? viewModel.groupNumber(groupID) {
            field.stringValue = "\(current)"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            viewModel.setManualNumber(nil, forGroup: groupID)
        } else if let number = Int(trimmed), (0...99).contains(number) {
            viewModel.setManualNumber(number, forGroup: groupID)
        }
    }

    @objc private func menuSplitAllUnmatched() {
        viewModel?.splitAllUnmatchedIntoGroups()
    }

    @objc private func menuApplyName() {
        guard let groupID else { return }
        viewModel?.applyNameToMetadata(groupID: groupID)
    }

    @objc private func menuAddToKnownPeople() {
        guard let group = currentGroup, let name = group.name, !name.isEmpty, let viewModel else { return }

        do {
            _ = try viewModel.addGroupToKnownPeople(groupID: group.id, name: name)
        } catch {
            Logger(subsystem: "com.aagedal.photo-agent", category: "FaceGroupCard")
                .error("Failed to add to Known People: \(error.localizedDescription)")
        }
    }

    @objc private func menuUngroup() {
        guard let groupID else { return }
        viewModel?.ungroupMultiple([groupID])
    }

    @objc private func menuDeleteFaces() {
        guard let group = currentGroup else { return }
        viewModel?.deleteFaces(Set(group.faceIDs))
    }

    @objc private func menuDeleteGroup() {
        guard let group = currentGroup else { return }
        callbacks.onDeleteGroup?(group)
    }
}

// MARK: - NSTextFieldDelegate

extension FaceGroupCardView: NSComboBoxDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        // Filter newlines from name
        let current = nameEditor.stringValue
        let filtered = current.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        if filtered != current {
            nameEditor.stringValue = filtered
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if isEditingName {
            nameEditorCommit()
        }
    }
}

// MARK: - NSComboBoxDataSource (structured Person Shown names)

extension FaceGroupCardView: NSComboBoxDataSource {
    func numberOfItems(in comboBox: NSComboBox) -> Int {
        structuredNameCache.count
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        structuredNameCache.indices.contains(index) ? structuredNameCache[index] : nil
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        structuredNameCache.firstIndex { $0.caseInsensitiveCompare(string) == .orderedSame } ?? NSNotFound
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        nil
    }
}
