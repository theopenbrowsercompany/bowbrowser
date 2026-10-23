import AppKit

/// Debug-only hooks that get the main thread stuck in a nested run loop that never ends, the way a synthetic
/// mouseDown that reaches an AppKit tracking loop with no mouseUp does. Only the watchdog's self tests
/// (`selectedByNameOnly`, in E2E/Tests/Engine.swift) call them, to prove the run then ends with `E2E: TIMEOUT`;
/// no real test may, since they never return and the watchdog ends the process.
@MainActor
enum E2ENestedLoop {
    /// Waits forever for a mouseUp in AppKit's event tracking mode, as `NSTableView`'s and `NSControl`'s mouse
    /// tracking loops do. Timers in the common modes keep firing, but the main queue, where the harness runs, is not
    /// served while this runs inside one of its jobs.
    static func trackWithoutMouseUp() -> Never {
        while true {
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantFuture, inMode: .eventTracking, dequeue: true)
        }
    }

    /// Runs the main run loop in its default mode forever from inside the running step, as code that spins the run
    /// loop to wait for something (`RunLoop.run(until:)`) does when that something never comes.
    static func spinDefaultMode() -> Never {
        while true {
            _ = CFRunLoopRunInMode(.defaultMode, 60, false)
        }
    }
}
