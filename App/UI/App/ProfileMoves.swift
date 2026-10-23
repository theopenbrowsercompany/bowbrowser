import AppKit
import BowCore

/// Changes that carry tabs from one profile's storage to another's, shared by every window: pointing a Space at
/// another profile, moving a tab to a Space of another profile, and deleting a profile no Space shows.
///
/// A page cannot take its logins and storage to another profile, so each change closes the pages involved first,
/// page by page, each running its leave prompt (the engine has no call that asks every page before closing any).
/// A page whose person chooses to stay stops the change, and nothing moves. A change also stops, without asking
/// any further page, when its window starts closing or the app starts quitting: those close every page themselves,
/// so the change never asks a page a second time and loads nothing.
@MainActor
final class ProfileMoves: AppFeature {
    /// The Spaces whose profile is being changed, while their pages are asked to close.
    private var changing: Set<SidebarSpaceID> = []
    /// The tabs being moved to a Space of another profile, from the question until the move is done or stopped.
    private var moving: Set<SidebarItemID> = []

    init(dataDirectory: URL) {}

    // MARK: A Space's profile

    /// Points Space `id` at `profile`: closes the Space's open pages in every window on `owner`'s sidebar (each
    /// running its leave prompt), then changes the Space's profile, and the window loads the active tab again in it.
    /// Stops, leaving the Space on its profile, when a page's person chooses to stay, another Space comes on screen,
    /// the Space's profile changes meanwhile, or the window closes or the app quits.
    func changeProfile(of id: SidebarSpaceID, to profile: SidebarProfileID, in owner: BrowserWindowController) {
        guard case .reload? = owner.store.graph.spaceProfileChange(id, to: profile) else { return }
        // Only the Space on screen has its open pages listed, so only it can change (its menu is the one shown).
        guard owner.store.graph.activeSpaceID == id, !owner.isClosing, !BowEngine.isQuitting,
            changing.insert(id).inserted
        else {
            NSSound.beep()
            return
        }
        let store = owner.store
        let original = store.graph.space(id)?.profileID
        Task { @MainActor in
            defer { changing.remove(id) }
            @MainActor func stillWanted() -> Bool {
                let graph = store.graph
                return graph.activeSpaceID == id && graph.space(id)?.profileID == original && !owner.isClosing
                    && !BowEngine.isQuitting
            }
            while stillWanted() {
                guard let tab = Self.openPage(ofSpace: id, store: store) else {
                    owner.changeSidebar { try $0.setSpaceProfile(id, to: profile) }
                    Self.refreshOthers(on: store, besides: owner)
                    return
                }
                guard await tab.close() else { break }
            }
            Self.refreshAfterStop(on: store)
        }
    }

    // MARK: Moving a tab to another Space

    /// "Move to Space": moves tab `item` of `owner`'s sidebar to Space `target`. Between Spaces of one profile the
    /// tab keeps its live page. To a Space of another profile it asks first, every time, in a sheet on the window:
    /// Move closes the tab's page (running its leave prompt), then moves the row, and the tab loads its address
    /// again in the target's profile when it is next shown; Cancel, or staying at the leave prompt, leaves the tab
    /// where it was with its page. While the window shows another sheet, closes or the app quits, it only beeps.
    func moveTab(_ item: SidebarItemID, toSpace target: SidebarSpaceID, in owner: BrowserWindowController) {
        let graph = owner.store.graph
        guard let kind = graph.tabMoveKind(of: item, to: target), !owner.isClosing, !BowEngine.isQuitting,
            !moving.contains(item)
        else {
            NSSound.beep()
            return
        }
        guard case .needsReload(let from, let to) = kind else {
            owner.changeSidebar { try $0.moveTab(item, toSpace: target) }
            Self.refreshOthers(on: owner.store, besides: owner)
            return
        }
        guard let window = owner.window, window.attachedSheet == nil, let space = graph.space(target) else {
            NSSound.beep()
            return
        }
        moving.insert(item)
        let profiles = owner.appFeatures.require(ProfileRegistryStore.self)
        let name = { (id: SidebarProfileID) in profiles.registry?.profile(for: id)?.name ?? id.rawValue }
        let title = graph[item].map { $0.title ?? $0.tab?.savedTitle ?? "" } ?? ""
        let alert = NSAlert()
        alert.messageText =
            title.isEmpty ? "Move this tab to “\(space.title)”?" : "Move “\(title)” to “\(space.title)”?"
        alert.informativeText =
            "“\(space.title)” uses the profile “\(name(to))”, not “\(name(from))”. The page loads again there, "
            + "with that profile’s logins and cookies."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard response == .alertFirstButtonReturn else {
                    self.moving.remove(item)
                    return
                }
                Task { @MainActor in
                    defer { self.moving.remove(item) }
                    await self.reloadMove(item, to: target, kind: kind, owner: owner)
                }
            }
        }
    }

    /// Closes the open pages of tab `item` (in every window on the sidebar), then moves it to `target`. Stops, with
    /// the tab where it was, when a page's person chooses to stay, the move would no longer mean `kind` (the tab or
    /// Space went, a profile changed), or the window closes or the app quits.
    private func reloadMove(
        _ item: SidebarItemID, to target: SidebarSpaceID, kind: TabMoveKind, owner: BrowserWindowController
    ) async {
        let store = owner.store
        @MainActor func stillWanted() -> Bool {
            store.graph.tabMoveKind(of: item, to: target) == kind && !owner.isClosing && !BowEngine.isQuitting
        }
        while stillWanted() {
            guard let page = Self.openPage(ofTab: item, store: store) else {
                owner.changeSidebar { try $0.moveTab(item, toSpace: target) }
                Self.refreshOthers(on: store, besides: owner)
                return
            }
            guard await page.close() else { break }
        }
        Self.refreshAfterStop(on: store)
    }

    // MARK: Deleting a profile

    /// Asks in a sheet, then deletes profile `id` (`ProfileRegistryStore.deleteProfile`): it leaves the list at once
    /// and its folder goes at the next launch. Only a profile no Space shows in any window can be deleted.
    func askToDeleteProfile(_ id: SidebarProfileID, context: any SidebarActionContext, owner: BrowserWindowController) {
        let profiles = owner.appFeatures.require(ProfileRegistryStore.self)
        guard let record = profiles.deletableProfiles(spaceProfiles: Self.spaceProfiles()).first(where: { $0.id == id })
        else {
            NSSound.beep()
            return
        }
        context.confirm(
            "Delete the profile “\(record.name)”?",
            detail: "Its logins, cookies, history and site data are removed the next time Bow starts. "
                + "This cannot be undone.",
            action: "Delete Profile"
        ) {
            do {
                // Asked again: a Space may have chosen the profile while the sheet was up.
                try profiles.deleteProfile(id, spaceProfiles: Self.spaceProfiles())
            } catch {
                FileHandle.standardError.write(Data("bow: the profile could not be deleted: \(error)\n".utf8))
                NSSound.beep()
            }
        }
    }

    /// The profile of every Space in every window's sidebar.
    static func spaceProfiles() -> [SidebarProfileID] {
        var seen = Set<ObjectIdentifier>()
        return allWindows().filter { seen.insert(ObjectIdentifier($0.store)).inserted }.flatMap {
            $0.store.graph.spaces.map(\.profileID)
        }
    }

    // MARK: Windows and pages

    /// An open page of a tab of Space `id` that a window on `store` lists. Windows on one sidebar show the same Space.
    private static func openPage(ofSpace id: SidebarSpaceID, store: SidebarStore) -> (any EngineTab)? {
        let graph = store.graph
        for window in windows(on: store) {
            for tab in window.tabs where !tab.isClosed {
                guard let item = window.modelID(of: tab).flatMap(window.sidebarItemID(for:)) else { continue }
                if graph.spaceID(containing: item) == id { return tab }
            }
        }
        return nil
    }

    /// An open page of tab `item` in any window on `store`, in whichever Space is on screen.
    private static func openPage(ofTab item: SidebarItemID, store: SidebarStore) -> (any EngineTab)? {
        for window in windows(on: store) {
            for id in window.loadedTabIDs where window.sidebarItemID(for: id) == item {
                if let tab = window.engineTab(for: id), !tab.isClosed { return tab }
            }
        }
        return nil
    }

    private static func allWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
    }

    private static func windows(on store: SidebarStore) -> [BrowserWindowController] {
        allWindows().filter { $0.store === store }
    }

    private static func refreshOthers(on store: SidebarStore, besides owner: BrowserWindowController) {
        for window in windows(on: store) where window !== owner && !window.isClosing { window.changeSidebar { _ in } }
    }

    /// After a change stopped: the pages that closed load again where their tabs are, the active one now. Quitting
    /// loads nothing, so the sidebar keeps its active tab as it was, and a closing window loads nothing either.
    private static func refreshAfterStop(on store: SidebarStore) {
        guard !BowEngine.isQuitting else { return }
        for window in windows(on: store) where !window.isClosing { window.changeSidebar { _ in } }
    }
}
