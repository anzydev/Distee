import Foundation

/// Reconnection policy from COMMUNICATION_ARCHITECTURE.md §8:
/// 1, 2, 4, 8, 16, 32, 60 s with ±20% jitter; counter resets after 60 s online.
public struct BackoffPolicy: Equatable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var jitterFraction: Double
    public var resetAfterOnline: TimeInterval

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        jitterFraction: Double = 0.2,
        resetAfterOnline: TimeInterval = 60
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
        self.resetAfterOnline = resetAfterOnline
    }

    /// - Parameters:
    ///   - attempt: 1 for the first retry, increasing by one per consecutive failure.
    ///   - jitter: a value in -1...1; multiplied by `jitterFraction`.
    public func delay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let base = min(maximumDelay, initialDelay * pow(2, exponent))
        let clampedJitter = min(1, max(-1, jitter))
        let factor = 1 + (jitterFraction * clampedJitter)
        return max(0, base * factor)
    }
}
