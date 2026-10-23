import Foundation

/// Where BowCore reads the current time. Logic that depends on elapsed time takes one of these, so tests and the
/// end to end harness can move time forward instead of waiting.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

/// The real clock.
public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

/// A clock that only moves when told to. Safe to share between threads.
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }

    public func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}
