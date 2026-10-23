import Foundation

/// Links from other apps as a test sees them: GetURL Apple Events delivered to the app's own handler.
/// E2E/Harness/E2EAppAdapter+Links.swift implements it; every action is refused once the test has ended.
///
/// A link the harness delivers is told apart from a real one by the app's `e2eDeliversLinks` seam, which is true
/// only while the harness hands its own event to the handler (on the main thread, which the handler runs on at once),
/// so a real link from another app that reaches an e2e run is still ignored.
@MainActor
protocol E2ELinksApp: E2EApp {
    /// What the links of `E2EEarlyLinksTest` tests did when they were delivered, before the first test.
    var earlyLinks: E2EEarlyLinks { get }
    /// Opens the links the app kept, as launch does once its first window is open (an e2e run opens no window at
    /// launch, so it keeps every link until a test asks, once its window is open). Returns the links that opened.
    func openKeptLinks() throws -> [E2EOpenedLink]
    /// Delivers `links`, in order, as the harness's own. Returns the links that opened.
    func deliverLinks(_ links: [E2ELink]) throws -> [E2EOpenedLink]
    /// The bundle identifier of a helper process of this app (Chromium's renderer, for example) and the app it
    /// counts as when it sends a link, or nil when this app runs no helper.
    func helperLinkSource() throws -> (helper: String, app: String?)?
    /// The bundle identifier of this app, which links the harness sends with a sender come from.
    var appBundleID: String { get }
}

/// A link to deliver as a GetURL Apple Event. With `sender`, the event is sent through the system's Apple Event
/// Manager to this process, which names this app as its sender; without, it is handed to the app's handler unsent,
/// so it carries no sender, as a link from a process the system cannot name.
struct E2ELink {
    var address: String
    var sender: Bool
}

/// A link from another app that opened: in which window's Space, and with which sender.
@MainActor
struct E2EOpenedLink {
    var address: String
    /// The sending app's bundle identifier, or nil when the link had no sender or the sender is in no app.
    var senderBundleID: String?
    /// The sending process, or nil when the link had no sender.
    var senderProcessID: Int32?
    /// True when the new tab is in the Space its window shows.
    var inSpaceOnScreen: Bool
    var page: any E2EPage
}

/// What the early links did when they were delivered.
struct E2EEarlyLinks {
    /// How many links were delivered.
    var delivered = 0
    /// The addresses the app kept, in order, and how many links opened right away (none should).
    var kept: [String] = []
    var openedAtOnce = 0
}

/// A test that has links delivered the moment the app has installed its link handler, before the first test. That is
/// the earliest a link can arrive: Chromium starts inside `CefInitialize`, before AppKit finishes launching, and
/// AppKit hands the app Apple Events only once it has, so in this app links never arrive before the engine starts.
@MainActor
protocol E2EEarlyLinksTest: E2ETest {
    var earlyLinks: [E2ELink] { get }
}
