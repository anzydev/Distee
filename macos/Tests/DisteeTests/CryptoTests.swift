import CryptoKit
import DisteeCore
import Foundation

enum CryptoTests {
    static func run(_ suite: TestSuite) async {
        await suite.run("encoding.base64url round-trips arbitrary bytes") {
            let bytes = Data((0..<64).map { UInt8($0) }) + Data([0xFB, 0xFF, 0x00])
            let encoded = Base64URL.encode(bytes)
            suite.expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="),
                         "base64url must not contain +, / or padding")
            suite.expectEqual(try Base64URL.decode(encoded), bytes)
        }

        await suite.run("encoding.device id is 16 base32 characters from the public key") {
            let identity = makeIdentity()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            suite.expectEqual(deviceId.count, 16)
            suite.expect(deviceId.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) },
                         "device id must be lowercase base32")
            // Derived purely from the public key: stable across processes.
            suite.expectEqual(deviceId, DeviceIdentifier.derive(from: identity.publicKey))
        }

        await suite.run("ulid.ids are 26 chars and monotonically increasing") {
            let ids = (0..<200).map { _ in ULID.generate(at: Date(timeIntervalSince1970: 1_760_000_000)) }
            suite.expect(ids.allSatisfy { $0.count == 26 }, "ULID length")
            suite.expectEqual(ids, ids.sorted(), "ULIDs generated in order must sort in order")
        }

        await suite.run("backoff.matches the Phase 1 ladder") {
            let policy = BackoffPolicy()
            let zeroJitter = (1...7).map { policy.delay(forAttempt: $0, jitter: 0) }
            suite.expectEqual(zeroJitter, [1, 2, 4, 8, 16, 32, 60])
            suite.expectEqual(policy.delay(forAttempt: 9, jitter: 0), 60, "capped at 60 s")
            suite.expectEqual(policy.delay(forAttempt: 1, jitter: 1), 1.2, accuracyMessage: "+20% jitter")
            suite.expectEqual(policy.delay(forAttempt: 1, jitter: -1), 0.8, accuracyMessage: "-20% jitter")
            suite.expect(policy.delay(forAttempt: 1, jitter: 5) <= 1.2, "jitter input is clamped")
        }

        await suite.run("envelope.canonical bytes are stable and newline-delimited") {
            let header = EnvelopeCoding.headerBytes(t: "cmd.lock", d: "abcd", e: 3, id: "01ABC", seq: 42, ts: 1_760_000_000, n: "bm9uY2U")
            let text = String(decoding: header, as: UTF8.self)
            suite.expectEqual(text, "distee/v1\ncmd.lock\nabcd\n3\n01ABC\n42\n1760000000\nbm9uY2U")

            let input = EnvelopeCoding.signingInput(header: header, eph: "ZXBo", ciphertext: Data("ct".utf8))
            suite.expect(input.count == header.count + 1 + "ZXBo".utf8.count + 1 + 32, "input length matches components")
            suite.expect(input.suffix(32) == SHA256Digest.bytes(of: Data("ct".utf8)), "ct is covered by its digest")
        }

        await suite.run("ecies.seal then open returns the plaintext") {
            let sender = makeIdentity()
            let recipient = P256.KeyAgreement.PrivateKey()
            let payload = Data("{\"action\":\"lock\"}".utf8)

            let envelope = try EnvelopeCrypto.seal(
                payload,
                type: "cmd.lock",
                deviceId: "k3m9x2qv7b1n4z8r",
                epoch: 1,
                messageId: ULID.generate(),
                seq: 1,
                timestamp: 1_760_000_000,
                recipient: recipient.publicKey,
                signer: sender
            )

            suite.expectEqual(try Base64URL.decode(envelope.n).count, 12)
            suite.expect(envelope.sig.count > 0 && envelope.ct.count > 0, "signature and ciphertext present")
            let opened = try EnvelopeCrypto.open(
                envelope,
                recipientKey: recipient,
                senderSigningKey: sender.publicKey,
                expectedDeviceId: "k3m9x2qv7b1n4z8r"
            )
            suite.expectEqual(opened, payload)
        }

        await suite.run("ecies.ct is ciphertext‖tag with no nonce prefix (WebCrypto layout)") {
            let sender = makeIdentity()
            let recipient = P256.KeyAgreement.PrivateKey()
            let payload = Data("{\"action\":\"lock\"}".utf8)

            let envelope = try EnvelopeCrypto.seal(
                payload, type: "cmd.lock", deviceId: "dev", epoch: 1,
                messageId: "id", seq: 1, timestamp: 1, recipient: recipient.publicKey, signer: sender
            )
            let ct = try Base64URL.decode(envelope.ct)
            suite.expectEqual(ct.count, payload.count + EnvelopeCrypto.tagLength,
                              "ct must be exactly plaintext + 16-byte tag")

            // Rebuild the envelope the way the PWA does it: derive the key from the same ECDH
            // secret and HKDF inputs, then AES-GCM with ciphertext||tag as one blob.
            let nonce = try Base64URL.decode(envelope.n)
            let eph = try P256.KeyAgreement.PublicKey(x963Representation: try Base64URL.decode(envelope.eph))
            let shared = try recipient.sharedSecretFromKeyAgreement(with: eph)
            let key = EnvelopeCrypto.derivedKey(sharedSecret: shared, nonce: nonce, deviceId: "dev", epoch: 1)
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: ct.dropLast(16),
                tag: ct.suffix(16)
            )
            let opened = try AES.GCM.open(box, using: key, authenticating: EnvelopeCoding.headerBytes(for: envelope))
            suite.expectEqual(opened, payload)
        }

        await suite.run("ecies.opens an envelope assembled in the browser's layout") {
            let sender = makeIdentity()
            let recipient = P256.KeyAgreement.PrivateKey()
            let payload = Data("{\"action\":\"lock\"}".utf8)
            let deviceId = "k3m9x2qv7b1n4z8r"

            // Hand-build exactly what web/src/crypto/crypto.ts `sealEnvelope` produces.
            let nonce = EnvelopeCrypto.freshNonce()
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient.publicKey)
            let key = EnvelopeCrypto.derivedKey(sharedSecret: shared, nonce: nonce, deviceId: deviceId, epoch: 3)
            let nonceString = Base64URL.encode(nonce)
            let header = EnvelopeCoding.headerBytes(t: "cmd.lock", d: deviceId, e: 3, id: "01ABC", seq: 5, ts: 1_760_000_000, n: nonceString)
            let sealed = try AES.GCM.seal(payload, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: header)
            let webCiphertext = sealed.ciphertext + sealed.tag
            let ephString = Base64URL.encode(ephemeral.publicKey.x963Representation)
            let signature = try sender.signature(for: EnvelopeCoding.signingInput(header: header, eph: ephString, ciphertext: webCiphertext))

            let envelope = Envelope(
                t: "cmd.lock", d: deviceId, e: 3, id: "01ABC", seq: 5, ts: 1_760_000_000,
                n: nonceString, eph: ephString, ct: Base64URL.encode(webCiphertext),
                sig: Base64URL.encode(signature.derRepresentation)
            )
            let opened = try EnvelopeCrypto.open(
                envelope, recipientKey: recipient, senderSigningKey: sender.publicKey, expectedDeviceId: deviceId
            )
            suite.expectEqual(opened, payload)
        }

        await suite.run("ack.signing input is stable and binds type, device, epoch, command id, status and time") {
            let input = EnvelopeCoding.ackSigningInput(t: "lock.ack", d: "abcd", e: 3, id: "01ABC", status: "LOCKED", ts: 1_760_000_000)
            suite.expectEqual(String(decoding: input, as: UTF8.self),
                              "distee/v1/ack\nlock.ack\nabcd\n3\n01ABC\nLOCKED\n1760000000")
        }

        await suite.run("ecies.tampered ciphertext is rejected before decryption") {
            let sender = makeIdentity()
            let recipient = P256.KeyAgreement.PrivateKey()
            var envelope = try EnvelopeCrypto.seal(
                Data("lock".utf8), type: "cmd.lock", deviceId: "dev", epoch: 1,
                messageId: "id", seq: 1, timestamp: 1, recipient: recipient.publicKey, signer: sender
            )
            var bytes = try Base64URL.decode(envelope.ct)
            bytes[0] ^= 0xFF
            envelope.ct = Base64URL.encode(bytes)

            suite.expectThrows("modified ct must fail") {
                _ = try EnvelopeCrypto.open(envelope, recipientKey: recipient, senderSigningKey: sender.publicKey, expectedDeviceId: "dev")
            }
        }

        await suite.run("ecies.tampered header is rejected (header is signed)") {
            let sender = makeIdentity()
            let recipient = P256.KeyAgreement.PrivateKey()
            var envelope = try EnvelopeCrypto.seal(
                Data("lock".utf8), type: "cmd.lock", deviceId: "dev", epoch: 1,
                messageId: "id", seq: 1, timestamp: 1, recipient: recipient.publicKey, signer: sender
            )
            envelope.seq = 2
            suite.expectThrows("modified seq must fail") {
                _ = try EnvelopeCrypto.open(envelope, recipientKey: recipient, senderSigningKey: sender.publicKey, expectedDeviceId: "dev")
            }
        }

        await suite.run("ecies.wrong recipient key cannot decrypt") {
            let sender = makeIdentity()
            let recipient = P256.KeyAgreement.PrivateKey()
            let attacker = P256.KeyAgreement.PrivateKey()
            let envelope = try EnvelopeCrypto.seal(
                Data("lock".utf8), type: "cmd.lock", deviceId: "dev", epoch: 1,
                messageId: "id", seq: 1, timestamp: 1, recipient: recipient.publicKey, signer: sender
            )
            suite.expectThrows("different ECDH key must fail") {
                _ = try EnvelopeCrypto.open(envelope, recipientKey: attacker, senderSigningKey: sender.publicKey, expectedDeviceId: "dev")
            }
        }

        await suite.run("auth.proof is a verifiable signature over challenge, device and epoch") {
            let identity = makeIdentity()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let authenticator = RelayAuthenticator(deviceId: deviceId, epoch: 7, signer: identity)
            let challenge = Base64URL.encode(Data(repeating: 7, count: 32))
            let proof = try authenticator.proof(challenge: challenge)

            let signature = try P256.Signing.ECDSASignature(derRepresentation: try Base64URL.decode(proof))
            let input = Data("distee-auth-v1\n\(challenge)\n\(deviceId)\n7".utf8)
            suite.expect(identity.publicKey.isValidSignature(signature, for: input),
                         "relay must be able to verify the proof")
            let wrongEpoch = Data("distee-auth-v1\n\(challenge)\n\(deviceId)\n8".utf8)
            suite.expect(!identity.publicKey.isValidSignature(signature, for: wrongEpoch),
                         "proof must bind the epoch")
        }
    }

    private static func makeIdentity() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }
}

extension TestSuite {
    func expectEqual(_ lhs: Double, _ rhs: Double, accuracyMessage: String, line: UInt = #line) {
        if abs(lhs - rhs) > 0.0001 {
            expect(false, "expected \(rhs), got \(lhs) — \(accuracyMessage)", line: line)
        }
    }
}
