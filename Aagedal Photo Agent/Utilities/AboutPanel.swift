import AppKit

/// Presents the standard macOS About panel with clickable Homepage and
/// Source Code links in the credits area. Wired to the App-menu "About" item.
enum AboutPanel {
    private static let homepage = URL(string: "https://photoagent.aagedal.me")!
    private static let repository = URL(string: "https://codeberg.org/taagedal/Aagedal-Photo-Agent")!

    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Two centered hyperlinks shown below the version/copyright. The standard
    /// about panel renders credits in a text view, so `.link` attributes are
    /// clickable and open in the default browser.
    private static var credits: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3

        let result = NSMutableAttributedString()
        for (index, entry) in [("Homepage", homepage), ("Source Code", repository)].enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
            }
            result.append(NSAttributedString(string: entry.0, attributes: [
                .link: entry.1,
                .font: font,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }
}
