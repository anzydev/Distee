import Foundation
import DisteeCore
import DisteeTestSupport

// Distee macOS agent test suite.
// Run with: swift run distee-tests
// XCTest is unavailable with a Command Line Tools-only toolchain, so this is a plain
// executable with the same assertions and a non-zero exit code on failure.

let suite = TestSuite()

print("Distee agent tests")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n")

await CryptoTests.run(suite)
await StorageTests.run(suite)
await LockTests.run(suite)
await UnlockTests.run(suite)
await ConnectionTests.run(suite)
await PairingTests.run(suite)
await RemoteLockTests.run(suite)

suite.finish()
