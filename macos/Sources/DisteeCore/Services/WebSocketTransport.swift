import Foundation

public enum WebSocketError: Error, Equatable {
    case notConnected
    case closed(code: Int, reason: String?)
    case timedOut(operation: String)
    case protocolViolation(String)
    case transport(String)

    public var describedReason: String {
        switch self {
        case .notConnected: return "Socket is not connected"
        case let .closed(code, reason): return "Socket closed (\(code))\(reason.map { ": \($0)" } ?? "")"
        case let .timedOut(operation): return "Timed out during \(operation)"
        case let .protocolViolation(detail): return "Protocol violation: \(detail)"
        case let .transport(detail): return "Transport error: \(detail)"
        }
    }
}

/// Minimal WebSocket surface the connection manager depends on. Abstracting it keeps the
/// lifecycle logic testable without a network and keeps `URLSession` out of the state machine.
public protocol WebSocketConnecting: AnyObject {
    var maximumMessageSize: Int { get set }
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close(code: Int, reason: String)
}

public protocol WebSocketFactory {
    func makeSocket(url: URL) -> WebSocketConnecting
}

public struct URLSessionSocketFactory: WebSocketFactory {
    public init() {}
    public func makeSocket(url: URL) -> WebSocketConnecting {
        URLSessionSocket(url: url)
    }
}

public enum TimeoutError: Error, Equatable {
    case elapsed(String)
}

/// Runs `operation`, throwing `TimeoutError` if it does not finish in time.
public func withTimeout<T>(
    seconds: TimeInterval,
    operation: String,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TimeoutError.elapsed(operation)
        }
        guard let result = try await group.next() else {
            throw TimeoutError.elapsed(operation)
        }
        group.cancelAll()
        return result
    }
}

/// `URLSessionWebSocketTask` wrapper. Each socket owns its own `URLSession` so the
/// delegate callbacks are unambiguous; the agent holds at most one of these at a time.
public final class URLSessionSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    private let url: URL
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var isOpen = false
    private var terminalError: Error?
    private var finished = false

    public var maximumMessageSize: Int = 16 * 1024 {
        didSet { task?.maximumMessageSize = maximumMessageSize }
    }

    public init(url: URL) {
        self.url = url
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        // Connect/handshake deadlines are enforced by ConnectionManager. These URLSession
        // timeouts also apply to idle WebSocket traffic, so they must outlast the heartbeat
        // interval (60 s) or a quiet-but-healthy connection would be torn down. The resource
        // timeout is left at its default so the long-lived socket is not cut after a minute.
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
    }

    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if let terminalError {
                    lock.unlock()
                    continuation.resume(throwing: terminalError)
                    return
                }
                openContinuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(code: 1000, reason: "cancelled")
        }
    }

    public func send(_ data: Data) async throws {
        lock.lock()
        let error = terminalError
        lock.unlock()
        if let error { throw error }
        do {
            try await task.send(.data(data))
        } catch {
            throw map(error)
        }
    }

    public func receive() async throws -> Data {
        lock.lock()
        let error = terminalError
        lock.unlock()
        if let error { throw error }

        do {
            let message = try await task.receive()
            switch message {
            case .data(let data): return data
            case .string(let string): return Data(string.utf8)
            @unknown default: throw WebSocketError.transport("Unsupported WebSocket message kind")
            }
        } catch {
            throw map(error)
        }
    }

    public func close(code: Int, reason: String) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = openContinuation
        openContinuation = nil
        terminalError = WebSocketError.closed(code: code, reason: reason)
        lock.unlock()

        continuation?.resume(throwing: WebSocketError.closed(code: code, reason: reason))
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        session?.invalidateAndCancel()
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        isOpen = true
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) })
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(code: 1006, reason: error.localizedDescription)
        }
    }

    private func finish(code: Int, reason: String?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let error = WebSocketError.closed(code: code, reason: reason)
        terminalError = error
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func map(_ error: Error) -> Error {
        if let webSocketError = error as? WebSocketError { return webSocketError }
        if error is CancellationError { return WebSocketError.transport("Cancelled") }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return WebSocketError.timedOut(operation: "socket")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return WebSocketError.transport(nsError.localizedDescription)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return WebSocketError.transport("TLS handshake failed (possible captive portal)")
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return WebSocketError.transport("ATS blocked an insecure connection")
            default: return WebSocketError.transport(nsError.localizedDescription)
            }
        }
        return WebSocketError.transport(error.localizedDescription)
    }
}
