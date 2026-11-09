import AppKit
import CryptoKit
import Foundation

/// The background service. It owns the lifetime of the connection, the identity, and the
/// lock manager; it is the only component that mutates `ServiceStatus`.
///
/// "Background" here means one `LSUIElement` process with no window requirement — there is
/// no daemon and no XPC helper (Phase 1, ADR-007).
public final class BackgroundService {
    private let configuration: AppConfiguration
    private let logger: LoggingManager
    private let clock: Clock
    private let security: SecurityManager
    private let pairingStore: PairingStore
    private let loginItems: LoginItemManager
    private let networkMonitor: NetworkMonitor
    public let lockManager: MacLockManager
    public let unlockManager: MacUnlockManager
    public let pairingManager: PairingManager

    private var connection: ConnectionManager?
    private var identity: DeviceIdentity?
    private var wakeObserver: NSObjectProtocol?
    private var statusLock = NSLock()
    private var status = ServiceStatus.initial

    private var processedCommandIds = Set<String>()
    private var commandIdRingBuffer: [String] = []
    private let deduplicationLock = NSLock()

    private static let lastLockKey = "com.distee.lastLockAt"

    public var onStatusChange: ((ServiceStatus) -> Void)?

    public init(
        configuration: AppConfiguration = AppConfiguration.resolve(),
        logger: LoggingManager = .shared,
        clock: Clock = SystemClock(),
        security: SecurityManager = SecurityManager(),
        pairingStore: PairingStore = PairingStore(),
        loginItems: LoginItemManager = LoginItemManager(),
        networkMonitor: NetworkMonitor = NetworkMonitor(),
        lockManager: MacLockManager? = nil,
        unlockManager: MacUnlockManager? = nil
    ) {
        self.configuration = configuration
        self.logger = logger
        self.clock = clock
        self.security = security
        self.pairingStore = pairingStore
        self.loginItems = loginItems
        self.networkMonitor = networkMonitor
        self.lockManager = lockManager ?? MacLockManager(logger: logger, clock: clock)
        self.unlockManager = unlockManager ?? MacUnlockManager(logger: logger, clock: clock)
        self.pairingManager = PairingManager(store: pairingStore, security: security, logger: logger)

        self.pairingManager.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .pairingAvailable(let session) = state, let identity = self.identity {
                self.registerPairingCode(session: session, identity: identity)
            }
            self.refreshPairing()
            self.publishStatus()
        }

        status.isDevelopmentRelay = configuration.isDevelopmentRelay
        status.relayEndpoint = configuration.relayURL?.absoluteString
        if let timestamp = UserDefaults.standard.object(forKey: Self.lastLockKey) as? Date {
            status.lastLockAt = timestamp
        }
    }

    public var statusSnapshot: ServiceStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return status
    }

    // MARK: - Lifecycle

    public func start() {
        statusLock.lock()
        guard !status.isRunning else {
            statusLock.unlock()
            return
        }
        status.isRunning = true
        status.startedAt = clock.now
        statusLock.unlock()

        logger.notice("Distee agent starting")

        do {
            let identity = try security.loadOrCreateIdentity()
            self.identity = identity
            mutateStatus {
                $0.deviceId = identity.deviceId
                $0.keyStorage = identity.storage
            }
        } catch {
            logger.error("Identity unavailable: \(error.localizedDescription, privacy: .public)")
            mutateStatus { $0.lastError = "Device identity unavailable: \(error.localizedDescription)" }
        }

        refreshPairing()
        startConnection()
        observeEnvironment()
        refreshLaunchAtLogin()
        publishStatus()
    }

    public func stop() {
        logger.notice("Distee agent stopping")
        connection?.stop()
        connection = nil
        networkMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        mutateStatus {
            $0.isRunning = false
            $0.connection = .disconnected
        }
        publishStatus()
    }

    /// Synchronous shutdown for `applicationWillTerminate`, where awaiting is not possible.
    public func stopSynchronously(timeout: TimeInterval = 2) {
        let semaphore = DispatchSemaphore(value: 0)
        let manager = connection
        connection = nil
        DispatchQueue.global(qos: .utility).async {
            manager?.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        networkMonitor.stop()
        mutateStatus {
            $0.isRunning = false
            $0.connection = .disconnected
        }
    }

    // MARK: - Locking

    public func performLockNow() async -> LockOutcome {
        let outcome = await lockManager.performLock()
        logger.notice(
            "Lock result \(outcome.status.rawValue, privacy: .public) via \(outcome.mechanism.rawValue, privacy: .public) in \(outcome.durationMilliseconds) ms"
        )

        if outcome.status.isSuccess {
            let timestamp = clock.now
            UserDefaults.standard.set(timestamp, forKey: Self.lastLockKey)
            mutateStatus {
                $0.lastLockAt = timestamp
                $0.lastLockStatus = outcome.status
                $0.lastError = nil
            }
        } else {
            mutateStatus { $0.lastLockStatus = outcome.status }
            if outcome.status == .needsPermission {
                mutateStatus { $0.lastError = outcome.detail }
            }
        }
        publishStatus()
        return outcome
    }

    public func performUnlockNow(password: String) async -> UnlockOutcome {
        let outcome = await unlockManager.performUnlock(password: password)
        logger.notice(
            "Unlock result \(outcome.status.rawValue, privacy: .public) via \(outcome.mechanism.rawValue, privacy: .public) in \(outcome.durationMilliseconds) ms"
        )
        if outcome.status.isSuccess {
            mutateStatus {
                $0.lastError = nil
            }
        } else if outcome.status == .needsPermission {
            mutateStatus { $0.lastError = outcome.detail }
        }
        publishStatus()
        return outcome
    }

    // MARK: - Configuration changes

    public func setLaunchAtLogin(_ enabled: Bool) throws {
        try loginItems.setEnabled(enabled)
        refreshLaunchAtLogin()
        publishStatus()
    }

    public func resetApplication() {
        logger.notice("Reset requested: removing identity, pairing record and login item")
        stop()
        connection = nil

        try? loginItems.setEnabled(false)
        do {
            try security.destroyIdentity()
        } catch {
            logger.error("Failed to destroy identity: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try pairingStore.clear()
        } catch {
            logger.error("Failed to clear pairing record: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.removeObject(forKey: Self.lastLockKey)

        deduplicationLock.lock()
        processedCommandIds.removeAll()
        commandIdRingBuffer.removeAll()
        deduplicationLock.unlock()

        identity = nil
        statusLock.lock()
        status = ServiceStatus.initial
        status.isDevelopmentRelay = configuration.isDevelopmentRelay
        status.relayEndpoint = configuration.relayURL?.absoluteString
        statusLock.unlock()

        publishStatus()
        logger.notice("Reset complete; a new identity will be created on next launch")
    }

    // MARK: - Connection

    private func startConnection() {
        guard let identity else {
            mutateStatus { $0.lastError = "No device identity; relay connection not attempted" }
            publishStatus()
            return
        }
        guard let url = configuration.deviceURL(deviceId: identity.deviceId) else {
            logger.warning("No relay configured; running without a network connection")
            mutateStatus {
                $0.connection = .disconnected
                $0.lastError = "Relay not configured in this build"
            }
            publishStatus()
            return
        }

        if configuration.isDevelopmentRelay {
            logger.warning("Using development relay at \(url.absoluteString, privacy: .public)")
        }

        let authenticator = RelayAuthenticator(
            deviceId: identity.deviceId,
            epoch: pairingStore.currentEpoch,
            signer: identity.signer
        )
        let manager = ConnectionManager(
            options: ConnectionManager.Options(url: url),
            authenticator: authenticator,
            logger: logger,
            clock: clock
        )
        manager.onStateChange = { [weak self] state in
            self?.handleConnectionState(state)
        }
        manager.onMessage = { [weak self] data in
            self?.handleInboundMessage(data)
        }
        connection = manager
        manager.start()
    }

    /// Test seam: observes every frame the service emits, in addition to sending it.
    public var onOutboundFrame: (([String: Any]) -> Void)?

    /// Feeds one inbound relay frame through the same path the live connection uses.
    /// Exposed so tests can exercise the real command pipeline without a socket.
    public func receiveFrame(_ data: Data) {
        handleInboundMessage(data)
    }

    public func sendFrame(_ frame: [String: Any]) {
        onOutboundFrame?(frame)
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        Task {
            try? await connection?.send(data)
        }
    }

    private func handleInboundMessage(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["t"] as? String else {
            logger.debug("Inbound binary or unformatted frame (\(data.count) bytes)")
            return
        }

        logger.info("Inbound frame: \(type)")

        switch type {
        case "pair.request":
            handlePairRequestFrame(json)
        case "cmd.lock":
            handleLockCommandFrame(json)
        case "cmd.unlock":
            handleUnlockCommandFrame(json)
        case "cmd.unpair":
            handleUnpairCommandFrame(json)
        case "test.lock":
            handleTestLockFrame(json)
        default:
            logger.debug("Ignored unhandled frame type: \(type)")
        }
    }

    private func registerPairingCode(session: PairingSession, identity: DeviceIdentity) {
        let frame: [String: Any] = [
            "t": "pair.code_register",
            "code": session.pairingCode,
            "deviceId": identity.deviceId,
            "sid": session.sessionId,
            "pk": Base64URL.encode(identity.signingPublicKey.rawRepresentation),
            "ek": Base64URL.encode(identity.keyAgreementKey.publicKey.rawRepresentation),
            "k": Base64URL.encode(session.psk),
            "exp": Int(session.expiresAt.timeIntervalSince1970),
            "name": Host.current().localizedName ?? "Mac"
        ]
        sendFrame(frame)

        if let relayURL = configuration.relayURL {
            let httpURL = relayURL.absoluteString
                .replacingOccurrences(of: "wss://", with: "https://")
                .replacingOccurrences(of: "ws://", with: "http://")
            if let endpoint = URL(string: "\(httpURL)/api/pair/code"),
               let body = try? JSONSerialization.data(withJSONObject: frame) {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                URLSession.shared.dataTask(with: request).resume()
            }
        }
    }

    private func handlePairRequestFrame(_ json: [String: Any]) {
        guard let sid = json["sid"] as? String,
              let req = json["req"] as? String,
              let nonce = (json["n"] as? String) ?? (json["nonce"] as? String) else {
            sendFrame(["v": 1, "t": "pair.reject", "reason": "MALFORMED_REQUEST", "sid": json["sid"] as? String ?? ""])
            return
        }

        let ts = (json["ts"] as? Int) ?? Int(Date().timeIntervalSince1970)

        do {
            let staged = try pairingManager.handlePairRequest(
                sessionId: sid,
                encryptedPayloadBase64: req,
                nonceBase64: nonce,
                timestamp: ts
            )

            // A running app asks the user to approve; headless contexts (tests) auto-approve.
            guard NSApp?.isRunning == true else {
                let acceptFrame = try pairingManager.confirmPairing()
                sendFrame(acceptFrame)
                refreshPairing()
                publishStatus()
                return
            }

            let requestedAt = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Pair with \(staged.request.phoneLabel)?"
                alert.informativeText = "Confirmation code: \(staged.confirmationCode)\n\nAllow only if this code matches the one shown on your phone. The phone will be able to lock this Mac."
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Deny")
                let allowed = alert.runModal() == .alertFirstButtonReturn
                let stillFresh = Date().timeIntervalSince(requestedAt) < 28

                if allowed && stillFresh {
                    do {
                        let acceptFrame = try self.pairingManager.confirmPairing()
                        self.sendFrame(acceptFrame)
                    } catch {
                        self.logger.error("Pairing confirmation failed: \(error.localizedDescription, privacy: .public)")
                        self.sendFrame(self.pairingManager.rejectPairing(reason: "DENIED"))
                    }
                } else {
                    if allowed {
                        self.logger.warning("Pairing approval arrived after the phone timed out; denied")
                    }
                    self.sendFrame(self.pairingManager.rejectPairing(reason: allowed ? "SESSION_EXPIRED" : "DENIED"))
                }
                self.refreshPairing()
                self.publishStatus()
            }
        } catch let error as PairingError {
            let reason: String
            switch error {
            case .alreadyPaired: reason = "ALREADY_PAIRED"
            case .sessionExpired: reason = "SESSION_EXPIRED"
            case .invalidSession: reason = "INVALID_SESSION"
            case .pairingInProgress: reason = "PAIRING_IN_PROGRESS"
            default: reason = "BAD_CRYPTO"
            }
            sendFrame(["v": 1, "t": "pair.reject", "sid": sid, "reason": reason, "ts": Int(Date().timeIntervalSince1970)])
        } catch {
            sendFrame(["v": 1, "t": "pair.reject", "sid": sid, "reason": "DENIED", "ts": Int(Date().timeIntervalSince1970)])
        }
    }

    private struct CommandRejection: Error {
        let id: String
        let reason: String
    }

    private struct ValidatedCommand {
        let id: String
        let epoch: Int
        let payload: [String: Any]
    }

    /// Validates a signed, encrypted command envelope from the paired phone: pairing, target
    /// device, epoch, freshness, replay, ECDSA signature, then decryption of the payload and a
    /// check that the decrypted action matches the signed command type.
    private func validateSignedCommand(_ json: [String: Any], type: String) -> Result<ValidatedCommand, CommandRejection> {
        let fallbackId = (json["id"] as? String) ?? ULID.generate()

        guard let record = pairingStore.load() else {
            return .failure(CommandRejection(id: fallbackId, reason: "NOT_PAIRED"))
        }

        guard let d = json["d"] as? String,
              let id = json["id"] as? String,
              let e = json["e"] as? Int,
              let seq = json["seq"] as? Int,
              let ts = json["ts"] as? Int,
              let n = json["n"] as? String,
              let eph = json["eph"] as? String,
              let ct = json["ct"] as? String,
              let sig = json["sig"] as? String else {
            return .failure(CommandRejection(id: fallbackId, reason: "MALFORMED_FRAME"))
        }

        guard let myDeviceId = identity?.deviceId, d.lowercased() == myDeviceId.lowercased() else {
            return .failure(CommandRejection(id: id, reason: "WRONG_DEVICE"))
        }

        guard e == record.epoch else {
            return .failure(CommandRejection(id: id, reason: "INVALID_EPOCH"))
        }

        let now = Int(clock.now.timeIntervalSince1970)
        guard abs(now - ts) <= 120 else {
            return .failure(CommandRejection(id: id, reason: "COMMAND_EXPIRED"))
        }

        guard !isDuplicate(id: id) else {
            return .failure(CommandRejection(id: id, reason: "REPLAY_DETECTED"))
        }

        let envelope = Envelope(
            v: (json["v"] as? Int) ?? 1,
            t: type,
            d: d,
            e: e,
            id: id,
            seq: seq,
            ts: ts,
            n: n,
            eph: eph,
            ct: ct,
            sig: sig
        )

        guard let keyBytes = try? Base64URL.decode(record.phoneSigningPublicKey) else {
            return .failure(CommandRejection(id: id, reason: "CORRUPT_PHONE_KEY"))
        }

        let phoneSignKey: P256.Signing.PublicKey? = {
            if keyBytes.count == 65 {
                return try? P256.Signing.PublicKey(x963Representation: keyBytes)
            } else if keyBytes.count == 64 {
                return try? P256.Signing.PublicKey(rawRepresentation: keyBytes)
            }
            return nil
        }()

        guard let phoneSignKey,
              (try? EnvelopeCrypto.verifySignature(envelope, senderSigningKey: phoneSignKey)) == true else {
            return .failure(CommandRejection(id: id, reason: "INVALID_SIGNATURE"))
        }

        // Authenticate first, then decrypt: unauthenticated input never reaches AES-GCM.
        guard let macIdentity = identity else {
            return .failure(CommandRejection(id: id, reason: "INTERNAL_ERROR"))
        }
        let plaintext: Data
        do {
            plaintext = try EnvelopeCrypto.open(
                envelope,
                recipientKey: macIdentity.keyAgreementKey,
                senderSigningKey: phoneSignKey,
                expectedDeviceId: d
            )
        } catch {
            logger.warning("Command payload could not be decrypted: \(String(describing: error), privacy: .public)")
            return .failure(CommandRejection(id: id, reason: "DECRYPT_FAILED"))
        }
        let expectedAction = type.hasPrefix("cmd.") ? String(type.dropFirst(4)) : type
        guard let payload = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
              payload["action"] as? String == expectedAction else {
            return .failure(CommandRejection(id: id, reason: "PAYLOAD_MISMATCH"))
        }

        // Sequence numbers must strictly increase. Checked only after the signature is
        // verified (so forged frames cannot advance the counter) and persisted so a replay
        // captured before a restart is still refused.
        guard seq > record.lastSequence else {
            return .failure(CommandRejection(id: id, reason: "REPLAY_DETECTED"))
        }
        var advanced = record
        advanced.lastSequence = seq
        do {
            try pairingStore.save(advanced)
        } catch {
            logger.error("Could not persist command sequence: \(error.localizedDescription, privacy: .public)")
            return .failure(CommandRejection(id: id, reason: "INTERNAL_ERROR"))
        }

        recordProcessedCommand(id: id)
        return .success(ValidatedCommand(id: id, epoch: e, payload: payload))
    }

    /// Builds a Mac-signed result frame. Returns nil (and logs) rather than ever emitting an
    /// unsigned result: the phone ignores unsigned acks, so an unsigned frame would only be
    /// a forgery opportunity for the relay.
    private func makeSignedAck(
        type: String,
        id: String,
        epoch: Int,
        status: String,
        extra: [String: Any] = [:]
    ) -> [String: Any]? {
        guard let macIdentity = identity else {
            logger.error("Cannot sign \(type, privacy: .public): no device identity")
            return nil
        }
        let ts = Int(clock.now.timeIntervalSince1970)
        let input = EnvelopeCoding.ackSigningInput(t: type, d: macIdentity.deviceId, e: epoch, id: id, status: status, ts: ts)
        guard let signature = try? macIdentity.signer.signature(for: input) else {
            logger.error("Signing \(type, privacy: .public) failed")
            return nil
        }
        var frame = extra
        frame["v"] = 1
        frame["t"] = type
        frame["d"] = macIdentity.deviceId
        frame["e"] = epoch
        frame["id"] = id
        frame["status"] = status
        frame["ts"] = ts
        frame["sig"] = Base64URL.encode(signature.derRepresentation)
        return frame
    }

    private func handleLockCommandFrame(_ json: [String: Any]) {
        let command: ValidatedCommand
        switch validateSignedCommand(json, type: "cmd.lock") {
        case .success(let validated):
            command = validated
        case .failure(let rejection):
            sendReject(id: rejection.id, reason: rejection.reason, type: "lock.rejected")
            return
        }

        // 8. Execute actual screen lock
        Task {
            let outcome = await performLockNow()
            let ackType = outcome.status.isSuccess ? "lock.ack" : "lock.failed"
            guard let ack = makeSignedAck(
                type: ackType,
                id: command.id,
                epoch: command.epoch,
                status: outcome.status.rawValue,
                extra: [
                    "mechanism": outcome.mechanism.rawValue,
                    "durationMs": outcome.durationMilliseconds,
                    "detail": outcome.detail ?? ""
                ]
            ) else { return }
            sendFrame(ack)
        }
    }

    /// Locks on behalf of the relay's password-gated test/emergency panel.
    ///
    /// Deliberately has no signature or pairing check: judges must be able to lock a demo Mac
    /// without pairing a phone. The relay never forwards `test.*` frames from mobile clients
    /// and only emits this frame from its own password-protected endpoint, while the
    /// WebSocket carrying it is already authenticated as this Mac.
    ///
    /// The Mac answers with an unsigned `test.lock.ack` so the panel can report whether the
    /// screen actually locked instead of only knowing the signal was sent.
    private func handleTestLockFrame(_ json: [String: Any]) {
        guard json["t"] as? String == "test.lock" else { return }
        if let target = json["d"] as? String, let identity, target != identity.deviceId {
            logger.warning("Ignoring test.lock addressed to \(target, privacy: .public)")
            return
        }
        let requestId = (json["id"] as? String) ?? ULID.generate()
        logger.notice("Relay fleet lock requested (id \(requestId, privacy: .public))")

        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.performLockNow()
            self.logger.notice(
                "Fleet lock result \(outcome.status.rawValue, privacy: .public) via \(outcome.mechanism.rawValue, privacy: .public)"
            )
            var ack: [String: Any] = [
                "v": 1,
                "t": "test.lock.ack",
                "id": requestId,
                "status": outcome.status.rawValue,
                "mechanism": outcome.mechanism.rawValue,
                "durationMs": outcome.durationMilliseconds,
                "ts": Int(self.clock.now.timeIntervalSince1970)
            ]
            if let deviceId = self.identity?.deviceId { ack["d"] = deviceId }
            if let detail = outcome.detail { ack["detail"] = detail }
            self.sendFrame(ack)
        }
    }

    private func handleUnlockCommandFrame(_ json: [String: Any]) {
        let command: ValidatedCommand
        switch validateSignedCommand(json, type: "cmd.unlock") {
        case .success(let validated):
            command = validated
        case .failure(let rejection):
            sendReject(id: rejection.id, reason: rejection.reason, type: "unlock.rejected")
            return
        }

        let password = (command.payload["password"] as? String) ?? ""

        Task {
            let outcome = await performUnlockNow(password: password)
            let ackType = outcome.status.isSuccess ? "unlock.ack" : "unlock.failed"
            guard let ack = makeSignedAck(
                type: ackType,
                id: command.id,
                epoch: command.epoch,
                status: outcome.status.rawValue,
                extra: [
                    "mechanism": outcome.mechanism.rawValue,
                    "durationMs": outcome.durationMilliseconds,
                    "detail": outcome.detail ?? ""
                ]
            ) else { return }
            sendFrame(ack)
        }
    }

    private func sendReject(id: String, reason: String, type: String = "lock.rejected") {
        logger.warning("\(type, privacy: .public): \(reason, privacy: .public) for id \(id, privacy: .public)")
        sendFrame([
            "v": 1,
            "t": type,
            "id": id,
            "reason": reason,
            "ts": Int(clock.now.timeIntervalSince1970)
        ])
    }

    private func isDuplicate(id: String) -> Bool {
        deduplicationLock.lock()
        defer { deduplicationLock.unlock() }
        return processedCommandIds.contains(id)
    }

    private func recordProcessedCommand(id: String) {
        deduplicationLock.lock()
        defer { deduplicationLock.unlock() }
        processedCommandIds.insert(id)
        commandIdRingBuffer.append(id)
        if commandIdRingBuffer.count > 500 {
            let removed = commandIdRingBuffer.removeFirst()
            processedCommandIds.remove(removed)
        }
    }

    private func handleUnpairCommandFrame(_ json: [String: Any]) {
        let command: ValidatedCommand
        switch validateSignedCommand(json, type: "cmd.unpair") {
        case .success(let validated):
            command = validated
        case .failure(let rejection):
            logger.warning("Unpair command rejected: \(rejection.reason, privacy: .public)")
            sendFrame([
                "v": 1,
                "t": "unpair.rejected",
                "id": rejection.id,
                "reason": rejection.reason,
                "ts": Int(clock.now.timeIntervalSince1970)
            ])
            return
        }

        do {
            try pairingManager.unpair()
            if let ack = makeSignedAck(type: "unpair.ack", id: command.id, epoch: command.epoch, status: "UNPAIRED") {
                sendFrame(ack)
            }
            refreshPairing()
            publishStatus()
        } catch {
            logger.error("Remote unpair failed: \(error.localizedDescription)")
        }
    }

    private func handleConnectionState(_ state: ConnectionState) {
        mutateStatus { $0.connection = state }
        if case let .failed(reason) = state {
            mutateStatus { $0.lastError = reason }
        }
        publishStatus()
    }

    // MARK: - Environment

    private func observeEnvironment() {
        networkMonitor.onPathChange = { [weak self] satisfied in
            guard let self else { return }
            self.logger.info("Network path \(satisfied ? "available" : "unavailable", privacy: .public)")
            if satisfied {
                self.connection?.reconnectImmediately(reason: "network path available")
            }
        }
        networkMonitor.start()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("System wake detected; reconnecting")
            self?.connection?.reconnectImmediately(reason: "system wake")
        }
    }

    private func refreshPairing() {
        let epoch = pairingStore.currentEpoch
        if let record = pairingStore.load() {
            mutateStatus {
                $0.pairing = .paired(label: record.phoneLabel, epoch: record.epoch, pairedAt: record.pairedAt)
            }
        } else {
            mutateStatus { $0.pairing = .notPaired }
            logger.info("No pairing record (epoch \(epoch)); awaiting Phase 3 pairing")
        }
    }

    private func refreshLaunchAtLogin() {
        let state = loginItems.status()
        mutateStatus {
            $0.launchAtLoginEnabled = state.enabled
            $0.loginItemMechanism = state.mechanism
        }
    }

    // MARK: - Status

    private func mutateStatus(_ mutation: (inout ServiceStatus) -> Void) {
        statusLock.lock()
        mutation(&status)
        statusLock.unlock()
    }

    private func publishStatus() {
        let snapshot = statusSnapshot
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(snapshot)
        }
    }
}
