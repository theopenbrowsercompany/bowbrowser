import AppKit
import BowCore

/// Reads the links other apps send as GetURL Apple Events (a link clicked in Mail, `open https://...`), with the app
/// that sent each one.
enum ExternalLinks {
    /// The link in a GetURL event, with its sender when the event names one, or nil when the event carries no usable
    /// web address.
    static func link(from event: NSAppleEventDescriptor) -> IncomingLink? {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return nil }
        return IncomingLink(text: text, source: senderProcessID(of: event).map(source(processID:)))
    }

    /// The sending process, from the sender attributes the system adds to an event another process sent. An event
    /// built in this process and never sent has none.
    private static func senderProcessID(of event: NSAppleEventDescriptor) -> pid_t? {
        if let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value, pid > 0 { return pid }
        // The audit token names the sender too; its sixth word is the process ID (audit_token_to_pid).
        if let token = event.attributeDescriptor(forKeyword: keySenderAuditTokenAttr)?.data,
            token.count == MemoryLayout<audit_token_t>.size
        {
            let pid = token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self).val.5 }
            if pid > 0 { return pid_t(bitPattern: pid) }
        }
        return nil
    }

    /// The sender with the bundle identifier of the app it belongs to. A helper process (for example "Slack Helper",
    /// inside Slack.app) counts as the app that contains it; a process in no app (a command line tool) has none.
    static func source(processID: pid_t) -> LinkSource {
        LinkSource(processID: processID, bundleID: bundleID(processID: processID))
    }

    private static func bundleID(processID: pid_t) -> String? {
        // Launch Services' path of the app first: macOS may run an app from a temporary copy of its bundle (after
        // the app was updated in place), whose path is no app bundle.
        if let app = NSRunningApplication(processIdentifier: processID) {
            if let bundle = app.bundleURL,
                let outer = LinkSource.appBundlePath(containing: bundle.path), outer != bundle.path
            {
                return bundleID(ofAppAt: outer) ?? app.bundleIdentifier
            }
            if let id = app.bundleIdentifier { return id }
        }
        // A process Launch Services does not list (some helpers): the app its executable is in.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let executable = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return LinkSource.appBundlePath(containing: executable).flatMap(bundleID(ofAppAt:))
    }

    /// Read without creating a Bundle, which the process would keep for good.
    private static func bundleID(ofAppAt path: String) -> String? {
        let info =
            CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: path, isDirectory: true) as CFURL) as NSDictionary?
        return info?[kCFBundleIdentifierKey as String] as? String
    }
}
