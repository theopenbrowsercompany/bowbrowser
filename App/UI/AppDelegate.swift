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
    #endif
    /// True once the engine has started and windows can open.
    private var engineStarted = false
    /// Links from other apps that arrived before the engine started.
    private var pendingLinks: [URL] = []
    /// True once launch found the app's sidebar unusable and is telling the person before it quits.
    private var refusedToStart = false
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

    /// Called by the engine once Chromium is ready to create browsers.
    @objc func engineDidStart() {
        // Tabs live in the sidebar, so AppKit's own window tabs (and their menu items) stay off.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.make()
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
                // Bow refuses to start rather than run on a sidebar that would not be saved. Links that arrive
                // while the alert is open are dropped, so no second alert stacks on it.
                refusedToStart = true
                pendingLinks.removeAll()
                appFeatures.require(SidebarStores.self).present(error, in: nil)
                BowEngine.exitCode = 1
                NSApp.terminate(nil)
                return
            }
            controller.showWindow(nil)
        }
        let links = pendingLinks
        pendingLinks.removeAll()
        for link in links { openLink(link) }
    }

    /// Called by main after the engine has shut down, just before the process exits with `BowEngine.exitCode`.
    @objc func engineDidStop() {
        // The sidebar is saved after every change; this writes one a failed save left behind.
        if engineStarted { appFeatures.require(SidebarStores.self).saveAll() }
        #if BOW_E2E
            e2eRunner?.engineDidStop()  // E2E seam
        #endif
    }

    /// Links from other apps (a link clicked in Mail, `open https://...`). Each opens in a new tab of the most recently
    /// used browser window, in the profile of its Space on screen, or in a new window when none is open. Links that
    /// arrive before the engine has started open once it has.
    func application(_ application: NSApplication, open urls: [URL]) {
        // An e2e or smoke run is a throwaway beside the person's own Bow: a link meant for them never opens in it.
        guard !options.isE2E, !options.isSmokeTest, !refusedToStart else { return }
        for url in urls where ["http", "https"].contains(url.scheme?.lowercased()) {
            if engineStarted {
                openLink(url)
            } else {
                pendingLinks.append(url)
            }
        }
    }

    /// Opens a link from another app. Until link routing rules exist, it opens in the profile of the target window's
    /// Space on screen. Returns the window it opened in, or nil when it opened nowhere (an e2e run never opens an on
    /// screen window for it).
    @discardableResult
    func openLink(_ url: URL) -> BrowserWindowController? {
        // The main window, else the last one on screen or in the Dock, else, while Bow is hidden and so no window is on
        // screen, the last one. A window that is closing opens no tab, so it is skipped and the link goes to another
        // window, or to a new one.
        let open = windowControllers.filter { !$0.isClosing }
        if let controller = open.first(where: { $0.window?.isMainWindow == true })
            ?? open.last(where: { $0.window.map { $0.isVisible || $0.isMiniaturized } == true })
            ?? (NSApp.isHidden ? open.last : nil)
        {
            guard controller.openTab(url: url) != nil else { return nil }
            // Brought forward (out of the Dock too), so the link is seen; e2e windows stay off screen and never key.
            if !options.isE2E {
                controller.window?.deminiaturize(nil)
                controller.showWindow(nil)
                NSApp.activate()
            }
            return controller
        }
        guard !options.isE2E else { return nil }
        let controller = openWindowOrExplain(url: url)
        controller?.showWindow(nil)
        return controller
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // An e2e run quits when its tests are done, even if a test closes every window on the way.
        !options.isE2E
    }

    /// Opens a browser window. With no `profile` it runs on the app's sidebar (saved in the data directory): it opens
    /// `url` in a new tab, or restores the sidebar when `url` is nil (the home page when the sidebar has no tabs).
    /// With a `profile` it runs on a new sidebar of its own whose one Space shows that profile, and opens `url`.
    /// A given `store` is used as it is, as on launch. `window` is the window to use (e2e runs pass an off-screen one),
    /// and `sidebarStores` the stores to take the sidebar from (the app's own when nil).
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
        sidebarStores: SidebarStores? = nil
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
        if url == nil, store.graph.activeSpaceID.map({ store.graph.tabIDs(in: $0).isEmpty }) ?? true {
            url = Self.homeURL
        }
        let engine = engine
        let downloads = appFeatures.require(DownloadsCenter.self)
        let missingProfiles = MissingProfileNotices(stores: stores, store: store)
        let controller = BrowserWindowController(
            store: store,
            // Every engine profile a window's tabs open in comes through here, before the tab exists, so its
            // downloads are handled from the first one (observing a profile again does nothing). A profile the engine
            // does not have is told to the person once per window, rather than leaving a window that opens nothing.
            profiles: {
                let profile = engine.profile(id: SidebarStores.engineProfileID(of: $0))
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
