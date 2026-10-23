import AppKit
import BowCore

@objc(AppDelegate)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let homeURL = URL(string: "https://www.google.com")!
    /// Chromium's profiles and caches for normal and smoke runs.
    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bow", isDirectory: true)
    }
    private static let smokeTestTimeout: TimeInterval = 30
    /// A smoke run fails with `BowEngineQuitTimeoutExitCode` if quitting takes longer than this.
    private static let smokeQuitTimeout: TimeInterval = 2
    /// Exit code for switches the app cannot parse (EX_USAGE).
    private static let usageExitCode: Int32 = 64

    /// The engine as app code sees it: the BowCore protocols over the bridge.
    let engine: any BrowserEngine = CEFEngine()
    private var windowControllers: [BrowserWindowController] = []
    private var options = LaunchOptions()
    /// Where the engine keeps its profiles for this launch; app services keep their files beside them.
    private var rootDataDirectory = AppDelegate.dataDirectory
    /// The app's services (`AppFeatures.all`), created on first use, once launch has settled the data directory.
    private(set) lazy var appFeatures = AppFeatureSet(dataDirectory: rootDataDirectory)
    #if BOW_E2E
        private var e2eRunner: E2ERunner?  // E2E seam
        /// True only while the harness delivers a link of its own, which an e2e run takes like a real one.
        var e2eDeliversLinks = false  // E2E seam
        /// Told about each link from another app that opened, with its sender and the window it opened in.
        var e2eLinkOpened: ((URL, LinkSource?, BrowserWindowController) -> Void)?  // E2E seam
        /// Opens the window Open in Bow needs with no browser window open, off screen, given how to open it.
        typealias E2EWindowOpen = (BrowserWindow) throws -> BrowserWindowController  // E2E seam
        var e2eOpenWindow: ((E2EWindowOpen) throws -> BrowserWindowController)?  // E2E seam
    #endif
    /// True from `engineDidStart` (an e2e run too, which leaves `engineStarted` false) until launch refuses to start:
    /// a reopen opens windows only then.
    private var engineReady = false
    /// True once the engine has started and windows can open.
    private var engineStarted = false
    /// Links from other apps: kept until the engine has started and the first window is open, dropped once launch
    /// refuses to start.
    private(set) var linkIntake = LinkIntake()
    private var smokeTimer: Timer?
    private var smokeFinished = false
    /// The smoke run's window, for the navigation delegate methods that finish the run.
    private weak var smokeController: BrowserWindowController?

    /// Called by main before Chromium starts: reads the launch switches and says how to start the engine.
    /// Returns nil, with `BowEngine.exitCode` set, when the switches are unusable and the app should exit.
    @objc func engineConfiguration() -> BowEngineConfiguration? {
        do {
            options = try LaunchOptions.parse(ProcessInfo.processInfo.arguments)
            if options.isE2E {
                #if BOW_E2E
                    let runner = try E2ERunner(options: options)  // E2E seam: the runner sets up the run.
                    e2eRunner = runner
                    rootDataDirectory = URL(fileURLWithPath: runner.engineConfiguration.rootDataDirectory)
                    return runner.engineConfiguration
                #else
                    FileHandle.standardError.write(
                        Data("bow: --e2e needs a Debug build; this one has no e2e harness\n".utf8))
                    BowEngine.exitCode = Self.usageExitCode
                    return nil
                #endif
            }
        } catch {
            FileHandle.standardError.write(Data("bow: \(error)\n".utf8))
            BowEngine.exitCode = Self.usageExitCode
            return nil
        }

        // Before Chromium starts: it keeps its profiles in this folder and could stop before any alert shows.
        do {
            try SidebarStores.prepareDataFolder(Self.dataDirectory)
        } catch {
            FileHandle.standardError.write(Data("bow: \(error)\n".utf8))
            if !options.isSmokeTest {
                NSApp.activate()
                SidebarStores.showAlert(error, in: nil)
            }
            BowEngine.exitCode = 1
            return nil
        }
        let configuration = BowEngineConfiguration(rootDataDirectory: Self.dataDirectory.path)
        if options.isSmokeTest {
            configuration.quitTimeout = Self.smokeQuitTimeout
            configuration.reportsQuitTime = true
        }
        return configuration
    }

    /// Installs the handler for links from other apps before AppKit delivers the launch's events, so a link that
    /// launched Bow is not lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        #if BOW_E2E
            e2eRunner?.linkHandlerInstalled(delegate: self)  // E2E seam: tests deliver links before the engine starts.
        #endif
    }

    /// Called by the engine once Chromium is ready to create browsers.
    @objc func engineDidStart() {
        // Tabs live in the sidebar, so AppKit's own window tabs (and their menu items) stay off.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.make()
        engineReady = true
        #if BOW_E2E
            if let e2eRunner {  // E2E seam: an e2e run hands control to its runner.
                e2eRunner.start(delegate: self)
                return
            }
        #endif

        engineStarted = true
        if options.isSmokeTest {
            // A smoke run opens its page in a sidebar of its own, so it never adds tabs to the person's sidebar.
            let startURL = options.smokeInput.flatMap(AddressInput.resolve) ?? Self.homeURL
            guard let profile = engine.profile(id: .default) else {
                // Never the person's own sidebar in its place.
                finishSmokeTest("the engine has no default profile", exitCode: 1)
                return
            }
            do {
                let controller = try openWindow(url: startURL, profile: profile)
                // Stay in the background so a smoke run never takes the keyboard from whoever is typing.
                controller.window?.orderBack(nil)
                runSmokeTest(in: controller)
            } catch {
                finishSmokeTest("no window opened: \(error)", exitCode: 1)
                return
            }
        } else {
            // The saved sidebar comes back with only its active tab loading; an empty one opens the home page.
            NSApp.activate()
            let controller: BrowserWindowController
            do {
                controller = try openWindow(url: nil)
            } catch {
                // Bow refuses to start rather than run on a sidebar that would not be saved. Links kept until now
                // and links that arrive while the alert is open are dropped, so no second alert stacks on it.
                linkIntake.refuse()
                engineReady = false  // a reopen must not open a window on the sidebar that failed
                appFeatures.require(SidebarStores.self).present(error, in: nil)
                BowEngine.exitCode = 1
                NSApp.terminate(nil)
                return
            }
            controller.showWindow(nil)
            // Folders of profiles deleted last run go now: no browser of theirs was created this run.
            appFeatures.require(ProfileRegistryStore.self).deleteMarkedFolders(
                spaceProfiles: controller.store.graph.spaces.map(\.profileID))
        }
        openKeptLinks()
    }

    /// Opens the links kept until the engine started, oldest first; links from then on open as they arrive.
    func openKeptLinks() {
        for link in linkIntake.open() { openIncomingLink(link) }
    }

    /// Called by main after the engine has shut down, just before the process exits with `BowEngine.exitCode`.
    @objc func engineDidStop() {
        // The sidebar is saved after every change; this writes one a failed save left behind.
        if engineStarted { appFeatures.require(SidebarStores.self).saveAll() }
        #if BOW_E2E
            e2eRunner?.engineDidStop()  // E2E seam
        #endif
    }

    /// A link from another app (a link clicked in Mail, `open https://...`), as a GetURL Apple Event: AppKit's own
    /// handler is replaced so the event's sender can be read. Each link opens in Little Arc or a browser window
    /// (`openIncomingLink`). Links that arrive before the engine has started open once it has, in order; links while
    /// Bow quits, or while launch refuses to start, are dropped, and so is anything that is not an http or https
    /// address.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor)
    {
        // An e2e or smoke run is a throwaway beside the person's own Bow: a link meant for them never opens in it.
        var forThisRun = !options.isE2E && !options.isSmokeTest
        #if BOW_E2E
            if e2eDeliversLinks { forThisRun = true }  // E2E seam: a link the harness itself delivers.
        #endif
        guard forThisRun, !BowEngine.isQuitting, let link = ExternalLinks.link(from: event) else { return }
        if let link = linkIntake.receive(link) { openIncomingLink(link) }
    }

    /// Opens a link from another app where Air Traffic Control's rules send it (`AirTrafficControl.decide`), before
    /// any tab exists for it: a new tab created in the routed Space, or in a Space of the routed profile, so its first
    /// request goes out there; Little Arc; or the browser window (`openLink`). When no rule matches, the default
    /// applies; a default of Little Arc (the initial one) opens a new Little Arc window while "links from other apps
    /// open in Little Arc" is on (as in Arc), its page in the profile of the link window's Space on screen or, with no
    /// browser window open, of the Space shown last (as Arc opens Little Arc with no window open), and otherwise opens
    /// in a browser window.
    func openIncomingLink(_ link: IncomingLink) {
        let profile = littleArcProfile()
        let decision = appFeatures.require(AirTrafficControl.self).decide(link, isAvailable: routingDestinationExists)
        let opening = LinkRouting.opening(
            for: decision, littleArcSetting: LittleArcCenter.opensExternalLinks, hasSpace: profile != nil)
        switch opening {
        case .space(let id):
            openRoutedLink(link) { $0.space(id) != nil ? id : nil }
        case .profile(let id):
            openRoutedLink(link) { LinkRouting.spaceID(forProfile: id, in: $0) }
        case .littleArc:
            // A Space without its profile opens no page; the window path reports that.
            guard let profile else {
                openLink(link.url, from: link.source)
                return
            }
            appFeatures.require(LittleArcCenter.self).open(
                link.url, in: profile,
                permissions: PermissionPrompts.ProfilePermissions(
                    store: appFeatures.require(SitePermissionStores.self).store(for: profile), profile: profile),
                takesFocus: !options.isE2E,
                browserWindow: { [weak self] in self?.linkWindow() },
                openWindow: { [weak self] profileID in self?.openWindowForLittleArc(profileID: profileID) },
                closed: { [weak self] in self?.littleArcClosed() })
        case .browserWindow:
            openLink(link.url, from: link.source)
        }
    }

    /// The browser window a link goes to: the main window, else the last one on screen or in the Dock, else, while
    /// Bow is hidden and so no window is on screen, the last one. A window that is closing opens no tab, so it is
    /// skipped. Nil when no window can take the link.
    func linkWindow() -> BrowserWindowController? {
        let open = windowControllers.filter { !$0.isClosing }
        return open.first(where: { $0.window?.isMainWindow == true })
            ?? open.last(where: { $0.window.map { $0.isVisible || $0.isMiniaturized } == true })
            ?? (NSApp.isHidden ? open.last : nil)
    }

    /// The sidebar of the browser window that closed last, while something still holds it (the app's own sidebar
    /// always is). Weak, so a closed window's sidebar of its own is not kept for Little Arc.
    private weak var lastClosedSidebar: SidebarStore?

    /// The sidebar whose Space on screen is the Space shown last when no browser window is open: the last closed
    /// window's, else the app's own (never in an e2e run, whose windows have sidebars of their own).
    private var lastShownSidebar: SidebarStore? {
        if let lastClosedSidebar { return lastClosedSidebar }
        guard engineStarted, !options.isE2E else { return nil }
        return try? appFeatures.require(SidebarStores.self).main().store
    }

    /// The profile a Little Arc page opens in: that of the link window's Space on screen, else, with no browser window
    /// open, that of the Space shown last. Nil when neither has a profile the engine can open.
    private func littleArcProfile() -> (any EngineProfile)? {
        if let window = linkWindow() { return window.activeProfile }
        guard let profileID = lastShownSidebar?.graph.activeSpace?.profileID else { return nil }
        return appFeatures.require(ProfileRegistryStore.self).engineProfile(for: profileID, engine: engine)
    }

    /// Open in Bow from Little Arc with no browser window open: opens a window on the sidebar shown last, showing a
    /// Space of profile `profileID` (`LittleArc.newWindowSpace`), so the page can move into it. Returns nil, opening
    /// nothing, when that sidebar has no Space of the profile or the window cannot open.
    private func openWindowForLittleArc(profileID: SidebarProfileID) -> BrowserWindowController? {
        guard let store = lastShownSidebar,
            let spaceID = LittleArc.newWindowSpace(in: store.graph, profileID: profileID)
        else { return nil }
        if store.graph.activeSpaceID != spaceID {
            guard (try? store.switchToSpace(spaceID)) != nil else { return nil }
        }
        // The page arriving is the Space's new tab, so an empty Space opens no home page beside it.
        let open = { [self] (window: BrowserWindow?) throws(SidebarNotice) -> BrowserWindowController in
            try openWindow(url: nil, store: store, window: window, opensHomePage: false)
        }
        #if BOW_E2E
            if let e2eOpenWindow { return try? e2eOpenWindow { window in try open(window) } }  // E2E seam
        #endif
        guard !options.isE2E else { return nil }
        do {
            let controller = try open(nil)
            controller.showWindow(nil)
            return controller
        } catch {
            appFeatures.require(SidebarStores.self).present(error, in: nil)
            return nil
        }
    }

    /// Opens a link from another app in a browser window, in the profile of the target window's Space on screen, as
    /// Arc does without rules. `source` is the app that sent it. Returns the window it opened in, or nil when it opened
    /// nowhere (an e2e run never opens an on screen window for it).
    @discardableResult
    func openLink(_ url: URL, from source: LinkSource? = nil) -> BrowserWindowController? {
        // With no window to take it (`linkWindow`), the link opens a new one.
        if let controller = linkWindow() { return openLink(url, from: source, in: controller) }
        guard !options.isE2E else { return nil }
        let controller = openWindowOrExplain(url: url)
        controller?.showWindow(nil)
        return controller
    }

    /// Opens `url` in a new tab of `controller`'s Space on screen and brings the window forward.
    @discardableResult
    private func openLink(_ url: URL, from source: LinkSource?, in controller: BrowserWindowController)
        -> BrowserWindowController?
    {
        guard controller.openTab(url: url) != nil else { return nil }
        #if BOW_E2E
            e2eLinkOpened?(url, source, controller)  // E2E seam
        #endif
        // Brought forward (out of the Dock too), so the link is seen; e2e windows stay off screen and never key.
        if !options.isE2E {
            controller.window?.deminiaturize(nil)
            controller.showWindow(nil)
            NSApp.activate()
        }
        return controller
    }

    /// Opens a routed link in the Space `space` picks from a window's sidebar: the link window when it has one, else
    /// the most recently used window that has one. The window shows that Space first, then the tab is created in it,
    /// so its page loads in the Space's profile from its first request and never moves. With no window showing such a
    /// Space, a new window opens on the app's sidebar with that Space on screen; failing that the link opens as
    /// without rules.
    private func openRoutedLink(_ link: IncomingLink, space: (SidebarGraph) -> SidebarSpaceID?) {
        let open = windowControllers.filter { !$0.isClosing }
        let candidates = (linkWindow().map { [$0] } ?? []) + open.reversed()
        for controller in candidates {
            guard let id = space(controller.store.graph) else { continue }
            if controller.store.graph.activeSpaceID != id {
                if let sidebar = controller.feature(SidebarFeature.self) {
                    SpaceActions.show(id, context: sidebar)
                } else {
                    controller.changeSidebar { try $0.switchToSpace(id) }
                }
            }
            guard controller.store.graph.activeSpaceID == id else { continue }
            openLink(link.url, from: link.source, in: controller)
            return
        }
        if !options.isE2E, let main = try? appFeatures.require(SidebarStores.self).main().store,
            let id = space(main.graph), (try? main.switchToSpace(id)) != nil
        {
            openWindowOrExplain(url: link.url)?.showWindow(nil)
            return
        }
        openLink(link.url, from: link.source)
    }

    /// The sidebars the open windows show, and the app's own sidebar once it is open.
    private var routingGraphs: [SidebarGraph] {
        var graphs = windowControllers.filter { !$0.isClosing }.map(\.store.graph)
        if engineStarted, !options.isE2E, let main = try? appFeatures.require(SidebarStores.self).main().store {
            graphs.append(main.graph)
        }
        return graphs
    }

    /// Whether a routing destination still exists: a Space some sidebar holds, or a profile some Space shows (a link
    /// opens in a Space, so a profile with none cannot take it).
    private func routingDestinationExists(_ destination: RouteDestination) -> Bool {
        let graphs = routingGraphs
        let spaces = graphs.flatMap(\.spaces)
        return LinkRouting.isAvailable(
            destination, spaceIDs: Set(spaces.map(\.id.rawValue)), profileIDs: Set(spaces.map(\.profileID.rawValue)))
    }

    /// Bow > Air Traffic Control…: shows the routing rules editor, which offers every Space the windows show, every
    /// profile, Little Arc and the most recent window as destinations.
    func showAirTrafficControl() {
        appFeatures.require(AirTrafficControl.self).showEditor(takesFocus: !options.isE2E) { [weak self] in
            self?.routingChoices() ?? []
        }
    }

    /// The destinations the editor offers, in order: Spaces (in sidebar order, each once), profiles, Little Arc, the
    /// most recent window.
    private func routingChoices() -> [AirTrafficControl.Choice] {
        var choices: [AirTrafficControl.Choice] = []
        var seen = Set<String>()
        for space in routingGraphs.flatMap(\.spaces) where seen.insert(space.id.rawValue).inserted {
            choices.append(.init(title: "Space: \(space.title)", destination: .space(id: space.id.rawValue)))
        }
        var profiles: [(id: String, name: String)] =
            appFeatures.require(ProfileRegistryStore.self).registry?.profiles.map { ($0.id.rawValue, $0.name) } ?? []
        for space in routingGraphs.flatMap(\.spaces)
        where !profiles.contains(where: { $0.id.lowercased() == space.profileID.rawValue.lowercased() }) {
            profiles.append((space.profileID.rawValue, space.profileID.rawValue))
        }
        for profile in profiles {
            choices.append(.init(title: "Profile: \(profile.name)", destination: .profile(id: profile.id)))
        }
        choices.append(.init(title: "Little Arc", destination: .littleArc))
        choices.append(.init(title: "Most recent window", destination: .mostRecentWindow))
        return choices
    }

    /// Opens a window as `openWindow` does, or shows the person why it cannot (an alert of its own) and returns nil.
    func openWindowOrExplain(
        url: URL?,
        profile: (any EngineProfile)? = nil,
        window: BrowserWindow? = nil,
        sidebarStores: SidebarStores? = nil
    ) -> BrowserWindowController? {
        do {
            return try openWindow(url: url, profile: profile, window: window, sidebarStores: sidebarStores)
        } catch {
            (sidebarStores ?? appFeatures.require(SidebarStores.self)).present(error, in: nil)
            return nil
        }
    }

    /// File > Close Tab (Cmd+W) when the key window has no tabs (a page's popup window, for example): closes that
    /// window. A browser window takes the command first and closes its active tab.
    @objc func closeActiveTab(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    /// The browser windows that are not closing, the most recently used last. Little Arc and panels are not browser
    /// windows.
    var openBrowserWindows: [BrowserWindowController] { windowControllers.filter { !$0.isClosing } }

    /// A click on the Dock icon, or launching the app again while it runs (`DockReopen.decide`): with no browser
    /// window open a new one opens on the app's sidebar, so on the Space shown last (even when only Little Arc is
    /// open, as in Arc); a minimized window comes back from the Dock instead of another opening; with a window on
    /// screen the system brings it forward. Nothing opens while quitting or before the engine has started. A window
    /// opened while the app waits for closed tabs' downloads keeps it from quitting afterwards.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A smoke run is a throwaway that opens its one window itself: the system does what it would.
        if options.isSmokeTest { return true }
        guard engineReady else { return false }
        let windows = openBrowserWindows
        let states = windows.map {
            DockReopen.WindowState(
                isVisible: $0.window?.isVisible == true, isMiniaturized: $0.window?.isMiniaturized == true)
        }
        switch DockReopen.decide(windows: states, isQuitting: BowEngine.isQuitting) {
        case .none:
            return true
        case .restore(let index):
            // An e2e window never goes to the Dock: it stays off screen.
            if !options.isE2E {
                windows[index].window?.deminiaturize(nil)
                NSApp.activate()
            }
            return false
        case .openWindow:
            // The sidebar shown last (a window's own sidebar when that closed last), restored as launch does.
            let store = lastShownSidebar
            #if BOW_E2E
                // E2E seam: the harness opens the window off screen.
                if let e2eOpenWindow {
                    _ = try? e2eOpenWindow { try openWindow(url: nil, store: store, window: $0) }
                    return false
                }
            #endif
            guard !options.isE2E else { return false }
            do {
                let controller = try openWindow(url: nil, store: store)
                controller.showWindow(nil)
                NSApp.activate()
            } catch {
                appFeatures.require(SidebarStores.self).present(error, in: nil)
            }
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // An e2e run quits when its tests are done, even if a test closes every window on the way.
        if options.isE2E { return false }
        switch lastWindowClosed() {
        case .stay: return false
        case .quit: return true
        case .waitForDownloads:
            quitWhenClosedTabsReleased()
            return false
        }
    }

    #if BOW_E2E
        /// What the app decided the last time a Little Arc window closed as its last window, nil until then.
        var e2eLittleArcClosedDecision: LastWindowClosed?  // E2E seam
    #endif

    /// A Little Arc window has gone (closed or moved) and left the list of open ones. When it was the app's last
    /// window, the last window rule runs now, since AppKit does not count Little Arc as a window and never asks again:
    /// the app quits, or waits for the downloads of closed tabs and then quits.
    private func littleArcClosed() {
        let openLittleArc = appFeatures.require(LittleArcCenter.self).panels.count
        guard LittleArc.closeEndsLastWindow(openLittleArcWindows: openLittleArc, hasOtherWindow: hasOpenWindow)
        else { return }
        let decision = lastWindowClosed()
        #if BOW_E2E
            e2eLittleArcClosedDecision = decision  // E2E seam
        #endif
        // An e2e run quits when its tests are done, as with its browser windows.
        if options.isE2E { return }
        switch decision {
        case .stay: break
        case .quit: NSApp.terminate(nil)
        case .waitForDownloads: quitWhenClosedTabsReleased()
        }
    }

    /// True while a browser window is open (shown, in the Dock or hidden with the app) or any other window is on
    /// screen or in the Dock. A browser window that is closing does not count, even while it is still on screen, nor
    /// does a Little Arc window (its open ones are `LittleArcCenter.panels`; one closing may still be on screen).
    private var hasOpenWindow: Bool {
        windowControllers.contains { !$0.isClosing }
            || NSApp.windows.contains {
                ($0.isVisible || $0.isMiniaturized) && !($0.windowController is BrowserWindowController)
                    && !($0 is LittleArcWindow)
            }
    }

    /// What the app does when its last browser window has closed.
    enum LastWindowClosed {
        /// It keeps running: a Little Arc window is open, and counts as a window (as in Arc).
        case stay
        /// It quits.
        case quit
        /// Quitting would cancel the downloads of closed tabs, whose pages stay alive until they end: the app stays
        /// open until then, and quits then unless a window has opened meanwhile.
        case waitForDownloads
    }

    /// What the app does now that its last browser window has closed (`applicationShouldTerminateAfterLastWindowClosed`
    /// acts on it), without doing it.
    func lastWindowClosed() -> LastWindowClosed {
        let littleArc = appFeatures.require(LittleArcCenter.self).panels.count
        if LittleArc.keepsAppRunning(openLittleArcWindows: littleArc) { return .stay }
        return engine.keepsClosedTabsForDownloads ? .waitForDownloads : .quit
    }

    /// True while the app waits for closed tabs' downloads to end before quitting after its last window closed.
    private var waitsToQuitAfterDownloads = false

    private func quitWhenClosedTabsReleased() {
        guard !waitsToQuitAfterDownloads else { return }
        waitsToQuitAfterDownloads = true
        Task { [engine] in
            await engine.closedTabsForDownloadsReleased()
            waitsToQuitAfterDownloads = false
            // A browser window opened meanwhile or any other window keeps the app open, as it would have kept it from
            // quitting in the first place. A Little Arc window that keeps it open runs the rule again when it closes.
            let littleArc = appFeatures.require(LittleArcCenter.self).panels.count
            if !hasOpenWindow && !LittleArc.keepsAppRunning(openLittleArcWindows: littleArc) { NSApp.terminate(nil) }
        }
    }

    /// Opens a browser window. With no `profile` it runs on the app's sidebar (saved in the data directory): it opens
    /// `url` in a new tab, or restores the sidebar when `url` is nil (the home page when the sidebar has no tabs).
    /// With a `profile` it runs on a new sidebar of its own whose one Space shows that profile, and opens `url`.
    /// A given `store` is used as it is, as on launch. `window` is the window to use (e2e runs pass an off-screen one),
    /// and `sidebarStores` the stores to take the sidebar from (the app's own when nil). Without `opensHomePage` a
    /// restored Space with no tabs stays empty instead of opening the home page (a page is about to move into it).
    ///
    /// Throws, opening nothing, when the sidebar cannot be opened (the app's sidebar file can be neither read nor set
    /// aside, or a window sidebar cannot be created); the caller shows the notice. A window never runs on a temporary
    /// sidebar in place of the app's. A notice about the sidebar that opened (a file set aside, a Space whose profile
    /// the engine does not have) shows on the window.
    func openWindow(
        url: URL?,
        profile: (any EngineProfile)? = nil,
        store givenStore: SidebarStore? = nil,
        window: BrowserWindow? = nil,
        sidebarStores: SidebarStores? = nil,
        opensHomePage: Bool = true
    ) throws(SidebarNotice) -> BrowserWindowController {
        let stores = sidebarStores ?? appFeatures.require(SidebarStores.self)
        let store: SidebarStore
        var notices: [SidebarNotice] = []
        if let givenStore {
            store = givenStore
        } else if let profile {
            store = try stores.makeWindowStore(profile: SidebarStores.sidebarProfileID(of: profile.profileID))
        } else {
            let main = try stores.main()
            store = main.store
            if let notice = main.notice { notices.append(notice) }
        }
        var url = url
        if url == nil, opensHomePage,
            store.graph.activeSpaceID.map({ store.graph.tabIDs(in: $0).isEmpty }) ?? true
        {
            url = Self.homeURL
        }
        let engine = engine
        let downloads = appFeatures.require(DownloadsCenter.self)
        let missingProfiles = MissingProfileNotices(stores: stores, store: store)
        let registry = appFeatures.require(ProfileRegistryStore.self)
        let controller = BrowserWindowController(
            store: store,
            // Every engine profile a window's tabs open in comes through here, before the tab exists, so its
            // downloads are handled from the first one (observing a profile again does nothing). A registry profile
            // the engine does not have yet is created here, the first time one of its Spaces shows a tab. A profile
            // neither knows is told to the person once per window, rather than leaving a window that opens nothing.
            profiles: {
                let profile = registry.engineProfile(for: $0, engine: engine)
                if let profile { downloads.observe(profile) } else { missingProfiles.report($0) }
                return profile
            },
            url: url,
            newTabURL: url ?? Self.homeURL,
            appFeatures: appFeatures,
            window: window
        )
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
            // Its Space on screen is the Space shown last, which Little Arc uses while no window is open.
            self?.lastClosedSidebar = closed.store
        }
        // The most recently used browser window stays last, where links from other apps go.
        controller.onBecomeMain = { [weak self] main in
            guard let self, let index = self.windowControllers.firstIndex(where: { $0 === main }) else { return }
            self.windowControllers.append(self.windowControllers.remove(at: index))
        }
        windowControllers.append(controller)
        for notice in notices { stores.present(notice, in: controller.window) }
        missingProfiles.attach(to: controller.window)
        return controller
    }

    /// Loads the start page, prints one result line, and quits the way `--smoke-quit` says,
    /// with exit code 0 when the page loaded.
    private func runSmokeTest(in controller: BrowserWindowController) {
        smokeController = controller
        guard let tab = controller.selectedTab else {
            finishSmokeTest("no tab opened", exitCode: 1)
            return
        }
        // The first main frame load that finishes or fails ends the run.
        let tabID = tab.tabID
        controller.onTabEvent = { [weak self] eventTab, event in
            guard eventTab.tabID == tabID else { return }
            self?.smokeTab(eventTab, didReceive: event)
        }
        smokeTimer = Timer.scheduledTimer(withTimeInterval: Self.smokeTestTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishSmokeTest("timed out", exitCode: 2)
            }
        }
    }

    /// Runs once: later loads, errors or the timeout cannot print a second line or change the exit code.
    private func finishSmokeTest(_ line: String, exitCode: Int32) {
        guard !smokeFinished else { return }
        smokeFinished = true
        smokeTimer?.invalidate()
        smokeTimer = nil

        FileHandle.standardOutput.write(Data("smoke: \(line)\n".utf8))
        BowEngine.exitCode = exitCode
        // Time every quit method from here, including closing the window before the app quits.
        BowEngine.startQuitClock()
        // Quit from a fresh main thread task rather than inside the engine's load callback.
        let quitMethod = options.smokeQuit
        DispatchQueue.main.async { [weak window = smokeController?.window] in
            Self.quit(by: quitMethod, window: window)
        }
    }

    /// Quits the way a person would, so each path is checked end to end.
    private static func quit(by method: LaunchOptions.QuitMethod, window: NSWindow?) {
        switch method {
        case .terminate:
            NSApp.terminate(nil)
        case .menu:
            let commandQ = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "q",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12
            )
            if let commandQ, NSApp.mainMenu?.performKeyEquivalent(with: commandQ) == true { return }
            FileHandle.standardError.write(Data("smoke: Cmd+Q matched no menu item\n".utf8))
            BowEngine.exitCode = 1
            NSApp.terminate(nil)
        case .closeWindow:
            guard let window else {
                FileHandle.standardError.write(Data("smoke: no window to close\n".utf8))
                BowEngine.exitCode = 1
                NSApp.terminate(nil)
                return
            }
            window.performClose(nil)
        }
    }
}

/// A smoke run's result: the first load of its tab that finishes or fails.
extension AppDelegate {
    fileprivate func smokeTab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didFinish(let navigation, let httpStatus):
            let ok = (200..<400).contains(httpStatus)
            let url = tab.state.url?.absoluteString ?? navigation.url.absoluteString
            let line = "status=\(httpStatus) title=\"\(tab.state.title)\" url=\(url)"
            finishSmokeTest(line, exitCode: ok ? 0 : 1)
        case .didFail(let navigation, let error):
            // An aborted load was replaced (a script navigation or a meta refresh) or left no page; the result is
            // the load that follows, or the timeout.
            if error.isAborted { return }
            let line = "error=\(error.code) \(error.description) url=\(navigation.url.absoluteString)"
            finishSmokeTest(line, exitCode: 1)
        default:
            break
        }
    }
}

/// Tells the person, once per window and profile, that a Space's profile has no engine profile. Reports made while
/// the window is still being created wait until it exists, so the alert can show on it.
@MainActor
private final class MissingProfileNotices {
    private let stores: SidebarStores
    private let store: SidebarStore
    private weak var window: NSWindow?
    private var attached = false
    private var reported: Set<SidebarProfileID> = []
    private var waiting: [SidebarNotice] = []

    init(stores: SidebarStores, store: SidebarStore) {
        self.stores = stores
        self.store = store
    }

    func report(_ profile: SidebarProfileID) {
        guard reported.insert(profile).inserted else { return }
        let notice = SidebarStores.missingProfileNotice(profile, in: store.graph)
        if attached {
            stores.present(notice, in: window)
        } else {
            waiting.append(notice)
        }
    }

    func attach(to window: NSWindow?) {
        self.window = window
        attached = true
        let notices = waiting
        waiting.removeAll()
        for notice in notices { stores.present(notice, in: window) }
    }
}
