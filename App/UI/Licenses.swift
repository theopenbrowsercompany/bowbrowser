import AppKit

/// The license files that ship in the app's Resources (copied by scripts/bundle-licenses.sh) and the About panel
/// that links to them.
@MainActor
final class Licenses: NSObject {
    /// Resource file name and the label the About panel shows for it.
    static let files: [(name: String, label: String)] = [
        ("Bow-LICENSE.txt", "Bow license"),
        ("CEF-LICENSE.txt", "Chromium Embedded Framework license"),
        ("Chromium-Credits.html", "Chromium credits"),
    ]

    static func url(of name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    /// The About panel's credits: one link per license file, opened by the system's default app for it.
    static func credits() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for (index, file) in files.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let url = url(of: file.name) { attributes[.link] = url }
            text.append(NSAttributedString(string: file.label, attributes: attributes))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Shows the About panel with `options`; the e2e run replaces it so no panel opens on the person's screen.
    static var presentAboutPanel: ([NSApplication.AboutPanelOptionKey: Any]) -> Void = {
        NSApp.orderFrontStandardAboutPanel(options: $0)
    }

    /// The "About Bow" menu action.
    @objc static func showAbout(_ sender: Any?) {
        presentAboutPanel([.credits: credits()])
    }
}
