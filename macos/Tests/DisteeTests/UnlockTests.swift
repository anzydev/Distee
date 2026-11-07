import DisteeCore
import Foundation

final class FakeUnlockPoster: UnlockEventPosting {
    var wakeCalls = 0
    var escapeCalls = 0
    var keystrokesPosted: [String] = []
    var returnCalls = 0
    var systemEventsCalls: [String] = []

    var onPostReturn: (() -> Void)?
    var onSystemEvents: (() -> Void)?

    func wakeDisplay() -> Bool {
        wakeCalls += 1
        return true
    }

    func postEscape() -> Bool {
        escapeCalls += 1
        return true
    }

    func postKeystrokes(string: String) -> Bool {
        keystrokesPosted.append(string)
        return true
    }

    func postReturn() -> Bool {
        returnCalls += 1
        onPostReturn?()
        return true
    }

    func unlockViaSystemEvents(password: String) -> Bool {
        systemEventsCalls.append(password)
        onSystemEvents?()
        return true
    }
}

enum UnlockTests {
    static func run(_ suite: TestSuite) async {
        await suite.run("unlock.already unlocked is idempotent and posts nothing") {
            let screen = FakeScreen()
            screen.locked = false
            let poster = FakeUnlockPoster()
            let manager = MacUnlockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "unlock"),
                poster: poster,
                verificationTimeout: 0.05,
                pollInterval: 0.01
            )

            let outcome = await manager.performUnlock(password: "secret123")
            suite.expectEqual(outcome.status, .alreadyUnlocked)
            suite.expectEqual(outcome.mechanism, .none)
            suite.expectEqual(poster.keystrokesPosted.count, 0)
        }

        await suite.run("unlock.requests accessibility when not trusted") {
            let screen = FakeScreen()
            screen.locked = true
            screen.accessible = false
            let poster = FakeUnlockPoster()
            let manager = MacUnlockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "unlock"),
                poster: poster,
                verificationTimeout: 0.05,
                pollInterval: 0.01
            )

            let outcome = await manager.performUnlock(password: "secret123")
            suite.expectEqual(outcome.status, .needsPermission)
            suite.expect(screen.promptRequested, "should request accessibility prompt")
            suite.expectEqual(poster.keystrokesPosted.count, 0)
        }

        await suite.run("unlock.rejects empty password") {
            let screen = FakeScreen()
            screen.locked = true
            screen.accessible = true
            let poster = FakeUnlockPoster()
            let manager = MacUnlockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "unlock"),
                poster: poster,
                verificationTimeout: 0.05,
                pollInterval: 0.01
            )

            let outcome = await manager.performUnlock(password: "")
            suite.expectEqual(outcome.status, .failed)
            suite.expectEqual(poster.keystrokesPosted.count, 0)
        }

        await suite.run("unlock.successful keystroke unlock verified by screen state") {
            let screen = FakeScreen()
            screen.locked = true
            screen.accessible = true
            let poster = FakeUnlockPoster()

            poster.onPostReturn = {
                screen.locked = false
            }

            let manager = MacUnlockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "unlock"),
                poster: poster,
                verificationTimeout: 0.2,
                pollInterval: 0.01,
                sleep: { _ in }
            )

            let outcome = await manager.performUnlock(password: "mypassword")
            suite.expectEqual(outcome.status, .unlocked)
            suite.expectEqual(outcome.mechanism, .cgEvent)
            suite.expectEqual(poster.keystrokesPosted, ["mypassword"])
            suite.expectEqual(poster.returnCalls, 1)
        }

        await suite.run("unlock.falls back to System Events when CGEvent does not unlock") {
            let screen = FakeScreen()
            screen.locked = true
            screen.accessible = true
            let poster = FakeUnlockPoster()

            poster.onSystemEvents = {
                screen.locked = false
            }

            let manager = MacUnlockManager(
                screen: screen,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "unlock"),
                poster: poster,
                verificationTimeout: 0.05,
                pollInterval: 0.01,
                sleep: { _ in }
            )

            let outcome = await manager.performUnlock(password: "fallbackpass")
            suite.expectEqual(outcome.status, .unlocked)
            suite.expectEqual(outcome.mechanism, .systemEvents)
            suite.expectEqual(poster.systemEventsCalls, ["fallbackpass"])
        }
    }
}

