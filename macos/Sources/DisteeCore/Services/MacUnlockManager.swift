import ApplicationServices
import CoreGraphics
import Foundation

public enum UnlockMechanism: String, Equatable {
    case cgEvent = "CGEvent Keystroke"
    case systemEvents = "System Events Keystroke"
    case none = "none"
}

public enum UnlockStatus: String, Equatable {
    case unlocked = "UNLOCKED"
    case alreadyUnlocked = "ALREADY_UNLOCKED"
    case needsPermission = "NEEDS_PERMISSION"
    case failed = "FAILED"
    case unverified = "UNVERIFIED"

    public var isSuccess: Bool { self == .unlocked || self == .alreadyUnlocked }
}

public struct UnlockOutcome: Equatable {
    public let status: UnlockStatus
    public let mechanism: UnlockMechanism
    public let durationMilliseconds: Int
    public let detail: String?

    public init(status: UnlockStatus, mechanism: UnlockMechanism, durationMilliseconds: Int, detail: String? = nil) {
        self.status = status
        self.mechanism = mechanism
        self.durationMilliseconds = durationMilliseconds
        self.detail = detail
    }
}

public protocol UnlockEventPosting {
    func wakeDisplay() -> Bool
    func postWakePrompt() -> Bool
    func postEscape() -> Bool
    func postKeystrokes(string: String) -> Bool
    func postReturn() -> Bool
    func unlockViaSystemEvents(password: String) -> Bool
}

public extension UnlockEventPosting {
    func postWakePrompt() -> Bool { true }
    func postEscape() -> Bool { true }
}

public struct SystemUnlockEventPoster: UnlockEventPosting {
    private static let spaceKeyCode: CGKeyCode = 0x31
    private static let escapeKeyCode: CGKeyCode = 0x35
    private static let returnKeyCode: CGKeyCode = 0x24

    public init() {}

    public func wakeDisplay() -> Bool {
        // Assert user activity to turn on the screen
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "4"]
        try? process.run()

        // Also post a key event to stimulate HID system state
        let source = CGEventSource(stateID: .combinedSessionState)
        let shiftKey: CGKeyCode = 0x38
        if let down = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    public func postWakePrompt() -> Bool {
        // Space key dismisses the clock screensaver and displays the password box
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.spaceKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.spaceKeyCode, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    public func postEscape() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.escapeKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.escapeKeyCode, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    public func postKeystrokes(string: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        for char in string.utf16 {
            var utf16Char = [char]
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &utf16Char)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(35_000) // 35ms typing delay for reliable password buffer input
        }
        return true
    }

    public func postReturn() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.returnKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.returnKeyCode, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    public func unlockViaSystemEvents(password: String) -> Bool {
        let escaped = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\"\n"
            + "delay 0.5\n"
            + "keystroke \"\(escaped)\"\n"
            + "delay 0.2\n"
            + "key code 36\n"
            + "end tell"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

public final class MacUnlockManager {
    public typealias Sleeper = (TimeInterval) async -> Void

    private let screen: ScreenStateProviding
    private let logger: LoggingManager
    private let clock: Clock
    private let poster: UnlockEventPosting
    private let sleep: Sleeper
    private let verificationTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let stateLock = NSLock()
    private var unlockInProgress = false

    public init(
        screen: ScreenStateProviding = SystemScreenState(),
        logger: LoggingManager = .shared,
        clock: Clock = SystemClock(),
        poster: UnlockEventPosting = SystemUnlockEventPoster(),
        verificationTimeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.1,
        sleep: @escaping Sleeper = { interval in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.screen = screen
        self.logger = logger
        self.clock = clock
        self.poster = poster
        self.verificationTimeout = verificationTimeout
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    public func performUnlock(password: String) async -> UnlockOutcome {
        let start = clock.now

        if !screen.isLocked {
            logger.info("Unlock requested while screen is already unlocked")
            return UnlockOutcome(
                status: .alreadyUnlocked,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start)
            )
        }

        guard !password.isEmpty else {
            logger.warning("Unlock rejected: password payload was empty")
            return UnlockOutcome(
                status: .failed,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "Password was empty"
            )
        }

        stateLock.lock()
        if unlockInProgress {
            stateLock.unlock()
            logger.info("Concurrent unlock request ignored (already unlocking)")
            return UnlockOutcome(
                status: .unverified,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "Another unlock operation is already in progress"
            )
        }
        unlockInProgress = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            unlockInProgress = false
            stateLock.unlock()
        }

        guard screen.isAccessibilityTrusted else {
            logger.warning("Unlock refused: Accessibility is not granted")
            screen.requestAccessibilityIfNeeded()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
            try? proc.run()
            return UnlockOutcome(
                status: .needsPermission,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "Accessibility permission is required on your Mac. Open System Settings → Privacy & Security → Accessibility and turn ON Distee."
            )
        }

        // 1. Wake the display and give WindowServer time to turn on
        logger.info("Waking display for unlock")
        _ = poster.wakeDisplay()
        await sleep(0.8)

        // 2. Stimulate the lock screen to present and focus the password text box
        _ = poster.postWakePrompt()
        await sleep(0.6)

        // 3. Post keystrokes via native CGEvent
        logger.info("Posting unlock password via CGEvent")
        guard poster.postKeystrokes(string: password) else {
            logger.error("Failed to construct or post unlock CGEvents")
            return UnlockOutcome(
                status: .failed,
                mechanism: .cgEvent,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "CGEvent creation failed"
            )
        }

        await sleep(0.1)
        guard poster.postReturn() else {
            logger.error("Failed to post return CGEvent")
            return UnlockOutcome(
                status: .failed,
                mechanism: .cgEvent,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "CGEvent return failed"
            )
        }

        // 4. Verify whether the screen unlocked
        if let outcome = await awaitUnlockVerification(start: start, mechanism: .cgEvent, timeout: verificationTimeout) {
            return outcome
        }

        // 5. Fallback attempt via System Events if CGEvent did not unlock within timeout
        logger.info("Attempting unlock fallback via System Events")
        _ = poster.unlockViaSystemEvents(password: password)
        if let fallbackOutcome = await awaitUnlockVerification(start: start, mechanism: .systemEvents, timeout: 2.5) {
            return fallbackOutcome
        }

        logger.warning("Screen remained locked after unlock attempts")
        return UnlockOutcome(
            status: .failed,
            mechanism: .cgEvent,
            durationMilliseconds: elapsedMilliseconds(since: start),
            detail: "Screen remained locked (incorrect password or lock screen unresponsive)"
        )
    }

    private func awaitUnlockVerification(start: Date, mechanism: UnlockMechanism, timeout: TimeInterval) async -> UnlockOutcome? {
        let deadline = clock.now.addingTimeInterval(timeout)
        while clock.now < deadline {
            if !screen.isLocked {
                let duration = elapsedMilliseconds(since: start)
                logger.notice("Unlock verified via \(mechanism.rawValue, privacy: .public) in \(duration) ms")
                return UnlockOutcome(status: .unlocked, mechanism: mechanism, durationMilliseconds: duration)
            }
            await sleep(pollInterval)
        }

        if !screen.isLocked {
            let duration = elapsedMilliseconds(since: start)
            logger.notice("Unlock verified after timeout window in \(duration) ms")
            return UnlockOutcome(status: .unlocked, mechanism: mechanism, durationMilliseconds: duration)
        }

        return nil
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(max(0, clock.now.timeIntervalSince(start)) * 1000)
    }
}

