import Foundation

/// Small assertion harness. XCTest is not available with a Command Line Tools-only
/// installation (no Xcode), so the suite runs as a SwiftPM executable instead. The tests are
/// ordinary functions and can be moved to XCTest/swift-testing unchanged.
final class TestSuite {
    private var passed = 0
    private var skipped = 0
    private var failures: [(name: String, message: String)] = []
    private var current = ""

    func run(_ name: String, _ body: () async throws -> Void) async {
        current = name
        let before = failures.count
        do {
            try await body()
        } catch {
            failures.append((name, "threw: \(error)"))
        }
        if failures.count == before {
            passed += 1
            print("  ✓ \(name)")
        } else {
            for failure in failures[before...] {
                print("  ✗ \(name): \(failure.message)")
            }
        }
    }

    func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
        if !condition {
            failures.append((current, "\(message) (line \(line))"))
        }
    }

    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", line: UInt = #line) {
        if lhs != rhs {
            failures.append((current, "expected \(rhs), got \(lhs) \(message.isEmpty ? "" : "— \(message)") (line \(line))"))
        }
    }

    func expectThrows(_ message: String, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            failures.append((current, "expected an error but none was thrown — \(message) (line \(line))"))
        } catch {
            // expected
        }
    }

    /// A test that could not run in this environment. Never counted as a pass.
    func skip(_ name: String, _ reason: String) {
        skipped += 1
        print("  ↷ \(name) — SKIPPED: \(reason)")
    }

    func finish() -> Never {
        print("")
        let skipNote = skipped > 0 ? ", \(skipped) skipped" : ""
        if failures.isEmpty {
            print("PASS — \(passed) tests\(skipNote)")
            exit(0)
        }
        print("FAIL — \(passed) passed, \(failures.count) failed\(skipNote)")
        exit(1)
    }
}

/// Polls a condition with a deadline. Used instead of expectations because state changes
/// are delivered on the main queue by the connection manager.
func waitUntil(timeout: TimeInterval = 4, interval: TimeInterval = 0.01, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return condition()
}

func loadPhase1Document(_ name: String) -> String? {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent("docs/phase-1/\(name)"),
        cwd.appendingPathComponent("../docs/phase-1/\(name)")
    ]
    for url in candidates {
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
    }
    return nil
}
