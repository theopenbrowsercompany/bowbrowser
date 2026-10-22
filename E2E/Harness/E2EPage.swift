import Foundation

// The small protocol e2e tests use to drive the app. Tests never touch engine or window types directly:
// E2EAppAdapter.swift implements these on today's bridge, so reshaping the bridge swaps that one file.

/// The app as a test sees it.
@MainActor
protocol E2EApp: AnyObject {
    /// Opens a browser window on `url`, off screen and never key, and returns its page.
    /// Throws when the window would be visible on a screen or the app could take focus.
    func openWindow(at url: URL) throws -> any E2EPage
    /// Quits the way the app's Quit menu item does.
    func quit()
}

/// One web page in a browser window.
@MainActor
protocol E2EPage: AnyObject {
    /// Waits until the main frame finishes loading and returns its HTTP status, or throws if loading failed.
    /// Returns at once when a load finished since the last call.
    func waitForLoad() async throws -> Int
    /// Calls a Chrome DevTools protocol method and returns its result object.
    func devTools(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
}

extension E2EPage {
    /// Evaluates `expression` in the page and returns its value as JSON types (nil for undefined or null).
    /// A promise is awaited, so an expression can wait on a page state change without fixed sleeps.
    func evaluate(_ expression: String) async throws -> Any? {
        let response = try await devTools(
            "Runtime.evaluate",
            ["expression": expression, "returnByValue": true, "awaitPromise": true]
        )
        if let details = response["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = exception?["description"] as? String ?? details["text"] as? String ?? "exception"
            throw E2EError("\(expression) threw: \(text)")
        }
        return (response["result"] as? [String: Any])?["value"]
    }

    /// Evaluates `expression` and returns it as a string, throwing when it is something else.
    func string(_ expression: String) async throws -> String {
        let value = try await evaluate(expression)
        guard let string = value as? String else {
            throw E2EError("\(expression) is \(value.map { "\($0)" } ?? "null"), not a string")
        }
        return string
    }
}

/// A failed e2e step, with a message for its FAIL line.
struct E2EError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
