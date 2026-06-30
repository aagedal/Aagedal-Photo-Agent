import AppKit

/// A Pinterest-style waterfall layout for the face-group grid.
///
/// `NSCollectionViewFlowLayout` aligns whole rows to the tallest card in the row, so a short card
/// (one face) sitting next to a tall one (many faces) leaves a large dead gap underneath until the
/// next row begins. This layout instead drops each card into the currently-shortest column, so the
/// columns stay tightly packed and that mid-grid empty space disappears.
///
/// Cards keep their natural, variable heights. Items flagged full-width (the "unmatched" group)
/// span every column and reset all columns to below themselves.
final class FaceGroupWaterfallLayout: NSCollectionViewLayout {

    /// Minimum width a single card may shrink to before the column count drops.
    var minColumnWidth: CGFloat = 300
    var interitemSpacing: CGFloat = 16
    var lineSpacing: CGFloat = 16
    var sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

    /// Natural height for the item at a path, given the resolved card width.
    var heightForItem: ((IndexPath, CGFloat) -> CGFloat)?
    /// Whether the item spans the full content width (e.g. the unmatched group).
    var isFullWidthItem: ((IndexPath) -> Bool)?

    private var attributesByPath: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var allAttributes: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = 0

    private func columnCount(for width: CGFloat) -> Int {
        let available = width - sectionInset.left - sectionInset.right
        let count = Int((available + interitemSpacing) / (minColumnWidth + interitemSpacing))
        return max(1, count)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }

        attributesByPath.removeAll(keepingCapacity: true)
        allAttributes.removeAll(keepingCapacity: true)

        let width = collectionView.bounds.width
        preparedWidth = width

        let cols = columnCount(for: width)
        let usable = width - sectionInset.left - sectionInset.right - interitemSpacing * CGFloat(cols - 1)
        let columnWidth = max(minColumnWidth, usable / CGFloat(cols))
        let fullWidth = width - sectionInset.left - sectionInset.right

        // Running bottom edge of each column (starts at the top inset).
        var columnHeights = [CGFloat](repeating: sectionInset.top, count: cols)

        for section in 0..<collectionView.numberOfSections {
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                let path = IndexPath(item: item, section: section)
                let attr = NSCollectionViewLayoutAttributes(forItemWith: path)

                if isFullWidthItem?(path) ?? false {
                    let y = columnHeights.max() ?? sectionInset.top
                    let h = heightForItem?(path, fullWidth) ?? 120
                    attr.frame = NSRect(x: sectionInset.left, y: y, width: fullWidth, height: h)
                    let bottom = y + h + lineSpacing
                    for i in columnHeights.indices { columnHeights[i] = bottom }
                } else {
                    // Shortest column wins; ties favour the leftmost so reading order stays stable.
                    var col = 0
                    for i in 1..<cols where columnHeights[i] < columnHeights[col] - 0.5 { col = i }
                    let x = sectionInset.left + CGFloat(col) * (columnWidth + interitemSpacing)
                    let y = columnHeights[col]
                    let h = heightForItem?(path, columnWidth) ?? 120
                    attr.frame = NSRect(x: x, y: y, width: columnWidth, height: h)
                    columnHeights[col] = y + h + lineSpacing
                }

                attributesByPath[path] = attr
                allAttributes.append(attr)
            }
        }

        let tallest = columnHeights.max() ?? sectionInset.top
        // `tallest` already includes a trailing lineSpacing from the last card in its column.
        contentHeight = max(sectionInset.top, tallest - lineSpacing + sectionInset.bottom)
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: preparedWidth, height: max(0, contentHeight))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        allAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributesByPath[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != preparedWidth
    }
}
