import DisteeCore
import Foundation

final class FakeScreen: ScreenStateProviding {
    var locked = false
    var accessible = false
    var immediatePassword = true
    var promptRequested = false

    var isLocked: Bool { locked }
    var isAccessibilityTrusted: Bool { accessible }
    var locksImmediatelyOnDisplaySleep: Bool { immediatePassword }
    func requestAccessibilityIfNeeded() { promptRequested = true }
}

final class FakeProcessRunner: ProcessRunning {
    var invocations: [(String, [String])] = []
    var error: Error?
    var effect: (() -> Void)?

    func run(executable: String, arguments: [String]) throws {
        invocations.append((executable, arguments))
        if let error { throw error }
        effect?()
    }
}

final class FakePoster: LockEventPosting {
    var posts = 0
    var succeeds = true
    var effect: (() -> Void)?

    func postLockShortcut() -> Bool {
        posts += 1
        if succeeds { effect?() }
        return succeeds
    }
}

enum LockTests {
    static func run(_ suite: TestSuite) async {
        await suite.run("lock.already locked is idempotent and posts nothing") {
            let screen = FakeScreen()
            screen.locked = true
            let poster = FakePoster()
            let runner = FakeProcessRunner()
            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: runner,
                poster: poster,
                verificationTimeout: 0.05,
                pollInterval: 0.01
            )

            let outcome = await manager.performLock()
            suite.expectEqual(outcome.status, .alreadyLocked)
            suite.expectEqual(outcome.mechanism, .none)
            suite.expectEqual(poster.posts, 0)
            suite.expectEqual(runner.invocations.count, 0)
        }

        await suite.run("lock.uses CGEvent when Accessibility is granted, verified by screen state") {
            let screen = FakeScreen()
            let poster = FakePoster()
            poster.effect = { screen.locked = true }
            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: FakeProcessRunner(),
                poster: poster,
                verificationTimeout: 0.2,
                pollInterval: 0.01
            )
            screen.accessible = true

            let outcome = await manager.performLock()
            suite.expectEqual(outcome.status, .locked)
            suite.expectEqual(outcome.mechanism, .cgEvent)
            suite.expectEqual(poster.posts, 1)
        }

        await suite.run("lock.falls back to display sleep when Accessibility is missing") {
            let screen = FakeScreen()
            screen.accessible = false
            screen.immediatePassword = true
            let runner = FakeProcessRunner()
            runner.effect = { screen.locked = true }
            let poster = FakePoster()

            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: runner,
                poster: poster,
                verificationTimeout: 0.2,
                pollInterval: 0.01
            )

            let outcome = await manager.performLock()
            suite.expectEqual(outcome.status, .locked)
            suite.expectEqual(outcome.mechanism, .displaySleep)
            suite.expectEqual(poster.posts, 0, "must not post key events without trust")
            suite.expectEqual(runner.invocations.count, 1)
            suite.expectEqual(runner.invocations.first?.0, "/usr/bin/pmset")
            suite.expectEqual(runner.invocations.first?.1, ["displaysleepnow"])
        }

        await suite.run("lock.requests permission instead of pretending, when sleep would not lock") {
            let screen = FakeScreen()
            screen.accessible = false
            screen.immediatePassword = false
            let runner = FakeProcessRunner()
            let poster = FakePoster()
            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: runner,
                poster: poster,
                verificationTimeout: 0.1,
                pollInterval: 0.01
            )

            let outcome = await manager.performLock()
            suite.expectEqual(outcome.status, .needsPermission)
            suite.expectEqual(outcome.mechanism, .none)
            suite.expectEqual(runner.invocations.count, 0, "must not sleep the display when it would not lock")
            suite.expect(outcome.detail?.contains("Accessibility") == true, "explains the missing permission")
        }

        await suite.run("lock.reports UNVERIFIED when the screen state never confirms") {
            let screen = FakeScreen()
            screen.accessible = true
            let poster = FakePoster() // posts but nothing locks
            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: FakeProcessRunner(),
                poster: poster,
                verificationTimeout: 0.1,
                pollInterval: 0.01
            )

            let outcome = await manager.performLock()
            suite.expectEqual(outcome.status, .unverified)
            suite.expect(!outcome.status.isSuccess, "unverified must never count as success")
        }

        await suite.run("lock.reports FAILED when the fallback process fails") {
            let screen = FakeScreen()
            screen.accessible = false
            screen.immediatePassword = true
            let runner = FakeProcessRunner()
            runner.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "pmset unavailable"])
            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: runner,
                poster: FakePoster(),
                verificationTimeout: 0.1,
                pollInterval: 0.01
            )

            let outcome = await manager.performLock()
            suite.expectEqual(outcome.status, .failed)
            suite.expectEqual(outcome.mechanism, .displaySleep)
        }

        await suite.run("lock.a concurrent request does not double-execute") {
            let screen = FakeScreen()
            screen.accessible = true
            let poster = FakePoster()
            poster.effect = { Thread.sleep(forTimeInterval: 0.15); screen.locked = true }

            let manager = MacLockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "lock"),
                processRunner: FakeProcessRunner(),
                poster: poster,
                verificationTimeout: 0.5,
                pollInterval: 0.01
            )

            async let first = manager.performLock()
            try? await Task.sleep(nanoseconds: 40_000_000)
            let second = await manager.performLock()
            let firstOutcome = await first

            suite.expectEqual(second.status, .alreadyLocked, "second concurrent request is rejected")
            suite.expectEqual(second.mechanism, .none)
            suite.expectEqual(firstOutcome.status, .locked)
            suite.expectEqual(poster.posts, 1, "only one keystroke was posted")
        }
    }
}
