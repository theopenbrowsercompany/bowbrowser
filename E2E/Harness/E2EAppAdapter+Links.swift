import AppKit
import BowCore

// The links area of the adapter: E2ELinksApp over the app delegate's GetURL handler. Links are real GetURL Apple
// Events; the delegate takes them as the harness's own only while `e2eDeliversLinks` is set around the delivery,
// and reports each one that opened through `e2eLinkOpened`, which is set for that time only.

extension E2EAppAdapter {
    /// What the early links did when they were delivered.
    static var earlyLinks = E2EEarlyLinks()

    /// Delivers the early links of `tests`, right after the app installed its link handler, and records what the app
    /// did with them.
    static func deliverEarlyLinks(of tests: [any E2EEarlyLinksTest], delegate: AppDelegate) {
        let links = tests.flatMap(\.earlyLinks)
        guard !links.isEmpty else { return }
        var opened = 0
        var record = E2EEarlyLinks(delivered: links.count)
        do {
            try deliver(links, delegate: delegate) { _, _, _ in opened += 1 }
        } catch {
            FileHandle.standardError.write(Data("e2e: early links not delivered: \(error)\n".utf8))
        }
        record.kept = delegate.linkIntake.pending.map(\.url.absoluteString)
        record.openedAtOnce = opened
        earlyLinks = record
    }

    /// Delivers each link as a GetURL Apple Event that the delegate takes as the harness's own, calling `opened` for
    /// each that opened, during the call only.
    static func deliver(
        _ links: [E2ELink], delegate: AppDelegate,
        opened: @escaping (URL, LinkSource?, BrowserWindowController) -> Void
    ) throws {
        delegate.e2eDeliversLinks = true
        delegate.e2eLinkOpened = opened
        defer {
            delegate.e2eDeliversLinks = false
            delegate.e2eLinkOpened = nil
        }
        for link in links { try sendGetURLEvent(link) }
    }

    /// Hands a GetURL Apple Event for `link` to this process's handler, on the main thread, before returning.
    static func sendGetURLEvent(_ link: E2ELink) throws {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: link.address), forKeyword: keyDirectObject)
        if link.sender {
            // The Apple Event Manager runs the handler of an event sent to its own process at once, and adds the
            // sender attributes (this process) as it does for any sent event.
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
        } else {
            guard let descriptor = event.aeDesc else { throw E2EError("the GetURL event has no descriptor") }
            var reply = AEDesc()
            defer { AEDisposeDesc(&reply) }
            // Through the handler table without sending: no sender attributes.
            var refCon = 0
            let status = withUnsafeMutablePointer(to: &refCon) {
                NSAppleEventManager.shared().dispatchRawAppleEvent(
                    descriptor, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer($0))
            }
            guard status == noErr else { throw E2EError("dispatching the GetURL event failed: \(status)") }
        }
    }

    /// Delivers `link` the way a link from another app arrives, not as the harness's own.
    func deliverLinkFromOtherApp(_ url: URL) throws {
        try Self.sendGetURLEvent(E2ELink(address: url.absoluteString, sender: true))
    }

    func openedLinks(
        token: Int, _ action: (_ opened: @escaping (URL, LinkSource?, BrowserWindowController) -> Void) throws -> Void
    )
        rethrows -> [E2EOpenedLink]
    {
        var links: [E2EOpenedLink] = []
        try action { [unowned self] url, source, controller in
            guard let tab = controller.selectedTab else { return }
            links.append(
                E2EOpenedLink(
                    address: url.absoluteString,
                    senderBundleID: source?.bundleID,
                    senderProcessID: source?.processID,
                    inSpaceOnScreen: controller.tabs.contains { $0.tabID == tab.tabID },
                    page: track(tab, in: controller, token: token)
                ))
        }
        return links
    }
}

extension E2ETestApp: E2ELinksApp {
    var earlyLinks: E2EEarlyLinks { E2EAppAdapter.earlyLinks }

    var appBundleID: String { Bundle.main.bundleIdentifier ?? "" }

    func openKeptLinks() throws -> [E2EOpenedLink] {
        try adapter.requireActive(token, "open the kept links")
        let delegate = adapter.delegate
        return adapter.openedLinks(token: token) { opened in
            delegate.e2eLinkOpened = opened
            defer { delegate.e2eLinkOpened = nil }
            delegate.openKeptLinks()
        }
    }

    func deliverLinks(_ links: [E2ELink]) throws -> [E2EOpenedLink] {
        try adapter.requireActive(token, "deliver links")
        let delegate = adapter.delegate
        return try adapter.openedLinks(token: token) { opened in
            try E2EAppAdapter.deliver(links, delegate: delegate, opened: opened)
        }
    }

    func helperLinkSource() throws -> (helper: String, app: String?)? {
        try adapter.requireActive(token, "read a helper's link source")
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
            return (helperID, ExternalLinks.source(processID: pid).bundleID)
        }
        return nil
    }
}
