import DisteeCore
import Foundation

/// Scriptable socket: each `receive()` pops the next scripted step, or waits for the socket
/// to be closed. Records everything the manager sends so tests can assert on the wire bytes.
final class ScriptedSocket: WebSocketConnecting {
    struct Step {
        var data: Data?
        var error: WebSocketError?
        var delay: TimeInterval = 0
    }

    var maximumMessageSize: Int = 16 * 1024
    let url: URL
    var connectionError: Error?
    var onSend: ((Data, ScriptedSocket) -> Void)?

    private let lock = NSLock()
    private var steps: [Step] = []
    private var sentFrames: [Data] = []
    private var closeInfo: (code: Int, reason: String)?
    private var connectCount = 0
    private var closed = false

    init(url: URL) {
        self.url = url
    }

    var sent: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames
    }

    var close: (code: Int, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        return closeInfo
    }

    var connects: Int {
        lock.lock()
        defer { lock.unlock() }
        return connectCount
    }

    func push(_ data: Data, delay: TimeInterval = 0) {
        lock.lock()
        steps.append(Step(data: data, delay: delay))
        lock.unlock()
    }

    func pushJSON(_ object: [String: Any], delay: TimeInterval = 0) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        push(data, delay: delay)
    }

    func failNextReceive(with error: WebSocketError) {
        lock.lock()
        steps.append(Step(error: error))
        lock.unlock()
    }

    // MARK: - WebSocketConnecting

    func connect() async throws {
        lock.lock()
        connectCount += 1
        lock.unlock()
        if let connectionError { throw connectionError }
    }

    func send(_ data: Data) async throws {
        lock.lock()
        sentFrames.append(data)
        lock.unlock()
        onSend?(data, self)
    }

    func receive() async throws -> Data {
        while true {
            lock.lock()
            if !steps.isEmpty {
                let step = steps.removeFirst()
                let isClosed = closed
                let info = closeInfo
                lock.unlock()
                if step.delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                }
                if let error = step.error { throw error }
                if let data = step.data { return data }
                if isClosed { throw WebSocketError.closed(code: info?.code ?? 1006, reason: info?.reason) }
                continue
            }
            let info = closeInfo
            let isClosed = closed
            lock.unlock()

            if isClosed {
                throw WebSocketError.closed(code: info?.code ?? 1006, reason: info?.reason)
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func close(code: Int, reason: String) {
        lock.lock()
        closed = true
        closeInfo = (code, reason)
        lock.unlock()
    }
}

/// Factory that hands out scripted sockets in order and records them for assertions.
final class ScriptedSocketFactory: WebSocketFactory {
    private let lock = NSLock()
    private var sockets: [ScriptedSocket] = []
    private var created: [ScriptedSocket] = []
    private let configure: (Int, ScriptedSocket) -> Void

    init(count: Int = 1, configure: @escaping (Int, ScriptedSocket) -> Void = { _, _ in }) {
        self.configure = configure
        _ = count
    }

    func makeSocket(url: URL) -> WebSocketConnecting {
        let socket = ScriptedSocket(url: url)
        lock.lock()
        let index = created.count
        created.append(socket)
        sockets.append(socket)
        lock.unlock()
        configure(index, socket)
        return socket
    }

    var all: [ScriptedSocket] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    var latest: ScriptedSocket? {
        lock.lock()
        defer { lock.unlock() }
        return created.last
    }
}

enum TestFrames {
    static func hello(challenge: String = "Y2hhbGxlbmdlLWJ5dGVzLTAxMjM0NTY3ODk") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "t": "hello",
            "challenge": challenge,
            "ts": 1_760_000_000
        ])
    }

    static func authOK() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "t": "auth.ok",
            "ts": 1_760_000_000,
            "presence": "online"
        ])
    }

    static func error(_ reason: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["t": "error", "reason": reason])
    }

    static func pong() -> Data {
        try! JSONSerialization.data(withJSONObject: ["t": "pong", "ts": 1_760_000_001])
    }
}
