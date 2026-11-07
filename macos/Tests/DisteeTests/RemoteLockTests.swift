import CryptoKit
import DisteeCore
import Foundation

enum RemoteLockTests {
    static func run(_ suite: TestSuite) async {
        await suite.run("remotelock.valid signed envelope is authenticated and verified") {
            let phoneSignKey = P256.Signing.PrivateKey()
            _ = P256.KeyAgreement.PrivateKey()
            let macKey = P256.KeyAgreement.PrivateKey()
            let macSignKey = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: macSignKey.publicKey)
            let epoch = 1

            let payload = Data("{\"action\":\"lock\",\"requestedAt\":1700000000}".utf8)
            let envelope = try EnvelopeCrypto.seal(
                payload,
                type: "cmd.lock",
                deviceId: deviceId,
                epoch: epoch,
                messageId: ULID.generate(),
                seq: 1,
                timestamp: Int(Date().timeIntervalSince1970),
                recipient: macKey.publicKey,
                signer: phoneSignKey
            )

            suite.expectEqual(envelope.t, "cmd.lock")
            suite.expectEqual(envelope.d, deviceId)
            suite.expectEqual(envelope.e, epoch)

            // Mac verifies signature using phone's signing public key
            let isValid = try EnvelopeCrypto.verifySignature(envelope, senderSigningKey: phoneSignKey.publicKey)
            suite.expect(isValid, "signature must be valid")

            // Mac opens envelope
            let decrypted = try EnvelopeCrypto.open(
                envelope,
                recipientKey: macKey,
                senderSigningKey: phoneSignKey.publicKey,
                expectedDeviceId: deviceId
            )
            suite.expectEqual(decrypted, payload, "decrypted payload matches")
        }

        await suite.run("remotelock.forged signature is rejected") {
            let phoneSignKey = P256.Signing.PrivateKey()
            let attackerKey = P256.Signing.PrivateKey()
            let macKey = P256.KeyAgreement.PrivateKey()
            let macSignKey = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: macSignKey.publicKey)

            let payload = Data("{\"action\":\"lock\"}".utf8)
            let envelope = try EnvelopeCrypto.seal(
                payload,
                type: "cmd.lock",
                deviceId: deviceId,
                epoch: 1,
                messageId: ULID.generate(),
                seq: 1,
                timestamp: Int(Date().timeIntervalSince1970),
                recipient: macKey.publicKey,
                signer: attackerKey // attacker signs!
            )

            // Mac verifies against legitimate paired phone key
            let isValid = try EnvelopeCrypto.verifySignature(envelope, senderSigningKey: phoneSignKey.publicKey)
            suite.expect(!isValid, "forged signature must be rejected")
        }

        await suite.run("remotelock.tampered ciphertext or header invalidates signature") {
            let phoneSignKey = P256.Signing.PrivateKey()
            let macKey = P256.KeyAgreement.PrivateKey()
            let macSignKey = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: macSignKey.publicKey)

            let envelope = try EnvelopeCrypto.seal(
                Data("{\"action\":\"lock\"}".utf8),
                type: "cmd.lock",
                deviceId: deviceId,
                epoch: 1,
                messageId: ULID.generate(),
                seq: 1,
                timestamp: Int(Date().timeIntervalSince1970),
                recipient: macKey.publicKey,
                signer: phoneSignKey
            )

            // Tamper with device ID
            var tampered = envelope
            tampered.d = "wrongdevice12345"
            let validTamperedD = try? EnvelopeCrypto.verifySignature(tampered, senderSigningKey: phoneSignKey.publicKey)
            suite.expect(validTamperedD == false, "tampered device ID must fail verification")

            // Tamper with sequence
            tampered = envelope
            tampered.seq = 999
            let validTamperedSeq = try? EnvelopeCrypto.verifySignature(tampered, senderSigningKey: phoneSignKey.publicKey)
            suite.expect(validTamperedSeq == false, "tampered seq must fail verification")
        }

        await suite.run("remotelock.real path: valid lock is decrypted, executed and answered with a signed ack") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            let id = try fixture.send(type: "cmd.lock", payload: "{\"action\":\"lock\"}", seq: 1)
            let ack = await fixture.wait(forType: "lock.ack")
            suite.expect(ack != nil, "service must answer a valid lock with lock.ack")
            guard let ack else { return }

            suite.expectEqual(ack["id"] as? String, id, "ack answers this command")
            suite.expectEqual(ack["status"] as? String, "LOCKED")
            suite.expectEqual(fixture.poster.posts, 1, "the real lock path ran exactly once")
            suite.expect(fixture.verifyAck(ack), "ack must carry a valid Mac signature")
            suite.expectEqual(fixture.store.load()?.lastSequence, 1, "sequence advanced and persisted")
        }

        await suite.run("remotelock.real path: replayed command is refused and does not lock twice") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            let data = try fixture.envelopeData(type: "cmd.lock", payload: "{\"action\":\"lock\"}", seq: 1)
            fixture.service.receiveFrame(data)
            _ = await fixture.wait(forType: "lock.ack")
            fixture.service.receiveFrame(data)

            let rejected = await fixture.wait(forType: "lock.rejected")
            suite.expectEqual(rejected?["reason"] as? String, "REPLAY_DETECTED")
            suite.expectEqual(fixture.poster.posts, 1, "replay must not trigger a second lock")
        }

        await suite.run("remotelock.real path: command signed by another key never locks") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            _ = try fixture.send(type: "cmd.lock", payload: "{\"action\":\"lock\"}", seq: 1, signer: P256.Signing.PrivateKey())
            let rejected = await fixture.wait(forType: "lock.rejected")
            suite.expectEqual(rejected?["reason"] as? String, "INVALID_SIGNATURE")
            suite.expectEqual(fixture.poster.posts, 0)
        }

        await suite.run("remotelock.real path: validly signed but undecryptable payload never locks") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            // Authentic phone signature, but sealed to a key the Mac does not hold.
            _ = try fixture.send(
                type: "cmd.lock",
                payload: "{\"action\":\"lock\"}",
                seq: 1,
                recipient: P256.KeyAgreement.PrivateKey().publicKey
            )
            let rejected = await fixture.wait(forType: "lock.rejected")
            suite.expectEqual(rejected?["reason"] as? String, "DECRYPT_FAILED")
            suite.expectEqual(fixture.poster.posts, 0)
        }

        await suite.run("remotelock.real path: payload action must match the signed command type") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            _ = try fixture.send(type: "cmd.lock", payload: "{\"action\":\"unpair\"}", seq: 1)
            let rejected = await fixture.wait(forType: "lock.rejected")
            suite.expectEqual(rejected?["reason"] as? String, "PAYLOAD_MISMATCH")
            suite.expectEqual(fixture.poster.posts, 0)
            suite.expect(fixture.store.load() != nil, "still paired")
        }

        await suite.run("remotelock.real path: lock failure is reported as a signed lock.failed, never as success") {
            let fixture = try CommandFixture(lockSucceeds: false)
            defer { fixture.tearDown() }

            _ = try fixture.send(type: "cmd.lock", payload: "{\"action\":\"lock\"}", seq: 1)
            let failed = await fixture.wait(forType: "lock.failed")
            suite.expect(failed != nil, "unverified lock must produce lock.failed")
            suite.expect(fixture.frames.allSatisfy { ($0["t"] as? String) != "lock.ack" }, "no success ack")
            if let failed { suite.expect(fixture.verifyAck(failed), "lock.failed is signed too") }
        }

        await suite.run("remotelock.real path: tampered or retargeted ack fails verification") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            _ = try fixture.send(type: "cmd.lock", payload: "{\"action\":\"lock\"}", seq: 1)
            guard let ack = await fixture.wait(forType: "lock.ack") else {
                suite.expect(false, "no ack")
                return
            }
            suite.expect(fixture.verifyAck(ack), "genuine ack verifies")

            var otherCommand = ack
            otherCommand["id"] = ULID.generate()
            suite.expect(!fixture.verifyAck(otherCommand), "ack must not verify for a different command id")

            var forgedStatus = ack
            forgedStatus["status"] = "ALREADY_LOCKED"
            suite.expect(!fixture.verifyAck(forgedStatus), "status is covered by the signature")

            var unsigned = ack
            unsigned.removeValue(forKey: "sig")
            suite.expect(!fixture.verifyAck(unsigned), "unsigned ack must not verify")
        }

        await suite.run("remotelock.real path: signed unpair clears the pairing and is acked with a signed unpair.ack") {
            let fixture = try CommandFixture()
            defer { fixture.tearDown() }

            let id = try fixture.send(type: "cmd.unpair", payload: "{\"action\":\"unpair\"}", seq: 1)
            let ack = await fixture.wait(forType: "unpair.ack")
            suite.expect(ack != nil, "unpair must be acknowledged")
            guard let ack else { return }
            suite.expectEqual(ack["id"] as? String, id)
            suite.expect(fixture.verifyAck(ack), "unpair.ack must be signed by the Mac")
            suite.expect(fixture.store.load() == nil, "pairing record removed")
            suite.expectEqual(fixture.store.currentEpoch, 2, "epoch advanced on unpair")
        }
    }
}

/// Drives a real `BackgroundService` through its inbound-frame pipeline with a seeded
/// pairing, fake screen and fake key poster, and records every frame it emits.
final class CommandFixture {
    let keychain: KeychainManager
    let store: PairingStore
    let service: BackgroundService
    let screen: FakeScreen
    let poster: FakePoster
    let phoneSignKey: P256.Signing.PrivateKey
    let identity: DeviceIdentity
    let epoch = 1

    private let framesLock = NSLock()
    private var recorded: [[String: Any]] = []

    init(lockSucceeds: Bool = true) throws {
        let keychain = KeychainManager(service: "test.distee.command.\(UUID().uuidString)")
        let security = SecurityManager(keychain: keychain, preferSecureEnclave: false)
        let store = PairingStore(keychain: keychain)
        let identity = try security.loadOrCreateIdentity()
        let phoneSignKey = P256.Signing.PrivateKey()

        try store.save(PairingRecord(
            phoneLabel: "Test iPhone",
            phoneSigningPublicKey: Base64URL.encode(phoneSignKey.publicKey.x963Representation),
            phoneKeyAgreementPublicKey: Base64URL.encode(P256.KeyAgreement.PrivateKey().publicKey.x963Representation),
            epoch: 1
        ))

        let screen = FakeScreen()
        screen.accessible = true
        let poster = FakePoster()
        if lockSucceeds { poster.effect = { screen.locked = true } }
        let lockManager = MacLockManager(
            screen: screen,
            logger: LoggingManager(subsystem: "com.distee.tests", category: "remotelock"),
            processRunner: FakeProcessRunner(),
            poster: poster,
            verificationTimeout: 0.3,
            pollInterval: 0.01
        )
        let service = BackgroundService(
            configuration: AppConfiguration(relayURL: nil),
            security: security,
            pairingStore: store,
            lockManager: lockManager
        )

        self.keychain = keychain
        self.store = store
        self.identity = identity
        self.phoneSignKey = phoneSignKey
        self.screen = screen
        self.poster = poster
        self.service = service

        service.onOutboundFrame = { [weak self] frame in self?.record(frame) }
        service.start()
    }

    private func record(_ frame: [String: Any]) {
        framesLock.lock()
        recorded.append(frame)
        framesLock.unlock()
    }

    var frames: [[String: Any]] {
        framesLock.lock()
        defer { framesLock.unlock() }
        return recorded
    }

    func wait(forType type: String) async -> [String: Any]? {
        _ = await waitUntil { self.frames.contains { ($0["t"] as? String) == type } }
        return frames.first { ($0["t"] as? String) == type }
    }

    /// Builds the exact JSON a phone would send, sealed to this Mac's key-agreement key.
    func envelopeData(
        type: String,
        payload: String,
        seq: Int,
        id: String = ULID.generate(),
        signer: EnvelopeSigner? = nil,
        recipient: P256.KeyAgreement.PublicKey? = nil
    ) throws -> Data {
        let envelope = try EnvelopeCrypto.seal(
            Data(payload.utf8),
            type: type,
            deviceId: identity.deviceId,
            epoch: epoch,
            messageId: id,
            seq: seq,
            timestamp: Int(Date().timeIntervalSince1970),
            recipient: recipient ?? identity.keyAgreementKey.publicKey,
            signer: signer ?? phoneSignKey
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Sends a command through the service and returns its message id.
    @discardableResult
    func send(
        type: String,
        payload: String,
        seq: Int,
        signer: EnvelopeSigner? = nil,
        recipient: P256.KeyAgreement.PublicKey? = nil
    ) throws -> String {
        let id = ULID.generate()
        service.receiveFrame(try envelopeData(type: type, payload: payload, seq: seq, id: id, signer: signer, recipient: recipient))
        return id
    }

    /// Verifies a Mac result frame the way the phone does.
    func verifyAck(_ frame: [String: Any]) -> Bool {
        guard let t = frame["t"] as? String,
              let d = frame["d"] as? String,
              let e = frame["e"] as? Int,
              let id = frame["id"] as? String,
              let status = frame["status"] as? String,
              let ts = frame["ts"] as? Int,
              let sigString = frame["sig"] as? String,
              let sigData = try? Base64URL.decode(sigString),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData) else {
            return false
        }
        let input = EnvelopeCoding.ackSigningInput(t: t, d: d, e: e, id: id, status: status, ts: ts)
        return identity.signingPublicKey.isValidSignature(signature, for: input)
    }

    func tearDown() {
        service.stop()
        try? keychain.deleteAll()
    }
}
