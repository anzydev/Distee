import ApplicationServices
import CoreGraphics
import Foundation

/// Reads the session's lock state. `CGSSessionScreenIsLocked` is present-and-true while
/// locked and **absent** while unlocked (it is never written as `false`), so absence must
/// be treated as "not locked", not as "unknown".
public protocol ScreenStateProviding {
    var isLocked: Bool { get }
    var isAccessibilityTrusted: Bool { get }
    func requestAccessibilityIfNeeded()
    /// `true` when the screen requires a password immediately after display sleep, which
    /// is the only condition under which `pmset displaysleepnow` is equivalent to locking.
    var locksImmediatelyOnDisplaySleep: Bool { get }
}

public struct SystemScreenState: ScreenStateProviding {
    public init() {}

    public var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public var locksImmediatelyOnDisplaySleep: Bool {
        // Host-specific preference. A missing key means the macOS default, which on the
        // supported versions is "require password immediately".
        let byHost = CFPreferencesCopyValue(
            "askForPasswordDelay" as CFString,
            "com.apple.screensaver" as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? NSNumber

        let anyHost = CFPreferencesCopyValue(
            "askForPasswordDelay" as CFString,
            "com.apple.screensaver" as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? NSNumber

        guard let delay = byHost ?? anyHost else { return true }
        return delay.doubleValue <= 0
    }
}
