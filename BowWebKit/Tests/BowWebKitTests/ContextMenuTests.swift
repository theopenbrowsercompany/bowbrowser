import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab delegate that answers context menus, records each request and each command it was asked to run, and hands
/// every other event to the rig's recording delegate.
@MainActor
private final class MenuDelegate: EngineTabDelegate {
    let recorder: RecordingTabDelegate
    private(set) var requests: [ContextMenuRequest] = []
    private(set) var commands: [ContextMenuCommand] = []
    /// The answer to each request; Bow's own menu by default.
    var decision: (ContextMenuRequest) -> ContextMenuDecision = { ContextMenuPolicy.defaultDecision(for: $0) }
    /// The commands the app runs itself; every other one is left to the engine.
    var runsItself: Set<ContextMenuCommand> = [.openLinkInNewTab, .inspect]

    init(_ recorder: RecordingTabDelegate) {
        self.recorder = recorder
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        recorder.tab(tab, didReceive: event)
    }

    func tab(_ tab: any EngineTab, decideContextMenu request: ContextMenuRequest) -> ContextMenuDecision {
        requests.append(request)
        return decision(request)
    }

    func tab(_ tab: any EngineTab, runContextMenuCommand command: ContextMenuCommand, request: ContextMenuRequest)
        -> Bool
    {
        commands.append(command)
        return runsItself.contains(command)
    }
}

/// A menu as the tab left it just before it would open.
@MainActor
private struct OpenedMenu {
    var items: [NSMenuItem]
    var identifiers: [String]

    var titles: [String] { items.filter { !$0.isSeparatorItem }.map(\.title) }

    /// Chooses the item titled `title` the way AppKit does when the person picks it: its action sent to its target.
    func choose(_ title: String) throws {
        guard let item = items.first(where: { $0.title == title }), let action = item.action else {
            throw TestError("no item \(title) in \(titles)")
        }
        #expect(item.isEnabled, "\(title) is disabled")
        #expect(NSApp.sendAction(action, to: item.target, from: item), "\(title) reached no target")
    }
}

/// A right click on a link, an image, a field, a selection and a cross origin frame gives the delegate the target
/// W1 criterion 3 found, Bow's menu replaces WebKit's, and its commands reach the app or run in the engine.
@Suite(.serialized) @MainActor struct ContextMenuTests {
    init() {
        TestHost.start()
    }

    /// A right click at `point` (page coordinates) as AppKit delivers a real one, to the web view's window; returns
    /// once WebKit has handled it.
    private func rightClick(_ webView: WKWebView, at point: CGPoint) async throws {
        guard let window = webView.window as? TestWindow else { throw TestError("the web view is in no test window") }
        window.reportsKey = true
        let at = PageDriver(webView).windowPoint(point)
        for type in [NSEvent.EventType.mouseMoved, .rightMouseDown, .rightMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .rightMouseDown ? 1 : 0)
            else { throw TestError("could not make a \(type) event") }
            window.sendEvent(event)
        }
        #expect(await WebKitSPI.afterPendingMouseEvents(webView), "WebKit did not finish the right click")
    }

    /// The public fallback, where WebKit does not ask the tab first: `willOpenMenu(_:with:)`, called here as AppKit
    /// calls it (the menu then never opens, since nothing tracks it), rebuilds the menu from the delegate's answer,
    /// empties it for a `.none` answer, and leaves a menu the private callback already gave alone.
    @Test func willOpenMenuRebuildsOrEmptiesTheMenu() async throws {
        let rig = try TabRig()
        let tab = rig.tab("/contextmenu/target.html")
        let delegate = MenuDelegate(rig.delegate)
        tab.delegate = delegate
        do {
            try await fallback(tab, rig, delegate)
        } catch {
            try? await rig.finish()
            throw error
        }
        try await rig.finish()
    }

    private func fallback(_ tab: WebKitTab, _ rig: TabRig, _ delegate: MenuDelegate) async throws {
        let page = rig.url("/contextmenu/target.html")
        try await rig.waitFor("finish \(page)")
        try await waitUntil("the tab's address \(page)") { tab.state.url == page }
        let webView = try #require(tab.webView)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        func webKitMenu() -> NSMenu {
            let menu = NSMenu()
            let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
            menu.addItem(item)
            return menu
        }

        let shown = webKitMenu()
        webView.willOpenMenu(shown, with: event)
        let request = try #require(delegate.requests.last)
        let expected = ContextMenuPolicy.items(for: request).filter { !$0.isSeparator }.map(\.title)
        let titles = shown.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(request.pageURL == page && titles == expected, "fallback menu \(titles) for \(request)")

        delegate.decision = { _ in .none }
        let emptied = webKitMenu()
        webView.willOpenMenu(emptied, with: event)
        let emptiedOK = emptied.items.isEmpty && !emptied.allowsContextMenuPlugIns && delegate.requests.count == 2
        #expect(emptiedOK, "a .none answer left \(emptied.items.map(\.title))")

        // A menu the private callback already built is left as it is, and asks no second time.
        webView.contextMenuHandled = true
        let given = webKitMenu()
        webView.willOpenMenu(given, with: event)
        #expect(given.items.map(\.title) == ["Copy"] && delegate.requests.count == 2 && !webView.contextMenuHandled)
        print(
            "\(titles == expected && emptiedOK ? "PASS" : "FAIL") contextmenu.fallback: show \(titles), "
                + "none \(emptied.items.map(\.title))")
    }

    @Test func rightClickGivesTheTargetAndRunsCommands() async throws {
        let rig = try TabRig()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("bow.test.contextmenu.\(UUID().uuidString)"))
        WebKitTab.contextMenuPasteboard = pasteboard
        defer {
            WebKitTab.contextMenuPasteboard = .general
            pasteboard.releaseGlobally()
        }
        let tab = rig.tab("/contextmenu/index.html")
        let delegate = MenuDelegate(rig.delegate)
        tab.delegate = delegate
        do {
            try await walk(tab, rig, delegate, pasteboard)
        } catch {
            try? await rig.finish()
            throw error
        }
        try await rig.finish()
        #expect(TestHost.windowsOnScreen().isEmpty, "a menu reached a screen")
        #expect(IsolationMonitor.violations.isEmpty, "windows seen on a screen: \(IsolationMonitor.violations)")
    }

    /// The walk itself, holding the web view only while it runs, so `finish()` can check it is released.
    private func walk(_ tab: WebKitTab, _ rig: TabRig, _ delegate: MenuDelegate, _ pasteboard: NSPasteboard)
        async throws
    {
        let page = rig.url("/contextmenu/index.html")
        try await rig.waitFor("finish \(page)")
        let webView = try #require(tab.webView)
        try await PageDriver(webView).waitForLoad(of: page)
        try await waitUntil("the cross origin frame loaded") {
            try await PageDriver(webView).string("return document.body.dataset.frameLoaded || ''") == "1"
        }
        rig.window.makeFirstResponder(webView)

        // The menu as the tab rebuilt it, recorded and kept from opening (WebKit's private callback then gets nil),
        // so no menu reaches a screen.
        var menus: [OpenedMenu] = []
        webView.onContextMenu = { menu in
            menus.append(
                OpenedMenu(items: menu.items, identifiers: menu.items.compactMap { $0.identifier?.rawValue }))
            return false
        }

        /// Right clicks `selector` and returns the request and the menu it gave, which came through WebKit's
        /// private callback and opened on no screen.
        func open(_ name: String, _ selector: String) async throws -> (ContextMenuRequest, OpenedMenu, CGPoint) {
            let point = try await PageDriver(webView).centre(of: selector)
            let requestsBefore = delegate.requests.count
            let menusBefore = menus.count
            let callbacksBefore = webView.contextMenuCallbacks
            try await rightClick(webView, at: point)
            try await waitUntil(
                "the \(name) request, menu and callback; requests \(delegate.requests.count), menus \(menus.count), "
                    + "callbacks \(webView.contextMenuCallbacks)", timeout: 5
            ) {
                delegate.requests.count == requestsBefore + 1 && menus.count == menusBefore + 1
                    && webView.contextMenuCallbacks == callbacksBefore + 1
            }
            IsolationMonitor.check()
            #expect(TestHost.windowsOnScreen().isEmpty, "the \(name) menu reached a screen")
            return (delegate.requests[requestsBefore], menus[menusBefore], point)
        }

        func near(_ position: PagePoint, _ point: CGPoint) -> Bool {
            abs(position.x - point.x) < 2 && abs(position.y - point.y) < 2
        }

        func report(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL") contextmenu.\(name): \(detail)")
        }

        let linkURL = rig.url("/contextmenu/target.html")
        let imageURL = rig.url("/contextmenu/image.svg")
        let frameURL = URL(string: rig.server.otherBase + "/contextmenu/frame.html")!
        _ = try await PageDriver(webView).eval("getSelection().removeAllRanges(); return true")

        // Link: its address and text, and Bow's link items in place of WebKit's.
        let (link, linkMenu, linkPoint) = try await open("link", "#link")
        let linkOK =
            link.linkURL == linkURL && link.linkText == "Target link" && link.imageURL == nil && !link.isEditable
            && link.frameURL == nil && link.pageURL == page && near(link.position, linkPoint)
            && linkMenu.titles == ContextMenuPolicy.items(for: link).filter { !$0.isSeparator }.map(\.title)
            && linkMenu.titles.first == "Open Link in New Tab"
        #expect(linkOK, "link request \(link), menu \(linkMenu.titles)")
        report("link", linkOK, "link \(link.linkURL?.absoluteString ?? "nil") text \(link.linkText ?? "nil") menu \(linkMenu.titles)")

        // Image: its source.
        let (image, _, _) = try await open("image", "#image")
        let imageOK = image.imageURL == imageURL && image.linkURL == nil && !image.isEditable && image.frameURL == nil
        #expect(imageOK, "image request \(image)")
        report("image", imageOK, "image \(image.imageURL?.absoluteString ?? "nil")")

        // Field: editable, with no selection text.
        let (field, fieldMenu, _) = try await open("field", "#field")
        let fieldOK = field.isEditable && field.linkURL == nil && field.selectionText.isEmpty
            && fieldMenu.titles.contains("Paste")
        #expect(fieldOK, "field request \(field), menu \(fieldMenu.titles)")
        report("field", fieldOK, "editable \(field.isEditable) flags \(field.editFlags.rawValue) menu \(fieldMenu.titles)")

        // Selection: focus leaves the field first, or the selection stays in it.
        _ = try await PageDriver(webView).eval(
            "document.activeElement?.blur(); getSelection().selectAllChildren(document.getElementById('para')); return true"
        )
        let (selection, selectionMenu, _) = try await open("selection", "#para")
        let selectionOK =
            selection.selectionText.hasPrefix("A paragraph of plain text") && !selection.isEditable
            && selection.linkURL == nil && selectionMenu.titles.contains("Copy")
        #expect(selectionOK, "selection request \(selection), menu \(selectionMenu.titles)")
        report("selection", selectionOK, "text \"\(selection.selectionText)\" menu \(selectionMenu.titles)")
        _ = try await PageDriver(webView).eval("getSelection().removeAllRanges(); return true")

        // Cross origin frame: the frame's own address, and the page's.
        let (frame, _, _) = try await open("iframe", "#frame")
        let frameOK = frame.frameURL == frameURL && frame.pageURL == page && frame.linkURL == nil && !frame.isEditable
        #expect(frameOK, "iframe request \(frame)")
        report("iframe", frameOK, "frame \(frame.frameURL?.absoluteString ?? "nil") page \(frame.pageURL?.absoluteString ?? "nil")")

        // Commands: the app runs Open Link in New Tab and Inspect itself; Copy Link Address it leaves to the engine,
        // which puts the address on the pasteboard.
        try linkMenu.choose("Open Link in New Tab")
        try linkMenu.choose("Inspect")
        try linkMenu.choose("Copy Link Address")
        let copied = pasteboard.string(forType: .string)
        let commandsOK =
            delegate.commands == [.openLinkInNewTab, .inspect, .copyLinkAddress] && copied == linkURL.absoluteString
        #expect(commandsOK, "commands \(delegate.commands), pasteboard \(copied ?? "nil")")
        report("commands", commandsOK, "commands \(delegate.commands) pasteboard \(copied ?? "nil")")

        // The page cancels its menu: no question and no menu, as in Safari and Chromium.
        let requestsBefore = delegate.requests.count
        let menusBefore = menus.count
        try await rightClick(webView, at: try await PageDriver(webView).centre(of: "#cancelled"))
        try await waitUntil("the page saw its cancelled contextmenu event") {
            try await PageDriver(webView).string("return document.body.dataset.cancelled || ''") == "1"
        }
        _ = await WebKitSPI.afterPendingMouseEvents(webView)
        let cancelledOK = delegate.requests.count == requestsBefore && menus.count == menusBefore
        #expect(cancelledOK, "a cancelled contextmenu event still asked (\(delegate.requests.count - requestsBefore))")
        report("cancelled", cancelledOK, "requests \(delegate.requests.count - requestsBefore)")

        // Show nothing: the menu is emptied, so it does not open. The engine's own: WebKit's items stay.
        delegate.decision = { _ in .none }
        let (_, noneMenu, _) = try await open("none", "#link")
        #expect(noneMenu.items.isEmpty, "a .none answer left \(noneMenu.titles)")
        delegate.decision = { _ in .engineDefault }
        let (_, engineMenu, _) = try await open("engine default", "#link")
        #expect(
            engineMenu.identifiers.contains("WKMenuItemIdentifierOpenLinkInNewWindow"),
            "WebKit's own menu: \(engineMenu.identifiers)")
        report("decisions", noneMenu.items.isEmpty, "none \(noneMenu.titles) engine default \(engineMenu.identifiers)")

        // The target script is in Bow's own world: neither the page nor another world sees its handler.
        let pageSees = try await webView.evaluateJavaScript("typeof window.webkit?.messageHandlers?.bowContextMenu")
        #expect(pageSees as? String == "undefined")
        #expect(
            try await PageDriver(webView).string("return typeof window.webkit?.messageHandlers?.bowContextMenu")
                == "undefined")

        // A choice made after the page moved on is dropped.
        let commandsBefore = delegate.commands
        pasteboard.clearContents()
        tab.load(linkURL)
        try await rig.waitFor("finish \(linkURL.absoluteString)")
        try linkMenu.choose("Copy Link Address")
        try linkMenu.choose("Open Link in New Tab")
        #expect(delegate.commands == commandsBefore, "a choice for a page gone ran: \(delegate.commands)")
        #expect(pasteboard.string(forType: .string) == nil)
        webView.onContextMenu = nil
    }
}
