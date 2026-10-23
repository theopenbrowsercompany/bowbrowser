import AppKit
import BowCore

// The routing area of the adapter: E2ERoutingApp over the app delegate's GetURL handler and AirTrafficControl. Links
// are real GetURL Apple Events the delegate takes as the harness's own (as in the links area), so the routing
// decision, the window, the Space and the tab are the app's own. The editor opens off every screen
// (`AirTrafficControl.e2eEditorFrame`) and never takes the keyboard.

extension E2EAppAdapter {
    /// Where e2e runs open the rule editor: far from every screen, apart from the test windows and Little Arc.
    static let routingEditorFrame = NSRect(x: -20_000, y: -26_000, width: 780, height: 440)

    /// Sets up Air Traffic Control for the run before the first link can arrive: the editor opens off every screen.
    static func prepareRouting() {
        AirTrafficControl.e2eEditorFrame = routingEditorFrame
        AirTrafficControl.e2eSourceRenames = [:]
    }

    var airTrafficControl: AirTrafficControl { delegate.appFeatures.require(AirTrafficControl.self) }

    /// Puts the routing rules, the editor and the sender's stand-in back to the run's own after a test: the initial
    /// rules, no editor, and links from Bow counting as Bow's.
    func resetRouting() {
        AirTrafficControl.e2eSourceRenames = [:]
        let control = airTrafficControl
        control.closeEditor()
        if control.table != .initial { control.update(.initial) }
    }

    /// Runs `action`, which opens a link, and returns where it opened: the tab a browser window reported through
    /// `e2eLinkOpened`, or the Little Arc window that opened meanwhile.
    func routedLink(
        token: Int, _ action: (_ opened: @escaping (URL, LinkSource?, BrowserWindowController) -> Void) throws -> Void
    ) rethrows -> E2ERoutedLink {
        let center = littleArcCenter
        let before = Set(center.panels.map(ObjectIdentifier.init))
        var result = E2ERoutedLink(page: nil, spaceTitle: nil, profileID: nil, littleArc: false)
        try action { [unowned self] _, _, controller in
            guard let tab = controller.selectedTab else { return }
            result = E2ERoutedLink(
                page: track(tab, in: controller, token: token), spaceTitle: controller.activeSpace?.title,
                profileID: tab.profileID.rawValue, littleArc: false)
        }
        if let panel = center.panels.first(where: { !before.contains(ObjectIdentifier($0)) }), let tab = panel.tab,
            let controller = delegate.linkWindow()
        {
            // The page's calls need a browser window: the one it can move into, as the Little Arc area does.
            let page = track(tab, in: controller, token: token)
            panel.e2eTabEvent = { [weak page] _, event in page?.tabDidReceive(event) }
            result = E2ERoutedLink(page: page, spaceTitle: nil, profileID: tab.profileID.rawValue, littleArc: true)
        }
        return result
    }

    /// The process ID of a helper process of this app (Chromium's renderer, for example) and its bundle identifier.
    func helperProcess() -> (pid: pid_t, bundleID: String)? {
        let count = proc_listchildpids(getpid(), nil, 0)
        guard count > 0 else { return nil }
        var children = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = children.withUnsafeMutableBytes {
            proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count))
        }
        guard found > 0 else { return nil }
        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks").path + "/"
        for pid in children.prefix(Int(found)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path.hasPrefix(frameworks), let helperRange = path.range(of: ".app/", options: .backwards)
            else { continue }
            let helperApp = URL(fileURLWithPath: String(path[..<helperRange.lowerBound]) + ".app")
            let info = CFBundleCopyInfoDictionaryForURL(helperApp as CFURL) as NSDictionary?
            guard let helperID = info?[kCFBundleIdentifierKey as String] as? String else { continue }
            return (pid, helperID)
        }
        return nil
    }
}

extension E2ETestApp: E2ERoutingApp {
    func setRoutingTable(_ table: RoutingTable) throws {
        try adapter.requireActive(token, "change the routing rules")
        if let problem = adapter.airTrafficControl.update(table) {
            throw E2EError("saving the rules failed: \(problem)")
        }
    }

    func reloadedRoutingTable() throws -> RoutingTable {
        try adapter.requireActive(token, "reload the routing rules")
        let folder = adapter.airTrafficControl.fileURL.deletingLastPathComponent()
        return AirTrafficControl(dataDirectory: folder).table
    }

    func routingTable() throws -> RoutingTable {
        try adapter.requireActive(token, "read the routing rules")
        return adapter.airTrafficControl.table
    }

    func sendLinks(as bundleID: String?) throws {
        try adapter.requireActive(token, "name the sender's app")
        let own = routingAppBundleID
        AirTrafficControl.e2eSourceRenames = bundleID.map { [own: $0] } ?? [:]
    }

    var routingAppBundleID: String { Bundle.main.bundleIdentifier ?? "" }

    func deliverRoutedLink(_ url: URL) throws -> E2ERoutedLink {
        try adapter.requireActive(token, "deliver a link")
        let delegate = adapter.delegate
        return try adapter.routedLink(token: token) { opened in
            try E2EAppAdapter.deliver(
                [E2ELink(address: url.absoluteString, sender: true)], delegate: delegate, opened: opened)
        }
    }

    func deliverLinkFromHelper(_ url: URL) throws -> (helper: String, opened: E2ERoutedLink)? {
        try adapter.requireActive(token, "deliver a link from a helper")
        guard let helper = adapter.helperProcess() else { return nil }
        let delegate = adapter.delegate
        // The sender as the GetURL handler reads it: the helper's process, which counts as the app that contains it.
        let link = IncomingLink(url: url, source: ExternalLinks.source(processID: helper.pid))
        let opened = adapter.routedLink(token: token) { opened in
            delegate.e2eLinkOpened = opened
            defer { delegate.e2eLinkOpened = nil }
            delegate.openIncomingLink(link)
        }
        return (helper.bundleID, opened)
    }

    func openRoutingEditor(from page: any E2EPage) throws {
        try adapter.requireActive(token, "open the rule editor")
        try adapter.chooseMenuItem(path: ["Bow", AirTrafficControlMenuFeature.title], in: page, allowAppTarget: true)
    }

    func routingEditor() throws -> E2ERoutingEditorState? {
        try adapter.requireActive(token, "read the rule editor")
        guard let editor = adapter.airTrafficControl.editor, let window = editor.window, window.isVisible else {
            return nil
        }
        return E2ERoutingEditorState(
            rows: (0..<editor.tableView.numberOfRows).map(editor.shownRow),
            lastSourceLine: editor.lastSourceLabel.stringValue,
            defaultTitle: editor.defaultPopUp.titleOfSelectedItem ?? "",
            intrudes: window.isKeyWindow || NSScreen.screens.contains { $0.frame.intersects(window.frame) },
            frame: window.frame, isKey: window.isKeyWindow)
    }

    func moveRuleDownInEditor(row: Int) throws {
        try adapter.requireActive(token, "move a rule")
        guard let editor = adapter.airTrafficControl.editor else { throw E2EError("the rule editor is not open") }
        editor.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard editor.downButton.isEnabled else { throw E2EError("Move Down is disabled for rule \(row + 1)") }
        editor.downButton.performClick(nil)
    }

    func closeRoutingEditor() throws {
        try adapter.requireActive(token, "close the rule editor")
        guard let editor = adapter.airTrafficControl.editor, let window = editor.window else {
            throw E2EError("the rule editor is not open")
        }
        guard let button = window.standardWindowButton(.closeButton) else {
            throw E2EError("the rule editor has no close button")
        }
        button.performClick(nil)
        if adapter.airTrafficControl.editor != nil { throw E2EError("the rule editor stayed open") }
    }

    var routingOpenBrowsers: Int { adapter.openBrowserCount }
}
