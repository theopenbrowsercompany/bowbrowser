import AppKit
import BowCore

/// A Space's profile in the Space menu (the context menu of the Space's name above its tabs), as Arc sets one per
/// Space from the Space's menu: "Profile" lists every profile with the Space's own checked, then "New Profile…",
/// which asks for a name in a sheet, creates the profile and puts the Space on it. Several Spaces may share one
/// profile, and with it their logins, cookies, history and Favorites.
///
/// Choosing another profile closes the Space's open pages first, each running its leave prompt, then points the
/// Space at the profile, and the active tab loads its address again there; the other tabs load there when chosen.
/// A page whose person chooses to stay keeps the Space on its profile, so no page ever runs in a profile its Space
/// does not show.
enum SpaceProfileMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.section(.pinned)] }

    /// The Spaces whose profile is being changed, while their pages are asked to close.
    private static var changing: Set<SidebarSpaceID> = []

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        guard let space = context.graph.spaces.first(where: { $0.pinnedContainerID == item }),
            let profiles = registryStore(of: context)
        else { return [] }
        let id = space.id
        let menu = NSMenu(title: "Profile")
        menu.autoenablesItems = false
        for choice in profiles.registry?.choices(current: space.profileID) ?? [] {
            let entry = SidebarMenuItem(title: choice.name) { [weak context] in
                guard let context else { return }
                change(id, to: choice.id, context: context)
            }
            entry.state = choice.isCurrent ? .on : .off
            menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let new = SidebarMenuItem(title: "New Profile…") { [weak context] in
            guard let context else { return }
            askForNewProfile(id, context: context)
        }
        new.isEnabled = profiles.registry != nil
        menu.addItem(new)
        let profile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profile.submenu = menu
        return [profile]
    }

    /// The window controller showing the sidebar `context` belongs to.
    private static func controller(of context: any SidebarActionContext) -> BrowserWindowController? {
        (context as? SidebarFeature)?.sidebar.window?.windowController as? BrowserWindowController
    }

    private static func registryStore(of context: any SidebarActionContext) -> ProfileRegistryStore? {
        controller(of: context)?.appFeatures.require(ProfileRegistryStore.self)
    }

    /// Asks for a profile name in a sheet on the sidebar's window. "Create Profile" adds a persistent profile with
    /// that name and puts Space `id` on it; an empty name or Cancel changes nothing. While the window shows another
    /// sheet it only beeps.
    static func askForNewProfile(_ id: SidebarSpaceID, context: any SidebarActionContext) {
        guard let space = context.graph.space(id), let window = controller(of: context)?.window,
            let profiles = registryStore(of: context)
        else { return }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText =
            "A profile keeps its own logins, cookies, history and Favorites. “\(space.title)” will use the new profile."
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Profile name"
        field.setAccessibilityLabel("Profile name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Profile")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak context] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let context, context.graph.space(id) != nil else { return }
                let name = field.stringValue
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    let record = try profiles.createProfile(named: name)
                    change(id, to: record.id, context: context)
                } catch {
                    FileHandle.standardError.write(Data("bow: the profile could not be created: \(error)\n".utf8))
                    NSSound.beep()
                }
            }
        }
    }

    /// Points Space `id` at `profile`: closes the Space's open pages in every window on this sidebar (each running
    /// its leave prompt), then changes the Space's profile, and the window loads the active tab again in it. Stops,
    /// leaving the Space on its profile, when a page's person chooses to stay, another Space comes on screen, the
    /// Space's profile changes meanwhile, or the window closes or the app quits.
    static func change(_ id: SidebarSpaceID, to profile: SidebarProfileID, context: any SidebarActionContext) {
        guard let owner = controller(of: context), case .reload? = owner.store.graph.spaceProfileChange(id, to: profile)
        else { return }
        guard changing.insert(id).inserted else {
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
                guard let tab = openPage(of: id, store: store) else {
                    owner.changeSidebar { try $0.setSpaceProfile(id, to: profile) }
                    refreshOthers(on: store, besides: owner)
                    return
                }
                guard await tab.close() else { break }
            }
            // Stopped: the pages that closed load again in the Space's own profile, the active one now.
            for window in windows(on: store) where !window.isClosing { window.changeSidebar { _ in } }
        }
    }

    /// An open page of a tab of Space `id` in any window on `store`. Windows on one sidebar show the same Space.
    private static func openPage(of id: SidebarSpaceID, store: SidebarStore) -> (any EngineTab)? {
        let graph = store.graph
        for window in windows(on: store) {
            for tab in window.tabs {
                guard let item = window.modelID(of: tab).flatMap(window.sidebarItemID(for:)) else { continue }
                if graph.spaceID(containing: item) == id { return tab }
            }
        }
        return nil
    }

    private static func windows(on store: SidebarStore) -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.store === store }
    }

    private static func refreshOthers(on store: SidebarStore, besides owner: BrowserWindowController) {
        for window in windows(on: store) where window !== owner && !window.isClosing { window.changeSidebar { _ in } }
    }
}
