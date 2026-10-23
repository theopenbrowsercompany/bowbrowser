import AppKit
import BowCore

// The chrome area of the adapter: E2EChromeApp over the window's CopyURLFeature.

extension E2ETestApp: E2EChromeApp {
    func usePrivatePasteboard(of page: any E2EPage) throws -> any E2EChromePasteboard {
        try adapter.requireActive(token, "use a private pasteboard")
        let feature = try Self.copyFeature(of: page)
        let board = NSPasteboard(name: NSPasteboard.Name("bow.e2e.\(UUID().uuidString)"))
        board.clearContents()
        feature.pasteboard = board
        return PrivatePasteboard(board: board)
    }

    func confirmation(of page: any E2EPage) throws -> E2EChromeConfirmation {
        try adapter.requireActive(token, "read the confirmation")
        let feature = try Self.copyFeature(of: page)
        let view = feature.confirmation
        let content = view.superview
        return E2EChromeConfirmation(
            isShown: !view.isHidden && view.alphaValue > 0 && view.window != nil,
            text: view.accessibilityLabel() ?? "",
            viewCount: content?.subviews.filter { $0 is CopyConfirmationView }.count ?? 0)
    }

    private static func copyFeature(of page: any E2EPage) throws -> CopyURLFeature {
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(CopyURLFeature.self) else {
            throw E2EError("the window has no copy feature")
        }
        return feature
    }
}

@MainActor
private final class PrivatePasteboard: E2EChromePasteboard {
    let board: NSPasteboard

    init(board: NSPasteboard) { self.board = board }

    var changeCount: Int { board.changeCount }
    var string: String? { board.string(forType: .string) }
    var url: URL? { board.string(forType: .URL).flatMap(URL.init(string:)) }
    func release() { board.releaseGlobally() }
}
