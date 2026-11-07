import CryptoKit
import Foundation

public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, delay: TimeInterval)
    case failed(reason: String)

    public var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case let .reconnecting(attempt, _): return "Reconnecting (attempt \(attempt))"
        case .failed: return "Failed"
        }
    }

    public var isConnected: Bool { self == .connected }
}

/// Challenge–response proof for the relay. A copied URL grants nothing.
public struct RelayAuthenticator {
    public static let authTag = "distee-auth-v1"
    public let deviceId: String
    public let epoch: Int
    public let signer: EnvelopeSigner

    public init(deviceId: String, epoch: Int, signer: EnvelopeSigner) {
        self.deviceId = deviceId
        self.epoch = epoch
        self.signer = signer
    }

    public func signingInput(challenge: String) -> Data {
        Data("\(Self.authTag)\n\(challenge)\n\(deviceId)\n\(epoch)".utf8)
    }

    public func proof(challenge: String) throws -> String {
        let signature = try signer.signature(for: signingInput(challenge: challenge))
        return Base64URL.encode(signature.derRepresentation)
    }
}

struct HelloFrame: Codable {
    var t: String
    var challenge: String?
    var d: String?
    var e: Int?
    var ts: Int?
    var reason: String?
}

struct AuthFrame: Codable {
    var t: String = "auth"
    var v: Int = 1
    var d: String
    var e: Int
    var sig: String
    var pk: String
}

struct AuthReply: Codable {
    var t: String
    var reason: String?
    var presence: String?
    var ts: Int?
}

struct PingFrame: Codable {
    var t: String = "ping"
    var ts: Int
}

/// Owns the WebSocket lifecycle: connect, authenticate, heartbeat, watchdog, reconnect.
///
/// It knows nothing about commands or locking; it delivers bytes. All state transitions are
/// reported through `onStateChange` so the UI never has to poll.
public final class ConnectionManager {
    public struct Options {
        public var url: URL
        public var heartbeatInterval: TimeInterval = 60
        public var watchdogTimeout: TimeInterval = 150
        public var connectTimeout: TimeInterval = 15
        public var handshakeTimeout: TimeInterval = 10
        public var backoff = BackoffPolicy()
        public var maximumFrameSize = 16 * 1024

        public init(url: URL) {
            self.url = url
        }
    }

    private let options: Options
    private let factory: WebSocketFactory
    private let authenticator: RelayAuthenticator
    private let logger: LoggingManager
    private let clock: Clock
    private let jitter: () -> Double
    private let sleep: (TimeInterval) async -> Void

    private let stateLock = NSLock()
    private var currentState: ConnectionState = .disconnected
    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var backoffSleep: Task<Void, Never>?
    private var socket: WebSocketConnecting?
    private var lastFrameAt: Date
    private var onlineSince: Date?
    private var attempt = 0
    private var shouldRun = false

    public var onStateChange: ((ConnectionState) -> Void)?
    public var onMessage: ((Data) -> Void)?

    public init(
        options: Options,
        authenticator: RelayAuthenticator,
        factory: WebSocketFactory = URLSessionSocketFactory(),
        logger: LoggingManager = .shared,
        clock: Clock = SystemClock(),
        jitter: @escaping () -> Double = { Double.random(in: -1...1) },
        sleep: @escaping (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        self.options = options
        self.authenticator = authenticator
        self.factory = factory
        self.logger = logger
        self.clock = clock
        self.jitter = jitter
        self.sleep = sleep
        self.lastFrameAt = clock.now
    }

    public var state: ConnectionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    public var isConnected: Bool { state == .connected }

    public func start() {
        stateLock.lock()
        guard !shouldRun else {
            stateLock.unlock()
            return
        }
        shouldRun = true
        attempt = 0
        stateLock.unlock()

        logger.info("Connection manager starting for \(self.options.url.host ?? "unknown", privacy: .public)")
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        stateLock.lock()
        shouldRun = false
        let loop = loopTask
        loopTask = nil
        backoffSleep?.cancel()
        backoffSleep = nil
        let activeSocket = socket
        socket = nil
        stateLock.unlock()

        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        loop?.cancel()
        activeSocket?.close(code: 1000, reason: "shutdown")
        setState(.disconnected)
        logger.info("Connection manager stopped")
    }

    /// Wake and path changes skip the remaining backoff delay.
    public func reconnectImmediately(reason: String) {
        logger.info("Immediate reconnect requested: \(reason, privacy: .public)")
        stateLock.lock()
        let sleeping = backoffSleep
        backoffSleep = nil
        stateLock.unlock()
        sleeping?.cancel()

        stateLock.lock()
        let activeSocket = socket
        stateLock.unlock()
        if case .connected = state {
            // Force a fresh handshake rather than waiting for the watchdog.
            activeSocket?.close(code: 1001, reason: "reconnect requested")
        }
    }

    public func send(_ data: Data) async throws {
        stateLock.lock()
        let activeSocket = socket
        let connected = currentState == .connected
        stateLock.unlock()

        guard connected, let activeSocket else {
            throw WebSocketError.notConnected
        }
        try await activeSocket.send(data)
    }

    // MARK: - Loop

    private func runLoop() async {
        while isRunning {
            let socket = factory.makeSocket(url: options.url)
            socket.maximumMessageSize = options.maximumFrameSize

            stateLock.lock()
            let isFirstAttempt = attempt == 0
            self.socket = socket
            stateLock.unlock()

            setState(isFirstAttempt ? .connecting : .reconnecting(attempt: attempt, delay: 0))

            do {
                try await withTimeout(seconds: options.connectTimeout, operation: "connect") {
                    try await socket.connect()
                }
                try await performHandshake(on: socket)
                try await runConnectedSession(on: socket)
            } catch is CancellationError {
                socket.close(code: 1000, reason: "cancelled")
                break
            } catch let failure as ConnectionFailure {
                socket.close(code: failure.closeCode, reason: failure.reason)
                stateLock.lock()
                self.socket = nil
                stateLock.unlock()

                if failure.isTerminal {
                    logger.error("Connection failed permanently: \(failure.reason, privacy: .public)")
                    setState(.failed(reason: failure.reason))
                    return
                }
                logger.warning("Connection ended: \(failure.reason, privacy: .public)")
            } catch {
                if let webSocketError = error as? WebSocketError,
                   case let .closed(code, reason) = webSocketError {
                    socket.close(code: code, reason: reason ?? "dropped")
                    if code == 4401 || code == 4403 {
                        let reasonStr = code == 4401 ? "EPOCH_MISMATCH" : "BAD_SIGNATURE"
                        logger.error("Relay rejected this device (\(reasonStr, privacy: .public)); re-pairing required")
                        setState(.failed(reason: "Relay rejected this device (\(reasonStr)). Re-pair this Mac."))
                        return
                    }
                } else {
                    socket.close(code: 1011, reason: "error")
                }
                stateLock.lock()
                self.socket = nil
                stateLock.unlock()

                logger.warning("Connection error: \(describe(error), privacy: .public)")
            }

            // The session is over: stop its heartbeat and watchdog so they do not keep
            // pinging a dead socket (and logging spurious watchdog drops) during backoff.
            heartbeatTask?.cancel()
            watchdogTask?.cancel()

            guard isRunning else { break }
            await waitBeforeRetry()
        }

        setState(.disconnected)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldRun && !Task.isCancelled
    }

    private func waitBeforeRetry() async {
        stateLock.lock()
        // A connection that stayed up long enough resets the ladder.
        if let onlineSince, clock.now.timeIntervalSince(onlineSince) >= options.backoff.resetAfterOnline {
            attempt = 0
        }
        attempt += 1
        let attemptNumber = attempt
        onlineSince = nil
        stateLock.unlock()

        let delay = options.backoff.delay(forAttempt: attemptNumber, jitter: jitter())
        setState(.reconnecting(attempt: attemptNumber, delay: delay))
        logger.info("Reconnect attempt \(attemptNumber) in \(String(format: "%.1f", delay)) s")

        let task = Task { [sleep] in
            await sleep(delay)
        }
        stateLock.lock()
        backoffSleep = task
        stateLock.unlock()
        await task.value
        // DispatchQueue.main not required; clearing the handle is enough.
        stateLock.lock()
        backoffSleep = nil
        stateLock.unlock()
    }

    private func performHandshake(on socket: WebSocketConnecting) async throws {
        let helloData = try await withTimeout(seconds: options.handshakeTimeout, operation: "hello") {
            try await socket.receive()
        }
        guard let hello = try? JSONDecoder().decode(HelloFrame.self, from: helloData), hello.t == "hello" else {
            throw ConnectionFailure(reason: "Unexpected greeting", closeCode: 1011)
        }
        guard let challenge = hello.challenge else {
            throw ConnectionFailure(reason: "Missing challenge", closeCode: 1011)
        }

        let signature = try authenticator.proof(challenge: challenge)
        let publicKey = Base64URL.encode(authenticator.signer.publicKey.x963Representation)
        let auth = AuthFrame(d: authenticator.deviceId, e: authenticator.epoch, sig: signature, pk: publicKey)
        try await socket.send(try JSONEncoder().encode(auth))

        let replyData = try await withTimeout(seconds: options.handshakeTimeout, operation: "auth") {
            try await socket.receive()
        }
        guard let reply = try? JSONDecoder().decode(AuthReply.self, from: replyData) else {
            throw ConnectionFailure(reason: "Malformed auth reply", closeCode: 1011)
        }

        switch reply.t {
        case "auth.ok":
            break
        case "error":
            throw ConnectionFailure(
                reason: reply.reason ?? "Authentication rejected",
                closeCode: connectionFailureCode(for: reply.reason),
                isTerminal: true
            )
        default:
            throw ConnectionFailure(reason: "Unexpected auth reply: \(reply.t)", closeCode: 1011)
        }

        stateLock.lock()
        lastFrameAt = clock.now
        onlineSince = clock.now
        stateLock.unlock()

        logger.notice("Authenticated with relay; presence \(reply.presence ?? "unknown", privacy: .public)")
        setState(.connected)
        startHeartbeat(on: socket)
        startWatchdog(on: socket)
    }

    private func runConnectedSession(on socket: WebSocketConnecting) async throws {
        while isRunning {
            let data = try await socket.receive()
            stateLock.lock()
            lastFrameAt = clock.now
            stateLock.unlock()

            if handleControlFrame(data) { continue }
            onMessage?(data)
        }
    }

    private func handleControlFrame(_ data: Data) -> Bool {
        guard let frame = try? JSONDecoder().decode(AuthReply.self, from: data) else { return false }
        switch frame.t {
        case "pong", "peer.joined", "peer.left":
            return true
        case "error":
            logger.error("Relay error frame: \(frame.reason ?? "unspecified", privacy: .public)")
            return true
        default:
            return false
        }
    }

    private func startHeartbeat(on socket: WebSocketConnecting) {
        heartbeatTask?.cancel()
        let interval = options.heartbeatInterval
        let clock = clock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                do {
                    let frame = try JSONEncoder().encode(PingFrame(ts: clock.unixTime))
                    try await socket.send(frame)
                } catch {
                    self?.logger.warning("Heartbeat send failed: \(String(describing: error), privacy: .public)")
                    socket.close(code: 1001, reason: "heartbeat failed")
                    return
                }
            }
        }
    }

    private func startWatchdog(on socket: WebSocketConnecting) {
        watchdogTask?.cancel()
        let timeout = options.watchdogTimeout
        let checkInterval = min(15, max(1, timeout / 3))
        let clock = clock
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.stateLock.lock()
                let last = self.lastFrameAt
                self.stateLock.unlock()
                if clock.now.timeIntervalSince(last) > timeout {
                    self.logger.warning("Watchdog: no frame for \(String(format: "%.0f", clock.now.timeIntervalSince(last))) s; dropping socket")
                    socket.close(code: 1001, reason: "watchdog timeout")
                    return
                }
            }
        }
    }

    private func connectionFailureCode(for reason: String?) -> Int {
        switch reason {
        case "EPOCH_MISMATCH": return 4401
        case "BAD_SIGNATURE": return 4403
        case "RATE_LIMITED": return 4429
        case "PROTOCOL_ERROR": return 4400
        default: return 1011
        }
    }

    private func setState(_ newState: ConnectionState) {
        stateLock.lock()
        guard currentState != newState else {
            stateLock.unlock()
            return
        }
        currentState = newState
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    private func describe(_ error: Error) -> String {
        if let webSocketError = error as? WebSocketError { return webSocketError.describedReason }
        if let timeout = error as? TimeoutError {
            switch timeout {
            case let .elapsed(operation): return "Timeout during \(operation)"
            }
        }
        return error.localizedDescription
    }
}

/// A connection failure that must not be retried.
struct ConnectionFailure: Error {
    let reason: String
    let closeCode: Int
    var isTerminal: Bool = false
}
