import Foundation

/// Injectable time source so reconnection, staleness and rate limiting are testable.
public protocol Clock: AnyObject {
    var now: Date { get }
    var unixTime: Int { get }
}

public extension Clock {
    var unixTime: Int { Int(now.timeIntervalSince1970) }
}

public final class SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// Test double: time moves only when the test moves it.
public final class FixedClock: Clock {
    private let lock = NSLock()
    private var current: Date

    public init(_ date: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        current = date
    }

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
