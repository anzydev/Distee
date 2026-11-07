import CryptoKit
import DisteeCore
import Foundation
import Network

/// A minimal WebSocket relay used **only** for local development and tests. It speaks the
/// Phase 1 handshake (`hello` → `auth` → `auth.ok`), answers `ping` with `pong`, and routes
/// nothing else. It is not a backend for the product: the real relay is a Cloudflare Worker
/// built in Phase 3, and this server deliberately cannot verify pairing signatures because
/// it has no pairing registry.
public final class MiniRelayServer {
    public enum ServerFailure: Error {
        case startTimedOut
        case listenerFailed(String)
    }

    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var buffer: [UInt8] = []
        var upgraded = false
        var path = ""

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.distee.mini-relay")
    private let lock = NSLock()
    private var peers: [UUID: Peer] = [:]
    private var challengeByPeer: [UUID: String] = [:]

    public private(set) var port: UInt16 = 0
    public var verbose = false
    public var onText: ((UUID, String) -> Void)?
    /// Captures the last auth frame so tests can verify the client's signature.
    public private(set) var lastAuth: (challenge: String, deviceId: String, epoch: Int, signature: String)?

    public init(port: UInt16 = 0) throws {
        var parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        listener = try NWListener(using: parameters, on: endpointPort)
    }

    public var url: URL {
        URL(string: "ws://127.0.0.1:\(port)")!
    }

    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peers.count
    }

    public func start(timeout: TimeInterval = 5) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let raw = self?.listener.port?.rawValue { self?.port = raw }
                semaphore.signal()
            case let .failed(error):
                failure = ServerFailure.listenerFailed(error.localizedDescription)
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw ServerFailure.startTimedOut
        }
        if let failure { throw failure }
        if verbose {
            print("[relay] listening on \(url.absoluteString)")
        }
    }

    public func stop() {
        listener.cancel()
        lock.lock()
        let current = peers.values.map(\.connection)
        peers.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    /// Simulates a relay restart or network drop by closing every live socket.
    public func dropAllConnections() {
        lock.lock()
        let current = peers.values.map(\.connection)
        peers.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        lock.lock()
        peers[peer.id] = peer
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.remove(peer)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: peer)
    }

    private func remove(_ peer: Peer) {
        lock.lock()
        peers.removeValue(forKey: peer.id)
        challengeByPeer.removeValue(forKey: peer.id)
        lock.unlock()
    }

    private func receive(on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(contentsOf: data)
                self.processBuffer(peer)
            }
            if error != nil || isComplete {
                peer.connection.cancel()
                self.remove(peer)
                return
            }
            self.receive(on: peer)
        }
    }

    private func processBuffer(_ peer: Peer) {
        if !peer.upgraded {
            guard let endRange = findHeaderTerminator(peer.buffer) else { return }
            let headerBytes = Array(peer.buffer[0..<endRange.lowerBound])
            peer.buffer.removeFirst(endRange.upperBound)
            guard let request = String(bytes: headerBytes, encoding: .utf8) else {
                peer.connection.cancel()
                return
            }
            guard performUpgrade(request, on: peer) else {
                peer.connection.cancel()
                return
            }
        }

        while let frame = Self.nextFrame(from: &peer.buffer) {
            handle(frame, on: peer)
        }
    }

    private func findHeaderTerminator(_ bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= 4 else { return nil }
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index..<(index + 4)
            }
            index += 1
        }
        return nil
    }

    private func performUpgrade(_ request: String, on peer: Peer) -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        peer.path = String(parts[1])

        guard let keyLine = lines.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else {
            return false
        }
        let key = keyLine.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let accept = Self.acceptKey(for: key)

        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        peer.upgraded = true

        let challenge = Base64URL.encode(Self.randomBytes(32))
        lock.lock()
        challengeByPeer[peer.id] = challenge
        lock.unlock()

        let deviceId = peer.path.split(separator: "/").last.map(String.init) ?? "unknown"
        sendJSON([
            "t": "hello",
            "challenge": challenge,
            "d": deviceId,
            "ts": Int(Date().timeIntervalSince1970)
        ], to: peer)
        return true
    }

    private static func acceptKey(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    // MARK: - Frames

    private struct Frame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private static func nextFrame(from buffer: inout [UInt8]) -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[0]
        let second = buffer[1]
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var offset = 2

        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = (Int(buffer[offset]) << 8) | Int(buffer[offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var value = 0
            for index in 0..<8 { value = (value << 8) | Int(buffer[offset + index]) }
            length = value
            offset += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<(offset + 4)])
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }

        var payload = Array(buffer[offset..<(offset + length)])
        buffer.removeFirst(offset + length)

        if masked {
            for index in payload.indices {
                payload[index] ^= maskKey[index % 4]
            }
        }
        return Frame(opcode: opcode, payload: payload)
    }

    private func handle(_ frame: Frame, on peer: Peer) {
        switch frame.opcode {
        case 0x1:
            guard let text = String(bytes: frame.payload, encoding: .utf8) else { return }
            handleText(text, on: peer)
        case 0x8:
            sendFrame(opcode: 0x8, payload: [], to: peer)
            peer.connection.cancel()
            remove(peer)
        case 0x9:
            sendFrame(opcode: 0xA, payload: frame.payload, to: peer)
        default:
            break
        }
    }

    private func handleText(_ text: String, on peer: Peer) {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["t"] as? String
        else {
            onText?(peer.id, text)
            return
        }

        switch type {
        case "auth":
            lock.lock()
            let challenge = challengeByPeer[peer.id] ?? ""
            lock.unlock()
            lastAuth = (
                challenge: challenge,
                deviceId: object["d"] as? String ?? "",
                epoch: object["e"] as? Int ?? 0,
                signature: object["sig"] as? String ?? ""
            )
            if verbose { print("[relay] auth from \(object["d"] ?? "?") epoch \(object["e"] ?? "?")") }
            sendJSON(["t": "auth.ok", "ts": Int(Date().timeIntervalSince1970), "presence": "online"], to: peer)
        case "ping":
            sendJSON(["t": "pong", "ts": Int(Date().timeIntervalSince1970)], to: peer)
        default:
            onText?(peer.id, text)
            // Echo unknown frames so a future command path can be exercised locally.
            sendText(text, to: peer)
        }
    }

    private func sendJSON(_ object: [String: Any], to peer: Peer) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text, to: peer)
    }

    private func sendText(_ text: String, to peer: Peer) {
        sendFrame(opcode: 0x1, payload: Array(text.utf8), to: peer)
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8], to peer: Peer) {
        var bytes: [UInt8] = [0x80 | opcode]
        if payload.count <= 125 {
            bytes.append(UInt8(payload.count))
        } else if payload.count <= 65_535 {
            bytes.append(126)
            bytes.append(UInt8((payload.count >> 8) & 0xFF))
            bytes.append(UInt8(payload.count & 0xFF))
        } else {
            bytes.append(127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((count >> UInt64(shift)) & 0xFF))
            }
        }
        bytes.append(contentsOf: payload)
        peer.connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }
}
