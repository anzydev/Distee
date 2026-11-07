import CryptoKit
import Darwin
import Foundation

/// Pairing session information created by the Mac when unpaired.
public struct PairingSession: Equatable {
    public let sessionId: String
    public let psk: Data
    public let pairingCode: String
    public let createdAt: Date
    public let expiresAt: Date
    public let qrPayload: String

    public init(
        sessionId: String,
        psk: Data,
        pairingCode: String = "",
        createdAt: Date = Date(),
        ttlSeconds: TimeInterval = 120,
        qrPayload: String
    ) {
        self.sessionId = sessionId
        self.psk = psk
        self.pairingCode = pairingCode.isEmpty ? Self.deriveNumericCode(psk: psk, sid: sessionId) : pairingCode
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(ttlSeconds)
        self.qrPayload = qrPayload
    }

    public static func deriveNumericCode(psk: Data, sid: String) -> String {
        var hash = SHA256()
        hash.update(data: psk)
        hash.update(data: Data(sid.utf8))
        let digest = hash.finalize()
        let prefix = Array(digest.prefix(4))
        let num = (UInt32(prefix[0]) << 24) | (UInt32(prefix[1]) << 16) | (UInt32(prefix[2]) << 8) | UInt32(prefix[3])
        return String(format: "%06u", num % 1_000_000)
    }

    public var formattedCode: String {
        guard pairingCode.count == 6 else { return pairingCode }
        let first = pairingCode.prefix(3)
        let last = pairingCode.suffix(3)
        return "\(first) \(last)"
    }

    public var isExpired: Bool {
        Date() >= expiresAt
    }

    public var secondsRemaining: Int {
        max(0, Int(expiresAt.timeIntervalSince(Date())))
    }
}

/// Incoming pair request from mobile.
public struct PairingRequest: Equatable {
    public let sessionId: String
    public let phoneSignPubKey: String
    public let phoneEcdhPubKey: String
    public let phoneLabel: String
    public let platform: String
    public let timestamp: Int

    public init(
        sessionId: String,
        phoneSignPubKey: String,
        phoneEcdhPubKey: String,
        phoneLabel: String,
        platform: String,
        timestamp: Int
    ) {
        self.sessionId = sessionId
        self.phoneSignPubKey = phoneSignPubKey
        self.phoneEcdhPubKey = phoneEcdhPubKey
        self.phoneLabel = phoneLabel
        self.platform = platform
        self.timestamp = timestamp
    }
}

/// Pairing state machine according to Phase 3 specification.
public enum PairingState: Equatable {
    case unpaired
    case generatingQR
    case pairingAvailable(PairingSession)
    case pairingPending(request: PairingRequest, confirmationCode: String)
    case paired(PairingRecord)
    case pairingExpired
    case pairingFailed(reason: String)
    case revocationPending
}

public enum PairingError: LocalizedError, Equatable {
    case alreadyPaired
    case sessionExpired
    case invalidSession
    case invalidCiphertext
    case badCrypto
    case notInPendingState
    case identityUnavailable
    case pairingInProgress

    public var errorDescription: String? {
        switch self {
        case .alreadyPaired: return "Mac is already paired with an authorized mobile device"
        case .sessionExpired: return "Pairing QR session has expired"
        case .invalidSession: return "Invalid or mismatched pairing session ID"
        case .invalidCiphertext: return "Failed to decrypt pairing payload with PSK"
        case .badCrypto: return "Malformed cryptographic keys in pairing request"
        case .notInPendingState: return "No pairing request is currently pending confirmation"
        case .identityUnavailable: return "Mac device identity is not initialized"
        case .pairingInProgress: return "Another pairing request is already awaiting confirmation"
        }
    }
}

/// Manages pairing session lifecycle, QR code payload generation,
/// device authorization verification, and mutual cryptographic handshake.
public final class PairingManager {
    public private(set) var state: PairingState
    public var onStateChange: ((PairingState) -> Void)?

    private let store: PairingStore
    private let security: SecurityManager
    private let logger: LoggingManager
    private let lock = NSLock()
    private var activeSession: PairingSession?
    private var pendingRequest: PairingRequest?

    public init(
        store: PairingStore = PairingStore(),
        security: SecurityManager = SecurityManager(),
        logger: LoggingManager = .shared
    ) {
        self.store = store
        self.security = security
        self.logger = logger

        if let existing = store.load() {
            self.state = .paired(existing)
        } else {
            self.state = .unpaired
        }
    }

    public var isPaired: Bool {
        if case .paired = state { return true }
        return false
    }

    public var activeRecord: PairingRecord? {
        if case .paired(let record) = state { return record }
        return store.load()
    }

    public var currentSession: PairingSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSession
    }

    // MARK: - QR Session Generation

    /// Discovers the local Wi-Fi / Ethernet IPv4 address of this Mac.
    public static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidate: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if !ip.isEmpty && ip != "127.0.0.1" && !ip.hasPrefix("169.254") {
                        candidate = ip
                        if name == "en0" { return ip }
                    }
                }
            }
        }
        return candidate
    }

    /// Resolves the base URL to encode into the pairing QR code.
    /// Priority: explicit parameter -> DISTEE_WEB_URL env -> ~/.distee_web_url -> production cloud URL -> local LAN IP -> localhost.
    public static func resolveWebBaseURL(preferred: String? = nil, defaultPort: Int = 8799) -> String {
        if let preferred = preferred, !preferred.isEmpty {
            return preferred.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let env = ProcessInfo.processInfo.environment["DISTEE_WEB_URL"], !env.isEmpty {
            return env.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".distee_web_url")
        if let content = try? String(contentsOf: homeURL, encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("https://") {
                return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        // Default to permanent production cloud web app
        return "https://distee.onrender.com"
    }

    /// Initiates a new pairing session with a 120s TTL and generates the QR payload.
    /// Fails if the Mac is already paired.
    public func startPairingSession(
        webBaseURL: String? = nil,
        macDisplayName: String = Host.current().localizedName ?? "Mac"
    ) throws -> PairingSession {
        lock.lock()
        defer { lock.unlock() }

        if store.load() != nil {
            throw PairingError.alreadyPaired
        }

        let identity = try security.loadOrCreateIdentity()

        // 16-byte random session ID
        var sidBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, sidBytes.count, &sidBytes)
        let sid = Base64URL.encode(Data(sidBytes))

        // 32-byte (256-bit) cryptographically secure PSK
        var pskBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, pskBytes.count, &pskBytes)
        let psk = Data(pskBytes)
        let pskString = Base64URL.encode(psk)

        let exp = Int(Date().addingTimeInterval(120).timeIntervalSince1970)
        let macSignPubString = Base64URL.encode(identity.signingPublicKey.rawRepresentation)
        let macEcdhPubString = Base64URL.encode(identity.keyAgreementKey.publicKey.rawRepresentation)
        let encodedName = macDisplayName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Mac"

        let code = PairingSession.deriveNumericCode(psk: psk, sid: sid)

        let queryParams = [
            "v=1",
            "d=\(identity.deviceId)",
            "pk=\(macSignPubString)",
            "ek=\(macEcdhPubString)",
            "sid=\(sid)",
            "k=\(pskString)",
            "exp=\(exp)",
            "c=\(code)",
            "n=\(encodedName)"
        ].joined(separator: "&")

        let baseURL = Self.resolveWebBaseURL(preferred: webBaseURL)
        let qrPayload = "\(baseURL)/#/pair?\(queryParams)"

        let session = PairingSession(
            sessionId: sid,
            psk: psk,
            pairingCode: code,
            ttlSeconds: 120,
            qrPayload: qrPayload
        )

        self.activeSession = session
        self.pendingRequest = nil
        transition(to: .pairingAvailable(session))
        logger.notice("Pairing session \(sid) generated (120s TTL)")
        return session
    }

    public func cancelSession() {
        lock.lock()
        defer { lock.unlock() }
        activeSession = nil
        pendingRequest = nil
        if store.load() == nil {
            transition(to: .unpaired)
        }
    }

    // MARK: - Handshake Processing

    /// Derives the 256-bit PSK encryption key: Kp = HKDF-SHA256(psk, salt=sid, info="distee/pair/v1")
    public static func derivePairingKey(psk: Data, sid: String) -> SymmetricKey {
        let sidData = (try? Base64URL.decode(sid)) ?? Data(sid.utf8)
        let info = Data("distee/pair/v1".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: sidData,
            info: info,
            outputByteCount: 32
        )
    }

    /// Derives the 6-digit confirmation code shown on both Mac and phone screens.
    public static func deriveConfirmationCode(
        psk: Data,
        sid: String,
        phoneSignPub: String,
        phoneEcdhPub: String
    ) -> String {
        let sidData = (try? Base64URL.decode(sid)) ?? Data(sid.utf8)
        let signData = (try? Base64URL.decode(phoneSignPub)) ?? Data(phoneSignPub.utf8)
        let ecdhData = (try? Base64URL.decode(phoneEcdhPub)) ?? Data(phoneEcdhPub.utf8)

        var transcript = Data()
        transcript.append(psk)
        transcript.append(sidData)
        transcript.append(signData)
        transcript.append(ecdhData)

        let digest = SHA256.hash(data: transcript)
        let prefix = Array(digest.prefix(4))
        let num = (UInt32(prefix[0]) << 24) | (UInt32(prefix[1]) << 16) | (UInt32(prefix[2]) << 8) | UInt32(prefix[3])
        let code = num % 1_000_000
        return String(format: "%06u", code)
    }

    /// Processes an incoming `pair.request` frame from the mobile device.
    /// Validates exclusivity, decrypts payload with PSK, and transitions to `.pairingPending`.
    public func handlePairRequest(
        sessionId: String,
        encryptedPayloadBase64: String,
        nonceBase64: String,
        timestamp: Int
    ) throws -> (request: PairingRequest, confirmationCode: String) {
        lock.lock()
        defer { lock.unlock() }

        if store.load() != nil {
            logger.warning("Pairing attempt rejected: Mac is already paired")
            throw PairingError.alreadyPaired
        }

        guard let session = activeSession, session.sessionId == sessionId else {
            logger.warning("Pairing attempt rejected: invalid or inactive session \(sessionId)")
            throw PairingError.invalidSession
        }

        if session.isExpired {
            transition(to: .pairingExpired)
            throw PairingError.sessionExpired
        }

        // Only one phone may claim an unpaired Mac. A second request while the first is still
        // awaiting approval must not replace it, or "Allow" would pair the wrong device.
        if pendingRequest != nil {
            logger.warning("Pairing attempt rejected: another request is awaiting confirmation")
            throw PairingError.pairingInProgress
        }

        let identity = try security.loadOrCreateIdentity()
        let kp = Self.derivePairingKey(psk: session.psk, sid: sessionId)

        guard let ciphertext = try? Base64URL.decode(encryptedPayloadBase64),
              let nonceData = try? Base64URL.decode(nonceBase64),
              let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw PairingError.badCrypto
        }

        let aad = Data("\(sessionId)\(identity.deviceId)pair.request".utf8)

        guard let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)),
              let plaintext = try? AES.GCM.open(sealedBox, using: kp, authenticating: aad) else {
            // Also try sealedBox where ciphertext includes tag or without separate tag
            if let box = try? AES.GCM.SealedBox(combined: nonceData + ciphertext),
               let opened = try? AES.GCM.open(box, using: kp, authenticating: aad) {
                return try parseAndStageRequest(opened, sessionId: sessionId, session: session, timestamp: timestamp)
            }
            logger.error("Pairing request decryption failed with PSK")
            throw PairingError.invalidCiphertext
        }

        return try parseAndStageRequest(plaintext, sessionId: sessionId, session: session, timestamp: timestamp)
    }

    private func parseAndStageRequest(
        _ plaintext: Data,
        sessionId: String,
        session: PairingSession,
        timestamp: Int
    ) throws -> (request: PairingRequest, confirmationCode: String) {
        guard let json = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let phoneSignPub = json["phoneSignPub"] as? String,
              let phoneEcdhPub = json["phoneEcdhPub"] as? String,
              let label = json["label"] as? String else {
            throw PairingError.badCrypto
        }

        let platform = (json["platform"] as? String) ?? "Mobile"
        let request = PairingRequest(
            sessionId: sessionId,
            phoneSignPubKey: phoneSignPub,
            phoneEcdhPubKey: phoneEcdhPub,
            phoneLabel: label,
            platform: platform,
            timestamp: timestamp
        )

        let confCode = Self.deriveConfirmationCode(
            psk: session.psk,
            sid: sessionId,
            phoneSignPub: phoneSignPub,
            phoneEcdhPub: phoneEcdhPub
        )

        self.pendingRequest = request
        transition(to: .pairingPending(request: request, confirmationCode: confCode))
        logger.notice("Pairing request received from '\(label)'; conf code: \(confCode)")
        return (request, confCode)
    }

    /// User confirms on Mac: stores the pairing record and generates the signed `pair.accept` frame.
    public func confirmPairing() throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        guard let request = pendingRequest, let session = activeSession else {
            throw PairingError.notInPendingState
        }

        let nextEpoch = store.currentEpoch + 1
        let identity = try security.loadOrCreateIdentity()

        let record = PairingRecord(
            phoneLabel: request.phoneLabel,
            phoneSigningPublicKey: request.phoneSignPubKey,
            phoneKeyAgreementPublicKey: request.phoneEcdhPubKey,
            epoch: nextEpoch,
            pairedAt: Date()
        )

        // Generate proof signature: Sign(macSignKey, "distee-pair-accept\n" + sid + "\n" + epoch + "\n" + phoneSignPub + "\n" + macSignPub)
        let macSignPubString = Base64URL.encode(identity.signingPublicKey.rawRepresentation)
        let macEcdhPubString = Base64URL.encode(identity.keyAgreementKey.publicKey.rawRepresentation)

        let proofInput = Data("distee-pair-accept\n\(session.sessionId)\n\(nextEpoch)\n\(request.phoneSignPubKey)\n\(macSignPubString)".utf8)
        let signature = try identity.signer.signature(for: proofInput)
        let proofString = Base64URL.encode(signature.derRepresentation)

        let acceptPlaintextData = try JSONSerialization.data(withJSONObject: [
            "epoch": nextEpoch,
            "macSignPub": macSignPubString,
            "macEcdhPub": macEcdhPubString,
            "proof": proofString
        ])

        let kp = Self.derivePairingKey(psk: session.psk, sid: session.sessionId)
        let nonce = try AES.GCM.Nonce(data: EnvelopeCrypto.freshNonce())
        let aad = Data("\(session.sessionId)\(identity.deviceId)pair.accept".utf8)
        let sealed = try AES.GCM.seal(acceptPlaintextData, using: kp, nonce: nonce, authenticating: aad)

        let resCiphertext = Base64URL.encode(sealed.ciphertext + sealed.tag)
        let nonceString = Base64URL.encode(Data(nonce))

        // Persist only after the accept frame has been fully built, so a failure above can
        // never leave the Mac paired to a phone that never received its proof.
        try store.save(record)

        self.activeSession = nil
        self.pendingRequest = nil
        transition(to: .paired(record))
        logger.notice("Pairing confirmed with '\(record.phoneLabel)'; epoch is now \(nextEpoch)")

        return [
            "v": 1,
            "t": "pair.accept",
            "d": identity.deviceId,
            "sid": session.sessionId,
            "res": resCiphertext,
            "n": nonceString,
            "ts": Int(Date().timeIntervalSince1970)
        ]
    }

    /// User or timeout rejects pairing on Mac.
    public func rejectPairing(reason: String = "DENIED") -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let sid = activeSession?.sessionId ?? ""
        pendingRequest = nil
        if let session = activeSession, !session.isExpired {
            transition(to: .pairingAvailable(session))
        } else {
            transition(to: .unpaired)
        }
        logger.notice("Pairing rejected: \(reason)")

        return [
            "v": 1,
            "t": "pair.reject",
            "sid": sid,
            "reason": reason,
            "ts": Int(Date().timeIntervalSince1970)
        ]
    }

    /// Local unpairing initiated on the Mac.
    public func unpair() throws {
        lock.lock()
        defer { lock.unlock() }

        try store.clear()
        activeSession = nil
        pendingRequest = nil
        transition(to: .unpaired)
        logger.notice("Mac locally unpaired. Ready for new pairing.")
    }

    private func transition(to newState: PairingState) {
        self.state = newState
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(newState)
        }
    }
}
