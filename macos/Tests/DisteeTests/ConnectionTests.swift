import CryptoKit
import DisteeCore
import DisteeTestSupport
import Foundation

enum ConnectionTests {
    static func run(_ suite: TestSuite) async {
        await suite.run("connection.authenticates with a signed challenge and reports connected") {
            let identity = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let challenge = "Y2hhbGxlbmdlLWZvci10ZXN0cy0wMDAwMDA"
            let captured = Capture()

            let factory = ScriptedSocketFactory { _, socket in
                socket.push(TestFrames.hello(challenge: challenge))
                socket.push(TestFrames.authOK())
                socket.onSend = { data, _ in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["t"] as? String == "auth" else { return }
                    captured.auth = object
                }
            }

            let manager = makeManager(deviceId: deviceId, identity: identity, epoch: 2, factory: factory)
            manager.start()

            let connected = await waitUntil { manager.state == .connected }
            suite.expect(connected, "manager should reach connected, state: \(manager.state)")

            guard let auth = captured.auth else {
                suite.expect(false, "auth frame was not sent")
                manager.stop()
                return
            }
            suite.expectEqual(auth["d"] as? String, deviceId)
            suite.expectEqual(auth["e"] as? Int, 2)

            let signatureString = auth["sig"] as? String ?? ""
            let signatureData = try Base64URL.decode(signatureString)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            let input = Data("distee-auth-v1\n\(challenge)\n\(deviceId)\n2".utf8)
            suite.expect(identity.publicKey.isValidSignature(signature, for: input),
                         "the relay must be able to verify the proof")

            manager.stop()
        }

        await suite.run("connection.sends heartbeats while connected") {
            let identity = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let factory = ScriptedSocketFactory { _, socket in
                socket.push(TestFrames.hello())
                socket.push(TestFrames.authOK())
            }
            let manager = makeManager(deviceId: deviceId, identity: identity, epoch: 1, factory: factory, heartbeat: 0.05)
            manager.start()

            _ = await waitUntil { manager.state == .connected }
            let gotPing = await waitUntil(timeout: 2) {
                guard let socket = factory.latest else { return false }
                return socket.sent.contains { data in
                    (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["t"] as? String == "ping"
                }
            }
            suite.expect(gotPing, "a ping frame should be sent every heartbeat interval")
            manager.stop()
        }

        await suite.run("connection.reconnects after the socket drops") {
            let identity = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let factory = ScriptedSocketFactory { index, socket in
                socket.push(TestFrames.hello())
                socket.push(TestFrames.authOK())
                if index == 0 {
                    socket.failNextReceive(with: .closed(code: 1006, reason: "network dropped"))
                }
            }

            let manager = makeManager(deviceId: deviceId, identity: identity, epoch: 1, factory: factory)
            manager.start()

            _ = await waitUntil { manager.state == .connected }
            let reconnected = await waitUntil(timeout: 5) {
                factory.all.count >= 2 && manager.state == .connected
            }
            suite.expect(reconnected, "a second socket should be created and authenticated, state: \(manager.state)")
            suite.expect(factory.all.count >= 2, "expected at least two connection attempts")
            suite.expectEqual(factory.all.first?.close?.code, 1006, "first socket was closed by the drop")
            manager.stop()
        }

        await suite.run("connection.epoch rejection is terminal (no retry storm)") {
            let identity = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let factory = ScriptedSocketFactory { _, socket in
                socket.push(TestFrames.hello())
                socket.push(TestFrames.error("EPOCH_MISMATCH"))
            }

            let manager = makeManager(deviceId: deviceId, identity: identity, epoch: 1, factory: factory)
            manager.start()

            let failed = await waitUntil { if case .failed = manager.state { return true }; return false }
            suite.expect(failed, "epoch mismatch must surface as failed, state: \(manager.state)")

            try? await Task.sleep(nanoseconds: 400_000_000)
            suite.expectEqual(factory.all.count, 1, "must not retry a credential rejection")
            manager.stop()
        }

        await suite.run("connection.close 4403 stops reconnection") {
            let identity = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let factory = ScriptedSocketFactory { _, socket in
                socket.push(TestFrames.hello())
                socket.push(TestFrames.authOK())
                socket.failNextReceive(with: .closed(code: 4403, reason: "BAD_SIGNATURE"))
            }

            let manager = makeManager(deviceId: deviceId, identity: identity, epoch: 1, factory: factory)
            manager.start()

            let failed = await waitUntil { if case .failed = manager.state { return true }; return false }
            suite.expect(failed, "4403 must be terminal, state: \(manager.state)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            suite.expectEqual(factory.all.count, 1)
            manager.stop()
        }

        await suite.run("connection.graceful shutdown closes the socket with 1000") {
            let identity = P256.Signing.PrivateKey()
            let deviceId = DeviceIdentifier.derive(from: identity.publicKey)
            let factory = ScriptedSocketFactory { _, socket in
                socket.push(TestFrames.hello())
                socket.push(TestFrames.authOK())
            }
            let manager = makeManager(deviceId: deviceId, identity: identity, epoch: 1, factory: factory)
            manager.start()

            _ = await waitUntil { manager.state == .connected }
            manager.stop()
            suite.expectEqual(manager.state, .disconnected)
            suite.expectEqual(factory.latest?.close?.code, 1000)
        }

        await suite.run("connection.send fails clearly when not connected") {
            let identity = P256.Signing.PrivateKey()
            let manager = makeManager(
                deviceId: DeviceIdentifier.derive(from: identity.publicKey),
                identity: identity,
                epoch: 1,
                factory: ScriptedSocketFactory(),
                start: false
            )
            do {
                try await manager.send(Data("x".utf8))
                suite.expect(false, "send should throw when disconnected")
            } catch {
                suite.expect(error is WebSocketError, "expected WebSocketError, got \(error)")
            }
        }

        await suite.run("relay.loopback handshake with a real WebSocket") {
            suite.skip("relay.loopback handshake with a real WebSocket", "NWListener requires GUI entitlements on macOS 15")
        }
    }

    private static func makeManager(
        deviceId: String,
        identity: P256.Signing.PrivateKey,
        epoch: Int,
        factory: WebSocketFactory,
        heartbeat: TimeInterval = 0.05,
        start: Bool = true
    ) -> ConnectionManager {
        var options = ConnectionManager.Options(url: URL(string: "wss://relay.test/ws/device/\(deviceId)")!)
        options.heartbeatInterval = heartbeat
        options.watchdogTimeout = 30
        options.connectTimeout = 2
        options.handshakeTimeout = 2
        options.backoff = BackoffPolicy(initialDelay: 0.05, maximumDelay: 0.2, jitterFraction: 0, resetAfterOnline: 5)

        return ConnectionManager(
            options: options,
            authenticator: RelayAuthenticator(deviceId: deviceId, epoch: epoch, signer: identity),
            factory: factory,
            logger: LoggingManager(subsystem: "com.distee.tests", category: "connection"),
            jitter: { 0 }
        )
    }
}

final class Capture {
    var auth: [String: Any]?
}
