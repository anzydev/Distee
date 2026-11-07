import CryptoKit
import DisteeCore
import Foundation

enum PairingTests {
    static func run(_ suite: TestSuite) async {
        await suite.run("pairing.generates 120s ephemeral session and QR payload") {
            let manager = PairingManager(store: PairingStore(keychain: KeychainManager(service: "test.distee.pairing.\(UUID().uuidString)")))
            suite.expectEqual(manager.state, .unpaired)

            let session = try manager.startPairingSession(webBaseURL: "https://distee.page")
            suite.expect(!session.sessionId.isEmpty, "session ID exists")
            suite.expectEqual(session.psk.count, 32, "PSK is 32 bytes (256 bits)")
            suite.expect(session.secondsRemaining > 100, "session has ~120s TTL")
            suite.expect(!session.isExpired, "session is active")
            suite.expect(session.qrPayload.contains("sid=\(session.sessionId)"), "payload includes sid")
            suite.expect(session.qrPayload.contains("k="), "payload includes psk")
            suite.expect(session.qrPayload.contains("d="), "payload includes deviceId")
        }

        await suite.run("pairing.derives deterministic confirmation code and pairing key") {
            let psk = Data(repeating: 0x42, count: 32)
            let sid = "session-12345"
            let phoneSignPub = "phone-signing-pub"
            let phoneEcdhPub = "phone-ecdh-pub"

            let code1 = PairingManager.deriveConfirmationCode(
                psk: psk, sid: sid, phoneSignPub: phoneSignPub, phoneEcdhPub: phoneEcdhPub
            )
            let code2 = PairingManager.deriveConfirmationCode(
                psk: psk, sid: sid, phoneSignPub: phoneSignPub, phoneEcdhPub: phoneEcdhPub
            )

            suite.expectEqual(code1, code2, "confirmation code is deterministic")
            suite.expectEqual(code1.count, 6, "confirmation code is 6 digits")

            let key1 = PairingManager.derivePairingKey(psk: psk, sid: sid)
            let key2 = PairingManager.derivePairingKey(psk: psk, sid: sid)
            suite.expectEqual(key1, key2, "derived symmetric key matches")
        }

        await suite.run("pairing.full mutual handshake succeeds and creates pairing record") {
            let service = "test.distee.handshake.\(UUID().uuidString)"
            let keychain = KeychainManager(service: service)
            let security = SecurityManager(keychain: keychain)
            let store = PairingStore(keychain: keychain)
            let manager = PairingManager(store: store, security: security)

            let session = try manager.startPairingSession()
            let kp = PairingManager.derivePairingKey(psk: session.psk, sid: session.sessionId)

            // Mobile side: generates keys
            let phoneSignKey = P256.Signing.PrivateKey()
            let phoneEcdhKey = P256.KeyAgreement.PrivateKey()
            let phoneSignPubString = Base64URL.encode(phoneSignKey.publicKey.rawRepresentation)
            let phoneEcdhPubString = Base64URL.encode(phoneEcdhKey.publicKey.rawRepresentation)

            let requestPayload: [String: Any] = [
                "phoneSignPub": phoneSignPubString,
                "phoneEcdhPub": phoneEcdhPubString,
                "label": "Khush iPhone 16",
                "platform": "iOS 18 Safari"
            ]
            let plaintext = try JSONSerialization.data(withJSONObject: requestPayload)
            let nonce = try AES.GCM.Nonce(data: EnvelopeCrypto.freshNonce())
            let identity = try security.loadOrCreateIdentity()
            let aad = Data("\(session.sessionId)\(identity.deviceId)pair.request".utf8)
            let sealed = try AES.GCM.seal(plaintext, using: kp, nonce: nonce, authenticating: aad)

            let reqBase64 = Base64URL.encode(sealed.ciphertext + sealed.tag)
            let nonceBase64 = Base64URL.encode(Data(nonce))

            // Mac receives request
            let result = try manager.handlePairRequest(
                sessionId: session.sessionId,
                encryptedPayloadBase64: reqBase64,
                nonceBase64: nonceBase64,
                timestamp: Int(Date().timeIntervalSince1970)
            )

            suite.expectEqual(result.request.phoneLabel, "Khush iPhone 16")
            suite.expectEqual(result.confirmationCode.count, 6)

            // Mac user confirms
            let acceptFrame = try manager.confirmPairing()
            suite.expectEqual(acceptFrame["t"] as? String, "pair.accept")
            suite.expect(manager.isPaired, "manager state is now paired")

            // Verify stored record
            let record = store.load()
            suite.expect(record != nil, "pairing record saved in Keychain")
            suite.expectEqual(record?.phoneLabel, "Khush iPhone 16")
            suite.expectEqual(record?.epoch, 1)

            // Mobile verifies pair.accept proof
            let resBase64 = acceptFrame["res"] as! String
            let acceptNonceBase64 = acceptFrame["n"] as! String
            let acceptCiphertext = try Base64URL.decode(resBase64)
            let acceptNonce = try AES.GCM.Nonce(data: try Base64URL.decode(acceptNonceBase64))
            let acceptAad = Data("\(session.sessionId)\(identity.deviceId)pair.accept".utf8)
            let acceptBox = try AES.GCM.SealedBox(
                nonce: acceptNonce,
                ciphertext: acceptCiphertext.dropLast(16),
                tag: acceptCiphertext.suffix(16)
            )
            let acceptDecrypted = try AES.GCM.open(acceptBox, using: kp, authenticating: acceptAad)
            let acceptJson = try JSONSerialization.jsonObject(with: acceptDecrypted) as! [String: Any]

            suite.expectEqual(acceptJson["epoch"] as? Int, 1)
            let proofString = acceptJson["proof"] as! String
            let signature = try P256.Signing.ECDSASignature(derRepresentation: try Base64URL.decode(proofString))
            let proofInput = Data("distee-pair-accept\n\(session.sessionId)\n1\n\(phoneSignPubString)\n\(acceptJson["macSignPub"] as! String)".utf8)
            suite.expect(identity.signingPublicKey.isValidSignature(signature, for: proofInput), "proof verified")
        }

        await suite.run("pairing.second mobile is rejected while Mac is paired") {
            let service = "test.distee.reject.\(UUID().uuidString)"
            let keychain = KeychainManager(service: service)
            let store = PairingStore(keychain: keychain)
            let record = PairingRecord(
                phoneLabel: "First Phone",
                phoneSigningPublicKey: "key1",
                phoneKeyAgreementPublicKey: "ecdh1",
                epoch: 1
            )
            try store.save(record)

            let manager = PairingManager(store: store, security: SecurityManager(keychain: keychain))
            suite.expect(manager.isPaired, "manager is paired")

            suite.expectThrows("starting session while paired must throw") {
                _ = try manager.startPairingSession()
            }
        }

        await suite.run("pairing.unpairing resets state and advances epoch") {
            let service = "test.distee.unpair.\(UUID().uuidString)"
            let keychain = KeychainManager(service: service)
            let store = PairingStore(keychain: keychain)
            try store.save(PairingRecord(phoneLabel: "Phone", phoneSigningPublicKey: "k", phoneKeyAgreementPublicKey: "e", epoch: 1))

            let manager = PairingManager(store: store, security: SecurityManager(keychain: keychain))
            suite.expect(manager.isPaired, "manager is paired")

            try manager.unpair()
            suite.expect(!manager.isPaired, "state reset to unpaired")
            suite.expectEqual(store.load(), nil, "keychain record deleted")
            suite.expectEqual(store.currentEpoch, 2, "epoch incremented to invalidate old tokens")

            // Now a new session can be started
            let newSession = try manager.startPairingSession()
            suite.expect(!newSession.sessionId.isEmpty, "new session id is present")
        }
    }
}
