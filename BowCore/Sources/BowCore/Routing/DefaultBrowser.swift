import Foundation

/// The decisions behind the "Set as Default Browser" app menu item: which URL schemes make an app a browser, when
/// Bow already is the default, what the item says, and what a failed registration is shown as. The calls to the
/// system are the app's.
public enum DefaultBrowser {
    /// The schemes a default browser handles, in the order they are registered. Bow is already the default only when
    /// every one of them opens in Bow.
    public static let schemes = ["http", "https"]

    /// The item's title while Bow is not the default; the ellipsis says macOS asks for a confirmation.
    public static let setTitle = "Set as Default Browser…"

    /// The item's title (shown disabled) once Bow is the default.
    public static let isDefaultTitle = "Bow Is Your Default Browser"

    /// Whether `handler`, the app the system opens http links with (nil when none), is the app at `bundleURL`.
    /// Compares file locations with symbolic links resolved, so a path through /tmp and one through /private/tmp
    /// name the same app.
    public static func isDefault(handler: URL?, bundleURL: URL) -> Bool {
        guard let handler, handler.isFileURL, bundleURL.isFileURL else { return false }
        // The usual macOS volume ignores case, so Launch Services may answer with a differently cased path.
        return canonical(handler).caseInsensitiveCompare(canonical(bundleURL)) == .orderedSame
    }

    /// Whether Bow is the default for every scheme in `schemes`, given each one's handler in that order. A half done
    /// registration (http accepted, https declined) is not default, so the item stays available to finish it.
    public static func isDefault(handlers: [URL?], bundleURL: URL) -> Bool {
        handlers.count == schemes.count && handlers.allSatisfy { isDefault(handler: $0, bundleURL: bundleURL) }
    }

    /// The item's title when Bow `isDefault` or not.
    public static func title(isDefault: Bool) -> String {
        isDefault ? isDefaultTitle : setTitle
    }

    /// Whether the item can be chosen: not while Bow is the default, and not while a registration is still waiting
    /// for the person's answer to the system's prompt, so a second click cannot start a second one.
    public static func isEnabled(isDefault: Bool, registering: Bool) -> Bool {
        !isDefault && !registering
    }

    /// A registration the system refused, as plain values.
    public struct Failure: Equatable, Sendable {
        public var domain: String
        public var code: Int
        public var message: String

        public init(domain: String, code: Int, message: String) {
            self.domain = domain
            self.code = code
            self.message = message
        }
    }

    /// Whether the person turned the system's prompt down (Cocoa's user cancelled error), which is their answer and
    /// not a problem to report.
    public static func isCancellation(_ failure: Failure) -> Bool {
        failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError
    }

    /// The alert for a registration that failed on `scheme`, or nil when the person cancelled.
    public static func alert(for failure: Failure, scheme: String) -> (title: String, detail: String)? {
        guard !isCancellation(failure) else { return nil }
        let detail = failure.message.isEmpty ? "The system gave no reason." : failure.message
        return ("Bow could not be set as your default browser", "Registering for \(scheme) links failed. \(detail)")
    }

    private static func canonical(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
