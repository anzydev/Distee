import Foundation
import OSLog

/// Unified logging plus a bounded in-memory ring buffer for the diagnostics panel.
/// Never pass key material, signatures, PSKs or tokens to this type.
public final class LoggingManager {
    public enum Level: String, CaseIterable {
        case debug, info, notice, warning, error

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .notice: return .default
            case .warning: return .error
            case .error: return .fault
            }
        }
    }

    public struct Entry: Identifiable {
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let message: String
    }

    public static let shared = LoggingManager()

    private let logger: Logger
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int
    private let clock: Clock

    public init(subsystem: String = "com.distee.agent", category: String = "agent", capacity: Int = 200, clock: Clock = SystemClock()) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.capacity = capacity
        self.clock = clock
    }

    public func log(_ level: Level, _ message: @autoclosure () -> String) {
        let text = message()
        logger.log(level: level.osLogType, "\(text, privacy: .public)")

        let entry = Entry(date: clock.now, level: level, message: text)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
    }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(.notice, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }

    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    public func formatted(limit: Int = 200) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return snapshot().suffix(limit).map { entry in
            "\(formatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
    }
}

extension String.StringInterpolation {
    public enum Privacy {
        case `public`
        case `private`
    }

    public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {
        switch privacy {
        case .public:
            appendInterpolation(String(describing: value))
        case .private:
            appendInterpolation("<redacted>")
        }
    }
}
