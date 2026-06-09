import AppKit

/// Renders a team roster to a nicely laid-out A4 PDF: a header with the team
/// name and kit colour, then one row per player showing their jersey number,
/// name, and linked face thumbnail. Used by the Teams editor's "Export PDF…".
///
/// Colours are fixed (not the dynamic `labelColor` family) so the document looks
/// the same regardless of the app's light/dark appearance — a dynamic colour
/// would otherwise resolve to near-white ink on the white page in dark mode.
enum RosterPDFExporter {
    /// A4 portrait, in points (72 dpi).
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 48
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 6
    /// Gap between the two roster columns.
    private static let columnGutter: CGFloat = 22

    // Fixed palette.
    private static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let subtle = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.47, alpha: 1)
    private static let hairline = NSColor(srgbRed: 0.82, green: 0.82, blue: 0.84, alpha: 1)
    private static let rowFill = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    private static let rowFillAlt = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
    private static let placeholderFill = NSColor(srgbRed: 0.88, green: 0.88, blue: 0.90, alpha: 1)

    /// Build PDF data for `team`. Face images are resolved through `faceImage`
    /// (keeps this decoupled from KnownPeopleService for testing).
    static func makePDF(for team: Team, exportedOn date: Date, faceImage: (UUID) -> NSImage?) -> Data {
        let players = team.roster.sorted { $0.number < $1.number }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return data as Data }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return data as Data }

        let contentWidth = pageSize.width - margin * 2
        let columnWidth = (contentWidth - columnGutter) / 2
        let pitch = rowHeight + rowSpacing
        var index = 0
        var isFirstPage = true

        while index < players.count || isFirstPage {
            ctx.beginPDFPage(nil)
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            var bodyTop = pageSize.height - margin
            if isFirstPage {
                bodyTop = drawHeader(team: team, playerCount: players.count, date: date,
                                     topY: bodyTop, width: contentWidth) - 16
                if players.isEmpty {
                    draw("No players in this roster yet.",
                         font: .systemFont(ofSize: 13), color: subtle,
                         in: CGRect(x: margin, y: bodyTop - 18, width: contentWidth, height: 18))
                }
            }

            // How many rows fit in one column on this page.
            let capacityPerColumn = max(1, Int((bodyTop - margin + rowSpacing) / pitch))
            let countThisPage = min(players.count - index, capacityPerColumn * 2)
            // Balance the columns: the left column gets the extra on odd counts,
            // so a 20-player page reads 10 + 10 rather than 15 + 5.
            let leftRows = (countThisPage + 1) / 2

            for k in 0..<countThisPage {
                let column = k < leftRows ? 0 : 1
                let rowInColumn = column == 0 ? k : k - leftRows
                let x = margin + CGFloat(column) * (columnWidth + columnGutter)
                let y = bodyTop - CGFloat(rowInColumn) * pitch
                let rowRect = CGRect(x: x, y: y - rowHeight, width: columnWidth, height: rowHeight)
                drawRow(players[index], in: rowRect, faceImage: faceImage, alternate: rowInColumn % 2 == 1)
                index += 1
            }

            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            isFirstPage = false
        }

        ctx.closePDF()
        return data as Data
    }

    // MARK: - Header

    private static func drawHeader(team: Team, playerCount: Int, date: Date,
                                   topY: CGFloat, width: CGFloat) -> CGFloat {
        let title = team.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled Team" : team.name
        let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
        let titleHeight = ("Ag" as NSString).size(withAttributes: [.font: titleFont]).height

        // Kit colour swatch, vertically centred against the title.
        let swatch: CGFloat = 22
        let swatchRect = CGRect(x: margin, y: topY - titleHeight + (titleHeight - swatch) / 2,
                                width: swatch, height: swatch)
        let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 6, yRadius: 6)
        NSColor(srgbRed: team.primaryColor.r, green: team.primaryColor.g,
                blue: team.primaryColor.b, alpha: 1).setFill()
        swatchPath.fill()
        hairline.setStroke()
        swatchPath.lineWidth = 1
        swatchPath.stroke()

        let titleX = swatchRect.maxX + 12
        draw(title, font: titleFont, color: ink,
             in: CGRect(x: titleX, y: topY - titleHeight, width: width - (titleX - margin), height: titleHeight))

        // Subtitle: player count + export date.
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .none
        let subtitle = "\(playerCount) player\(playerCount == 1 ? "" : "s")  ·  \(df.string(from: date))"
        let subFont = NSFont.systemFont(ofSize: 12)
        let subHeight = ("Ag" as NSString).size(withAttributes: [.font: subFont]).height
        let subY = topY - titleHeight - 6 - subHeight
        draw(subtitle, font: subFont, color: subtle,
             in: CGRect(x: titleX, y: subY, width: width - (titleX - margin), height: subHeight))

        // Divider under the header.
        let lineY = subY - 14
        let line = NSBezierPath()
        line.move(to: CGPoint(x: margin, y: lineY))
        line.line(to: CGPoint(x: margin + width, y: lineY))
        line.lineWidth = 1
        hairline.setStroke()
        line.stroke()

        return lineY
    }

    // MARK: - Row

    private static func drawRow(_ player: RosterPlayer, in rect: CGRect,
                                faceImage: (UUID) -> NSImage?, alternate: Bool) {
        let bg = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (alternate ? rowFillAlt : rowFill).setFill()
        bg.fill()

        let inset: CGFloat = 5
        let imgSide = rect.height - inset * 2
        let imgRect = CGRect(x: rect.minX + inset, y: rect.minY + inset, width: imgSide, height: imgSide)
        let imgPath = NSBezierPath(roundedRect: imgRect, xRadius: 5, yRadius: 5)

        if let id = player.knownPersonID, let img = faceImage(id) {
            NSGraphicsContext.saveGraphicsState()
            imgPath.addClip()
            drawAspectFill(img, in: imgRect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            placeholderFill.setFill()
            imgPath.fill()
            if let glyph = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [subtle])) {
                let g = imgSide * 0.62
                glyph.draw(in: CGRect(x: imgRect.midX - g / 2, y: imgRect.midY - g / 2, width: g, height: g))
            }
        }

        // Jersey number, right-aligned in a fixed column so names line up.
        let numberX = imgRect.maxX + 10
        let numberWidth: CGFloat = 26
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        let numberHeight = ("0" as NSString).size(withAttributes: [.font: numberFont]).height
        draw("\(player.number)", font: numberFont, color: ink, align: .right,
             in: CGRect(x: numberX, y: rect.midY - numberHeight / 2, width: numberWidth, height: numberHeight))

        // Player name.
        let nameX = numberX + numberWidth + 10
        let name = player.playerName.trimmingCharacters(in: .whitespaces).isEmpty ? "—" : player.playerName
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let nameHeight = ("Ag" as NSString).size(withAttributes: [.font: nameFont]).height
        draw(name, font: nameFont, color: ink,
             in: CGRect(x: nameX, y: rect.midY - nameHeight / 2, width: rect.maxX - nameX - inset, height: nameHeight))
    }

    // MARK: - Helpers

    private static func draw(_ string: String, font: NSFont, color: NSColor,
                             align: NSTextAlignment = .left, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]).draw(in: rect)
    }

    /// Scale `image` to cover `rect` (aspect-fill), centred. Caller clips.
    private static func drawAspectFill(_ image: NSImage, in rect: CGRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height)
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
