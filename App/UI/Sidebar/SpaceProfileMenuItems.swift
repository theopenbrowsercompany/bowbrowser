import AppKit
import BowCore

/// A Space's profile in the Space menu (the context menu of the Space's name above its tabs), as Arc sets one per
/// Space from the Space's menu: "Profile" lists every profile with the Space's own checked, then "New Profile…",
/// which asks for a name in a sheet, creates the profile and puts the Space on it, and "Delete Profile…", which lists
/// the profiles and deletes one no Space uses after asking (Arc deletes profiles in its settings, which Bow does not
/// have yet). Several Spaces may share one profile, and with it their logins, cookies, history and Favorites.
///
/// Choosing another profile closes the Space's open pages first, each running its leave prompt, then points the
/// Space at the profile, and the active tab loads its address again there; the other tabs load there when chosen.
/// A page whose person chooses to stay keeps the Space on its profile, so no page ever runs in a profile its Space
/// does not show. The app service `ProfileMoves` makes the change.
enum SpaceProfileMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.section(.pinned)] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        guard let space = context.graph.spaces.first(where: { $0.pinnedContainerID == item }),
            let owner = controller(of: context)
        else { return [] }
        let profiles = owner.appFeatures.require(ProfileRegistryStore.self)
        let moves = owner.appFeatures.require(ProfileMoves.self)
        let id = space.id
        let menu = NSMenu(title: "Profile")
        menu.autoenablesItems = false
        for choice in profiles.registry?.choices(current: space.profileID) ?? [] {
            let entry = SidebarMenuItem(title: choice.name) { [weak owner] in
                guard let owner else { return }
                moves.changeProfile(of: id, to: choice.id, in: owner)
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
        menu.addItem(deleteItem(profiles: profiles, moves: moves, context: context, owner: owner))
        let profile = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        profile.submenu = menu
        return [profile]
    }

    /// "Delete Profile…": every profile but the default, each enabled only while no Space in any window shows it.
    private static func deleteItem(
        profiles: ProfileRegistryStore, moves: ProfileMoves, context: any SidebarActionContext,
        owner: BrowserWindowController
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Delete Profile…", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Delete Profile…")
        menu.autoenablesItems = false
        let deletable = Set(profiles.deletableProfiles(spaceProfiles: ProfileMoves.spaceProfiles()).map(\.id))
        for record in profiles.registry?.profiles ?? [] where !record.isDefault {
            let entry = SidebarMenuItem(title: record.name) { [weak context, weak owner] in
                guard let context, let owner else { return }
                moves.askToDeleteProfile(record.id, context: context, owner: owner)
            }
            entry.isEnabled = deletable.contains(record.id)
            menu.addItem(entry)
        }
        item.submenu = menu
        item.isEnabled = !deletable.isEmpty
        return item
    }

    /// The window controller showing the sidebar `context` belongs to.
    private static func controller(of context: any SidebarActionContext) -> BrowserWindowController? {
        (context as? SidebarFeature)?.sidebar.window?.windowController as? BrowserWindowController
    }

    /// Asks for a profile name in a sheet on the sidebar's window. "Create Profile" adds a persistent profile with
    /// that name and puts Space `id` on it; an empty name or Cancel changes nothing. While the window shows another
    /// sheet it only beeps.
    static func askForNewProfile(_ id: SidebarSpaceID, context: any SidebarActionContext) {
        guard let space = context.graph.space(id), let owner = controller(of: context), let window = owner.window
        else { return }
        let profiles = owner.appFeatures.require(ProfileRegistryStore.self)
        let moves = owner.appFeatures.require(ProfileMoves.self)
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
        alert.beginSheetModal(for: window) { [weak owner] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let owner, owner.store.graph.space(id) != nil else { return }
                let name = field.stringValue
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    let record = try profiles.createProfile(named: name)
                    moves.changeProfile(of: id, to: record.id, in: owner)
                } catch {
                    FileHandle.standardError.write(Data("bow: the profile could not be created: \(error)\n".utf8))
                    NSSound.beep()
                }
            }
        }
    }
}
