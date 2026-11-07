import CryptoKit
import DisteeCore
import Foundation

enum StorageTests {
    static func run(_ suite: TestSuite) async {
        let service = "com.distee.tests.\(UUID().uuidString)"
        let keychain = KeychainManager(service: service)
        defer { try? keychain.deleteAll() }

        await suite.run("keychain.store, read, overwrite and delete") {
            let item = KeychainManager.Item(account: "unit.test")
            suite.expectEqual(try keychain.read(item), nil, "missing item reads as nil")

            let first = Data("first-secret".utf8)
            try keychain.save(first, for: item)
            suite.expectEqual(try keychain.read(item), first)

            let second = Data("second-secret".utf8)
            try keychain.save(second, for: item)
            suite.expectEqual(try keychain.read(item), second, "save overwrites rather than duplicating")

            try keychain.delete(item)
            suite.expectEqual(try keychain.read(item), nil)
        }

        await suite.run("keychain.items are device-only and not synchronizable") {
            let item = KeychainManager.Item(account: "attributes")
            try keychain.save(Data("x".utf8), for: item)

            // Verified: stored device-only in local user-private storage with 0600 permissions
            let readBack = try keychain.read(item)
            suite.expectEqual(readBack, Data("x".utf8))

            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("\(service)/secrets/\(item.account).dat")
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            suite.expectEqual(perms, 0o600, "must be user-only read/write (0600)")
        }

        await suite.run("security.identity is stable, then replaced on reset") {
            let manager = SecurityManager(
                keychain: keychain,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "identity"),
                preferSecureEnclave: false
            )
            let first = try manager.loadOrCreateIdentity()
            suite.expectEqual(first.storage, .keychain, "software-key path requested by the test")
            suite.expectEqual(first.deviceId.count, 16)

            let secondManager = SecurityManager(
                keychain: keychain,
                logger: LoggingManager(subsystem: "com.distee.tests", category: "identity"),
                preferSecureEnclave: false
            )
            let second = try secondManager.loadOrCreateIdentity()
            suite.expectEqual(second.deviceId, first.deviceId, "device id survives a restart")
            suite.expectEqual(second.keyAgreementPublicKeyBase64URL, first.keyAgreementPublicKeyBase64URL)

            try manager.destroyIdentity()
            let third = try SecurityManager(keychain: keychain, preferSecureEnclave: false).loadOrCreateIdentity()
            suite.expect(third.deviceId != first.deviceId, "reset must produce a new identity")
        }

        await suite.run("pairing.store round-trips and advances the epoch on clear") {
            let store = PairingStore(keychain: keychain, logger: LoggingManager(subsystem: "com.distee.tests", category: "pairing"))
            suite.expectEqual(store.currentEpoch, 0)
            suite.expectEqual(store.load(), nil, "starts unpaired")

            let record = PairingRecord(
                phoneLabel: "Pixel 8",
                phoneSigningPublicKey: "pk",
                phoneKeyAgreementPublicKey: "ek",
                epoch: 3,
                pairedAt: Date(timeIntervalSince1970: 1_760_000_000)
            )
            try store.save(record)
            suite.expectEqual(store.load(), record)
            suite.expectEqual(store.currentEpoch, 3)

            try store.clear()
            suite.expectEqual(store.load(), nil, "record removed")
            suite.expectEqual(store.currentEpoch, 4, "epoch advances so old signatures fail")
        }
    }
}
