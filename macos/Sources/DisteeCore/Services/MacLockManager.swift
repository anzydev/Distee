import CoreGraphics
import Foundation

public enum LockMechanism: String, Equatable {
    case cgEvent = "CGEvent ⌃⌘Q"
    case displaySleep = "pmset displaysleepnow"
    case none = "none"
}

public enum LockStatus: String, Equatable {
    case locked = "LOCKED"
    case alreadyLocked = "ALREADY_LOCKED"
    case needsPermission = "NEEDS_PERMISSION"
    case unverified = "UNVERIFIED"
    case failed = "FAILED"

    public var isSuccess: Bool { self == .locked || self == .alreadyLocked }
}

public struct LockOutcome: Equatable {
    public let status: LockStatus
    public let mechanism: LockMechanism
    public let durationMilliseconds: Int
    public let detail: String?

    public init(status: LockStatus, mechanism: LockMechanism, durationMilliseconds: Int, detail: String? = nil) {
        self.status = status
        self.mechanism = mechanism
        self.durationMilliseconds = durationMilliseconds
        self.detail = detail
    }
}

public protocol ProcessRunning {
    func run(executable: String, arguments: [String]) throws
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "com.distee.process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) exited \(process.terminationStatus)"]
            )
        }
    }
}

/// Posts the system's own Lock Screen shortcut (⌃⌘Q) as a synthetic key event.
/// This is the only privileged capability the agent needs, and it requires Accessibility.
public protocol LockEventPosting {
    /// - Returns: `false` if the events could not be constructed.
    func postLockShortcut() -> Bool
}

public struct SystemLockEventPoster: LockEventPosting {
    public init() {}

    private static let qKeyCode: CGKeyCode = 0x0C

    public func postLockShortcut() -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.qKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.qKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = [.maskControl, .maskCommand]
        keyUp.flags = [.maskControl, .maskCommand]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

/// Locks the current session.
///
/// Primary mechanism (Phase 1): post the system's own ⌃⌘Q shortcut, which requires
/// Accessibility trust. The result is reported as `LOCKED` only after
/// `CGSSessionScreenIsLocked` is observed — a posted keystroke is not evidence that the
/// screen locked.
///
/// Fallback: `pmset displaysleepnow`, used only when the screen is configured to require a
/// password immediately, so display sleep is equivalent to a lock. That path needs no TCC
/// grant, which is why it is preferred when Accessibility is unavailable.
public final class MacLockManager {
    public typealias Sleeper = (TimeInterval) async -> Void

    private let screen: ScreenStateProviding
    private let logger: LoggingManager
    private let clock: Clock
    private let sleep: Sleeper
    private let processRunner: ProcessRunning
    private let poster: LockEventPosting
    private let verificationTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let stateLock = NSLock()
    private var lockInProgress = false

    public init(
        screen: ScreenStateProviding = SystemScreenState(),
        logger: LoggingManager = .shared,
        clock: Clock = SystemClock(),
        processRunner: ProcessRunning = SystemProcessRunner(),
        poster: LockEventPosting = SystemLockEventPoster(),
        verificationTimeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.1,
        sleep: @escaping Sleeper = { interval in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.screen = screen
        self.logger = logger
        self.clock = clock
        self.processRunner = processRunner
        self.poster = poster
        self.verificationTimeout = verificationTimeout
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    public func performLock() async -> LockOutcome {
        let start = clock.now

        if screen.isLocked {
            logger.info("Lock requested while screen is already locked")
            return LockOutcome(
                status: .alreadyLocked,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start)
            )
        }

        stateLock.lock()
        if lockInProgress {
            stateLock.unlock()
            logger.info("Concurrent lock request ignored (already locking)")
            return LockOutcome(
                status: .alreadyLocked,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start)
            )
        }
        lockInProgress = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            lockInProgress = false
            stateLock.unlock()
        }

        switch selectMechanism() {
        case .cgEvent:
            return await lockWithKeystroke(start: start)
        case .displaySleep:
            return await lockWithDisplaySleep(start: start)
        case .none:
            logger.warning("Lock refused: Accessibility is not granted and display sleep would not lock")
            // Ask macOS to show its permission prompt / add Distee to the Accessibility list.
            screen.requestAccessibilityIfNeeded()
            return LockOutcome(
                status: .needsPermission,
                mechanism: .none,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "Accessibility permission is required. Grant it in System Settings → Privacy & Security → Accessibility."
            )
        }
    }

    public var canVerifyLockState: Bool { true }

    private func selectMechanism() -> LockMechanism {
        if screen.isAccessibilityTrusted { return .cgEvent }
        if screen.locksImmediatelyOnDisplaySleep { return .displaySleep }
        return .none
    }

    private func lockWithKeystroke(start: Date) async -> LockOutcome {
        logger.info("Lock attempt via CGEvent ⌃⌘Q")
        guard poster.postLockShortcut() else {
            return LockOutcome(
                status: .failed,
                mechanism: .cgEvent,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: "CGEvent creation failed"
            )
        }
        return await awaitVerification(start: start, mechanism: .cgEvent)
    }

    private func lockWithDisplaySleep(start: Date) async -> LockOutcome {
        logger.info("Lock attempt via pmset displaysleepnow")
        do {
            try processRunner.run(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])
        } catch {
            logger.error("pmset displaysleepnow failed: \(error.localizedDescription, privacy: .public)")
            return LockOutcome(
                status: .failed,
                mechanism: .displaySleep,
                durationMilliseconds: elapsedMilliseconds(since: start),
                detail: error.localizedDescription
            )
        }
        return await awaitVerification(start: start, mechanism: .displaySleep)
    }

    /// Polls for the lock state rather than trusting the mechanism. Reporting `LOCKED`
    /// without observing it is exactly the failure mode Phase 1 forbids.
    private func awaitVerification(start: Date, mechanism: LockMechanism) async -> LockOutcome {
        let deadline = start.addingTimeInterval(verificationTimeout)
        while clock.now < deadline {
            if screen.isLocked {
                let duration = elapsedMilliseconds(since: start)
                logger.notice("Lock verified via \(mechanism.rawValue, privacy: .public) in \(duration) ms")
                return LockOutcome(status: .locked, mechanism: mechanism, durationMilliseconds: duration)
            }
            await sleep(pollInterval)
        }

        if screen.isLocked {
            let duration = elapsedMilliseconds(since: start)
            logger.notice("Lock verified after timeout window in \(duration) ms")
            return LockOutcome(status: .locked, mechanism: mechanism, durationMilliseconds: duration)
        }

        logger.warning("Lock mechanism fired but the screen state could not be verified")
        return LockOutcome(
            status: .unverified,
            mechanism: mechanism,
            durationMilliseconds: elapsedMilliseconds(since: start),
            detail: "The lock request was delivered, but macOS did not report a locked session."
        )
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(max(0, clock.now.timeIntervalSince(start)) * 1000)
    }
}
