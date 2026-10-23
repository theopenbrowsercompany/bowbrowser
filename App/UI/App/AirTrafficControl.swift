import AppKit
import BowCore

/// Air Traffic Control for the whole app: the routing rules (`RoutingStore`, saved as `LinkRouting.json` beside the
/// sidebar file), the app the last link from another app came from, and the rule editor window. The app delegate asks
/// `decide(_:isAvailable:)` where each link from another app goes, before any tab exists for it, and opens it there.
@MainActor
final class AirTrafficControl: AppFeature {
    /// One destination the editor offers, with the title its menus show.
    struct Choice: Equatable {
        var title: String
        var destination: RouteDestination
    }

    #if BOW_E2E
        /// Bundle identifiers e2e runs read as another app's: the harness sends its links from Bow itself, through the
        /// real Apple Event path, and a test names the app the sender stands for.
        static var e2eSourceRenames: [String: String] = [:]  // E2E seam
        /// Where e2e runs open the editor, off every screen.
        static var e2eEditorFrame: NSRect?  // E2E seam
    #endif

    private let store: RoutingStore
    /// The app the last link came from, nil until a link arrives.
    private(set) var lastSource: LinkRouting.LastSource?
    /// The open editor, if any.
    private(set) var editor: AirTrafficControlEditor?

    init(dataDirectory: URL) {
        store = RoutingStore(fileURL: RoutingStore.fileURL(inApplicationSupportFolder: dataDirectory))
        switch store.origin {
        case .loaded, .freshBecauseMissing: break
        case .newerFile(let version):
            Self.report("\(store.fileURL.path) was saved by a newer Bow (format \(version)); it is left untouched")
        case .freshAfterSettingAside(let aside, let reason):
            Self.report("\(store.fileURL.path) could not be read (\(reason)); it was moved to \(aside.path)")
        case .unreadable(let reason):
            Self.report("\(store.fileURL.path) could not be read (\(reason)); it is left untouched")
        }
    }

    /// The rules in use.
    var table: RoutingTable { store.table }

    /// Where the rules are saved.
    var fileURL: URL { store.fileURL }

    /// Why changes are not saved, for the editor, or nil when they are.
    var readOnlyReason: String? {
        switch store.origin {
        case .newerFile(let version):
            "The rules were saved by a newer version of Bow (format \(version)). Bow leaves them untouched, so "
                + "changes here last only until Bow quits."
        case .unreadable:
            "The rules file could not be read. Bow leaves it untouched, so changes here last only until Bow quits."
        case .loaded, .freshBecauseMissing, .freshAfterSettingAside: nil
        }
    }

    /// Replaces the rules and saves them; an open editor other than `editor` (the one making the change) shows the new
    /// rules. Returns why saving failed, or nil.
    @discardableResult
    func update(_ table: RoutingTable, from editor: AirTrafficControlEditor? = nil) -> String? {
        var problem: String?
        do {
            try store.update(table)
        } catch {
            Self.report("\(error)")
            problem = error.description
        }
        if let open = self.editor, open !== editor { open.tableReplaced() }
        return problem
    }

    /// Where `link` goes: records its source app for the editor, then asks the rules. `isAvailable` says whether a
    /// Space or profile a rule names still exists.
    func decide(_ link: IncomingLink, isAvailable: (RouteDestination) -> Bool) -> RoutingDecision {
        let bundleID = Self.sourceBundleID(link.source?.bundleID)
        lastSource = LinkRouting.LastSource(bundleID: bundleID, name: bundleID.flatMap(Self.appName(bundleID:)))
        editor?.sourceChanged()
        return store.table.route(url: link.url.absoluteString, sourceBundleID: bundleID, isAvailable: isAvailable)
    }

    /// Shows the editor, opening it if needed. `choices` lists the destinations its menus offer, asked each time they
    /// are rebuilt. With `takesFocus` the window comes forward and takes the keyboard; without (e2e) it is ordered in
    /// off screen.
    @discardableResult
    func showEditor(takesFocus: Bool, choices: @escaping () -> [Choice]) -> AirTrafficControlEditor {
        if let editor {
            editor.show(takesFocus: takesFocus)
            return editor
        }
        let placed: NSRect? = {
            #if BOW_E2E
                return Self.e2eEditorFrame  // E2E seam
            #else
                return nil
            #endif
        }()
        let frame = placed ?? NSRect(x: 0, y: 0, width: 780, height: 440)
        let editor = AirTrafficControlEditor(
            frame: frame, keepsFrame: placed != nil, control: self, choices: choices
        ) { [weak self] closed in
            if self?.editor === closed { self?.editor = nil }
        }
        self.editor = editor
        if placed == nil { editor.window?.center() }
        editor.show(takesFocus: takesFocus)
        return editor
    }

    /// Closes the editor, if open.
    func closeEditor() {
        editor?.close()
        editor = nil
    }

    /// The bundle identifier routing matches for a sender whose app is `bundleID` (a helper process already counts as
    /// its parent app, `ExternalLinks.source(processID:)`).
    private static func sourceBundleID(_ bundleID: String?) -> String? {
        #if BOW_E2E
            if let bundleID, let renamed = e2eSourceRenames[bundleID] { return renamed }  // E2E seam
        #endif
        return bundleID
    }

    /// The name of the app with `bundleID`, as Finder shows it, or nil when no such app is installed.
    private static func appName(bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
            let name = running.localizedName
        {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("bow: air traffic control: \(message)\n".utf8))
    }
}
