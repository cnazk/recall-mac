import Foundation

/// Indirection over "now" so expiry, retention and dedup ordering are testable.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemClock: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

/// A clock the tests drive by hand.
public final class MutableClock: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += interval
    }
}
